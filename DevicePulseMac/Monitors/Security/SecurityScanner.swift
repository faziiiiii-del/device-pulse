//
//  SecurityScanner.swift
//  DevicePulseMac
//
//  Orchestrates a security scan: walks a bounded set of locations,
//  identifies executable content, and hands anything unsigned/invalid
//  off to code-signing + quarantine inspection to become a Finding.
//  Deliberately does NOT scan the whole filesystem — only the locations
//  listed below, subject to whatever macOS permissions allow.
//
//  RISK MODEL: every finding here comes from a combination of real,
//  observable signals (signature validity, location, recency,
//  persistence) — never an invented score. `classifyRisk` is the single
//  place that turns those signals into Low/Medium/High. Critical is
//  reserved entirely for a verified hash match against a configured
//  threat-intelligence source; since no such source is wired in, this
//  scanner never produces a Critical finding on its own.
//

import Foundation
import CryptoKit

/// Thread-safe cancellation flag shared between a background scan task
/// and the Cancel button on the main thread.
final class SecurityScanCancellationToken {
    private let lock = NSLock()
    private var _isCancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isCancelled
    }

    func cancel() {
        lock.lock(); _isCancelled = true; lock.unlock()
    }
}

enum SecuritySHA256 {
    /// Streams the file in 1 MB chunks rather than loading it whole, and
    /// gives up past `maxBytes` (default 200 MB) rather than stalling a
    /// scan on one huge file.
    static func hash(ofFileAt path: String, maxBytes: Int64 = 200_000_000) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        var totalRead: Int64 = 0
        while true {
            guard let chunk = try? handle.read(upToCount: 1_048_576), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            totalRead += Int64(chunk.count)
            if totalRead > maxBytes { return nil }
        }
        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }
}

enum SecurityScanner {
    private static let recentThresholdDays = 14
    private static let scriptExtensions: Set<String> = ["sh", "command", "py", "pl", "rb", "zsh", "bash", "js"]

    /// A cap on findings, not on files scanned — without this, a
    /// pathological case (thousands of legitimately-unsigned scripts in
    /// dependency trees the directory-name filter below didn't catch)
    /// could still hand SwiftUI an unbounded list to render. Scanning
    /// keeps counting real files/coverage past this point; it just stops
    /// accumulating more findings.
    private static let maxFindings = 300

    /// Directories that are almost always full of legitimately-unsigned,
    /// machine-generated executable content (package manager caches,
    /// build output, VCS internals) — descending into these during a
    /// home-directory Deep Scan produced thousands of noise findings
    /// (and, combined with rendering them all, was the direct cause of
    /// the app hanging after a scan). None of Quick Scan's locations
    /// (Downloads/Desktop/Applications/LaunchAgents) are affected by
    /// this, since it only applies to the recursive home-directory walk.
    private static let excludedDirectoryNames: Set<String> = [
        "node_modules", ".git", ".svn", ".hg", "venv", ".venv", "env", ".tox",
        "Pods", "DerivedData", ".build", "build", "target", "vendor",
        ".cache", ".npm", ".cargo", ".rustup", "dist", ".next", ".gradle",
        // Developer version/toolchain managers — each owns a directory tree
        // full of legitimately-unsigned shims/binaries for every installed
        // runtime version, which produced dozens of "suspicious executable"
        // findings for completely ordinary developer machines during
        // testing (rbenv/pyenv/nvm shims specifically — none of these are
        // ever code-signed, that's not a signal, it's just how they work).
        ".rbenv", ".pyenv", ".nvm", ".rvm", ".asdf", ".volta", ".sdkman",
        ".docker", ".gem", ".yarn", ".pnpm-store",
    ]

    static func quickScanLocations() -> [String] {
        let home = NSHomeDirectory()
        return [
            "\(home)/Downloads",
            "\(home)/Desktop",
            "/Applications",
            "\(home)/Applications",
            "\(home)/Library/LaunchAgents",
            "/Library/LaunchAgents",
            "/Library/LaunchDaemons",
        ]
    }

    /// Walking the whole home directory recursively already subsumes
    /// Downloads/Desktop/~/Applications/~/Library/*, so Deep Scan adds
    /// that instead of listing every subfolder separately.
    static func deepScanLocations() -> [String] {
        let home = NSHomeDirectory()
        return [home, "/Applications", "/Library/LaunchAgents", "/Library/LaunchDaemons"]
    }

    static func scan(
        kind: SecurityScanKind,
        token: SecurityScanCancellationToken,
        onProgress: @escaping (SecurityScanProgress) -> Void
    ) -> SecurityScanResult {
        var result = SecurityScanResult(kind: kind, startedAt: Date())
        var visited = Set<String>()
        let locations = kind == .quick ? quickScanLocations() : deepScanLocations()
        let fileLimit = kind == .quick ? 20_000 : 200_000
        let ignored = SecurityIgnoreList.all()

        for location in locations {
            if token.isCancelled { result.wasCancelled = true; break }
            scanLocation(location, fileLimit: fileLimit, ignored: ignored, token: token, result: &result, visited: &visited, onProgress: onProgress)
        }

        if !token.isCancelled {
            onProgress(SecurityScanProgress(currentLocation: "Persistence", currentItem: "Launch items", filesScanned: result.filesScanned))
            result.findings.append(contentsOf: scanPersistence().filter { !ignored.contains($0.path) })
        }

        result.finishedAt = Date()
        return result
    }

    private static func scanLocation(
        _ path: String, fileLimit: Int, ignored: Set<String>, token: SecurityScanCancellationToken,
        result: inout SecurityScanResult, visited: inout Set<String>,
        onProgress: @escaping (SecurityScanProgress) -> Void
    ) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            return // location genuinely doesn't exist on this Mac — not a permission failure, nothing to report
        }

        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path), includingPropertiesForKeys: resourceKeys, options: [.skipsPackageDescendants]
        ) else {
            result.skippedLocations.append(.init(path: path, reason: "macOS denied access to this location. Full Disk Access may be required — see Security ▸ Permissions."))
            return
        }

        result.scannedLocations.append(path)
        let rootName = (path as NSString).lastPathComponent

        for case let itemURL as URL in enumerator {
            if token.isCancelled { result.wasCancelled = true; return }
            if result.filesScanned >= fileLimit { return }

            let itemPath = itemURL.standardizedFileURL.path
            guard !visited.contains(itemPath) else { continue }
            visited.insert(itemPath)

            guard let values = try? itemURL.resourceValues(forKeys: Set(resourceKeys)) else {
                result.filesSkipped += 1
                continue
            }

            // Never traverse or resolve symlink targets — report presence only, don't follow.
            if values.isSymbolicLink == true { continue }

            if values.isDirectory == true, excludedDirectoryNames.contains(itemURL.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }

            result.filesScanned += 1
            if result.filesScanned % 250 == 0 {
                onProgress(SecurityScanProgress(currentLocation: rootName, currentItem: itemURL.lastPathComponent, filesScanned: result.filesScanned))
            }

            if itemURL.pathExtension == "app" {
                if ignored.contains(itemPath) {
                    // still counted as scanned/covered — just not re-reported
                } else if result.findings.count < maxFindings {
                    if let finding = inspectAppBundle(itemURL) { result.findings.append(finding) }
                } else {
                    result.findingsTruncated = true
                }
                continue
            }
            guard values.isDirectory != true else { continue }

            if isLikelyExecutable(itemURL), !ignored.contains(itemPath) {
                if result.findings.count < maxFindings {
                    if let finding = inspectLooseExecutable(itemURL, values: values, scannedRoot: path) {
                        result.findings.append(finding)
                    }
                } else {
                    result.findingsTruncated = true
                }
            }
        }
        onProgress(SecurityScanProgress(currentLocation: rootName, currentItem: "", filesScanned: result.filesScanned))
    }

    /// `FileManager.isExecutableFile` alone is far too broad a signal —
    /// all sorts of ordinary downloaded content (archive contents, media
    /// tooling sidecar files, anything that carried its source
    /// permissions through an extraction) ends up with the executable
    /// bit set without ever being a program. Requiring an actual Mach-O
    /// binary for the executable-bit path is what keeps a real Downloads
    /// folder from producing thousands of false positives.
    private static func isLikelyExecutable(_ url: URL) -> Bool {
        if scriptExtensions.contains(url.pathExtension.lowercased()) { return true }
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return false }
        return isMachOBinary(url)
    }

    private static let machOMagicNumbers: Set<UInt32> = [
        0xFEEDFACE, 0xFEEDFACF, // 32/64-bit Mach-O
        0xCEFAEDFE, 0xCFFAEDFE, // byte-swapped 32/64-bit Mach-O
        0xCAFEBABE, 0xBEBAFECA, // fat/universal binary
    ]

    private static func isMachOBinary(_ url: URL) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4), data.count == 4 else { return false }
        let magic = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return machOMagicNumbers.contains(magic)
    }

    /// The single place that turns observed signals into a risk tier.
    /// `isInvalid` (a tampered/broken signature) always lands at High —
    /// everything else scales with how many independent suspicious
    /// indicators are present. Critical is never produced here; it's
    /// reserved for a verified match against a real threat database.
    private static func classifyRisk(isInvalid: Bool, hasPersistence: Bool, isUnusualLocation: Bool, isRecent: Bool) -> SecurityRiskLevel {
        if isInvalid { return .high }
        var indicators = 0
        if hasPersistence { indicators += 1 }
        if isUnusualLocation { indicators += 1 }
        if isRecent { indicators += 1 }
        switch indicators {
        case 0: return .low
        case 1: return .medium
        default: return .high
        }
    }

    private static func isRecent(_ date: Date?) -> Bool {
        guard let date else { return false }
        return Date().timeIntervalSince(date) < Double(recentThresholdDays * 86_400)
    }

    private static func inspectAppBundle(_ url: URL) -> SecurityFinding? {
        let path = url.path
        let signing = SecurityCodeSigningScanner.inspect(path: path)
        guard signing.status == .unsigned || signing.status == .invalid else { return nil }

        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let created = attrs?[.creationDate] as? Date
        let modified = attrs?[.modificationDate] as? Date
        let quarantine = SecurityQuarantineManager.inspectQuarantineAttribute(path: path)
        let recent = isRecent(created)

        // Being unsigned is not, by itself, a reason to report a finding — the vast
        // majority of legitimate indie/open-source Mac apps are unsigned, and an app
        // that's sat in /Applications for months, was never flagged by macOS's own
        // quarantine (i.e. it already passed the user's own Gatekeeper "are you sure"
        // decision at some point), and hasn't been touched recently is indistinguishable
        // from an app the user has already reviewed and decided to trust. Only report
        // when there's an actual additional signal: a broken/tampered signature (always
        // worth surfacing), still-quarantined-by-macOS (never actually cleared), or very
        // recent (installed/modified in the last two weeks, still worth a first look).
        let hasSignal = signing.status == .invalid || quarantine == .quarantinedByMacOS || recent
        guard hasSignal else { return nil }

        let risk = classifyRisk(isInvalid: signing.status == .invalid, hasPersistence: false, isUnusualLocation: false, isRecent: recent)

        let reason = signing.status == .invalid
            ? "This app's code signature does not validate — it may have been modified after it was signed."
            : "This app isn't signed by Apple or a registered developer identity. Unsigned apps aren't automatically unsafe, but Device Pulse can't verify who built it."

        // Only fetched here — for the small number of apps actually being
        // flagged — never for every signed app in the scan. See the note
        // in SecurityCodeSigningScanner.inspect(path:).
        let gatekeeper = SecurityCodeSigningScanner.gatekeeperAssessment(path: path)

        return SecurityFinding(
            name: url.deletingPathExtension().lastPathComponent, path: path,
            type: signing.status == .invalid ? .invalidSignature : .unsignedExecutable,
            risk: risk, reason: reason, detectionMethod: "Code-signing inspection (Security framework)",
            signatureStatus: signing.status, developerName: signing.developerName, teamID: signing.teamID,
            gatekeeperAssessment: gatekeeper, quarantineStatus: quarantine,
            createdDate: created, modifiedDate: modified
        )
    }

    private static func inspectLooseExecutable(_ url: URL, values: URLResourceValues, scannedRoot: String) -> SecurityFinding? {
        let path = url.path
        let signing = SecurityCodeSigningScanner.inspect(path: path)
        guard signing.status == .unsigned || signing.status == .invalid else { return nil }

        let quarantine = SecurityQuarantineManager.inspectQuarantineAttribute(path: path)
        let created = values.creationDate
        let recent = isRecent(created)
        let unusualLocation = scannedRoot.hasSuffix("/Downloads") || scannedRoot.hasSuffix("/Desktop")
        let isScript = scriptExtensions.contains(url.pathExtension.lowercased())

        // Scripts are *never* code-signed — that's simply how interpreted scripts work,
        // not a suspicious property — so "unsigned" alone would otherwise flag every
        // personal shell/Python script a developer has ever written, anywhere in their
        // home directory, forever. Same logic as inspectAppBundle: only report when
        // there's a real additional signal beyond "unsigned": a broken signature, sitting
        // directly in Downloads/Desktop rather than wherever the user actually keeps their
        // tools, still marked quarantined by macOS (i.e. downloaded and never opened/
        // cleared), or created within the last two weeks. An old script living quietly in
        // ~/bin or a project's scripts/ folder — the overwhelming common case — is not a
        // security finding, it's just a script.
        let hasSignal = signing.status == .invalid || unusualLocation || recent || quarantine == .quarantinedByMacOS
        guard hasSignal else { return nil }

        let risk = classifyRisk(isInvalid: signing.status == .invalid, hasPersistence: false, isUnusualLocation: unusualLocation, isRecent: recent)

        var reasonParts: [String] = [
            signing.status == .invalid ? "Code signature does not validate." : "Not signed by any developer identity."
        ]
        if unusualLocation {
            reasonParts.append("Located directly in \(scannedRoot.hasSuffix("Desktop") ? "Desktop" : "Downloads"), not inside an Applications folder.")
        }
        if isScript { reasonParts.append("Is a script that macOS will run directly if executed.") }
        if recent { reasonParts.append("Created within the last \(recentThresholdDays) days.") }
        if quarantine == .quarantinedByMacOS { reasonParts.append("Still marked by macOS as recently downloaded.") }

        let sha = SecuritySHA256.hash(ofFileAt: path)

        return SecurityFinding(
            name: url.lastPathComponent, path: path,
            type: isScript ? .suspiciousScript : .unsignedExecutable,
            risk: risk, reason: reasonParts.joined(separator: " "),
            detectionMethod: isScript ? "Script content inspection" : "Executable-bit + code-signing inspection",
            signatureStatus: signing.status, developerName: signing.developerName, teamID: signing.teamID,
            quarantineStatus: quarantine, sha256: sha, hashReputation: sha != nil ? .unavailable : nil,
            fileSizeBytes: values.fileSize.map(Int64.init), createdDate: created, modifiedDate: values.contentModificationDate
        )
    }

    private static func scanPersistence() -> [SecurityFinding] {
        var findings: [SecurityFinding] = []
        for item in SecurityPersistenceScanner.scan() {
            guard let program = item.programPath, FileManager.default.fileExists(atPath: program) else { continue }

            let signing = SecurityCodeSigningScanner.inspect(path: program)
            guard signing.status == .unsigned || signing.status == .invalid else { continue }

            let attrs = try? FileManager.default.attributesOfItem(atPath: program)
            let created = attrs?[.creationDate] as? Date
            let modified = attrs?[.modificationDate] as? Date
            let recent = isRecent(created)
            let quarantine = SecurityQuarantineManager.inspectQuarantineAttribute(path: program)
            let risk = classifyRisk(isInvalid: signing.status == .invalid, hasPersistence: true, isUnusualLocation: false, isRecent: recent)
            let sha = SecuritySHA256.hash(ofFileAt: program)

            let signatureDesc = signing.status == .invalid ? "signed with a signature that does not validate" : "unsigned"
            var reason = "Configured to launch automatically (\(item.owner)) and runs \(program), which is \(signatureDesc)."
            if recent { reason += " Added within the last \(recentThresholdDays) days." }

            findings.append(SecurityFinding(
                name: item.label, path: item.plistPath, type: .suspiciousPersistence, risk: risk, reason: reason,
                detectionMethod: "launchd persistence scan + code-signing inspection",
                signatureStatus: signing.status, developerName: signing.developerName, teamID: signing.teamID,
                quarantineStatus: quarantine, sha256: sha, hashReputation: sha != nil ? .unavailable : nil,
                fileSizeBytes: attrs?[.size] as? Int64, createdDate: created, modifiedDate: modified,
                persistenceLabel: item.label, persistenceDomainTarget: item.domainTarget
            ))
        }
        return findings
    }
}

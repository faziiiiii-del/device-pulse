//
//  SecurityCodeSigningScanner.swift
//  DevicePulseMac
//
//  Code-signing inspection via the public Security framework
//  (SecStaticCode) — the same underlying mechanism Gatekeeper itself
//  uses, not a heuristic. Distinguishes Apple-signed, validly-signed
//  third-party, unsigned, and invalid/tampered signatures. An unsigned
//  file is NOT automatically treated as malicious — plenty of
//  legitimate developer tools and scripts are unsigned.
//
//  Gatekeeper's policy-database assessment (notarization, "source=")
//  has no public framework replacement — `spctl` is Apple's own
//  documented CLI surface for it, the same one Finder's "Are you sure
//  you want to open this?" prompt is backed by. It's invoked with a
//  fixed argument array (no shell, no string interpolation), and only
//  for application bundles where the assessment is meaningful.
//

import Foundation
import Security

struct SecuritySigningInfo {
    var status: SecuritySignatureStatus
    var identifier: String?
    var teamID: String?
    var developerName: String?
    var gatekeeperAssessment: String?
}

enum SecurityCodeSigningScanner {
    // Security framework's CSCommon error codes aren't all bridged as
    // Swift symbols by every SDK version, so the one this needs is
    // spelled out explicitly rather than relied on to import cleanly.
    private static let errSecCSUnsignedCode: OSStatus = -67062

    static func inspect(path: String) -> SecuritySigningInfo {
        let url = URL(fileURLWithPath: path)
        var staticCodeRef: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(rawValue: 0), &staticCodeRef)
        guard createStatus == errSecSuccess, let staticCode = staticCodeRef else {
            return SecuritySigningInfo(status: .unknown, identifier: nil, teamID: nil, developerName: nil, gatekeeperAssessment: nil)
        }

        let checkFlags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures)
        let validity = SecStaticCodeCheckValidity(staticCode, checkFlags, nil)

        var identifier: String?
        var teamID: String?
        var developerName: String?
        var infoRef: CFDictionary?
        if SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef) == errSecSuccess,
           let info = infoRef as? [String: Any] {
            identifier = info[kSecCodeInfoIdentifier as String] as? String
            teamID = info[kSecCodeInfoTeamIdentifier as String] as? String
            if let certs = info[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certs.first {
                developerName = SecCertificateCopySubjectSummary(leaf) as String?
            }
        }

        if validity == errSecCSUnsignedCode {
            return SecuritySigningInfo(status: .unsigned, identifier: identifier, teamID: teamID, developerName: nil, gatekeeperAssessment: nil)
        }
        if validity != errSecSuccess {
            return SecuritySigningInfo(status: .invalid, identifier: identifier, teamID: teamID, developerName: developerName, gatekeeperAssessment: nil)
        }

        var appleReq: SecRequirement?
        SecRequirementCreateWithString("anchor apple" as CFString, SecCSFlags(rawValue: 0), &appleReq)
        var isAppleSigned = false
        if let appleReq {
            isAppleSigned = SecStaticCodeCheckValidity(staticCode, checkFlags, appleReq) == errSecSuccess
        }

        let status: SecuritySignatureStatus = isAppleSigned ? .appleSigned : .validThirdParty
        // Gatekeeper assessment is NOT fetched here. `spctl --assess` can do a
        // network revocation/notarization-ticket check that occasionally
        // stalls for several seconds per app — calling it unconditionally for
        // every validly-signed app during a scan of /Applications (50-150+
        // apps) turned a scan into a multi-minute stall that read as a UI
        // freeze. It's only worth the cost for the small number of apps that
        // actually get flagged, so callers fetch it lazily via
        // `gatekeeperAssessment(path:)` themselves, only for those.
        return SecuritySigningInfo(status: status, identifier: identifier, teamID: teamID, developerName: developerName, gatekeeperAssessment: nil)
    }

    /// Bounded to `timeout` seconds — a single slow/hung `spctl` call (e.g.
    /// no network for its revocation check) must never be able to stall an
    /// entire scan. Only call this for items already flagged as suspicious;
    /// see the note in `inspect(path:)` above.
    static func gatekeeperAssessment(path: String, timeout: TimeInterval = 5) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/spctl")
        task.arguments = ["--assess", "--type", "execute", "-vv", path]
        let errPipe = Pipe()
        task.standardOutput = Pipe()
        task.standardError = errPipe
        guard (try? task.run()) != nil else { return nil }

        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            task.waitUntilExit()
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            task.terminate()
            return nil
        }

        let data = errPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

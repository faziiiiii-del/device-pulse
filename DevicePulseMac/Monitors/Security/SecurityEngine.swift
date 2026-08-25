//
//  SecurityEngine.swift
//  DevicePulseMac
//
//  Security Health, the Security Score, and the Privacy Audit. Every
//  check here either calls a real public API/documented command or
//  says "Unavailable" — none of these are guessed from indirect
//  evidence. `fdesetup`, `socketfilterfw`, `spctl`, and `csrutil` are
//  Apple's own documented CLIs for exactly these questions; there is no
//  framework-level replacement for any of them, the same situation as
//  Gatekeeper's assessment output in SecurityCodeSigningScanner.
//

import Foundation
import AVFoundation
import ApplicationServices
import CoreGraphics

enum SecurityHealthStatus {
    case good, warning, bad, unavailable
}

struct SecurityHealthCheck: Identifiable {
    let id = UUID()
    let name: String
    let status: SecurityHealthStatus
    let detail: String
}

struct SecurityScoreBreakdownItem: Identifiable {
    let id = UUID()
    let label: String
    /// nil = excluded from scoring entirely (unavailable/not applicable) —
    /// a check macOS won't answer must never silently count as a pass.
    let passed: Bool?
    let detail: String
}

struct SecurityScore {
    let score: Int
    let items: [SecurityScoreBreakdownItem]
}

enum PrivacyPermissionState {
    case granted, denied, notDetermined, unavailable
}

struct PrivacyPermissionCheck: Identifiable {
    let id = UUID()
    let name: String
    let state: PrivacyPermissionState
    let detail: String
    let settingsAnchor: String
}

enum SecurityEngine {
    // MARK: - Security Health (live system state, independent of any scan)

    static func healthChecks(latestScan: SecurityScanResult?) -> [SecurityHealthCheck] {
        var checks: [SecurityHealthCheck] = [
            healthCheck(
                name: "FileVault", status: fileVaultStatus(),
                good: "Disk encryption is enabled.",
                bad: "Disk encryption is off — anyone with physical access to this Mac can read its files.",
                unavailable: "macOS did not report FileVault status."
            ),
            healthCheck(
                name: "Firewall", status: firewallStatus(),
                good: "The application firewall is enabled.",
                bad: "The application firewall is off.",
                unavailable: "macOS did not report firewall status."
            ),
            healthCheck(
                name: "Gatekeeper", status: gatekeeperStatus(),
                good: "Gatekeeper is enabled — unsigned or unnotarized apps are blocked by default.",
                bad: "Gatekeeper assessments are disabled — macOS will run unsigned/unnotarized apps without warning.",
                unavailable: "macOS did not report Gatekeeper status."
            ),
            healthCheck(
                name: "System Integrity Protection", status: systemIntegrityStatus(),
                good: "System Integrity Protection is enabled.",
                bad: "System Integrity Protection is disabled.",
                unavailable: "macOS did not report System Integrity Protection status."
            ),
            healthCheck(
                name: "Automatic Updates", status: automaticUpdatesStatus(),
                good: "Automatic update checks are enabled.",
                bad: "Automatic update checks are off.",
                unavailable: "macOS does not expose this setting to third-party apps in a reliable way."
            ),
        ]

        if let latestScan {
            let persistenceCount = latestScan.findings.filter { $0.type == .suspiciousPersistence }.count
            checks.append(SecurityHealthCheck(
                name: "Suspicious Persistence",
                status: persistenceCount == 0 ? .good : .warning,
                detail: persistenceCount == 0
                    ? "No suspicious auto-launching items found in the last scan."
                    : "\(persistenceCount) auto-launching item(s) flagged in the last scan."
            ))

            let unsignedAppCount = latestScan.findings.filter { $0.type == .unsignedExecutable && $0.path.hasSuffix(".app") }.count
            checks.append(SecurityHealthCheck(
                name: "Unsigned Applications",
                status: unsignedAppCount == 0 ? .good : .warning,
                detail: unsignedAppCount == 0
                    ? "No unsigned applications found in the last scan."
                    : "\(unsignedAppCount) unsigned application(s) found in the last scan."
            ))

            let criticalCount = latestScan.threatCount
            checks.append(SecurityHealthCheck(
                name: "Known Malware",
                status: criticalCount == 0 ? .good : .bad,
                detail: criticalCount == 0
                    ? "No file matched a known-malicious hash in the last scan. No reputation source is configured, so this reflects the absence of a match, not a guarantee of safety."
                    : "\(criticalCount) file(s) matched a known-malicious signature."
            ))
        } else {
            for name in ["Suspicious Persistence", "Unsigned Applications", "Known Malware"] {
                checks.append(SecurityHealthCheck(name: name, status: .unavailable, detail: "Run a scan to check."))
            }
        }

        return checks
    }

    private static func healthCheck(name: String, status: SecurityHealthStatus, good: String, bad: String, unavailable: String) -> SecurityHealthCheck {
        let detail: String
        switch status {
        case .good: detail = good
        case .warning, .bad: detail = bad
        case .unavailable: detail = unavailable
        }
        return SecurityHealthCheck(name: name, status: status, detail: detail)
    }

    private struct CommandResult { let output: String; let exitCode: Int32 }

    private static func run(_ executable: String, _ args: [String]) -> CommandResult? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        guard (try? task.run()) != nil else { return nil }
        task.waitUntilExit()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let combined = (String(data: outData, encoding: .utf8) ?? "") + (String(data: errData, encoding: .utf8) ?? "")
        return CommandResult(output: combined, exitCode: task.terminationStatus)
    }

    private static func fileVaultStatus() -> SecurityHealthStatus {
        guard let result = run("/usr/bin/fdesetup", ["status"]) else { return .unavailable }
        let text = result.output.lowercased()
        if text.contains("filevault is on") { return .good }
        if text.contains("filevault is off") { return .bad }
        return .unavailable
    }

    private static func firewallStatus() -> SecurityHealthStatus {
        guard let result = run("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"]) else { return .unavailable }
        let text = result.output.lowercased()
        if text.contains("enabled") { return .good }
        if text.contains("disabled") { return .bad }
        return .unavailable
    }

    private static func gatekeeperStatus() -> SecurityHealthStatus {
        guard let result = run("/usr/sbin/spctl", ["--status"]) else { return .unavailable }
        let text = result.output.lowercased()
        if text.contains("assessments enabled") { return .good }
        if text.contains("assessments disabled") { return .bad }
        return .unavailable
    }

    private static func systemIntegrityStatus() -> SecurityHealthStatus {
        guard let result = run("/usr/bin/csrutil", ["status"]) else { return .unavailable }
        let text = result.output.lowercased()
        if text.contains("enabled") { return .good }
        if text.contains("disabled") { return .bad }
        return .unavailable
    }

    private static func automaticUpdatesStatus() -> SecurityHealthStatus {
        guard let result = run("/usr/bin/defaults", ["read", "/Library/Preferences/com.apple.SoftwareUpdate", "AutomaticCheckEnabled"]),
              result.exitCode == 0
        else { return .unavailable }
        switch result.output.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "1": return .good
        case "0": return .bad
        default: return .unavailable
        }
    }

    // MARK: - Security Score

    /// Deliberately distinct from the Dashboard's Health Score — this
    /// only exists once a scan has run (never "unscanned = 100"), and
    /// weighs security-relevant signals rather than resource checks.
    static func securityScore(latestScan: SecurityScanResult?) -> SecurityScore? {
        guard let latestScan else { return nil }
        let checks = healthChecks(latestScan: latestScan)
        let weights: [String: Double] = [
            "FileVault": 15, "Firewall": 15, "Gatekeeper": 15,
            "System Integrity Protection": 10, "Automatic Updates": 5,
            "Suspicious Persistence": 25, "Known Malware": 10,
        ]
        let unsignedAppCount = latestScan.findings.filter { $0.type == .unsignedExecutable && $0.path.hasSuffix(".app") }.count

        var items: [SecurityScoreBreakdownItem] = []
        var penalty = 0.0

        for check in checks {
            switch check.status {
            case .unavailable:
                items.append(.init(label: check.name, passed: nil, detail: check.detail))
            case .good:
                items.append(.init(label: check.name, passed: true, detail: check.detail))
            case .warning, .bad:
                items.append(.init(label: check.name, passed: false, detail: check.detail))
                if check.name == "Unsigned Applications" {
                    // Soft, count-scaled penalty rather than a flat weight —
                    // a couple of unsigned apps shouldn't tank the score the
                    // way disabled FileVault or live persistence should.
                    penalty += min(Double(unsignedAppCount) * 3, 15)
                } else {
                    penalty += weights[check.name] ?? 10
                }
            }
        }

        return SecurityScore(score: Int(max(0, 100 - penalty).rounded()), items: items)
    }

    // MARK: - Privacy Audit

    /// Reports Device Pulse's OWN permission state — there is no public
    /// API for a third-party app to inspect other apps' TCC grants, so
    /// this never attempts to. Where macOS genuinely exposes no public
    /// check (Full Disk Access, Automation), that's stated plainly
    /// rather than inferred by probing a protected path and guessing
    /// from the failure.
    static func privacyAudit() -> [PrivacyPermissionCheck] {
        [
            PrivacyPermissionCheck(
                name: "Camera", state: state(for: AVCaptureDevice.authorizationStatus(for: .video)),
                detail: "Device Pulse does not use the camera. This reflects whether macOS has ever been asked to grant it.",
                settingsAnchor: "Privacy_Camera"
            ),
            PrivacyPermissionCheck(
                name: "Microphone", state: state(for: AVCaptureDevice.authorizationStatus(for: .audio)),
                detail: "Device Pulse does not use the microphone. This reflects whether macOS has ever been asked to grant it.",
                settingsAnchor: "Privacy_Microphone"
            ),
            PrivacyPermissionCheck(
                name: "Accessibility", state: AXIsProcessTrusted() ? .granted : .denied,
                detail: "Device Pulse does not currently request Accessibility access.",
                settingsAnchor: "Privacy_Accessibility"
            ),
            PrivacyPermissionCheck(
                name: "Screen Recording", state: CGPreflightScreenCaptureAccess() ? .granted : .denied,
                detail: "Device Pulse does not currently request Screen Recording access.",
                settingsAnchor: "Privacy_ScreenCapture"
            ),
            PrivacyPermissionCheck(
                name: "Full Disk Access", state: .unavailable,
                detail: "macOS does not expose this permission state to third-party applications through any public API. Device Pulse needs Full Disk Access to fully scan protected locations (Mail, Messages, Time Machine, other users' folders) during Deep Scan — without it, those locations are reported as skipped, never as clean.",
                settingsAnchor: "Privacy_AllFiles"
            ),
            PrivacyPermissionCheck(
                name: "Automation", state: .unavailable,
                detail: "macOS does not expose a general way to check Automation permission without attempting to control a specific app (which would itself trigger a prompt). Device Pulse does not use Automation.",
                settingsAnchor: "Privacy_Automation"
            ),
        ]
    }

    private static func state(for status: AVAuthorizationStatus) -> PrivacyPermissionState {
        switch status {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .unavailable
        }
    }
}

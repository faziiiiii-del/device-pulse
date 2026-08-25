//
//  SecurityModels.swift
//  DevicePulseMac
//
//  Shared data types for the Security section. Kept separate from the
//  scanning/inspection logic so the risk model and finding shape can be
//  reasoned about independently of how a given signal was gathered.
//

import Foundation

enum SecurityRiskLevel: Int, Comparable, CaseIterable {
    case low = 0
    case medium
    case high
    case critical

    var label: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .critical: return "Critical"
        }
    }

    static func < (lhs: SecurityRiskLevel, rhs: SecurityRiskLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Code-signing outcome for a file, determined via the public Security
/// framework (`SecStaticCode`) — never inferred or guessed.
enum SecuritySignatureStatus: Equatable {
    case appleSigned
    case validThirdParty
    case unsigned
    case invalid
    /// The file couldn't be evaluated at all (e.g. not a code object,
    /// or unreadable) — distinct from "unsigned", which is a definite
    /// answer from `SecStaticCodeCheckValidity`.
    case unknown

    var label: String {
        switch self {
        case .appleSigned: return "Apple-signed"
        case .validThirdParty: return "Valid third-party signature"
        case .unsigned: return "Unsigned"
        case .invalid: return "Signature invalid"
        case .unknown: return "Unknown"
        }
    }
}

/// macOS quarantine metadata (`com.apple.quarantine` extended attribute),
/// distinct from Device Pulse's own quarantine store.
enum SecurityQuarantineStatus: Equatable {
    case quarantinedByMacOS
    case notQuarantined
    case unknown

    var label: String {
        switch self {
        case .quarantinedByMacOS: return "Quarantined by macOS (recently downloaded)"
        case .notQuarantined: return "Not quarantined"
        case .unknown: return "Unknown"
        }
    }
}

enum SecurityFindingType: String {
    case unsignedExecutable = "Unsigned Executable"
    case invalidSignature = "Invalid Signature"
    case suspiciousPersistence = "Suspicious Persistence"
    case quarantinedDownload = "Quarantined Download"
    case unusualLocation = "Unusual Location"
    case recentExecutable = "Recently Created Executable"
    case suspiciousScript = "Suspicious Script"
    case knownThreatHash = "Known Threat Hash"
}

/// A single scan result. Reputation is architected for but never
/// fabricated — `hashReputation` is `nil` unless a real, configured
/// source produced a verdict, and the UI must show "Hash reputation
/// unavailable" rather than implying a file is clean.
struct SecurityFinding: Identifiable, Equatable {
    let id: UUID
    var name: String
    var path: String
    var type: SecurityFindingType
    var risk: SecurityRiskLevel
    var reason: String
    var detectionMethod: String
    var signatureStatus: SecuritySignatureStatus
    var developerName: String?
    var teamID: String?
    var gatekeeperAssessment: String?
    var quarantineStatus: SecurityQuarantineStatus
    var sha256: String?
    var hashReputation: HashReputationResult?
    var fileSizeBytes: Int64?
    var createdDate: Date?
    var modifiedDate: Date?
    var persistenceLabel: String?
    /// The exact `launchctl` domain target (e.g. "gui/501" or "system") this
    /// persistence item loads into — only set for `.suspiciousPersistence`
    /// findings. Lets the "Disable" action unload the real running launchd
    /// job (`launchctl bootout <domainTarget>/<persistenceLabel>`) instead of
    /// just moving the plist file, which does nothing to a job launchd
    /// already has loaded into memory.
    var persistenceDomainTarget: String?
    var isDevicePulseQuarantined: Bool = false

    init(
        name: String, path: String, type: SecurityFindingType, risk: SecurityRiskLevel, reason: String,
        detectionMethod: String, signatureStatus: SecuritySignatureStatus, developerName: String? = nil,
        teamID: String? = nil, gatekeeperAssessment: String? = nil, quarantineStatus: SecurityQuarantineStatus = .unknown,
        sha256: String? = nil, hashReputation: HashReputationResult? = nil, fileSizeBytes: Int64? = nil,
        createdDate: Date? = nil, modifiedDate: Date? = nil, persistenceLabel: String? = nil,
        persistenceDomainTarget: String? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.path = path
        self.type = type
        self.risk = risk
        self.reason = reason
        self.detectionMethod = detectionMethod
        self.signatureStatus = signatureStatus
        self.developerName = developerName
        self.teamID = teamID
        self.gatekeeperAssessment = gatekeeperAssessment
        self.quarantineStatus = quarantineStatus
        self.sha256 = sha256
        self.hashReputation = hashReputation
        self.fileSizeBytes = fileSizeBytes
        self.createdDate = createdDate
        self.modifiedDate = modifiedDate
        self.persistenceLabel = persistenceLabel
        self.persistenceDomainTarget = persistenceDomainTarget
    }
}

/// Result of comparing a hash against a configured reputation source.
/// There is no bundled malware database — `HashReputationSource.none`
/// is always the active source today, so this always resolves to
/// `.unavailable`. The type exists so a real source can be wired in
/// later without reshaping findings.
enum HashReputationResult: Equatable {
    case unavailable
    case knownGood
    case knownMalicious(name: String)
}

enum SecurityScanKind: String {
    case quick = "Quick Scan"
    case deep = "Deep Scan"
}

struct SecurityScanResult {
    let kind: SecurityScanKind
    let startedAt: Date
    var finishedAt: Date?
    var filesScanned: Int = 0
    var filesSkipped: Int = 0
    var findings: [SecurityFinding] = []
    var scannedLocations: [String] = []
    var skippedLocations: [SkippedLocation] = []
    var wasCancelled: Bool = false
    /// True once the findings cap was hit — scanning continued (coverage
    /// numbers stay accurate), but not every suspicious item found further
    /// on was recorded, so the UI must say so rather than imply completeness.
    var findingsTruncated: Bool = false

    struct SkippedLocation: Identifiable {
        var id: String { path }
        let path: String
        let reason: String
    }

    var threatCount: Int { findings.filter { $0.risk == .critical }.count }
    var warningCount: Int { findings.filter { $0.risk == .medium || $0.risk == .high }.count }
}

/// Live progress published during a scan.
struct SecurityScanProgress {
    var currentLocation: String = ""
    var currentItem: String = ""
    var filesScanned: Int = 0
}

/// Lightweight, persisted summary of the last completed scan — NOT the
/// full findings list (those aren't persisted; each SecurityFinding
/// carries non-Codable enum associated data by design, since it's only
/// ever meant to live for the duration of one scan's review). This is
/// just enough to answer "what happened last time" after a relaunch:
/// the Dashboard's status card and the menu-bar indicator, both of
/// which only need counts and a timestamp, not full detail.
struct SecurityScanSummary: Codable {
    let kind: String
    let startedAt: Date
    let finishedAt: Date
    let filesScanned: Int
    let filesSkipped: Int
    let threatCount: Int
    let warningCount: Int
    let findingsCount: Int
}

/// Paths the user has explicitly reviewed and decided not to act on.
/// Persisted (not just dismissed for one session) so an item you've
/// already looked at and judged fine doesn't keep reappearing on every
/// future scan — the direct answer to "what can I do about it, or
/// ignore it." Ignoring is not quarantine: the file is never touched,
/// only excluded from future scan results.
enum SecurityIgnoreList {
    private static let key = "securityIgnoredPaths"

    static func all() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func isIgnored(_ path: String) -> Bool {
        all().contains(path)
    }

    static func ignore(_ path: String) {
        var set = all()
        set.insert(path)
        UserDefaults.standard.set(Array(set), forKey: key)
    }

    static func unignore(_ path: String) {
        var set = all()
        set.remove(path)
        UserDefaults.standard.set(Array(set), forKey: key)
    }
}

enum SecurityStatusCache {
    private static let key = "securityLastScanSummary"

    static func save(_ result: SecurityScanResult) {
        guard let finishedAt = result.finishedAt else { return }
        let summary = SecurityScanSummary(
            kind: result.kind.rawValue, startedAt: result.startedAt, finishedAt: finishedAt,
            filesScanned: result.filesScanned, filesSkipped: result.filesSkipped,
            threatCount: result.threatCount, warningCount: result.warningCount, findingsCount: result.findings.count
        )
        guard let data = try? JSONEncoder().encode(summary) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load() -> SecurityScanSummary? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SecurityScanSummary.self, from: data)
    }

    /// Menu-bar indicator reads this cache only — it never triggers a
    /// scan of its own, so the indicator can't become a hidden
    /// background scanner.
    static var menuBarIndicator: (symbol: String, label: String) {
        guard let summary = load() else { return ("⚪", "Security not scanned") }
        if summary.threatCount > 0 { return ("🔴", "Threat detected") }
        if summary.warningCount > 0 { return ("🟡", "Security attention") }
        return ("🟢", "Security OK")
    }
}

//
//  SecurityView.swift
//  DevicePulseMac
//
//  Mac security scanner and diagnostic — NOT a claim to replace
//  commercial antivirus. Every number shown here comes from a real,
//  explainable check (code signature, quarantine attribute, launchd
//  persistence, a documented `system` command) or is labeled honestly
//  as unavailable. The flow is Detect → Explain → Investigate →
//  Quarantine, never Scan → Panic → Delete: nothing is ever deleted
//  automatically, and "unsigned" is never treated as "malicious" on
//  its own — see SecurityScanner's risk model for exactly how each
//  finding earns its risk tier.
//

import SwiftUI
import UserNotifications

struct SecurityView: View {
    @State private var lastResult: SecurityScanResult?
    @State private var lastSummary: SecurityScanSummary?
    @State private var isScanning = false
    @State private var scanProgress = SecurityScanProgress()
    @State private var scanToken: SecurityScanCancellationToken?

    @State private var healthChecks: [SecurityHealthCheck] = []
    @State private var securityScore: SecurityScore?

    @State private var quarantineRecords: [DevicePulseQuarantineRecord] = []
    @State private var ignoredPaths: Set<String> = []
    @State private var selectedFinding: SecurityFinding?
    @State private var pendingQuarantine: SecurityFinding?
    @State private var pendingDelete: DevicePulseQuarantineRecord?
    @State private var toastMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Security").font(.largeTitle).bold()
                Text("Mac security scanner and diagnostic — code-signing inspection, quarantine attributes, and launch-item persistence, using only public macOS APIs. Not a replacement for commercial antivirus.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                statusCard
                scanControls
                if isScanning { progressCard }
                if let lastResult, !lastResult.findings.isEmpty { findingsCard }
                if let lastResult, !lastResult.skippedLocations.isEmpty || lastResult.filesSkipped > 0 { skippedCard }
                if !quarantineRecords.isEmpty { quarantineCard }
                if !ignoredPaths.isEmpty { ignoredCard }
                securityScoreCard
                securityHealthCard
                privacyAuditCard
                permissionsCard
            }
            .padding(24)
        }
        .overlay(alignment: .bottom) {
            if let toastMessage {
                Text(toastMessage)
                    .font(.subheadline)
                    .padding(12)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(radius: 8, y: 2)
                    .padding()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toastMessage)
        .onAppear {
            quarantineRecords = SecurityQuarantineManager.loadRecords()
            ignoredPaths = SecurityIgnoreList.all()
            lastSummary = SecurityStatusCache.load()
            refreshHealthAndScore()
        }
        .sheet(item: $selectedFinding) { finding in
            SecurityInspectView(finding: finding)
        }
        .alert(
            pendingQuarantine.map { "Quarantine \($0.name)?" } ?? "",
            isPresented: Binding(get: { pendingQuarantine != nil }, set: { if !$0 { pendingQuarantine = nil } })
        ) {
            Button("Cancel", role: .cancel) { pendingQuarantine = nil }
            Button("Quarantine", role: .destructive) {
                if let finding = pendingQuarantine { performQuarantine(finding) }
                pendingQuarantine = nil
            }
        } message: {
            if let finding = pendingQuarantine {
                Text("This moves \(finding.path) to Device Pulse's quarantine folder. Nothing is deleted — you can restore it anytime from Quarantine below.")
            }
        }
        .alert(
            "Delete Permanently?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Delete Permanently", role: .destructive) {
                if let record = pendingDelete { performDelete(record) }
                pendingDelete = nil
            }
        } message: {
            if let record = pendingDelete {
                Text("This permanently deletes \((record.originalPath as NSString).lastPathComponent) from quarantine. This cannot be undone.")
            }
        }
    }

    // MARK: - Status

    private var hasScannedBefore: Bool { lastResult != nil || lastSummary != nil }
    private var effectiveThreatCount: Int { lastResult?.threatCount ?? lastSummary?.threatCount ?? 0 }
    private var effectiveWarningCount: Int { lastResult?.warningCount ?? lastSummary?.warningCount ?? 0 }
    private var effectiveFilesScanned: Int { lastResult?.filesScanned ?? lastSummary?.filesScanned ?? 0 }
    private var effectiveLastScanDate: Date? { lastResult?.finishedAt ?? lastSummary?.finishedAt }

    private var statusTint: Color {
        guard hasScannedBefore else { return .secondary }
        if effectiveThreatCount > 0 { return .red }
        if effectiveWarningCount > 0 { return .yellow }
        return .green
    }

    private var statusIcon: String {
        guard hasScannedBefore else { return "shield" }
        if effectiveThreatCount > 0 { return "xmark.shield.fill" }
        if effectiveWarningCount > 0 { return "exclamationmark.shield.fill" }
        return "checkmark.shield.fill"
    }

    private var statusHeadline: String {
        guard hasScannedBefore else { return "Security scan not yet performed." }
        if effectiveThreatCount > 0 { return "\(effectiveThreatCount) threat(s) detected — review immediately." }
        if effectiveWarningCount > 0 { return "\(effectiveWarningCount) warning(s) found — review recommended." }
        return "No known or suspicious threats detected."
    }

    private var statusCard: some View {
        MacCard(title: "Security Status", systemImage: "checkmark.shield", tint: statusTint) {
            HStack(spacing: 16) {
                Image(systemName: statusIcon).font(.system(size: 32)).foregroundStyle(statusTint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(statusHeadline).font(.title3).bold()
                    if let date = effectiveLastScanDate {
                        Text("Last scan: \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            if hasScannedBefore {
                Divider()
                HStack(spacing: 28) {
                    MacMiniStat(label: "Files Scanned", value: "\(effectiveFilesScanned)")
                    MacMiniStat(label: "Threats", value: "\(effectiveThreatCount)")
                    MacMiniStat(label: "Warnings", value: "\(effectiveWarningCount)")
                }
                if effectiveThreatCount > 0 || effectiveWarningCount > 0 {
                    Text(
                        lastResult != nil
                            ? "See Findings below for what each one is, why it was flagged, and what you can do — Inspect for details, Quarantine to move it aside, or Ignore if you've reviewed it and it's fine."
                            : "This count is from your last scan in a previous session — run Quick Scan or Deep Scan again to see and act on each item individually."
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Scan controls

    private var scanControls: some View {
        HStack(spacing: 12) {
            Button { runScan(kind: .quick) } label: { Label("Quick Scan", systemImage: "bolt") }
                .buttonStyle(.borderedProminent)
                .disabled(isScanning)

            Button { runScan(kind: .deep) } label: { Label("Deep Scan", systemImage: "magnifyingglass") }
                .buttonStyle(.bordered)
                .disabled(isScanning)

            if isScanning {
                Button("Cancel") { scanToken?.cancel() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var progressCard: some View {
        MacCard(title: "Scanning", systemImage: "arrow.triangle.2.circlepath", tint: MacSection.security.tint) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Scanning: \(scanProgress.currentLocation.isEmpty ? "Starting…" : scanProgress.currentLocation)")
                        .font(.subheadline).bold()
                }
                if !scanProgress.currentItem.isEmpty {
                    Text("Current item: \(scanProgress.currentItem)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text("Files scanned: \(scanProgress.filesScanned)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Findings

    private var sortedFindings: [SecurityFinding] {
        (lastResult?.findings ?? []).sorted { $0.risk > $1.risk }
    }

    private var findingsCard: some View {
        MacCard(title: "Findings (\(sortedFindings.count))", systemImage: "list.bullet.clipboard", tint: MacSection.security.tint) {
            if lastResult?.findingsTruncated == true {
                Text("Showing the first \(sortedFindings.count) findings — scanning found more than that and stopped recording additional ones so the list stays responsive. Coverage counts above are still accurate.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            LazyVStack(spacing: 0) {
                ForEach(sortedFindings) { finding in
                    SecurityFindingRow(
                        finding: finding,
                        onInspect: { selectedFinding = finding },
                        onQuarantine: { pendingQuarantine = finding },
                        onIgnore: { ignoreFinding(finding) }
                    )
                    if finding.id != sortedFindings.last?.id { Divider() }
                }
            }
        }
    }

    private var skippedCard: some View {
        MacCard(title: "Scan Coverage", systemImage: "eye.slash", tint: MacSection.security.tint) {
            VStack(alignment: .leading, spacing: 8) {
                if let lastResult, lastResult.filesSkipped > 0 {
                    Text("\(lastResult.filesSkipped) file(s) could not be scanned because macOS denied access. They are not reported as clean.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let lastResult, !lastResult.skippedLocations.isEmpty {
                    ForEach(lastResult.skippedLocations) { skipped in
                        Text("\(skipped.path) — \(skipped.reason)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Quarantine

    private var quarantineCard: some View {
        MacCard(title: "Quarantine (\(quarantineRecords.count))", systemImage: "archivebox", tint: MacSection.security.tint) {
            LazyVStack(spacing: 0) {
                ForEach(quarantineRecords) { record in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.findingName).font(.subheadline).bold()
                            Text(record.originalPath).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Text("Quarantined \(record.quarantinedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("Restore") { restore(record) }.buttonStyle(.bordered).controlSize(.small)
                        Button("Delete Permanently") { pendingDelete = record }.buttonStyle(.bordered).controlSize(.small)
                    }
                    .padding(.vertical, 6)
                    if record.id != quarantineRecords.last?.id { Divider() }
                }
            }
            Text("Quarantined files are moved to a Device Pulse–managed folder, never deleted, until you choose Restore or Delete Permanently.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Ignored

    private var ignoredCard: some View {
        let sorted = ignoredPaths.sorted()
        return MacCard(title: "Ignored (\(sorted.count))", systemImage: "eye.slash", tint: MacSection.security.tint) {
            VStack(spacing: 0) {
                ForEach(sorted, id: \.self) { path in
                    HStack {
                        Text(path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Un-ignore") { unignore(path) }.buttonStyle(.bordered).controlSize(.small)
                    }
                    .padding(.vertical, 4)
                    if path != sorted.last { Divider() }
                }
            }
            Text("These paths are reviewed and excluded from future scan results — the files themselves were never touched.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Security Score

    private var securityScoreCard: some View {
        MacCard(title: "Security Score", systemImage: "gauge.with.dots.needle.50percent", tint: MacSection.security.tint) {
            if let score = securityScore {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(score.score)").font(.system(size: 40, weight: .bold))
                    Text("/ 100").font(.title3).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(score.items) { item in
                        HStack {
                            Text(item.label).font(.caption)
                            Spacer()
                            Text(item.passed == nil ? "—" : (item.passed == true ? "✓" : "⚠"))
                                .font(.caption).bold()
                                .foregroundStyle(item.passed == nil ? Color.secondary : (item.passed == true ? Color.green : Color.orange))
                        }
                    }
                }
            } else if lastSummary != nil {
                Text("Security score unavailable — run a new scan in this session to calculate it.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Security score unavailable. Run a scan first — a score is never shown for an unscanned Mac.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Security Health

    private var securityHealthCard: some View {
        MacCard(title: "Security Health", systemImage: "heart.text.square", tint: MacSection.security.tint) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(healthChecks) { check in
                    HStack(alignment: .top, spacing: 8) {
                        Text(healthSymbol(check.status))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(check.name).font(.subheadline).bold()
                            Text(check.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func healthSymbol(_ status: SecurityHealthStatus) -> String {
        switch status {
        case .good: return "🟢"
        case .warning: return "🟡"
        case .bad: return "🔴"
        case .unavailable: return "⚪"
        }
    }

    // MARK: - Privacy Audit

    private var privacyAuditCard: some View {
        let permissions = SecurityEngine.privacyAudit()
        return MacCard(title: "Privacy Audit", systemImage: "hand.raised", tint: MacSection.security.tint) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Reflects Device Pulse's own permission state only — macOS provides no public API for a third-party app to inspect other apps' permissions.")
                    .font(.caption2).foregroundStyle(.secondary)
                ForEach(permissions) { permission in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(permission.name).font(.subheadline).bold()
                            Text(permission.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(privacyStateLabel(permission.state)).font(.caption).bold().foregroundStyle(privacyStateColor(permission.state))
                            Button("Open System Settings") { openSystemSettings(anchor: permission.settingsAnchor) }
                                .buttonStyle(.bordered).controlSize(.mini)
                        }
                    }
                    if permission.id != permissions.last?.id { Divider() }
                }
            }
        }
    }

    private func privacyStateLabel(_ state: PrivacyPermissionState) -> String {
        switch state {
        case .granted: return "Granted"
        case .denied: return "Denied"
        case .notDetermined: return "Not Determined"
        case .unavailable: return "Requires System Settings"
        }
    }

    private func privacyStateColor(_ state: PrivacyPermissionState) -> Color {
        switch state {
        case .granted: return .green
        case .denied: return .red
        case .notDetermined, .unavailable: return .secondary
        }
    }

    // MARK: - Permissions

    private var permissionsCard: some View {
        MacCard(title: "Security Permissions", systemImage: "lock.shield", tint: MacSection.security.tint) {
            VStack(alignment: .leading, spacing: 14) {
                permissionRow(
                    name: "Full Disk Access",
                    detail: "Needed so Deep Scan can read protected locations (Mail, Messages, Time Machine, other users' folders) instead of reporting them as skipped.",
                    anchor: "Privacy_AllFiles"
                )
                permissionRow(
                    name: "Notifications",
                    detail: "Used only to alert you after a scan finds something that needs review — never for marketing or unrelated alerts.",
                    anchor: nil
                )
                Text("Device Pulse never requests more access than a feature actually needs, and never silently expands its own permissions.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func permissionRow(name: String, detail: String, anchor: String?) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline).bold()
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let anchor {
                Button("Open System Settings") { openSystemSettings(anchor: anchor) }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
    }

    private func openSystemSettings(anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Actions

    private func runScan(kind: SecurityScanKind) {
        isScanning = true
        scanProgress = SecurityScanProgress()
        let token = SecurityScanCancellationToken()
        scanToken = token

        DispatchQueue.global(qos: .userInitiated).async {
            let result = SecurityScanner.scan(kind: kind, token: token) { progress in
                DispatchQueue.main.async { scanProgress = progress }
            }
            DispatchQueue.main.async {
                lastResult = result
                SecurityStatusCache.save(result)
                lastSummary = SecurityStatusCache.load()
                isScanning = false
                scanToken = nil
                refreshHealthAndScore()
                notifyIfNeeded(result)
            }
        }
    }

    private func refreshHealthAndScore() {
        let scan = lastResult
        DispatchQueue.global(qos: .utility).async {
            let checks = SecurityEngine.healthChecks(latestScan: scan)
            let score = scan.flatMap { SecurityEngine.securityScore(latestScan: $0) }
            DispatchQueue.main.async {
                healthChecks = checks
                securityScore = score
            }
        }
    }

    /// Only fires after a scan the user explicitly ran — this is not a
    /// background watcher, so there's no continuous scanning to notify
    /// from. Reuses the same UNUserNotificationCenter path
    /// MacAlertMonitor already uses for threshold alerts.
    private func notifyIfNeeded(_ result: SecurityScanResult) {
        let severe = result.findings.filter { $0.risk == .high || $0.risk == .critical }
        guard !severe.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = "Device Pulse Security"
        content.body = severe.count == 1
            ? "1 item needs review after your \(result.kind.rawValue.lowercased()): \(severe[0].name)"
            : "\(severe.count) items need review after your \(result.kind.rawValue.lowercased())."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "security-scan-\(Date().timeIntervalSince1970)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func performQuarantine(_ finding: SecurityFinding) {
        guard SecurityQuarantineManager.quarantine(path: finding.path, findingName: finding.name, reason: finding.reason) != nil else {
            toastMessage = "Couldn't quarantine this file."
            scheduleToastDismiss()
            return
        }
        quarantineRecords = SecurityQuarantineManager.loadRecords()
        lastResult?.findings.removeAll { $0.id == finding.id }
        toastMessage = "File moved to quarantine."
        scheduleToastDismiss()
    }

    private func ignoreFinding(_ finding: SecurityFinding) {
        SecurityIgnoreList.ignore(finding.path)
        ignoredPaths = SecurityIgnoreList.all()
        lastResult?.findings.removeAll { $0.id == finding.id }
        toastMessage = "Won't flag this again on future scans."
        scheduleToastDismiss()
    }

    private func unignore(_ path: String) {
        SecurityIgnoreList.unignore(path)
        ignoredPaths = SecurityIgnoreList.all()
    }

    private func restore(_ record: DevicePulseQuarantineRecord) {
        if SecurityQuarantineManager.restore(record) {
            quarantineRecords = SecurityQuarantineManager.loadRecords()
            toastMessage = "File restored to its original location."
        } else {
            toastMessage = "Couldn't restore — something already exists at the original location."
        }
        scheduleToastDismiss()
    }

    private func performDelete(_ record: DevicePulseQuarantineRecord) {
        _ = SecurityQuarantineManager.deletePermanently(record)
        quarantineRecords = SecurityQuarantineManager.loadRecords()
        toastMessage = "File permanently deleted."
        scheduleToastDismiss()
    }

    private func scheduleToastDismiss() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { toastMessage = nil }
    }
}

// MARK: - Finding row

private struct SecurityFindingRow: View {
    let finding: SecurityFinding
    let onInspect: () -> Void
    let onQuarantine: () -> Void
    let onIgnore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: iconName).foregroundStyle(finding.risk.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(finding.name).font(.subheadline).bold()
                    Text(finding.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                SecurityRiskBadge(risk: finding.risk)
            }
            Text(finding.reason).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Inspect", action: onInspect).buttonStyle(.bordered).controlSize(.small)
                Button("Quarantine", action: onQuarantine).buttonStyle(.bordered).controlSize(.small)
                Button("Ignore", action: onIgnore).buttonStyle(.bordered).controlSize(.small)
                    .help("Reviewed this and it's fine — hide it from future scans without touching the file.")
                Spacer()
            }
        }
        .padding(.vertical, 8)
    }

    private var iconName: String {
        switch finding.type {
        case .suspiciousPersistence: return "bolt.trianglebadge.exclamationmark"
        case .unsignedExecutable, .invalidSignature: return "exclamationmark.shield"
        case .suspiciousScript: return "terminal"
        case .quarantinedDownload: return "arrow.down.circle"
        case .unusualLocation: return "questionmark.folder"
        case .recentExecutable: return "clock.badge.exclamationmark"
        case .knownThreatHash: return "xmark.shield"
        }
    }
}

private struct SecurityRiskBadge: View {
    let risk: SecurityRiskLevel

    var body: some View {
        Text(risk.label.uppercased())
            .font(.caption2).bold()
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(risk.color.opacity(0.18))
            .foregroundStyle(risk.color)
            .clipShape(Capsule())
    }
}

extension SecurityRiskLevel {
    var color: Color {
        switch self {
        case .low: return .yellow
        case .medium: return .orange
        case .high: return .red
        case .critical: return .purple
        }
    }
}

// MARK: - Inspect sheet

private struct SecurityInspectView: View {
    let finding: SecurityFinding
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(finding.name).font(.title2).bold()
                Spacer()
                Button("Done") { dismiss() }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    MacInfoRow(label: "Path", value: finding.path)
                    MacInfoRow(label: "Type", value: finding.type.rawValue)
                    MacInfoRow(label: "Risk", value: finding.risk.label)
                    if let size = finding.fileSizeBytes { MacInfoRow(label: "File Size", value: ByteFormat.string(size)) }
                    if let created = finding.createdDate { MacInfoRow(label: "Created", value: created.formatted(date: .abbreviated, time: .shortened)) }
                    if let modified = finding.modifiedDate { MacInfoRow(label: "Modified", value: modified.formatted(date: .abbreviated, time: .shortened)) }

                    Divider()
                    MacInfoRow(label: "Code Signature", value: finding.signatureStatus.label)
                    if let developer = finding.developerName { MacInfoRow(label: "Developer", value: developer) }
                    if let team = finding.teamID { MacInfoRow(label: "Team ID", value: team) }
                    if let gatekeeper = finding.gatekeeperAssessment { MacInfoRow(label: "Gatekeeper Assessment", value: gatekeeper) }
                    MacInfoRow(label: "Quarantine", value: finding.quarantineStatus.label)

                    if let sha = finding.sha256 {
                        Divider()
                        Text("SHA-256").font(.caption).foregroundStyle(.secondary)
                        Text(sha).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        MacInfoRow(label: "Hash Reputation", value: reputationLabel(finding.hashReputation))
                    }

                    if let label = finding.persistenceLabel {
                        Divider()
                        MacInfoRow(label: "Persistence Mechanism", value: label)
                    }

                    Divider()
                    Text("Why Device Pulse flagged this").font(.headline)
                    Text(finding.reason).font(.callout)
                    Text("Detected via: \(finding.detectionMethod)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(20)
        .frame(width: 480, height: 540)
    }

    private func reputationLabel(_ result: HashReputationResult?) -> String {
        switch result {
        case .none: return "Not calculated"
        case .unavailable: return "Hash reputation unavailable — no reputation source is configured."
        case .knownGood: return "Known good"
        case .knownMalicious(let name): return "Known malicious: \(name)"
        }
    }
}

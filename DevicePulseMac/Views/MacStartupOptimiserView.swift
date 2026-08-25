//
//  MacStartupOptimiserView.swift
//  DevicePulseMac
//

import SwiftUI

struct MacStartupOptimiserView: View {
    @State private var items: [StartupItem] = []
    @State private var isScanning = false
    @State private var pendingAction: (item: StartupItem, enable: Bool)?
    @State private var changeLog: [(label: String, action: String, date: Date)] = []
    @State private var actionError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Startup Optimiser").font(.largeTitle).bold()

                MacCard(title: "Login Items", systemImage: "person.crop.circle", tint: MacSection.startupOptimiser.tint) {
                    Text("macOS does not provide a public API for a third-party app to list other apps' System Settings ▸ General ▸ Login Items — the old API that used to allow this was deprecated and locked down. Check that panel directly for those. What's below (LaunchAgents/LaunchDaemons) IS legitimately, publicly inspectable, and covers most background auto-start software.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                summaryCard

                HStack {
                    Button {
                        scan()
                    } label: {
                        if isScanning {
                            HStack { ProgressView().controlSize(.small); Text("Scanning…") }
                        } else {
                            Label("Refresh Startup Items", systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isScanning)
                }

                ForEach(StartupItemType.allCases, id: \.self) { type in
                    let group = items.filter { $0.type == type }
                    if !group.isEmpty {
                        MacCard(title: type.rawValue + "s", systemImage: "gearshape.2", tint: MacSection.startupOptimiser.tint) {
                            VStack(spacing: 0) {
                                ForEach(group) { item in
                                    row(for: item)
                                    if item.id != group.last?.id { Divider() }
                                }
                            }
                        }
                    }
                }

                if !changeLog.isEmpty {
                    MacCard(title: "Change History", systemImage: "clock.arrow.circlepath", tint: MacSection.startupOptimiser.tint) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(changeLog.enumerated()), id: \.offset) { _, entry in
                                Text("\(entry.label): \(entry.action) — \(entry.date.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .onAppear(perform: scan)
        .alert(
            pendingAction.map { "\($0.enable ? "Enable" : "Disable") \($0.item.label)?" } ?? "",
            isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } })
        ) {
            Button("Cancel", role: .cancel) { pendingAction = nil }
            Button(pendingAction?.enable == true ? "Enable" : "Disable", role: pendingAction?.enable == true ? .none : .destructive) {
                if let action = pendingAction { apply(action) }
                pendingAction = nil
            }
        } message: {
            if let action = pendingAction {
                Text(action.enable
                    ? "This will load \(action.item.label) via launchctl bootstrap, pointing at its existing file:\n\(action.item.plistPath)\n\nNothing is written or deleted."
                    : "This will unload \(action.item.label) via launchctl bootout. The file itself is NOT deleted:\n\(action.item.plistPath)\n\nIt may reload automatically on next login depending on how it was installed.")
            }
        }
        .alert(
            "Couldn't complete that",
            isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    private var summaryCard: some View {
        let agents = items.filter { $0.type == .userLaunchAgent || $0.type == .globalLaunchAgent }.count
        let daemons = items.filter { $0.type == .launchDaemon }.count
        let unknown = items.filter { $0.classification == .unknown }.count

        return MacCard(title: "Startup Summary", systemImage: "chart.bar", tint: MacSection.startupOptimiser.tint) {
            HStack(spacing: 24) {
                MacMiniStat(label: "LaunchAgents", value: "\(agents)")
                MacMiniStat(label: "LaunchDaemons", value: "\(daemons)")
                MacMiniStat(label: "Unknown Origin", value: "\(unknown)")
            }
        }
    }

    private func row(for item: StartupItem) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.label).font(.subheadline).bold()
                    classificationBadge(item.classification)
                }
                Text(item.plistPath).font(.caption2).foregroundStyle(.secondary)
                if let program = item.programPath {
                    Text(program).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(item.isLoaded ? "Loaded" : "Not Loaded")
                    .font(.caption)
                    .foregroundStyle(item.isLoaded ? .green : .secondary)
                Button(item.isLoaded ? "Disable" : "Enable") {
                    pendingAction = (item, !item.isLoaded)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(item.classification == .apple || item.type == .launchDaemon)
                if item.type == .launchDaemon {
                    Text("Requires admin").font(.caption2).foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func classificationBadge(_ classification: StartupClassification) -> some View {
        let color: Color = {
            switch classification {
            case .apple: return .blue
            case .knownThirdParty: return .green
            case .userInstalled: return .orange
            case .unknown: return .gray
            }
        }()
        return Text(classification.rawValue)
            .font(.caption2).bold()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func scan() {
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = MacStartupMonitor.scan()
            DispatchQueue.main.async {
                items = result
                isScanning = false
            }
        }
    }

    private func apply(_ action: (item: StartupItem, enable: Bool)) {
        let success = action.enable ? MacStartupMonitor.enable(action.item) : MacStartupMonitor.disable(action.item)
        if success {
            changeLog.insert((action.item.label, action.enable ? "Enabled" : "Disabled", Date()), at: 0)
        } else {
            actionError = "Failed to \(action.enable ? "enable" : "disable") \(action.item.label). This usually means it needs administrator privileges, which this app doesn't request."
        }
        scan()
    }
}

extension StartupItemType: CaseIterable {
    static var allCases: [StartupItemType] { [.userLaunchAgent, .globalLaunchAgent, .launchDaemon] }
}

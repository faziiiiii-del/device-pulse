//
//  HomeView.swift
//  DevicePulse
//
//  Overview dashboard. Every card is a quick-glance summary that jumps to
//  the relevant tab for detail; deeper tools (full diagnostic, history,
//  snapshots, live monitor, investigate, advanced/experimental) live one
//  tap away via the links below. This screen intentionally does not
//  compute a single blended "health score" — see DiagnosticsEngine.swift
//  for why.
//

import SwiftUI

/// Value-based navigation destinations for Home's pushed screens. Using
/// `.navigationDestination(for:)` instead of `NavigationLink(destination:)`
/// means each screen (and the monitors/timers it owns) is only constructed
/// when actually navigated to — `NavigationLink(destination:)` builds its
/// destination eagerly on every parent re-render, which for Home's 5-second
/// auto-refresh meant reconstructing every tool screen (and its
/// BatteryMonitor/NWPathMonitor/etc.) every 5 seconds without ever tearing
/// the old ones down.
enum HomeDestination: Hashable {
    case diagnostic, investigate, history, snapshots, liveMonitor, advanced
}

struct HomeView: View {
    @Binding var selection: DashboardTab
    @State private var path = NavigationPath()

    @StateObject private var battery = BatteryMonitor()
    @StateObject private var network = NetworkMonitor()
    @StateObject private var thermal = ThermalMonitor()
    @StateObject private var memoryPressure = MemoryPressureMonitor()

    @State private var memoryStats: MemoryStats?
    @State private var storageStats: StorageStats?
    @State private var lastUpdated: Date?
    @State private var checks: [DiagnosticCheck] = []

    private let refreshTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 16) {
                    summaryCard
                    actionsRow

                    VStack(spacing: 12) {
                        OverviewCard(
                            title: "Battery",
                            systemImage: battery.isCharging ? "battery.100.bolt" : "battery.75",
                            value: battery.levelPercentText,
                            subtitle: battery.stateText + (battery.lowPowerMode ? " · Low Power Mode" : ""),
                            level: batteryLevel
                        ) { selection = .battery }

                        OverviewCard(
                            title: "Thermal State",
                            systemImage: "thermometer.medium",
                            value: thermal.text,
                            subtitle: thermal.isElevated ? "System is throttling to cool down" : "Operating normally",
                            level: thermal.isElevated ? .warning : .good
                        ) { selection = .device }

                        OverviewCard(
                            title: "Memory",
                            systemImage: "memorychip",
                            value: memoryStats.map { ByteFormat.string($0.used) } ?? "Unavailable",
                            subtitle: memorySubtitle,
                            level: memoryLevel
                        ) { selection = .memory }

                        OverviewCard(
                            title: "Storage",
                            systemImage: "internaldrive",
                            value: storageStats.map { ByteFormat.string($0.free) + " free" } ?? "Unavailable",
                            subtitle: storageStats.map { "\(Int($0.usedFraction * 100))% used" } ?? "",
                            level: storageLevel
                        ) { selection = .storage }

                        OverviewCard(
                            title: "Network",
                            systemImage: "wifi",
                            value: network.connectionType,
                            subtitle: network.isConnected ? "Connected" : "No connection",
                            level: network.isConnected ? .good : .bad
                        ) { selection = .network }

                        OverviewCard(
                            title: "Device",
                            systemImage: "iphone",
                            value: DeviceInfo.deviceName,
                            subtitle: "\(DeviceInfo.modelIdentifier) · \(DeviceInfo.systemVersion)",
                            level: .neutral
                        ) { selection = .device }
                    }

                    toolsSection

                    if let lastUpdated {
                        Text("Last updated \(lastUpdated.formatted(date: .omitted, time: .standard))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Dashboard")
            .onAppear { refresh() }
            .onReceive(refreshTimer) { _ in refresh() }
            .navigationDestination(for: HomeDestination.self) { destination in
                switch destination {
                case .diagnostic: DiagnosticView()
                case .investigate: InvestigateView()
                case .history: HistoryView()
                case .snapshots: SnapshotsView()
                case .liveMonitor: LiveMonitorView()
                case .advanced: AdvancedView()
                }
            }
        }
    }

    private var summaryCard: some View {
        let warnings = checks.filter { $0.status == .warning }.count
        let passes = checks.filter { $0.status == .pass }.count
        return StatCard(title: "Diagnostic Summary", systemImage: "checkmark.shield") {
            HStack(spacing: 20) {
                MiniStat(label: "Passing", value: "\(passes)")
                MiniStat(label: "Warnings", value: "\(warnings)")
                MiniStat(label: "Checks", value: "\(checks.count)")
            }
            Text(warnings > 0 ? "Something needs attention — see below or run the full diagnostic." : "No warnings from the current quick check.")
                .font(.caption)
                .foregroundStyle(warnings > 0 ? .orange : .secondary)
        }
    }

    private var actionsRow: some View {
        HStack(spacing: 12) {
            Button {
                refresh()
            } label: {
                Label("Quick Check", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                path.append(HomeDestination.diagnostic)
            } label: {
                Label("Run Full Diagnostic", systemImage: "stethoscope")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var toolsSection: some View {
        StatCard(title: "More Tools", systemImage: "wrench.and.screwdriver") {
            VStack(spacing: 0) {
                toolLink("Investigate a Problem", "questionmark.circle", .investigate)
                Divider()
                toolLink("History & Trends", "chart.xyaxis.line", .history)
                Divider()
                toolLink("Snapshots & Compare", "camera.on.rectangle", .snapshots)
                Divider()
                toolLink("Live Monitor", "waveform.path.ecg", .liveMonitor)
                Divider()
                toolLink("Advanced / Experimental", "flask", .advanced)
            }
        }
    }

    private func toolLink(_ title: String, _ systemImage: String, _ destination: HomeDestination) -> some View {
        Button {
            path.append(destination)
        } label: {
            HStack {
                Image(systemName: systemImage).frame(width: 24)
                Text(title)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    private func refresh() {
        memoryStats = MemoryReader.read()
        storageStats = StorageReader.read()
        checks = DiagnosticsEngine.syncChecks()
        lastUpdated = Date()

        HistoryStore.shared.recordIfDue(MetricObservation(
            timestamp: Date(),
            batteryLevel: battery.level >= 0 ? battery.level : nil,
            isCharging: battery.isCharging,
            thermalState: thermal.text,
            memoryUsedFraction: memoryStats?.usedFraction,
            memoryPressure: memoryPressure.level.rawValue,
            storageUsedFraction: storageStats?.usedFraction,
            storageFreeBytes: storageStats?.free,
            networkType: network.connectionType,
            latencyMs: nil
        ))

        Task {
            let networkResult = await DiagnosticsEngine.networkCheck()
            await MainActor.run {
                checks.append(networkResult)
            }
        }
    }

    private var memorySubtitle: String {
        guard let stats = memoryStats else { return "" }
        return "\(Int(stats.usedFraction * 100))% of \(ByteFormat.string(stats.total))"
    }

    private var batteryLevel: StatusLevel {
        guard battery.level >= 0 else { return .neutral }
        if !battery.isCharging && battery.level < 0.15 { return .bad }
        if !battery.isCharging && battery.level < 0.3 { return .warning }
        return .good
    }

    private var memoryLevel: StatusLevel {
        guard let stats = memoryStats else { return .neutral }
        if stats.usedFraction > 0.9 { return .warning }
        return .good
    }

    private var storageLevel: StatusLevel {
        guard let stats = storageStats else { return .neutral }
        let freeFraction = 1 - stats.usedFraction
        if freeFraction < 0.05 { return .bad }
        if freeFraction < 0.1 { return .warning }
        return .good
    }
}

#Preview {
    ContentView()
}

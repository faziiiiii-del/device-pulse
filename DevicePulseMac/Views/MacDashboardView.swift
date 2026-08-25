//
//  MacDashboardView.swift
//  DevicePulseMac
//
//  Two distinct layouts sharing the same underlying state/monitors,
//  switched by the app-wide theme toggle (Settings ▸ Appearance):
//  `classicBody` is the original card-grid dashboard, `frostedBody` is
//  the hero-ring/live-graph redesign. The frosted background itself and
//  the dark color scheme are now applied once, app-wide, in
//  MacRootView — this view only supplies its own content on top.
//  Every number on screen comes from the same real monitors either way
//  — this is a visual pass, not a data source change. The frosted
//  footer intentionally shows Thermal State (public, coarse 4-level)
//  rather than a temperature/fan/noise readout — macOS exposes none of
//  those on Apple Silicon, and this app doesn't fabricate numbers for
//  looks (see MacThermalMonitor, MacCPUView).
//

import Combine
import SwiftUI

struct MacDashboardView: View {
    @Binding var selection: MacSection?

    @StateObject private var cpu = MacCPUMonitor()
    @StateObject private var memory = MacMemoryMonitor()
    @StateObject private var network = MacNetworkMonitor()
    @StateObject private var thermal = MacThermalMonitor()

    @State private var volume: VolumeInfo?
    @State private var checks: [DiagnosticCheck] = []
    @State private var isRunningDiagnostic = false
    @State private var lastUpdated: Date?

    private var theme = ThemeReader()

    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if theme.current == .frosted {
                frostedBody
            } else {
                classicBody
            }
        }
        .onAppear { refresh() }
        .onReceive(timer) { _ in refresh() }
    }

    // MARK: - Classic layout (original)

    private var classicBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("How is my Mac doing?").font(.largeTitle).bold()

                classicSummaryCard

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 14) {
                    MacOverviewCard(
                        title: "CPU", systemImage: "cpu",
                        value: cpu.load.map { "\(Int($0.usedFraction * 100))%" } ?? "Collecting…",
                        subtitle: "\(cpu.coreCount) logical cores", level: cpuLevel, tint: MacSection.cpu.tint
                    ) { selection = .cpu }

                    MacOverviewCard(
                        title: "Memory", systemImage: "memorychip",
                        value: memory.stats.map { ByteFormat.memoryString($0.used) } ?? "Unavailable",
                        subtitle: memory.stats.map { "\(Int($0.usedFraction * 100))% of \(ByteFormat.memoryString($0.total))" } ?? "",
                        level: memoryLevel, tint: MacSection.memory.tint
                    ) { selection = .memory }

                    MacOverviewCard(
                        title: "Storage", systemImage: "internaldrive",
                        value: volume.map { ByteFormat.string($0.available) + " free" } ?? "Unavailable",
                        subtitle: volume.map { "\(Int($0.usedFraction * 100))% used on \($0.name)" } ?? "",
                        level: storageLevel, tint: MacSection.storage.tint
                    ) { selection = .storage }

                    MacOverviewCard(
                        title: "Network", systemImage: "wifi",
                        value: network.connectionType, subtitle: network.isConnected ? "Connected" : "No connection",
                        level: network.isConnected ? .good : .bad, tint: MacSection.network.tint
                    ) { selection = .network }

                    MacOverviewCard(
                        title: "Battery", systemImage: "battery.75",
                        value: batteryValue, subtitle: batterySubtitle, level: .neutral, tint: MacSection.battery.tint
                    ) { selection = .battery }

                    MacOverviewCard(
                        title: "Device", systemImage: "desktopcomputer",
                        value: MacDeviceMonitor.modelIdentifier, subtitle: MacDeviceMonitor.systemVersion, level: .neutral, tint: MacSection.device.tint
                    ) { selection = .device }
                }
            }
            .padding(24)
        }
    }

    private var classicSummaryCard: some View {
        MacCard(title: "Diagnostic Summary", systemImage: "checkmark.shield", tint: healthTint) {
            HStack(spacing: 24) {
                MacHealthRing(score: healthScore, tint: healthTint, size: 96)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 24) {
                        MacMiniStat(label: "Normal", value: "\(passesCount)")
                        MacMiniStat(label: "Warnings", value: "\(warningsCount)")
                        MacMiniStat(label: "Checks", value: "\(checks.count)")
                    }
                    Button {
                        runDiagnostic()
                    } label: {
                        if isRunningDiagnostic {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Run Full Diagnostic", systemImage: "stethoscope")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRunningDiagnostic)
                }
                Spacer()
            }
            if !checks.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(checks) { check in
                        HStack {
                            StatusBadge(status: check.status)
                            Text(check.name).font(.subheadline).bold()
                            Text(check.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let lastUpdated {
                Text("Last updated \(lastUpdated.formatted(date: .omitted, time: .standard))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Frosted layout

    private var frostedBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                topBar
                healthHeroCard
                statGrid
                deviceFooterBar
            }
            .padding(24)
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("How is my Mac doing?").font(.largeTitle).bold().foregroundStyle(.white)
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                if let lastUpdated {
                    Text("Last updated: \(lastUpdated.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.white.opacity(0.55))
                }
                Button { refresh() } label: {
                    Image(systemName: "arrow.clockwise").foregroundStyle(.white.opacity(0.75))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Health hero card

    private var passesCount: Int { checks.filter { $0.status == .pass }.count }
    private var warningsCount: Int { checks.filter { $0.status == .warning }.count }

    private var healthHeadline: String {
        guard let healthScore else { return "Not Checked" }
        switch healthScore {
        case 85...: return "Healthy"
        case 60..<85: return "Needs Attention"
        default: return "At Risk"
        }
    }

    private var healthSummaryLine: String {
        guard healthScore != nil else { return "Run a full diagnostic to check your Mac's health." }
        if warningsCount == 0 { return "All systems operating well." }
        return warningsCount == 1 ? "1 warning needs attention." : "\(warningsCount) warnings need attention."
    }

    private var healthHeroCard: some View {
        FrostedPanel {
            HStack(alignment: .top, spacing: 28) {
                MacHealthRing(score: healthScore, tint: healthTint, size: 120)
                VStack(alignment: .leading, spacing: 10) {
                    Text(healthHeadline).font(.title2).bold().foregroundStyle(.white)
                    Text(healthSummaryLine).font(.subheadline).foregroundStyle(.white.opacity(0.65))
                    if let lastUpdated {
                        Text("Last checked: \(lastUpdated.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.white.opacity(0.45))
                    }
                    HStack(spacing: 28) {
                        frostedMiniStat(label: "Normal", value: "\(passesCount)")
                        frostedMiniStat(label: "Warning", value: "\(warningsCount)", tint: warningsCount > 0 ? .yellow : nil)
                        frostedMiniStat(label: "Checks", value: "\(checks.count)")
                    }
                    Button {
                        runDiagnostic()
                    } label: {
                        if isRunningDiagnostic {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Run Full Diagnostic", systemImage: "stethoscope")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRunningDiagnostic)
                }
                Spacer()
            }
            if !checks.isEmpty {
                Divider().overlay(Color.white.opacity(0.15))
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(checks) { check in
                        HStack {
                            StatusBadge(status: check.status)
                            Text(check.name).font(.subheadline).bold().foregroundStyle(.white)
                            Text(check.detail).font(.caption).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
            }
        }
    }

    private func frostedMiniStat(label: String, value: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.subheadline).bold().foregroundStyle(tint ?? .white)
            Text(label).font(.caption2).foregroundStyle(.white.opacity(0.55))
        }
    }

    // MARK: - Stat grid

    private var statGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 14) {
            FrostedStatCard(
                title: "CPU", systemImage: "cpu", tint: MacSection.cpu.tint,
                value: cpu.load.map { "\(Int($0.usedFraction * 100))%" } ?? "Collecting…",
                subtitle: "\(cpu.coreCount) logical cores", level: cpuLevel
            ) { selection = .cpu } accessory: {
                MacSparkline(values: cpu.history, tint: MacSection.cpu.tint).frame(height: 32)
            }

            FrostedStatCard(
                title: "Memory", systemImage: "memorychip", tint: MacSection.memory.tint,
                value: memory.stats.map { ByteFormat.memoryString($0.used) } ?? "Unavailable",
                subtitle: memory.stats.map { "\(Int($0.usedFraction * 100))% of \(ByteFormat.memoryString($0.total))" } ?? "", level: memoryLevel
            ) { selection = .memory } accessory: {
                MacSparkline(values: memory.history, tint: MacSection.memory.tint).frame(height: 32)
            }

            FrostedStatCard(
                title: "Storage", systemImage: "internaldrive", tint: MacSection.storage.tint,
                value: volume.map { ByteFormat.string($0.available) + " free" } ?? "Unavailable",
                subtitle: volume.map { "\(Int($0.usedFraction * 100))% used on \($0.name)" } ?? "", level: storageLevel
            ) { selection = .storage } accessory: {
                frostedProgressBar(fraction: volume?.usedFraction ?? 0, tint: MacSection.storage.tint)
            }

            FrostedStatCard(
                title: "Network", systemImage: "wifi", tint: MacSection.network.tint,
                value: network.connectionType, subtitle: network.isConnected ? "Connected" : "No connection",
                level: network.isConnected ? .good : .bad
            ) { selection = .network } accessory: {
                frostedProgressBar(fraction: network.isConnected ? 1 : 0, tint: network.isConnected ? .green : .red)
            }

            FrostedStatCard(
                title: "Battery", systemImage: "battery.75", tint: MacSection.battery.tint,
                value: batteryValue, subtitle: batterySubtitle, level: .neutral
            ) { selection = .battery } accessory: {
                frostedProgressBar(fraction: batteryFraction, tint: MacSection.battery.tint)
            }

            FrostedStatCard(
                title: "Security", systemImage: "shield", tint: MacSection.security.tint,
                value: securityIndicator.label, subtitle: securitySubtitle, level: securityLevel
            ) { selection = .security } accessory: {
                frostedProgressBar(fraction: securityRingFraction, tint: securityLevel.color)
            }
        }
    }

    private func frostedProgressBar(fraction: Double, tint: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.12))
                RoundedRectangle(cornerRadius: 4).fill(tint)
                    .frame(width: max(4, geo.size.width * min(max(fraction, 0), 1)))
                    .animation(.easeInOut(duration: 0.5), value: fraction)
            }
        }
        .frame(height: 6)
    }

    // MARK: - Device footer

    private var deviceFooterBar: some View {
        FrostedPanel {
            HStack(spacing: 20) {
                MacIconTile(systemImage: "laptopcomputer", tint: .gray, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(MacDeviceMonitor.modelIdentifier).font(.subheadline).bold().foregroundStyle(.white)
                    Text("\(MacDeviceMonitor.systemVersion) • \(MacDeviceMonitor.processorBrand)")
                        .font(.caption).foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                footerStat(icon: "clock", label: "Uptime", value: MacDeviceMonitor.uptimeText)
                footerStat(icon: thermal.isElevated ? "flame.fill" : "thermometer.medium", label: "Thermal", value: thermal.text)
            }
        }
    }

    private func footerStat(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.white.opacity(0.7))
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.subheadline).bold().foregroundStyle(.white)
                Text(label).font(.caption2).foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    // MARK: - Health score

    /// Points deducted from 100 per warning, by check name — a critical
    /// resource running out (storage, thermal throttling, real memory
    /// pressure) should hurt the score far more than a low battery.
    /// `.info`/`.unavailable` checks (e.g. "CPU", "Memory") are purely
    /// informational and never scored — a Mac in perfect health should be
    /// able to reach 100, not be capped by checks that can never "pass".
    private static let warningPenalty: [String: Double] = [
        "Storage": 30,
        "Thermal State": 30,
        "Memory Pressure": 30,
        "Swap": 15,
        "Network": 15,
        "Battery": 10,
    ]
    private static let defaultWarningPenalty: Double = 15

    private var healthScore: Int? {
        let scoreable = checks.filter { $0.status == .pass || $0.status == .warning }
        guard !scoreable.isEmpty else { return nil }
        let penalty = scoreable
            .filter { $0.status == .warning }
            .reduce(0.0) { $0 + (Self.warningPenalty[$1.name] ?? Self.defaultWarningPenalty) }
        return Int(max(0, 100 - penalty).rounded())
    }

    private var healthTint: Color {
        guard let healthScore else { return .secondary }
        switch healthScore {
        case 85...: return .green
        case 60..<85: return .yellow
        default: return .red
        }
    }

    // MARK: - Data

    private func refresh() {
        volume = MacStorageMonitor.mainVolume()
        lastUpdated = Date()
    }

    private func runDiagnostic() {
        isRunningDiagnostic = true
        DispatchQueue.global(qos: .userInitiated).async {
            let results = MacDiagnosticsEngine.runAll()
            DispatchQueue.main.async {
                checks = results
                isRunningDiagnostic = false
                lastUpdated = Date()
            }
        }
    }

    private var cpuLevel: StatusLevel {
        guard cpu.load != nil else { return .neutral }
        if (cpu.load?.usedFraction ?? 0) > DevicePulseThresholds.cpuWarningFraction { return .warning }
        return .good
    }

    private var memoryLevel: StatusLevel {
        guard memory.stats != nil else { return .neutral }
        switch memory.pressure {
        case .critical: return .bad
        case .warning: return .warning
        case .normal: return .good
        }
    }

    private var storageLevel: StatusLevel {
        guard let volume else { return .neutral }
        let freeFraction = 1 - volume.usedFraction
        if freeFraction < DevicePulseThresholds.storageCriticalFreeFraction { return .bad }
        if freeFraction < DevicePulseThresholds.storageWarningFreeFraction { return .warning }
        return .good
    }

    private var batteryValue: String {
        guard MacBatteryMonitor.hasBattery() else { return "No Battery" }
        return MacBatteryMonitor.current().map { "\($0.percentage)%" } ?? "Unavailable"
    }

    private var batterySubtitle: String {
        guard MacBatteryMonitor.hasBattery() else { return "Desktop Mac" }
        return MacBatteryMonitor.current().map { $0.isCharging ? "Charging" : "On Battery" } ?? ""
    }

    private var batteryFraction: Double {
        guard MacBatteryMonitor.hasBattery(), let info = MacBatteryMonitor.current() else { return 0 }
        return Double(info.percentage) / 100.0
    }

    private var securitySummary: SecurityScanSummary? { SecurityStatusCache.load() }
    private var securityIndicator: (symbol: String, label: String) { SecurityStatusCache.menuBarIndicator }

    private var securityLevel: StatusLevel {
        guard let securitySummary else { return .neutral }
        if securitySummary.threatCount > 0 { return .bad }
        if securitySummary.warningCount > 0 { return .warning }
        return .good
    }

    /// Not a real percentage — Security doesn't have one continuous
    /// number the way CPU/Memory do — just a 3-tier fill (empty/partial/
    /// full) so the ring reads at a glance without implying more
    /// precision than "threat found / warning found / all clear" has.
    private var securityRingFraction: Double {
        guard let securitySummary else { return 0 }
        if securitySummary.threatCount > 0 { return 0.15 }
        if securitySummary.warningCount > 0 { return 0.55 }
        return 1.0
    }

    private var securitySubtitle: String {
        guard let securitySummary else { return "Not scanned yet" }
        return "Last scan: \(securitySummary.finishedAt.formatted(date: .abbreviated, time: .shortened))"
    }
}

// MARK: - Frosted glass components

private struct FrostedPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 20, y: 10)
    }
}

private struct FrostedStatCard<Accessory: View>: View {
    let title: String
    let systemImage: String
    let tint: Color
    let value: String
    let subtitle: String
    let level: StatusLevel
    var action: () -> Void
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    MacIconTile(systemImage: systemImage, tint: tint, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(title).font(.caption).foregroundStyle(.white.opacity(0.6))
                            StatusDot(level: level)
                        }
                        Text(value).font(.title3).bold().foregroundStyle(.white)
                    }
                    Spacer()
                }
                Text(subtitle).font(.caption2).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                accessory()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
            .macHoverLift(tint: tint)
        }
        .buttonStyle(MacPressableButtonStyle())
    }
}

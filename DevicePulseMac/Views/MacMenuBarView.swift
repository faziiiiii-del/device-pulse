//
//  MacMenuBarView.swift
//  DevicePulseMac
//
//  The menu bar label/content run their own lightweight CPU/Memory
//  monitors independent of the main window, so live stats are visible
//  even when the main window is closed.
//

import SwiftUI

struct MacMenuBarLabel: View {
    @StateObject private var cpu = MacCPUMonitor()
    @StateObject private var memory = MacMemoryMonitor()
    @State private var securityIndicator = SecurityStatusCache.menuBarIndicator

    private let securityRefreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var level: StatusLevel {
        let cpuBad = (cpu.load?.usedFraction ?? 0) > DevicePulseThresholds.cpuWarningFraction
        if cpuBad || memory.pressure == .critical { return .bad }
        if memory.pressure == .warning { return .warning }
        return .good
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(level.color).frame(width: 6, height: 6)
            Image(systemName: "cpu")
            Text(cpu.load.map { "\(Int($0.usedFraction * 100))%" } ?? "…")
            Image(systemName: "memorychip")
            Text(memory.stats.map { "\(Int($0.usedFraction * 100))%" } ?? "…")
            Text(securityIndicator.symbol)
        }
        .font(.system(size: 12, design: .monospaced))
        // Reads the last-scan cache only — never triggers a scan itself.
        .onReceive(securityRefreshTimer) { _ in securityIndicator = SecurityStatusCache.menuBarIndicator }
    }
}

struct MacMenuBarContent: View {
    @StateObject private var cpu = MacCPUMonitor()
    @StateObject private var memory = MacMemoryMonitor()
    @StateObject private var network = MacNetworkMonitor()
    @State private var volume: VolumeInfo?
    @State private var securityIndicator = SecurityStatusCache.menuBarIndicator

    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Device Pulse").font(.headline)

            statRow(icon: "cpu", tint: MacSection.cpu.tint, label: "CPU", value: cpu.load.map { "\(Int($0.usedFraction * 100))%" } ?? "Collecting…")
            statRow(icon: "memorychip", tint: MacSection.memory.tint, label: "Memory", value: memory.stats.map { "\(Int($0.usedFraction * 100))% of \(ByteFormat.memoryString($0.total))" } ?? "Unavailable")
            statRow(icon: "internaldrive", tint: MacSection.storage.tint, label: "Storage", value: volume.map { ByteFormat.string($0.available) + " free" } ?? "Unavailable")
            statRow(icon: "wifi", tint: MacSection.network.tint, label: "Network", value: network.isConnected ? network.connectionType : "No connection")
            statRow(icon: "shield", tint: MacSection.security.tint, label: "Security", value: "\(securityIndicator.symbol) \(securityIndicator.label)")

            Divider()

            Button("Open Device Pulse") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                for window in NSApplication.shared.windows where window.canBecomeKey {
                    window.makeKeyAndOrderFront(nil)
                    break
                }
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)

            Button("Quit Device Pulse") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
        }
        .padding(16)
        .frame(width: 260)
        .onAppear {
            volume = MacStorageMonitor.mainVolume()
            securityIndicator = SecurityStatusCache.menuBarIndicator
        }
        .onReceive(timer) { _ in
            volume = MacStorageMonitor.mainVolume()
            securityIndicator = SecurityStatusCache.menuBarIndicator
        }
    }

    private func statRow(icon: String, tint: Color, label: String, value: String) -> some View {
        HStack(spacing: 10) {
            MacIconTile(systemImage: icon, tint: tint, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.subheadline).bold()
            }
            Spacer()
        }
    }
}

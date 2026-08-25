//
//  LiveMonitorView.swift
//  DevicePulse
//
//  Foreground-only live polling. iOS does not let a normal app keep
//  running arbitrary code in the background, so this only refreshes
//  while this screen is open and the app is active — it is not a
//  background monitor, and it stops the moment you leave.
//

import SwiftUI

struct LiveMonitorView: View {
    @StateObject private var battery = BatteryMonitor()
    @StateObject private var network = NetworkMonitor()
    @StateObject private var thermal = ThermalMonitor()
    @StateObject private var memoryPressure = MemoryPressureMonitor()

    @State private var isLive = false
    @State private var memoryStats: MemoryStats?
    @State private var storageStats: StorageStats?
    @State private var latencyMs: Double?
    @State private var isTestingLatency = false
    @State private var tickCount = 0

    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                StatCard(title: "Live Monitor", systemImage: "waveform.path.ecg") {
                    Toggle(isOn: $isLive) {
                        Text(isLive ? "Live — refreshing every 2s" : "Paused")
                    }
                    Text("Foreground-only. This stops refreshing the instant you leave this screen or the app goes to the background — iOS doesn't allow continuous background polling for a normal app.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                StatCard(title: "Battery", systemImage: "battery.75") {
                    InfoRow(label: "Level", value: battery.levelPercentText)
                    InfoRow(label: "State", value: battery.stateText)
                }

                StatCard(title: "Thermal", systemImage: "thermometer.medium") {
                    InfoRow(label: "State", value: thermal.text)
                }

                StatCard(title: "Memory", systemImage: "memorychip") {
                    InfoRow(label: "Pressure", value: memoryPressure.level.rawValue)
                    if let stats = memoryStats {
                        InfoRow(label: "Used", value: "\(ByteFormat.string(stats.used)) (\(Int(stats.usedFraction * 100))%)")
                    }
                }

                StatCard(title: "Storage", systemImage: "internaldrive") {
                    if let stats = storageStats {
                        InfoRow(label: "Free", value: ByteFormat.string(stats.free))
                    }
                }

                StatCard(title: "Network", systemImage: "wifi") {
                    InfoRow(label: "Type", value: network.connectionType)
                    if isTestingLatency {
                        HStack { ProgressView(); Text("Testing latency…").font(.caption) }
                    } else if let latencyMs {
                        InfoRow(label: "Latency (last test)", value: "\(Int(latencyMs)) ms")
                    }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Live Monitor")
        .onAppear { refresh() }
        .onReceive(timer) { _ in
            guard isLive else { return }
            refresh()
            tickCount += 1
            if tickCount % 5 == 0 { testLatency() }
        }
    }

    private func refresh() {
        memoryStats = MemoryReader.read()
        storageStats = StorageReader.read()
    }

    private func testLatency() {
        guard !isTestingLatency else { return }
        isTestingLatency = true
        Task {
            let ms = await NetworkDiagnostics.tcpLatency()
            await MainActor.run {
                latencyMs = ms
                isTestingLatency = false
            }
        }
    }
}

#Preview {
    NavigationStack { LiveMonitorView() }
}

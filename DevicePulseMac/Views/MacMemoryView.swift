//
//  MacMemoryView.swift
//  DevicePulseMac
//

import Combine
import SwiftUI

struct MacMemoryView: View {
    @StateObject private var memory = MacMemoryMonitor()
    @State private var topProcesses: [ProcessInfoEntry] = []

    private let refreshTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Memory").font(.largeTitle).bold()

                MacCard(title: "Physical RAM", systemImage: "memorychip", tint: MacSection.memory.tint) {
                    if let stats = memory.stats {
                        MacUsageBar(
                            usedLabel: "Used \(ByteFormat.memoryString(stats.used))",
                            totalLabel: "of \(ByteFormat.memoryString(stats.total))",
                            fraction: stats.usedFraction,
                            tint: .purple
                        )
                        HStack(spacing: 20) {
                            MacMiniStat(label: "Wired", value: ByteFormat.memoryString(stats.wired))
                            MacMiniStat(label: "Active", value: ByteFormat.memoryString(stats.active))
                            MacMiniStat(label: "Inactive", value: ByteFormat.memoryString(stats.inactive))
                            MacMiniStat(label: "Compressed", value: ByteFormat.memoryString(stats.compressed))
                            MacMiniStat(label: "Free", value: ByteFormat.memoryString(stats.free))
                        }
                    } else {
                        Text("Collecting data…").font(.caption).foregroundStyle(.secondary)
                    }

                    Divider()

                    HStack {
                        Text("Memory Pressure").font(.subheadline).foregroundStyle(.secondary)
                        StatusDot(level: pressureLevel)
                        Text(memory.pressure.rawValue).font(.subheadline).bold()
                        Spacer()
                        if let swap = memory.swap {
                            Text("Swap: \(ByteFormat.memoryString(swap.used)) of \(ByteFormat.memoryString(swap.total))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                MacCard(title: "History", systemImage: "chart.xyaxis.line", tint: MacSection.memory.tint) {
                    MacSparkline(values: memory.history, tint: .purple)
                        .frame(height: 100)
                }

                MacCard(title: "Top Memory Users", systemImage: "list.bullet", tint: MacSection.memory.tint) {
                    if topProcesses.isEmpty {
                        Text("Loading…").font(.caption).foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(topProcesses.prefix(10)) { proc in
                                HStack {
                                    Text(proc.name)
                                    Spacer()
                                    Text(ByteFormat.memoryString(proc.residentBytes)).bold()
                                }
                                .font(.subheadline)
                                .padding(.vertical, 4)
                                if proc.id != topProcesses.prefix(10).last?.id { Divider() }
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .onAppear(perform: refreshProcesses)
        .onReceive(refreshTimer) { _ in refreshProcesses() }
    }

    private func refreshProcesses() {
        DispatchQueue.global(qos: .utility).async {
            let list = MacProcessMonitor.sorted(MacProcessMonitor.snapshot(), by: .memory)
            DispatchQueue.main.async { topProcesses = list }
        }
    }

    private var pressureLevel: StatusLevel {
        switch memory.pressure {
        case .normal: return .good
        case .warning: return .warning
        case .critical: return .bad
        }
    }
}

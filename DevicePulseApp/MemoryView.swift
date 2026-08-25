//
//  MemoryView.swift
//  DevicePulse
//

import SwiftUI

struct MemoryView: View {
    @StateObject private var memoryPressure = MemoryPressureMonitor()

    @State private var memoryStats: MemoryStats?
    @State private var appMemoryUsage: UInt64?
    @State private var observations: [MetricObservation] = []

    private let refreshTimer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    memoryCard
                    trendCard
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Memory")
            .onAppear {
                refresh()
                observations = HistoryStore.shared.recent(within: 24 * 3600).filter { $0.memoryUsedFraction != nil }
            }
            .onReceive(refreshTimer) { _ in refresh() }
        }
    }

    private func refresh() {
        memoryStats = MemoryReader.read()
        appMemoryUsage = MemoryReader.appMemoryUsage()
    }

    private var memoryCard: some View {
        StatCard(title: "Memory (RAM)", systemImage: "memorychip") {
            if let stats = memoryStats {
                VStack(alignment: .leading, spacing: 10) {
                    UsageBar(
                        usedLabel: "Used \(ByteFormat.string(stats.used))",
                        totalLabel: "of \(ByteFormat.string(stats.total))",
                        fraction: stats.usedFraction,
                        tint: .purple
                    )
                    HStack(spacing: 16) {
                        MiniStat(label: "Wired", value: ByteFormat.string(stats.wired))
                        MiniStat(label: "Active", value: ByteFormat.string(stats.active))
                        MiniStat(label: "Inactive", value: ByteFormat.string(stats.inactive))
                        MiniStat(label: "Compressed", value: ByteFormat.string(stats.compressed))
                    }

                    HStack {
                        Text("System Memory Pressure").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        StatusDot(level: pressureLevel)
                        Text(memoryPressure.level.rawValue).font(.caption).bold()
                    }
                    Text("This reflects system-wide pressure (GCD's public memory-pressure signal), not a suggestion to \"clean RAM\" — iOS manages memory automatically and manually killing apps generally doesn't help.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if let appMem = appMemoryUsage {
                        Text("This app is using \(ByteFormat.string(appMem)) — iOS doesn't let any app see what OTHER apps are using.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                ProgressView()
            }
        }
    }

    private var trendCard: some View {
        StatCard(title: "Trend (recorded while this app is open)", systemImage: "chart.xyaxis.line") {
            if observations.count >= 2 {
                Sparkline(values: observations.compactMap { $0.memoryUsedFraction }, tint: .purple)
                    .frame(height: 60)
                if let first = observations.first?.memoryUsedFraction, let last = observations.last?.memoryUsedFraction {
                    Text("\(Int(first * 100))% → \(Int(last * 100))% used across \(observations.count) observations.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Not enough observations yet — this app records a reading at most once every 5 minutes while open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var pressureLevel: StatusLevel {
        switch memoryPressure.level {
        case .normal: return .good
        case .warning: return .warning
        case .critical: return .bad
        }
    }
}

#Preview {
    MemoryView()
}

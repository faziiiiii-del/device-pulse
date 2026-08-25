//
//  HistoryView.swift
//  DevicePulse
//
//  Local-only trend view over observations this app has recorded while
//  open (recorded at most once every 5 minutes — see HistoryStore). This
//  is not continuous background monitoring; iOS doesn't allow that.
//

import SwiftUI

struct HistoryView: View {
    @State private var observations: [MetricObservation] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if observations.isEmpty {
                    StatCard(title: "History", systemImage: "chart.xyaxis.line") {
                        Text("No observations yet. This app records a lightweight snapshot at most once every 5 minutes while you have it open — check back after using it a bit.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    StatCard(title: "Battery Level", systemImage: "battery.75") {
                        Sparkline(values: observations.compactMap { $0.batteryLevel.map(Double.init) }, tint: .green)
                            .frame(height: 60)
                        rangeCaption(observations.compactMap { $0.batteryLevel.map { Int($0 * 100) } }, unit: "%")
                    }

                    StatCard(title: "Storage Used", systemImage: "internaldrive") {
                        Sparkline(values: observations.compactMap { $0.storageUsedFraction }, tint: .blue)
                            .frame(height: 60)
                        rangeCaption(observations.compactMap { $0.storageUsedFraction.map { Int($0 * 100) } }, unit: "%")
                    }

                    StatCard(title: "Memory Used", systemImage: "memorychip") {
                        Sparkline(values: observations.compactMap { $0.memoryUsedFraction }, tint: .purple)
                            .frame(height: 60)
                        rangeCaption(observations.compactMap { $0.memoryUsedFraction.map { Int($0 * 100) } }, unit: "%")
                    }

                    if observations.contains(where: { $0.latencyMs != nil }) {
                        StatCard(title: "Network Latency", systemImage: "wifi") {
                            let values = observations.compactMap { $0.latencyMs }
                            let normalized = normalize(values)
                            Sparkline(values: normalized, tint: .orange)
                                .frame(height: 60)
                            if let min = values.min(), let max = values.max(), let avg = average(values) {
                                Text("Best \(Int(min)) ms · Worst \(Int(max)) ms · Avg \(Int(avg)) ms")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    StatCard(title: "Recent Observations", systemImage: "list.bullet") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(observations.suffix(10).reversed(), id: \.id) { obs in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(obs.timestamp.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption).bold()
                                    Text(summaryLine(obs))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if obs.id != observations.suffix(10).reversed().last?.id {
                                    Divider()
                                }
                            }
                        }
                    }

                    Button(role: .destructive) {
                        HistoryStore.shared.clear()
                        observations = []
                    } label: {
                        Label("Clear History", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("History")
        .onAppear { observations = HistoryStore.shared.all() }
    }

    private func rangeCaption(_ values: [Int], unit: String) -> some View {
        Group {
            if let first = values.first, let last = values.last {
                Text("\(first)\(unit) → \(last)\(unit) over \(values.count) observations")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func summaryLine(_ obs: MetricObservation) -> String {
        var parts: [String] = []
        if let battery = obs.batteryLevel { parts.append("Battery \(Int(battery * 100))%") }
        if let mem = obs.memoryUsedFraction { parts.append("Mem \(Int(mem * 100))%") }
        if let storage = obs.storageUsedFraction { parts.append("Storage \(Int(storage * 100))%") }
        if let network = obs.networkType { parts.append(network) }
        if let thermal = obs.thermalState { parts.append("Thermal \(thermal)") }
        return parts.joined(separator: " · ")
    }

    private func normalize(_ values: [Double]) -> [Double] {
        guard let min = values.min(), let max = values.max(), max > min else {
            return values.map { _ in 0.5 }
        }
        return values.map { ($0 - min) / (max - min) }
    }

    private func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}

#Preview {
    NavigationStack { HistoryView() }
}

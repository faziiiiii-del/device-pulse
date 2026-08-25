//
//  BatteryView.swift
//  DevicePulse
//

import SwiftUI
import UIKit

struct BatteryView: View {
    @StateObject private var battery = BatteryMonitor()
    @StateObject private var thermal = ThermalMonitor()

    @State private var observations: [MetricObservation] = []

    private let refreshTimer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    batteryCard
                    trendCard
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Battery")
            .onAppear {
                observations = HistoryStore.shared.recent(within: 24 * 3600).filter { $0.batteryLevel != nil }
            }
        }
    }

    private var batteryCard: some View {
        StatCard(title: "Battery", systemImage: battery.isCharging ? "battery.100.bolt" : "battery.75") {
            HStack(alignment: .center, spacing: 20) {
                RingGauge(fraction: Double(max(battery.level, 0)), tint: batteryColor)
                    .frame(width: 72, height: 72)
                    .overlay(Text(battery.levelPercentText).font(.headline))

                VStack(alignment: .leading, spacing: 6) {
                    Label(battery.stateText, systemImage: battery.isCharging ? "bolt.fill" : "bolt.slash")
                        .font(.subheadline)
                        .foregroundStyle(battery.isCharging ? .green : .secondary)
                    if battery.lowPowerMode {
                        Label("Low Power Mode On", systemImage: "leaf.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                    }
                    Label("Thermal: \(thermal.text)", systemImage: "thermometer.medium")
                        .font(.caption)
                        .foregroundStyle(thermal.isElevated ? .orange : .secondary)
                    Text(monitoringAvailabilityText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Battery health % and cycle count aren't readable by any app — only Settings ▸ Battery ▸ Battery Health shows that.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    private var trendCard: some View {
        StatCard(title: "Trend (recorded while this app is open)", systemImage: "chart.xyaxis.line") {
            if observations.count >= 2 {
                Sparkline(values: observations.compactMap { $0.batteryLevel.map(Double.init) }, tint: .green)
                    .frame(height: 60)

                if let first = observations.first, let last = observations.last,
                   let firstLevel = first.batteryLevel, let lastLevel = last.batteryLevel {
                    let deltaPercent = Int((lastLevel - firstLevel) * 100)
                    Text("\(deltaPercent >= 0 ? "+" : "")\(deltaPercent)% since \(first.timestamp.formatted(date: .omitted, time: .shortened)) (\(observations.count) observations).")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let rate = drainRatePerHour() {
                        Text(String(format: "Estimated drain rate: %.1f%%/hour while unplugged (estimate from recorded observations, not a real-time measurement).", rate))
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            } else {
                Text("Not enough observations yet. This app records a battery reading at most once every 5 minutes while open — check back after using the app a bit over a few hours.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Average %/hour drop across consecutive observation pairs where the
    /// device was not charging in either reading. Estimate only — based on
    /// point-in-time readings while this app happened to be open.
    private func drainRatePerHour() -> Double? {
        var rates: [Double] = []
        for i in 1..<observations.count {
            let prev = observations[i - 1]
            let curr = observations[i]
            guard prev.isCharging == false, curr.isCharging == false,
                  let prevLevel = prev.batteryLevel, let currLevel = curr.batteryLevel else { continue }
            let hours = curr.timestamp.timeIntervalSince(prev.timestamp) / 3600
            guard hours > 0.05 else { continue }
            let delta = Double(prevLevel - currLevel) * 100
            if delta > 0 { rates.append(delta / hours) }
        }
        guard !rates.isEmpty else { return nil }
        return rates.reduce(0, +) / Double(rates.count)
    }

    private var monitoringAvailabilityText: String {
        "Battery monitoring: \(UIDevice.current.isBatteryMonitoringEnabled ? "enabled" : "unavailable")."
    }

    private var batteryColor: Color {
        if battery.isCharging { return .green }
        if battery.level < 0.2 { return .red }
        if battery.level < 0.5 { return .yellow }
        return .accentColor
    }
}

#Preview {
    BatteryView()
}

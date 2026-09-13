//
//  MacHistoryChartCard.swift
//  DevicePulseMac
//
//  Reusable persisted-history chart, backed by MacHistoryStore (real
//  samples taken every 5 minutes by MacHistoryRecorder) rather than the
//  in-memory-since-launch sparklines each tab already has. One component
//  used by CPU, Memory, Storage and Battery — each just supplies a
//  0–100 accessor for its own metric.
//

import SwiftUI
import Charts

enum MacHistoryRange: String, CaseIterable, Identifiable {
    case day = "24 Hours"
    case week = "7 Days"
    case month = "30 Days"

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .day: return 24 * 3600
        case .week: return 7 * 24 * 3600
        case .month: return 30 * 24 * 3600
        }
    }
}

private struct MacHistoryPoint: Identifiable {
    var id: Date { date }
    let date: Date
    let value: Double
}

struct MacHistoryChartCard: View {
    let title: String
    let systemImage: String
    let tint: Color
    let unit: String
    /// Returns a 0–100 value for this metric from an observation, or nil
    /// if that observation doesn't have one (e.g. no battery on a
    /// desktop Mac) — points with nil are simply omitted, never shown
    /// as zero.
    let percentValue: (MacMetricObservation) -> Double?

    @State private var range: MacHistoryRange = .day
    @State private var observations: [MacMetricObservation] = []

    var body: some View {
        MacCard(title: title, systemImage: systemImage, tint: tint) {
            Picker("", selection: $range) {
                ForEach(MacHistoryRange.allCases) { r in Text(r.rawValue).tag(r) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: range) { _ in load() }

            if points.count < 2 {
                Text("Not enough history yet for this range. Device Pulse records a sample every 5 minutes while it's running, so trends build up over time — leave it running in the background (Settings ▸ Menu bar only) to fill this in faster.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.top, 4)
            } else {
                Chart(points) { point in
                    AreaMark(x: .value("Time", point.date), y: .value(unit, point.value))
                        .foregroundStyle(tint.opacity(0.12))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", point.date), y: .value(unit, point.value))
                        .foregroundStyle(tint)
                        .interpolationMethod(.monotone)
                }
                .chartYScale(domain: 0...100)
                .frame(height: 150)
                .padding(.top, 6)

                if let latest = points.last {
                    Text("Latest: \(Int(latest.value))\(unit) at \(latest.date.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear(perform: load)
    }

    private var points: [MacHistoryPoint] {
        observations.compactMap { obs in
            percentValue(obs).map { MacHistoryPoint(date: obs.timestamp, value: $0) }
        }
    }

    private func load() {
        let selected = range
        DispatchQueue.global(qos: .utility).async {
            let found = MacHistoryStore.shared.recent(within: selected.seconds)
            DispatchQueue.main.async {
                if selected == range { observations = found }
            }
        }
    }
}

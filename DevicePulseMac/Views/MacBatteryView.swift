//
//  MacBatteryView.swift
//  DevicePulseMac
//

import SwiftUI

private struct BatterySample {
    let date: Date
    let percentage: Int
    let isCharging: Bool
}

struct MacBatteryView: View {
    @State private var info: BatteryInfo?
    @State private var hasBattery = false
    @State private var samples: [BatterySample] = []

    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    private let sampleInterval: TimeInterval = 60
    private let maxSamples = 60 // 1 hour at 60s

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Battery").font(.largeTitle).bold()

                if hasBattery, let info {
                    MacCard(title: "Charge", systemImage: "battery.75", tint: MacSection.battery.tint) {
                        MacUsageBar(usedLabel: "\(info.percentage)%", totalLabel: statusLabel(info), fraction: Double(info.percentage) / 100, tint: info.isCharging ? .green : .blue)
                        MacInfoRow(label: "Power Source", value: info.powerSourceState)
                        MacInfoRow(label: "Charging State", value: info.isFullyCharged ? "Fully Charged" : (info.isCharging ? "Charging" : "Not Charging"))
                        if let minutes = info.isCharging ? info.timeToFullMinutes : info.timeToEmptyMinutes {
                            MacInfoRow(label: info.isCharging ? "Estimated Time to Full" : "Estimated Time Remaining", value: durationString(minutes))
                        } else {
                            MacInfoRow(label: info.isCharging ? "Estimated Time to Full" : "Estimated Time Remaining", value: "Calculating…")
                        }
                    }

                    MacCard(title: "Battery Health", systemImage: "heart.text.square", tint: MacSection.battery.tint) {
                        if let health = info.healthLabel, let maxCap = info.maxCapacityPercent {
                            HStack(spacing: 8) {
                                Circle().fill(healthColor(health)).frame(width: 10, height: 10)
                                Text("Battery Health: \(health)").font(.subheadline).bold()
                            }
                            MacInfoRow(label: "Full Charge Capacity", value: "\(maxCap)% of design capacity")
                        } else {
                            MacInfoRow(label: "Battery Health", value: "Unavailable")
                        }
                        if let cycles = info.cycleCount {
                            MacInfoRow(label: "Cycle Count", value: "\(cycles)")
                        } else {
                            MacInfoRow(label: "Cycle Count", value: "Unavailable")
                        }
                        if let full = info.fullChargeCapacityMah {
                            MacInfoRow(label: "Full Charge Capacity", value: "\(full) mAh")
                        }
                        if let design = info.designCapacityMah {
                            MacInfoRow(label: "Design Capacity", value: "\(design) mAh")
                        }
                        if let remaining = info.remainingCapacityMah {
                            MacInfoRow(label: "Current Charge", value: "\(remaining) mAh")
                        }
                        Text("\"Battery Health\" here is a threshold on full-charge-vs-design capacity (Good ≥80%, Fair 60–79%, Poor <60%) — not Apple's own \"Service Recommended\" diagnostic, which uses a private algorithm. Treat this as a useful estimate, not an official verdict.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }

                    MacCard(title: "Power Draw", systemImage: "bolt", tint: MacSection.battery.tint) {
                        if let voltage = info.voltageMillivolts {
                            MacInfoRow(label: "Voltage", value: String(format: "%.2f V", Double(voltage) / 1000))
                        }
                        if let amperage = info.amperageMilliamps {
                            MacInfoRow(label: "Current", value: String(format: "%.0f mA (%@)", Double(abs(amperage)), amperage < 0 ? "discharging" : "charging"))
                        }
                        if let watts = info.wattage {
                            MacInfoRow(label: "Power Draw", value: String(format: "%.1f W", watts))
                        }
                        if let temp = info.temperatureCelsius {
                            MacInfoRow(label: "Battery Temperature", value: String(format: "%.1f°C", temp))
                        } else {
                            MacInfoRow(label: "Battery Temperature", value: "Not Exposed by This Mac")
                        }
                    }

                    MacCard(title: "Discharge Trend", systemImage: "chart.line.downtrend.xyaxis", tint: MacSection.battery.tint) {
                        if let rate = dischargeRatePerHour {
                            MacInfoRow(label: "Discharge Rate", value: String(format: "%.1f%%/hour", rate))
                            if rate > 0 {
                                MacInfoRow(label: "Measured Time to Empty", value: durationString(Int((Double(info.percentage) / rate) * 60)))
                            }
                            Text("Measured from \(samples.count) samples taken since Device Pulse was opened — not a long-term history, and resets if you plug in or the app restarts.")
                                .font(.caption2).foregroundStyle(.secondary)
                        } else {
                            Text(info.isCharging ? "Not discharging right now — plug out to measure a discharge trend." : "Collecting data… check back in a few minutes.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    Text("Percentage, charging state, and time estimates are read via the public IOKit power-source API. Cycle count, capacities, voltage, and current are read from IORegistry's AppleSmartBattery service — the standard, though not formally documented, way any Mac battery utility reads this. Time estimates and discharge rate are inherently approximate — actual runtime depends on what you're doing.")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if hasBattery {
                    MacCard(title: "Battery", systemImage: "battery.75", tint: MacSection.battery.tint) {
                        Text("Battery detected but details are currently unavailable.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    MacCard(title: "Battery", systemImage: "bolt.slash", tint: MacSection.battery.tint) {
                        Text("No battery detected — this looks like a desktop Mac.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(24)
        }
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in refresh() }
    }

    private var dischargeRatePerHour: Double? {
        let discharging = samples.filter { !$0.isCharging }
        guard let first = discharging.first, let last = discharging.last, first.date != last.date else { return nil }
        let hours = last.date.timeIntervalSince(first.date) / 3600
        guard hours > 0.03 else { return nil } // require a couple of minutes of data
        return Double(first.percentage - last.percentage) / hours
    }

    private func statusLabel(_ info: BatteryInfo) -> String {
        if info.isFullyCharged { return "Fully Charged" }
        return info.isCharging ? "Charging" : "On Battery"
    }

    private func healthColor(_ label: String) -> Color {
        switch label {
        case "Good": return .green
        case "Fair": return .yellow
        default: return .red
        }
    }

    private func durationString(_ minutes: Int) -> String {
        let hours = minutes / 60
        let mins = minutes % 60
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }

    private func refresh() {
        hasBattery = MacBatteryMonitor.hasBattery()
        info = MacBatteryMonitor.current()

        guard let info else { return }
        if let last = samples.last, Date().timeIntervalSince(last.date) < sampleInterval { return }
        samples.append(BatterySample(date: Date(), percentage: info.percentage, isCharging: info.isCharging))

        // Reset the trend whenever charging state flips, so plugging in
        // doesn't get averaged into a discharge measurement.
        if let previous = samples.dropLast().last, previous.isCharging != info.isCharging {
            samples = [samples.last!]
        }
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
    }
}

//
//  InvestigateView.swift
//  DevicePulse
//
//  Picks a common complaint and runs only the checks relevant to it,
//  then explains the findings in plain language.
//

import SwiftUI

private enum Problem: String, CaseIterable, Identifiable {
    case slow = "iPhone feels slow"
    case batteryDrain = "Battery draining quickly"
    case hot = "Phone feels hot"
    case slowNetwork = "Wi-Fi/internet feels slow"
    case storageFull = "Storage nearly full"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .slow: return "tortoise"
        case .batteryDrain: return "battery.25"
        case .hot: return "thermometer.high"
        case .slowNetwork: return "wifi.exclamationmark"
        case .storageFull: return "externaldrive.badge.exclamationmark"
        }
    }
}

struct InvestigateView: View {
    @State private var selected: Problem?
    @State private var isRunning = false
    @State private var findings: [String] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                StatCard(title: "What's going on?", systemImage: "questionmark.circle") {
                    Text("Pick what you're noticing and this runs only the checks that matter for it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 8) {
                        ForEach(Problem.allCases) { problem in
                            Button {
                                investigate(problem)
                            } label: {
                                HStack {
                                    Image(systemName: problem.icon).frame(width: 24)
                                    Text(problem.rawValue)
                                    Spacer()
                                    if selected == problem && isRunning {
                                        ProgressView()
                                    }
                                }
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if problem != Problem.allCases.last { Divider() }
                        }
                    }
                }

                if let selected, !findings.isEmpty {
                    StatCard(title: "Findings: \(selected.rawValue)", systemImage: "list.bullet.clipboard") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(findings, id: \.self) { finding in
                                Text("• " + finding)
                                    .font(.subheadline)
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Investigate")
    }

    private func investigate(_ problem: Problem) {
        selected = problem
        isRunning = true
        findings = []

        Task {
            var results: [String] = []
            switch problem {
            case .slow:
                let mem = DiagnosticsEngine.memoryCheck()
                let pressure = DiagnosticsEngine.memoryPressureCheck()
                let thermal = DiagnosticsEngine.thermalCheck()
                let storage = DiagnosticsEngine.storageCheck()
                results.append(sentence(pressure))
                results.append(sentence(thermal))
                results.append(sentence(mem))
                results.append(sentence(storage))
                if pressure.status == .pass && thermal.status == .pass && storage.status == .pass {
                    results.append("Nothing here points to a system-level cause. iOS doesn't expose per-app CPU usage of other apps, so a single background app hogging resources can't be confirmed from this app.")
                }

            case .batteryDrain:
                let battery = DiagnosticsEngine.batteryCheck()
                results.append(sentence(battery))
                let history = HistoryStore.shared.recent(within: 6 * 3600).filter { $0.batteryLevel != nil }
                if history.count >= 2, let first = history.first, let last = history.last,
                   let firstLevel = first.batteryLevel, let lastLevel = last.batteryLevel {
                    let deltaPercent = Int((firstLevel - lastLevel) * 100)
                    let hours = last.timestamp.timeIntervalSince(first.timestamp) / 3600
                    if hours > 0.1 {
                        let rate = Double(deltaPercent) / hours
                        results.append(String(format: "Over the last %.1f hours of observations, battery changed by %d%% (≈%.1f%%/hour). This is from readings this app recorded while open, not a full-day background measurement.", hours, deltaPercent, rate))
                    }
                } else {
                    results.append("Not enough history yet to estimate a drain rate — open this app a few times over the next few hours and check back.")
                }
                results.append("Apple doesn't expose per-app battery usage or battery health/cycle count to any third-party app — for that, use Settings ▸ Battery.")

            case .hot:
                let thermal = DiagnosticsEngine.thermalCheck()
                results.append(sentence(thermal))
                results.append("iOS only reports a 4-level thermal state (nominal/fair/serious/critical), not a temperature — there's no public API for degrees.")

            case .slowNetwork:
                let net = await DiagnosticsEngine.networkCheck()
                results.append(sentence(net))
                if net.status == .pass {
                    let (dnsOK, dnsMs) = await NetworkDiagnostics.resolveDNS()
                    if dnsOK, let ms = dnsMs {
                        results.append("DNS resolved in \(Int(ms)) ms.")
                    } else {
                        results.append("DNS resolution failed — this points to a network or DNS problem rather than just a slow link.")
                    }
                    if let latency = await NetworkDiagnostics.tcpLatency() {
                        let history = HistoryStore.shared.recent(within: 7 * 24 * 3600).compactMap { $0.latencyMs }
                        if !history.isEmpty {
                            let avg = history.reduce(0, +) / Double(history.count)
                            if latency > avg * 1.5 {
                                results.append(String(format: "Latency is %d ms, unusually high compared with your saved average of %d ms.", Int(latency), Int(avg)))
                            } else {
                                results.append(String(format: "Latency is %d ms, in line with your saved average of %d ms.", Int(latency), Int(avg)))
                            }
                        } else {
                            results.append("Latency is \(Int(latency)) ms. Run \"Test Connection\" on the Network tab a few more times to build a comparison baseline.")
                        }
                    }
                }

            case .storageFull:
                let storage = DiagnosticsEngine.storageCheck()
                results.append(sentence(storage))
                if let stats = StorageReader.read() {
                    let freePercent = Int((1 - stats.usedFraction) * 100)
                    results.append("\(freePercent)% free (\(ByteFormat.string(stats.free))).")
                    if freePercent < 10 {
                        results.append("Check the Storage tab's Photos & Videos estimate — photos/videos are often the largest reclaimable category on-device.")
                    }
                }
            }

            await MainActor.run {
                findings = results
                isRunning = false
            }
        }
    }

    private func sentence(_ check: DiagnosticCheck) -> String {
        "\(check.name): \(check.detail)"
    }
}

#Preview {
    NavigationStack { InvestigateView() }
}

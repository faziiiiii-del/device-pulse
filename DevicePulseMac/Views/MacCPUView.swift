//
//  MacCPUView.swift
//  DevicePulseMac
//

import SwiftUI

struct MacCPUView: View {
    @StateObject private var cpu = MacCPUMonitor()
    @StateObject private var gpu = MacGPUMonitor()
    @StateObject private var thermal = MacThermalMonitor()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("CPU & Thermal").font(.largeTitle).bold()

                MacCard(title: "Utilization", systemImage: "cpu", tint: MacSection.cpu.tint) {
                    if let load = cpu.load {
                        MacUsageBar(
                            usedLabel: "\(Int(load.usedFraction * 100))% used",
                            totalLabel: "\(cpu.coreCount) logical cores",
                            fraction: load.usedFraction,
                            tint: .blue
                        )
                        HStack(spacing: 24) {
                            MacMiniStat(label: "User", value: percent(load.user, of: load.total))
                            MacMiniStat(label: "System", value: percent(load.system, of: load.total))
                            MacMiniStat(label: "Idle", value: percent(load.idle, of: load.total))
                            MacMiniStat(label: "Nice", value: percent(load.nice, of: load.total))
                        }
                    } else {
                        Text("Collecting data…").font(.caption).foregroundStyle(.secondary)
                    }
                    MacInfoRow(label: "Frequency", value: "Not exposed by this Mac (no public API on Apple Silicon)")
                }

                MacCard(title: "Per-Core Utilization", systemImage: "square.grid.3x3", tint: MacSection.cpu.tint) {
                    if cpu.perCoreUsage.isEmpty {
                        Text("Collecting data…").font(.caption).foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(cpu.perCoreUsage.enumerated()), id: \.offset) { index, usage in
                                HStack(spacing: 10) {
                                    Text("Core \(index)").font(.caption2).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                                    coreBar(usage)
                                    Text("\(Int(usage * 100))%").font(.caption2).monospacedDigit().frame(width: 34, alignment: .trailing)
                                }
                            }
                        }
                        if cpu.performanceCoreCount > 0 || cpu.efficiencyCoreCount > 0 {
                            Text("\(cpu.performanceCoreCount) Performance + \(cpu.efficiencyCoreCount) Efficiency cores (from hw.perflevel sysctls). Which specific core index above is which type isn't officially documented, so it isn't labeled per-row.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }

                MacCard(title: "Thermal Pressure", systemImage: "thermometer.medium", tint: MacSection.cpu.tint) {
                    HStack(spacing: 8) {
                        StatusDot(level: thermal.isElevated ? .warning : .good)
                        Text(thermal.text).font(.subheadline).bold()
                    }
                    Text("macOS's own 4-level thermal state (Nominal/Fair/Serious/Critical) — there's no public API for an exact CPU temperature in °C on Apple Silicon, so this coarse state is the honest ceiling of what any app can show.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                MacCard(title: "GPU", systemImage: "cube.transparent", tint: MacSection.cpu.tint) {
                    if let util = gpu.utilizationPercent {
                        MacUsageBar(
                            usedLabel: "\(util)% used",
                            totalLabel: gpu.model ?? "GPU",
                            fraction: Double(util) / 100,
                            tint: .purple
                        )
                        HStack(spacing: 24) {
                            if let inUse = gpu.inUseMemoryBytes {
                                MacMiniStat(label: "In-Use Memory", value: ByteFormat.string(inUse))
                            }
                            if let allocated = gpu.allocatedMemoryBytes {
                                MacMiniStat(label: "Allocated", value: ByteFormat.string(allocated))
                            }
                            if let cores = gpu.coreCount {
                                MacMiniStat(label: "GPU Cores", value: "\(cores)")
                            }
                        }
                        Text("Apple Silicon uses unified memory — \"In-Use\"/\"Allocated\" here are GPU-attributed system memory, not a separate VRAM pool. No public API exposes GPU temperature or clock speed.")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("GPU utilization unavailable on this Mac.").font(.caption).foregroundStyle(.secondary)
                    }
                }

                MacCard(title: "History", systemImage: "chart.xyaxis.line", tint: MacSection.cpu.tint) {
                    Text("CPU").font(.caption).foregroundStyle(.secondary)
                    MacSparkline(values: cpu.history, tint: .blue)
                        .frame(height: 70)
                    if !gpu.history.isEmpty {
                        Text("GPU").font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                        MacSparkline(values: gpu.history, tint: .purple)
                            .frame(height: 70)
                    }
                    Text("Sampled every 2 seconds via host_statistics(HOST_CPU_LOAD_INFO) and IORegistry's GPU PerformanceStatistics — the same public APIs Activity Monitor and open-source GPU monitors use.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
    }

    private func coreBar(_ fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.gray.opacity(0.2))
                RoundedRectangle(cornerRadius: 3).fill(Color.blue)
                    .frame(width: max(3, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 8)
    }

    private func percent(_ value: Double, of total: Double) -> String {
        guard total > 0 else { return "—" }
        return "\(Int((value / total) * 100))%"
    }
}

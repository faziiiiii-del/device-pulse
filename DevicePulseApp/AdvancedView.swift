//
//  AdvancedView.swift
//  DevicePulse
//
//  EXPERIMENTAL. On-device, relative benchmarks — not official scores,
//  not comparable across devices/OS versions/benchmark tools. Useful only
//  as a same-device reference point over time. See Benchmarks.swift.
//

import SwiftUI

struct AdvancedView: View {
    @State private var cpuResult: Benchmarks.CPUResult?
    @State private var diskResult: Benchmarks.DiskResult?
    @State private var memoryResult: Benchmarks.MemoryResult?
    @State private var gpuResult: Benchmarks.GPUResult?
    @State private var runningTask: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("These are rough, single-run, relative benchmarks using only public APIs (CPU math, file I/O, Metal). They are NOT official scores and aren't comparable to Geekbench or similar tools — useful only for comparing this device against itself over time.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)

                benchmarkCard(
                    title: "CPU (Prime Sieve)",
                    icon: "cpu",
                    isRunning: runningTask == "cpu",
                    action: runCPU
                ) {
                    if let result = cpuResult {
                        InfoRow(label: "Elapsed", value: String(format: "%.0f ms", result.elapsedMs))
                        InfoRow(label: "Primes found", value: "\(result.primesFound)")
                    }
                }

                benchmarkCard(
                    title: "Disk I/O (this app's tmp folder)",
                    icon: "internaldrive",
                    isRunning: runningTask == "disk",
                    action: runDisk
                ) {
                    if let result = diskResult {
                        InfoRow(label: "Write", value: String(format: "%.0f MB/s", result.writeMBps))
                        InfoRow(label: "Read", value: String(format: "%.0f MB/s", result.readMBps))
                    } else if runningTask != "disk" {
                        Text("Not run yet.").font(.caption).foregroundStyle(.secondary)
                    }
                }

                benchmarkCard(
                    title: "Memory Allocation",
                    icon: "memorychip",
                    isRunning: runningTask == "memory",
                    action: runMemory
                ) {
                    if let result = memoryResult {
                        InfoRow(label: "Buffer size", value: "\(result.megabytes) MB")
                        InfoRow(label: "Alloc + fill + free", value: String(format: "%.0f ms", result.allocateMs))
                    }
                }

                benchmarkCard(
                    title: "GPU (Metal)",
                    icon: "cube.transparent",
                    isRunning: runningTask == "gpu",
                    action: runGPU
                ) {
                    if let result = gpuResult {
                        InfoRow(label: "Device", value: result.deviceName)
                        if let ms = result.elapsedMs {
                            InfoRow(label: "4M-element add kernel", value: String(format: "%.1f ms", ms))
                        } else {
                            Text("Device found but the compute test couldn't run (common in Simulator).")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else if runningTask != "gpu" {
                        Text("Not run yet.").font(.caption).foregroundStyle(.secondary)
                    }
                }

                StatCard(title: "Filesystem", systemImage: "externaldrive.badge.questionmark") {
                    filesystemStats
                }

                StatCard(title: "Network Interfaces", systemImage: "network") {
                    let interfaces = NetworkDiagnostics.localIPAddresses()
                    if interfaces.isEmpty {
                        Text("No active interfaces with an IPv4 address found.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(interfaces, id: \.address) { entry in
                            InfoRow(label: entry.interface, value: entry.address)
                        }
                    }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Advanced")
    }

    private func benchmarkCard<Content: View>(
        title: String, icon: String, isRunning: Bool, action: @escaping () -> Void, @ViewBuilder content: () -> Content
    ) -> some View {
        StatCard(title: title, systemImage: icon) {
            content()
            Button {
                action()
            } label: {
                if isRunning {
                    HStack { ProgressView(); Text("Running…") }
                } else {
                    Label("Run", systemImage: "play.fill")
                }
            }
            .buttonStyle(.bordered)
            .disabled(runningTask != nil)
        }
    }

    private var filesystemStats: some View {
        var stat = statfs()
        let path = NSHomeDirectory()
        let result = statfs(path, &stat)
        return Group {
            if result == 0 {
                let blockSize = Int64(stat.f_bsize)
                let totalBytes = blockSize * Int64(stat.f_blocks)
                let freeBytes = blockSize * Int64(stat.f_bfree)
                let fsType = withUnsafeBytes(of: stat.f_fstypename) { raw -> String in
                    let cString = raw.bindMemory(to: CChar.self)
                    return String(cString: cString.baseAddress!)
                }
                InfoRow(label: "Filesystem type", value: fsType)
                InfoRow(label: "Block size", value: ByteFormat.string(Int64(blockSize)))
                InfoRow(label: "Total blocks", value: "\(stat.f_blocks)")
                InfoRow(label: "Free blocks", value: "\(stat.f_bfree)")
                InfoRow(label: "Via statfs()", value: "\(ByteFormat.string(freeBytes)) free of \(ByteFormat.string(totalBytes))")
            } else {
                Text("statfs() failed.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func runCPU() {
        runningTask = "cpu"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Benchmarks.cpuBenchmark()
            DispatchQueue.main.async {
                cpuResult = result
                runningTask = nil
            }
        }
    }

    private func runDisk() {
        runningTask = "disk"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Benchmarks.diskBenchmark()
            DispatchQueue.main.async {
                diskResult = result
                runningTask = nil
            }
        }
    }

    private func runMemory() {
        runningTask = "memory"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Benchmarks.memoryAllocationBenchmark()
            DispatchQueue.main.async {
                memoryResult = result
                runningTask = nil
            }
        }
    }

    private func runGPU() {
        runningTask = "gpu"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Benchmarks.gpuInfo()
            DispatchQueue.main.async {
                gpuResult = result
                runningTask = nil
            }
        }
    }
}

#Preview {
    NavigationStack { AdvancedView() }
}

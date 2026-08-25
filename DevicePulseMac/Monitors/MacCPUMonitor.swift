//
//  MacCPUMonitor.swift
//  DevicePulseMac
//
//  Aggregate CPU utilization via the PUBLIC Mach host_statistics API
//  (HOST_CPU_LOAD_INFO). This is the same public, documented API used by
//  Activity Monitor and countless legitimate open-source tools — not a
//  private API. It reports cumulative tick counts per state; percentages
//  are derived from the delta between two polls.
//

import Foundation
import Combine

struct CPULoad {
    let user: Double
    let system: Double
    let idle: Double
    let nice: Double

    var total: Double { user + system + idle + nice }
    var usedFraction: Double { total == 0 ? 0 : (user + system + nice) / total }
}

final class MacCPUMonitor: ObservableObject {
    @Published var load: CPULoad?
    @Published var history: [Double] = []
    @Published var coreCount: Int = ProcessInfo.processInfo.activeProcessorCount
    @Published var perCoreUsage: [Double] = []

    /// Apple Silicon reports performance and efficiency cores as
    /// separate `hw.perflevelN.physicalcpu` groups — public sysctls.
    /// Core ordering within `host_processor_info`'s per-core array isn't
    /// documented as stable, so this is shown as a count split, not a
    /// claim about which specific core index is which type.
    @Published var performanceCoreCount: Int = 0
    @Published var efficiencyCoreCount: Int = 0

    private var previousTicks: host_cpu_load_info?
    private var previousPerCoreTicks: [[UInt32]]?
    private var timer: Timer?
    private var timeSinceLastRefresh: TimeInterval = 0
    private let tickInterval: TimeInterval = 1
    private let maxHistory = 60

    init() {
        performanceCoreCount = Self.sysctlInt("hw.perflevel0.physicalcpu") ?? 0
        efficiencyCoreCount = Self.sysctlInt("hw.perflevel1.physicalcpu") ?? 0
        refresh()
        // Ticks every second but only actually refreshes once the
        // user's configured interval (Settings ▸ Refresh) has elapsed —
        // read fresh each tick, so changing the slider takes effect
        // immediately with no timer to reschedule.
        timer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            timeSinceLastRefresh += tickInterval
            if timeSinceLastRefresh >= DevicePulseSettings.refreshInterval {
                timeSinceLastRefresh = 0
                refresh()
            }
        }
    }

    deinit { timer?.invalidate() }

    func refresh() {
        refreshAggregate()
        refreshPerCore()
    }

    private func refreshAggregate() {
        guard let ticks = Self.readTicks() else { return }
        defer { previousTicks = ticks }

        guard let previous = previousTicks else { return }

        let userDelta = Double(ticks.cpu_ticks.0 &- previous.cpu_ticks.0)
        let systemDelta = Double(ticks.cpu_ticks.1 &- previous.cpu_ticks.1)
        let idleDelta = Double(ticks.cpu_ticks.2 &- previous.cpu_ticks.2)
        let niceDelta = Double(ticks.cpu_ticks.3 &- previous.cpu_ticks.3)

        let result = CPULoad(user: userDelta, system: systemDelta, idle: idleDelta, nice: niceDelta)
        load = result
        history.append(result.usedFraction)
        if history.count > maxHistory {
            history.removeFirst(history.count - maxHistory)
        }
    }

    private func refreshPerCore() {
        guard let ticks = Self.readPerCoreTicks() else { return }
        defer { previousPerCoreTicks = ticks }
        guard let previous = previousPerCoreTicks, previous.count == ticks.count else { return }

        perCoreUsage = zip(ticks, previous).map { current, prior in
            let user = Double(current[0] &- prior[0])
            let system = Double(current[1] &- prior[1])
            let idle = Double(current[2] &- prior[2])
            let nice = Double(current[3] &- prior[3])
            let total = user + system + idle + nice
            return total == 0 ? 0 : (user + system + nice) / total
        }
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    private static func readPerCoreTicks() -> [[UInt32]]? {
        var processorCount: natural_t = 0
        var processorInfo: processor_info_array_t?
        var processorInfoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &processorCount, &processorInfo, &processorInfoCount)
        guard result == KERN_SUCCESS, let info = processorInfo else { return nil }
        defer {
            let size = vm_size_t(processorInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)
        }

        var cores: [[UInt32]] = []
        let cpuStateCount = 4
        for i in 0..<Int(processorCount) {
            var ticks: [UInt32] = []
            for state in 0..<cpuStateCount {
                ticks.append(UInt32(bitPattern: info[i * cpuStateCount + state]))
            }
            cores.append(ticks)
        }
        return cores
    }

    private static func readTicks() -> host_cpu_load_info? {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        var info = host_cpu_load_info()
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info
    }
}

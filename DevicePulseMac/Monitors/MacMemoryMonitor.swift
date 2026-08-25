//
//  MacMemoryMonitor.swift
//  DevicePulseMac
//
//  Real macOS memory statistics via PUBLIC APIs:
//   - host_statistics64(HOST_VM_INFO64) for wired/active/inactive/free/
//     compressed page counts — the same Mach API Activity Monitor uses.
//   - sysctlbyname("vm.swapusage") for swap total/used/free — the same
//     data `sysctl vm.swapusage` on the command line reports.
//   - DispatchSource memory-pressure for the live pressure signal.
//

import Foundation
import Darwin
import Combine

struct MacMemoryStats {
    let total: UInt64
    let used: UInt64
    let free: UInt64
    let active: UInt64
    let inactive: UInt64
    let wired: UInt64
    let compressed: UInt64

    var usedFraction: Double {
        total == 0 ? 0 : Double(used) / Double(total)
    }
}

struct SwapStats {
    let total: UInt64
    let used: UInt64
    let free: UInt64
}

/// One-shot reads of the kernel's own memory pressure classification —
/// the same signal `DispatchSourceMemoryPressure` delivers as events,
/// via the `kern.memorystatus_vm_pressure_level` sysctl (undocumented in
/// a header, but the same value macOS's own `memory_pressure` CLI tool
/// exposes; 1=normal, 2=warning, 4=critical). This is NOT the same
/// thing as "% of RAM used" — macOS can legitimately sit at 90%+ used
/// via caching/compression while pressure stays normal. Point-in-time
/// callers (diagnostics, one-shot dashboard reads) should use this
/// instead of thresholding raw usedFraction; continuously-updating UI
/// should prefer `MacMemoryMonitor.pressure`, which is event-driven.
enum MacMemoryPressureReader {
    static func current() -> MacMemoryMonitor.PressureLevel {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0 else {
            return .normal
        }
        switch value {
        case 4: return .critical
        case 2: return .warning
        default: return .normal
        }
    }
}

final class MacMemoryMonitor: ObservableObject {
    enum PressureLevel: String {
        case normal = "Normal"
        case warning = "Warning"
        case critical = "Critical"
    }

    @Published var stats: MacMemoryStats?
    @Published var swap: SwapStats?
    @Published var pressure: PressureLevel = .normal
    @Published var history: [Double] = []

    private var timer: Timer?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var timeSinceLastRefresh: TimeInterval = 0
    private let tickInterval: TimeInterval = 1
    private let maxHistory = 60

    init() {
        refresh()
        // See MacCPUMonitor for why this ticks every second but only
        // refreshes once Settings' configured interval has elapsed.
        timer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            timeSinceLastRefresh += tickInterval
            if timeSinceLastRefresh >= DevicePulseSettings.refreshInterval {
                timeSinceLastRefresh = 0
                refresh()
            }
        }

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical, .normal], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let event = source?.data else { return }
            if event.contains(.critical) {
                self?.pressure = .critical
            } else if event.contains(.warning) {
                self?.pressure = .warning
            } else {
                self?.pressure = .normal
            }
        }
        source.resume()
        pressureSource = source
    }

    deinit {
        timer?.invalidate()
        pressureSource?.cancel()
    }

    func refresh() {
        stats = Self.readMemoryStats()
        swap = Self.readSwapUsage()

        if let stats {
            history.append(stats.usedFraction)
            if history.count > maxHistory {
                history.removeFirst(history.count - maxHistory)
            }
            // Cross-check against the kernel's own current classification
            // rather than a raw usedFraction threshold — high RAM usage
            // alone (caching/compression) is not the same thing as
            // memory pressure. The DispatchSource above still owns
            // updates the moment a new pressure event actually fires;
            // this just keeps the value correct between events/at startup.
            pressure = MacMemoryPressureReader.current()
        }
    }

    private static func readMemoryStats() -> MacMemoryStats? {
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)

        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)

        let result = withUnsafeMutablePointer(to: &vmStats) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let total = ProcessInfo.processInfo.physicalMemory
        let pageSize64 = UInt64(pageSize)
        let free = UInt64(vmStats.free_count) * pageSize64
        let active = UInt64(vmStats.active_count) * pageSize64
        let inactive = UInt64(vmStats.inactive_count) * pageSize64
        let wired = UInt64(vmStats.wire_count) * pageSize64
        let compressed = UInt64(vmStats.compressor_page_count) * pageSize64
        let used = active + wired + compressed

        return MacMemoryStats(total: total, used: used, free: free, active: active, inactive: inactive, wired: wired, compressed: compressed)
    }

    private static func readSwapUsage() -> SwapStats? {
        var size: Int = 0
        guard sysctlbyname("vm.swapusage", nil, &size, nil, 0) == 0, size >= 24 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("vm.swapusage", &buffer, &size, nil, 0) == 0 else { return nil }

        return buffer.withUnsafeBytes { raw -> SwapStats in
            let total = raw.load(fromByteOffset: 0, as: UInt64.self)
            let used = raw.load(fromByteOffset: 8, as: UInt64.self)
            let free = raw.load(fromByteOffset: 16, as: UInt64.self)
            return SwapStats(total: total, used: used, free: free)
        }
    }

    /// Best-effort process-level memory footprint for this app itself.
    static func appMemoryUsage() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.stride / MemoryLayout<natural_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.resident_size
    }
}

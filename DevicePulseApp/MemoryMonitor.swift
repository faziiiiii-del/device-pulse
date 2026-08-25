//
//  MemoryMonitor.swift
//  DevicePulse
//
//  Reads system-wide memory statistics via the PUBLIC Mach host_statistics64
//  API. This is the same technique used by legitimate "device info" apps —
//  it is not a private/undocumented API. It gives an approximation of
//  used/free/active/inactive/wired/compressed memory across the whole
//  device. It does NOT give a per-app breakdown of what other apps are
//  using — iOS does not allow any app to see that.
//

import Foundation
import Darwin

struct MemoryStats {
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

enum MemoryReader {
    static func read() -> MemoryStats? {
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

        return MemoryStats(
            total: total,
            used: used,
            free: free,
            active: active,
            inactive: inactive,
            wired: wired,
            compressed: compressed
        )
    }

    /// Memory this app process itself is using (resident size).
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

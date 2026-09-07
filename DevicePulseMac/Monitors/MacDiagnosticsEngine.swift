//
//  MacDiagnosticsEngine.swift
//  DevicePulseMac
//
//  Runs every check this app can legitimately make on macOS and reports
//  NORMAL / WARNING / INFORMATION / UNAVAILABLE with the exact threshold
//  documented in the detail text. No blended health score.
//

import Foundation

enum MacDiagnosticsEngine {
    static func runAll() -> [DiagnosticCheck] {
        var checks: [DiagnosticCheck] = []
        checks.append(cpuCheck())
        checks.append(memoryCheck())
        checks.append(memoryPressureCheck())
        checks.append(swapCheck())
        checks.append(storageCheck())
        checks.append(networkCheck())
        checks.append(batteryCheck())
        checks.append(thermalCheck())
        return checks
    }

    static func cpuCheck() -> DiagnosticCheck {
        DiagnosticCheck(name: "CPU", status: .info, detail: "See the CPU tab for live utilization and history.")
    }

    static func memoryCheck() -> DiagnosticCheck {
        guard let stats = readMemory() else {
            return DiagnosticCheck(name: "Memory", status: .unavailable, detail: "Could not read memory statistics.")
        }
        return DiagnosticCheck(name: "Memory", status: .info, detail: "\(ByteFormat.memoryString(stats.used)) used of \(ByteFormat.memoryString(stats.total)).")
    }

    static func memoryPressureCheck() -> DiagnosticCheck {
        guard let stats = readMemory() else {
            return DiagnosticCheck(name: "Memory Pressure", status: .unavailable, detail: "Could not read memory statistics.")
        }
        let pressure = MacMemoryPressureReader.current()
        let usedText = "\(Int(stats.usedFraction * 100))% of physical RAM used"
        switch pressure {
        case .critical:
            return DiagnosticCheck(name: "Memory Pressure", status: .warning, detail: "Critical — macOS is actively reclaiming memory. \(usedText).")
        case .warning:
            return DiagnosticCheck(name: "Memory Pressure", status: .warning, detail: "Elevated — macOS is under memory pressure. \(usedText).")
        case .normal:
            return DiagnosticCheck(name: "Memory Pressure", status: .pass, detail: "Normal. \(usedText) — high usage alone (caching/compression) isn't pressure.")
        }
    }

    static func swapCheck() -> DiagnosticCheck {
        guard let swap = readSwap() else {
            return DiagnosticCheck(name: "Swap", status: .unavailable, detail: "Could not read swap statistics.")
        }
        if swap.used > DevicePulseThresholds.swapWarningBytes {
            return DiagnosticCheck(name: "Swap", status: .warning, detail: "\(ByteFormat.memoryString(swap.used)) swapped (threshold: warning above \(ByteFormat.memoryString(DevicePulseThresholds.swapWarningBytes))). Heavy swap usage means macOS is actively paging to disk.")
        }
        return DiagnosticCheck(name: "Swap", status: .pass, detail: "\(ByteFormat.memoryString(swap.used)) swapped.")
    }

    static func storageCheck() -> DiagnosticCheck {
        guard let volume = MacStorageMonitor.mainVolume() else {
            return DiagnosticCheck(name: "Storage", status: .unavailable, detail: "Could not read storage statistics.")
        }
        let freeFraction = 1 - volume.usedFraction
        if freeFraction < DevicePulseThresholds.storageWarningFreeFraction {
            return DiagnosticCheck(name: "Storage", status: .warning, detail: "Only \(Int(freeFraction * 100))% free on \(volume.name) (threshold: warning below \(Int(DevicePulseThresholds.storageWarningFreeFraction * 100))%).")
        }
        return DiagnosticCheck(name: "Storage", status: .pass, detail: "\(ByteFormat.string(volume.available)) free of \(ByteFormat.string(volume.total)) on \(volume.name).")
    }

    static func networkCheck() -> DiagnosticCheck {
        // Point-in-time synchronous read using getifaddrs presence as a proxy;
        // the live NWPathMonitor-backed state is shown on the Network tab.
        let addresses = MacNetworkMonitor.localIPAddresses()
        guard let first = addresses.first else {
            return DiagnosticCheck(name: "Network", status: .warning, detail: "No active network interface with an IPv4 address found.")
        }
        return DiagnosticCheck(name: "Network", status: .pass, detail: "Active interface: \(first.interface) (\(first.address)).")
    }

    static func batteryCheck() -> DiagnosticCheck {
        guard MacBatteryMonitor.hasBattery() else {
            return DiagnosticCheck(name: "Battery", status: .info, detail: "No battery detected (desktop Mac).")
        }
        guard let info = MacBatteryMonitor.current() else {
            return DiagnosticCheck(name: "Battery", status: .unavailable, detail: "Battery detected but details could not be read.")
        }
        if !info.isCharging && info.percentage < DevicePulseThresholds.batteryLowPercent {
            return DiagnosticCheck(name: "Battery", status: .warning, detail: "\(info.percentage)% and not charging (threshold: warning below \(DevicePulseThresholds.batteryLowPercent)%).")
        }
        return DiagnosticCheck(name: "Battery", status: .pass, detail: "\(info.percentage)%, \(info.isCharging ? "charging" : "on battery").")
    }

    static func thermalCheck() -> DiagnosticCheck {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return DiagnosticCheck(name: "Thermal State", status: .pass, detail: "Nominal.")
        case .fair: return DiagnosticCheck(name: "Thermal State", status: .pass, detail: "Fair — slightly elevated but normal under load.")
        case .serious: return DiagnosticCheck(name: "Thermal State", status: .warning, detail: "Serious — the system is actively limiting performance to cool down.")
        case .critical: return DiagnosticCheck(name: "Thermal State", status: .warning, detail: "Critical — significant thermal throttling in effect.")
        @unknown default: return DiagnosticCheck(name: "Thermal State", status: .info, detail: "Unknown state.")
        }
    }

    private static func readMemory() -> MacMemoryStats? {
        // Lightweight direct read (mirrors MacMemoryMonitor's static logic)
        // so diagnostics don't depend on an already-running ObservableObject.
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

    private static func readSwap() -> SwapStats? {
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
}

//
//  MacDeviceMonitor.swift
//  DevicePulseMac
//
//  Static hardware/software info via PUBLIC APIs: sysctl (the same
//  mechanism the `sysctl` command line tool uses), ProcessInfo, and
//  AppKit's NSScreen.
//

import Foundation
import AppKit

enum MacDeviceMonitor {
    static var modelIdentifier: String {
        sysctlString("hw.model") ?? "Unknown"
    }

    static var processorBrand: String {
        sysctlString("machdep.cpu.brand_string") ?? architectureFallback
    }

    private static var architectureFallback: String {
        #if arch(arm64)
        return "Apple Silicon"
        #else
        return "Unknown"
        #endif
    }

    static var architecture: String {
        #if arch(arm64)
        return "arm64 (Apple Silicon)"
        #elseif arch(x86_64)
        return "x86_64 (Intel)"
        #else
        return "Unknown"
        #endif
    }

    static var physicalMemory: UInt64 {
        ProcessInfo.processInfo.physicalMemory
    }

    static var coreCount: Int {
        ProcessInfo.processInfo.activeProcessorCount
    }

    static var systemVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static var buildVersion: String {
        sysctlString("kern.osversion") ?? "Unknown"
    }

    static var hostName: String {
        ProcessInfo.processInfo.hostName
    }

    static var uptimeText: String {
        let uptime = ProcessInfo.processInfo.systemUptime
        let days = Int(uptime) / 86400
        let hours = (Int(uptime) % 86400) / 3600
        let minutes = (Int(uptime) % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    static var displaySummaries: [String] {
        NSScreen.screens.map { screen in
            let frame = screen.frame
            let scale = screen.backingScaleFactor
            return "\(Int(frame.width)) × \(Int(frame.height)) @ \(scale)x"
        }
    }

    private static func sysctlString(_ name: String) -> String? {
        var size: Int = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

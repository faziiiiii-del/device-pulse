//
//  DeviceInfo.swift
//  DevicePulse
//
//  Static device info via public APIs: model identifier, iOS version,
//  device name, and system uptime.
//

import UIKit
import Metal

enum DeviceInfo {
    static var processorArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64 (Simulator)"
        #else
        return "Unknown"
        #endif
    }

    static var screenSizeText: String {
        let bounds = UIScreen.main.bounds
        return "\(Int(bounds.width)) × \(Int(bounds.height))"
    }

    static var screenScaleText: String {
        "\(UIScreen.main.scale)x"
    }

    static var localeText: String {
        Locale.current.identifier
    }

    static var timezoneText: String {
        let tz = TimeZone.current
        let offsetHours = Double(tz.secondsFromGMT()) / 3600
        return "\(tz.identifier) (UTC\(offsetHours >= 0 ? "+" : "")\(offsetHours))"
    }

    static var metalAvailableText: String {
        MTLCreateSystemDefaultDevice()?.name ?? "Unavailable"
    }

    static var modelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce("") { partial, element in
            guard let value = element.value as? Int8, value != 0 else { return partial }
            return partial + String(UnicodeScalar(UInt8(value)))
        }
        return identifier
    }

    static var systemVersion: String {
        "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
    }

    static var deviceName: String {
        UIDevice.current.name
    }

    static var uptimeText: String {
        let uptime = ProcessInfo.processInfo.systemUptime
        let days = Int(uptime) / 86400
        let hours = (Int(uptime) % 86400) / 3600
        let minutes = (Int(uptime) % 3600) / 60
        if days > 0 {
            return "\(days)d \(hours)h \(minutes)m"
        } else if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
}

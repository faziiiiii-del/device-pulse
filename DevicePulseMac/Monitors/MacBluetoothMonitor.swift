//
//  MacBluetoothMonitor.swift
//  DevicePulseMac
//
//  Connected Bluetooth peripherals and their battery levels, read via
//  `system_profiler SPBluetoothDataType -json` — Apple's own reporting
//  tool, the exact data "System Report ▸ Bluetooth" shows. Battery level
//  is only reported for devices that actually publish it over Bluetooth
//  (most Apple peripherals, many third-party mice / keyboards / headsets);
//  devices that don't publish one are shown without a level rather than a
//  guessed number.
//

import Foundation

struct BluetoothPeripheral: Identifiable, Equatable {
    var id: String { address.isEmpty ? name : address }
    let name: String
    let address: String
    let kind: Kind
    let isConnected: Bool
    /// Single battery percentage for simple devices (mouse, keyboard…).
    let battery: Int?
    /// AirPods-style split levels; any of these may be nil.
    let batteryLeft: Int?
    let batteryRight: Int?
    let batteryCase: Int?
    /// Signal strength in dBm — reported for some nearby devices
    /// (handoff peers) instead of a battery level.
    let rssi: Int?

    enum Kind: String {
        case mouse = "Mouse"
        case keyboard = "Keyboard"
        case trackpad = "Trackpad"
        case headphones = "Headphones"
        case speaker = "Speaker"
        case gamepad = "Game Controller"
        case phone = "Phone"
        case tablet = "Tablet"
        case other = "Device"

        var symbol: String {
            switch self {
            case .mouse: return "magicmouse"
            case .keyboard: return "keyboard"
            case .trackpad: return "rectangle.and.hand.point.up.left"
            case .headphones: return "headphones"
            case .speaker: return "hifispeaker"
            case .gamepad: return "gamecontroller"
            case .phone: return "iphone"
            case .tablet: return "ipad"
            case .other: return "dot.radiowaves.left.and.right"
            }
        }
    }

    var hasAnyBattery: Bool {
        battery != nil || batteryLeft != nil || batteryRight != nil || batteryCase != nil
    }

    /// Lowest known cell, for a quick "worst-case" summary.
    var lowestBattery: Int? {
        [battery, batteryLeft, batteryRight, batteryCase].compactMap { $0 }.min()
    }

    /// Short human-readable status for the right-hand side of a row.
    var statusText: String {
        if let battery { return "\(battery)%" }
        var parts: [String] = []
        if let batteryLeft { parts.append("L \(batteryLeft)%") }
        if let batteryRight { parts.append("R \(batteryRight)%") }
        if let batteryCase { parts.append("Case \(batteryCase)%") }
        if !parts.isEmpty { return parts.joined(separator: "  ") }
        if let rssi { return "Signal \(rssi) dBm" }
        return isConnected ? "Connected" : "Paired"
    }
}

enum MacBluetoothMonitor {
    static func scan() -> [BluetoothPeripheral] {
        guard let output = runSystemProfiler(),
              let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]]
        else { return [] }

        var result: [BluetoothPeripheral] = []
        for section in sections {
            result += parseDeviceList(section["device_connected"], connected: true)
            result += parseDeviceList(section["device_not_connected"], connected: false)
        }
        return result.sorted {
            if $0.isConnected != $1.isConnected { return $0.isConnected }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func parseDeviceList(_ raw: Any?, connected: Bool) -> [BluetoothPeripheral] {
        guard let entries = raw as? [[String: Any]] else { return [] }
        return entries.compactMap { entry -> BluetoothPeripheral? in
            // Each entry is a single-key dict: { "Device Name": { props } }.
            guard let (name, value) = entry.first, let props = value as? [String: Any] else { return nil }
            return BluetoothPeripheral(
                name: name,
                address: props["device_address"] as? String ?? "",
                kind: classify(minorType: props["device_minorType"] as? String, name: name),
                isConnected: connected,
                battery: percent(props["device_batteryLevelMain"]),
                batteryLeft: percent(props["device_batteryLevelLeft"]),
                batteryRight: percent(props["device_batteryLevelRight"]),
                batteryCase: percent(props["device_batteryLevelCase"]),
                rssi: intValue(props["device_rssi"])
            )
        }
    }

    /// `system_profiler` reports levels as strings like `"80%"`; tolerate
    /// a bare number or a missing value too.
    private static func percent(_ raw: Any?) -> Int? {
        guard let raw else { return nil }
        if let n = raw as? Int { return clampPercent(n) }
        if let s = raw as? String {
            let digits = s.trimmingCharacters(in: CharacterSet(charactersIn: "% "))
            if let n = Int(digits) { return clampPercent(n) }
        }
        return nil
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let n = raw as? Int { return n }
        if let s = raw as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    private static func clampPercent(_ n: Int) -> Int { min(100, max(0, n)) }

    private static func classify(minorType: String?, name: String) -> BluetoothPeripheral.Kind {
        let hay = "\(minorType ?? "") \(name)".lowercased()
        if hay.contains("mouse") { return .mouse }
        if hay.contains("trackpad") { return .trackpad }
        if hay.contains("keyboard") { return .keyboard }
        if hay.contains("gamepad") || hay.contains("controller") { return .gamepad }
        if hay.contains("headphone") || hay.contains("headset") || hay.contains("airpod") { return .headphones }
        if hay.contains("speaker") { return .speaker }
        if hay.contains("ipad") || hay.contains("tablet") { return .tablet }
        if hay.contains("iphone") || hay.contains("phone") { return .phone }
        return .other
    }

    private static func runSystemProfiler() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        task.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}

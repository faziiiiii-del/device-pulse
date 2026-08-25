//
//  MacWiFiNetworksMonitor.swift
//  DevicePulseMac
//
//  Lists networks this Mac has previously joined and remembers — via
//  `networksetup`, Apple's own documented CLI for exactly this (the
//  same tool System Settings ▸ Wi-Fi ▸ Advanced uses under the hood).
//  This is NOT a live scan of nearby networks: iOS/macOS give
//  third-party apps no public API for that without Location permission,
//  and even with it, signal strength/BSSID aren't exposed. This only
//  ever shows/removes entries from this Mac's own preferred-network
//  list — never anything about networks it hasn't joined.
//

import Foundation

struct SavedWiFiNetwork: Identifiable, Equatable {
    var id: String { ssid }
    let ssid: String
}

enum MacWiFiNetworksMonitor {
    /// Found via `-listallhardwareports` rather than assumed — "en0"
    /// is not guaranteed to be the Wi-Fi interface on every Mac.
    static func wifiDeviceName() -> String? {
        guard let output = run(["-listallhardwareports"]) else { return nil }
        let lines = output.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() where line.contains("Wi-Fi") || line.contains("AirPort") {
            guard index + 1 < lines.count, let range = lines[index + 1].range(of: "Device: ") else { continue }
            return String(lines[index + 1][range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    static func preferredNetworks() -> [SavedWiFiNetwork] {
        guard let device = wifiDeviceName(), let output = run(["-listpreferredwirelessnetworks", device]) else { return [] }
        return output
            .components(separatedBy: "\n")
            .dropFirst() // header: "Preferred networks on en0:"
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { SavedWiFiNetwork(ssid: $0) }
    }

    /// Same action as System Settings ▸ Wi-Fi ▸ Advanced ▸ remove
    /// network. Real removal via the documented CLI — never a guess,
    /// and the caller is told honestly if it fails rather than assuming
    /// success.
    @discardableResult
    static func forget(_ network: SavedWiFiNetwork) -> Bool {
        guard let device = wifiDeviceName() else { return false }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        task.arguments = ["-removepreferredwirelessnetwork", device, network.ssid]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    private static func run(_ arguments: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return nil }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}

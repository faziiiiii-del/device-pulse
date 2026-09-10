//
//  MacWiFiInfoMonitor.swift
//  DevicePulseMac
//
//  Live details about the Wi-Fi network this Mac is CURRENTLY joined to
//  — signal, noise, channel, band, PHY mode, negotiated rate, security.
//  Read via `system_profiler SPAirPortDataType -json`, Apple's own
//  diagnostic dump (System Report ▸ Wi-Fi). This path does not prompt
//  for Location access; the modern `CWWiFiClient` RSSI/SSID accessors do
//  on macOS 14+, so they're deliberately not used here.
//
//  On some macOS versions the current SSID comes back as "<redacted>"
//  unless the app has Location permission — signal/channel/rate are
//  still reported in that case, and the UI says the name is hidden by
//  macOS rather than showing a blank or a fake value.
//

import Foundation

struct WiFiConnectionInfo: Equatable {
    var ssid: String?
    var ssidRedacted: Bool
    var rssiDbm: Int?
    var noiseDbm: Int?
    var channel: Int?
    var band: String?          // "2.4 GHz" / "5 GHz" / "6 GHz"
    var channelWidthMHz: Int?
    var phyMode: String?       // "Wi-Fi 6 (802.11ax)"
    var txRateMbps: Int?
    var security: String?      // "WPA3", "WPA2 Personal", "Open", …
    var countryCode: String?

    /// Signal-to-noise ratio in dB — a better "how good is this link"
    /// number than raw RSSI alone.
    var snrDb: Int? {
        guard let rssiDbm, let noiseDbm else { return nil }
        return rssiDbm - noiseDbm
    }

    /// 0…1 for a bar, from RSSI. −50 dBm or stronger reads as full,
    /// −100 dBm as empty. Rough but matches how the macOS menu-bar
    /// Wi-Fi icon's bars behave.
    var signalFraction: Double? {
        guard let rssiDbm else { return nil }
        return min(1, max(0, Double(rssiDbm + 100) / 50))
    }

    var signalQuality: String {
        guard let rssiDbm else { return "Unknown" }
        switch rssiDbm {
        case (-55)...: return "Excellent"
        case (-67)..<(-55): return "Good"
        case (-75)..<(-67): return "Fair"
        case (-85)..<(-75): return "Weak"
        default: return "Poor"
        }
    }
}

enum MacWiFiInfoMonitor {
    /// Returns nil when there's no Wi-Fi hardware or the interface isn't
    /// associated with a network; the caller shows a "not connected"
    /// state rather than an empty card.
    static func current() -> WiFiConnectionInfo? {
        guard let output = runSystemProfiler(),
              let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPAirPortDataType"] as? [[String: Any]]
        else { return nil }

        for section in sections {
            guard let interfaces = section["spairport_airport_interfaces"] as? [[String: Any]] else { continue }
            for interface in interfaces {
                guard let net = interface["spairport_current_network_information"] as? [String: Any] else { continue }
                return parse(net)
            }
        }
        return nil
    }

    private static func parse(_ net: [String: Any]) -> WiFiConnectionInfo {
        var info = WiFiConnectionInfo(ssidRedacted: false)

        if let name = net["_name"] as? String {
            if name == "<redacted>" || name.lowercased() == "redacted" {
                info.ssidRedacted = true
            } else {
                info.ssid = name
            }
        }

        if let signalNoise = net["spairport_signal_noise"] as? String {
            // Format: "-49 dBm / -91 dBm"
            let numbers = signalNoise
                .components(separatedBy: "/")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if numbers.count == 2 {
                info.rssiDbm = firstInt(in: numbers[0])
                info.noiseDbm = firstInt(in: numbers[1])
            }
        }

        if let channelString = net["spairport_network_channel"] as? String {
            // Format: "100 (5GHz, 80MHz)"
            info.channel = firstInt(in: channelString)
            let lower = channelString.lowercased()
            if lower.contains("6ghz") { info.band = "6 GHz" }
            else if lower.contains("5ghz") { info.band = "5 GHz" }
            else if lower.contains("2ghz") || lower.contains("2.4ghz") { info.band = "2.4 GHz" }
            if let widthRange = lower.range(of: #"(\d+)mhz"#, options: .regularExpression) {
                info.channelWidthMHz = firstInt(in: String(lower[widthRange]))
            }
        }

        info.phyMode = friendlyPHYMode(net["spairport_network_phymode"] as? String)
        info.txRateMbps = intValue(net["spairport_network_rate"])
        info.security = friendlySecurity(net["spairport_security_mode"] as? String)
        info.countryCode = net["spairport_network_country_code"] as? String

        return info
    }

    /// Pulls the first (optionally signed) integer out of a string.
    private static func firstInt(in string: String) -> Int? {
        guard let range = string.range(of: #"-?\d+"#, options: .regularExpression) else { return nil }
        return Int(string[range])
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let n = raw as? Int { return n }
        if let d = raw as? Double { return Int(d) }
        if let s = raw as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    private static func friendlyPHYMode(_ raw: String?) -> String? {
        guard let raw else { return nil }
        switch raw {
        case "802.11ax": return "Wi-Fi 6/6E (802.11ax)"
        case "802.11ac": return "Wi-Fi 5 (802.11ac)"
        case "802.11n": return "Wi-Fi 4 (802.11n)"
        default: return raw
        }
    }

    private static func friendlySecurity(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let lower = raw.lowercased()
        if lower.contains("wpa3") { return lower.contains("transition") ? "WPA2/WPA3" : "WPA3" }
        if lower.contains("wpa2") { return lower.contains("enterprise") ? "WPA2 Enterprise" : "WPA2 Personal" }
        if lower.contains("wpa") { return "WPA" }
        if lower.contains("wep") { return "WEP (insecure)" }
        if lower.contains("none") || lower.contains("open") { return "Open (no security)" }
        return raw
    }

    private static func runSystemProfiler() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        task.arguments = ["SPAirPortDataType", "-json"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}

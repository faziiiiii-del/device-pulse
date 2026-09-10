//
//  MacDiagnosticsReport.swift
//  DevicePulseMac
//
//  Bundles everything Device Pulse can currently read into one plain-text
//  report, for handing to someone else (IT, a forum thread, a support
//  ticket). It only ever contains what the app already shows on screen —
//  no new data is collected for the export, and nothing is uploaded; the
//  caller writes the string to a file the user picks.
//

import Foundation

enum MacDiagnosticsReport {
    /// Builds the full report. Does real work (directory scans,
    /// system_profiler) — call it off the main thread.
    static func build() -> String {
        var out = String()

        func heading(_ title: String) {
            out += "\n" + String(repeating: "=", count: 60) + "\n"
            out += title.uppercased() + "\n"
            out += String(repeating: "=", count: 60) + "\n"
        }
        func row(_ label: String, _ value: String) {
            out += label.padding(toLength: max(label.count, 26), withPad: " ", startingAt: 0)
            out += "  \(value)\n"
        }

        let now = Date()
        let stamp = now.formatted(date: .abbreviated, time: .standard)

        out += "DEVICE PULSE — DIAGNOSTICS REPORT\n"
        out += "Generated: \(stamp)\n"

        // MARK: Hardware / software
        heading("System")
        row("Model", MacDeviceMonitor.modelIdentifier)
        row("Processor", MacDeviceMonitor.processorBrand)
        row("Architecture", MacDeviceMonitor.architecture)
        row("Logical cores", "\(MacDeviceMonitor.coreCount)")
        row("Physical memory", ByteFormat.memoryString(MacDeviceMonitor.physicalMemory))
        row("macOS", "\(MacDeviceMonitor.systemVersion) (\(MacDeviceMonitor.buildVersion))")
        row("Host name", MacDeviceMonitor.hostName)
        row("Uptime", MacDeviceMonitor.uptimeText)
        for (index, summary) in MacDeviceMonitor.displaySummaries.enumerated() {
            row("Display \(index + 1)", summary)
        }

        // MARK: Diagnostic checks (reuses the engine the Dashboard uses)
        heading("Diagnostic Checks")
        for check in MacDiagnosticsEngine.runAll() {
            row(check.name, "[\(check.status.reportWord)] \(check.detail)")
        }

        // MARK: Storage
        heading("Volumes")
        let volumes = MacStorageMonitor.allVolumes()
        if volumes.isEmpty {
            out += "No volumes reported.\n"
        }
        for volume in volumes {
            let free = ByteFormat.string(volume.available)
            let total = ByteFormat.string(volume.total)
            let pct = Int(volume.usedFraction * 100)
            let tags = [volume.isInternal ? "internal" : "external", volume.isRemovable ? "removable" : nil]
                .compactMap { $0 }.joined(separator: ", ")
            row(volume.name, "\(free) free of \(total) (\(pct)% used) — \(tags)")
        }

        // MARK: Battery
        heading("Battery")
        if !MacBatteryMonitor.hasBattery() {
            out += "No battery (desktop Mac).\n"
        } else if let info = MacBatteryMonitor.current() {
            row("Charge", "\(info.percentage)% (\(info.isCharging ? "charging" : "on battery"))")
            row("Power source", info.powerSourceState)
            if let health = info.healthLabel { row("Health estimate", health) }
            if let cap = info.maxCapacityPercent { row("Full charge vs design", "\(cap)%") }
            if let cycles = info.cycleCount { row("Cycle count", "\(cycles)") }
            if let watts = info.wattage { row("Power draw", String(format: "%.1f W", watts)) }
        } else {
            out += "Battery present but details unavailable.\n"
        }

        // MARK: Network
        heading("Network")
        let addresses = MacNetworkMonitor.localIPAddresses()
        if addresses.isEmpty {
            out += "No active IPv4 interface.\n"
        }
        for entry in addresses {
            row(entry.interface, entry.address)
        }
        if let wifi = MacWiFiInfoMonitor.current() {
            out += "\nCurrent Wi-Fi:\n"
            if let ssid = wifi.ssid { row("  Network", ssid) }
            else if wifi.ssidRedacted { row("  Network", "hidden by macOS") }
            if let rssi = wifi.rssiDbm { row("  Signal", "\(rssi) dBm (\(wifi.signalQuality))") }
            if let noise = wifi.noiseDbm { row("  Noise", "\(noise) dBm") }
            if let snr = wifi.snrDb { row("  SNR", "\(snr) dB") }
            if let channel = wifi.channel {
                let band = wifi.band.map { " · \($0)" } ?? ""
                let width = wifi.channelWidthMHz.map { " · \($0) MHz" } ?? ""
                row("  Channel", "\(channel)\(band)\(width)")
            }
            if let phy = wifi.phyMode { row("  Standard", phy) }
            if let rate = wifi.txRateMbps { row("  Link rate", "\(rate) Mbps") }
            if let security = wifi.security { row("  Security", security) }
        }

        // MARK: Bluetooth
        heading("Bluetooth Peripherals")
        let bluetooth = MacBluetoothMonitor.scan().filter(\.isConnected)
        if bluetooth.isEmpty {
            out += "No devices connected.\n"
        }
        for device in bluetooth {
            row(device.name, "\(device.kind.rawValue) — \(device.statusText)")
        }

        // MARK: Startup items
        heading("Startup Items (LaunchAgents / LaunchDaemons)")
        let startup = MacStartupMonitor.scan()
        let loaded = startup.filter(\.isLoaded).count
        row("Total", "\(startup.count) (\(loaded) currently loaded)")
        let byClass = Dictionary(grouping: startup, by: \.classification)
        for classification in [StartupClassification.apple, .knownThirdParty, .userInstalled, .unknown] {
            if let items = byClass[classification], !items.isEmpty {
                row("  \(classification.rawValue)", "\(items.count)")
            }
        }
        let nonApple = startup.filter { $0.classification != .apple }
        if !nonApple.isEmpty {
            out += "\nNon-Apple entries:\n"
            for item in nonApple.prefix(40) {
                row("  \(item.label)", "\(item.type.rawValue)\(item.isLoaded ? ", loaded" : "")")
            }
            if nonApple.count > 40 { out += "  … and \(nonApple.count - 40) more\n" }
        }

        // MARK: Crash reports
        heading("Diagnostic Reports (last 30 days)")
        let cutoff = now.addingTimeInterval(-30 * 24 * 3600)
        let recent = MacCrashReportMonitor.scan().reports.filter { $0.date >= cutoff }
        if recent.isEmpty {
            out += "None in the last 30 days.\n"
        } else {
            for (category, count) in MacCrashReportMonitor.counts(for: recent) {
                row(category.rawValue, "\(count)")
            }
            let topProcesses = Dictionary(grouping: recent, by: \.processName)
                .mapValues(\.count)
                .sorted { $0.value > $1.value }
                .prefix(8)
            out += "\nMost frequent:\n"
            for (process, count) in topProcesses where count > 1 {
                row("  \(process)", "\(count) reports")
            }
        }

        heading("End of report")
        out += "All values read via public macOS APIs / Apple's own CLI tools. "
        out += "Nothing in this report was uploaded anywhere.\n"

        return out
    }

    static func suggestedFileName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "DevicePulse-Diagnostics-\(formatter.string(from: date)).txt"
    }
}

private extension DiagnosticStatus {
    /// Fixed-width-ish word for the plain-text report.
    var reportWord: String {
        switch self {
        case .pass: return "OK"
        case .warning: return "WARN"
        case .info: return "INFO"
        case .unavailable: return "N/A"
        }
    }
}

//
//  MacSettingsView.swift
//  DevicePulseMac
//
//  A real macOS Settings window (⌘,), not a sidebar tab — sidebar items
//  are content, preferences belong here per platform convention.
//

import SwiftUI
import AppKit
import ServiceManagement

struct MacSettingsView: View {
    @AppStorage("refreshIntervalSeconds") private var refreshInterval: Double = 3
    @AppStorage("alertsEnabled") private var alertsEnabled: Bool = true
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false
    @AppStorage("menuBarOnlyMode") private var menuBarOnly: Bool = false
    @AppStorage(AppTheme.storageKey) private var appThemeRaw: String = AppTheme.classic.rawValue
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appThemeRaw) {
                    ForEach(AppTheme.allCases) { theme in
                        Label(theme.rawValue, systemImage: theme.icon).tag(theme.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Text("Frosted applies a translucent dark-glass look across the whole app, independent of your system's light/dark setting. Classic follows your Mac's normal appearance.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Launch Device Pulse at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { newValue in setLaunchAtLogin(newValue) }
                Toggle("Menu bar only (hide Dock icon and window on launch)", isOn: $menuBarOnly)
                    .onChange(of: menuBarOnly) { newValue in
                        NSApp.setActivationPolicy(newValue ? .accessory : .regular)
                    }
                if let launchAtLoginError {
                    Text(launchAtLoginError).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Alerts") {
                Toggle("Watch this Mac in the background", isOn: $alertsEnabled)
                    .onChange(of: alertsEnabled) { newValue in MacAlertMonitor.shared.setEnabled(newValue) }
                Text("Notifies you when: memory pressure is high (using macOS's own pressure signal, not just RAM %), storage falls below 10%, the battery finishes charging, CPU stays above 90% for 10 minutes, memory pressure is elevated AND a single process is unusually large, or a new login item appears. Each alert fires once when the condition starts. Turning this off fully stops the background checks — nothing keeps polling silently.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("Refresh") {
                VStack(alignment: .leading) {
                    Text("Refresh interval: \(Int(refreshInterval))s")
                    Slider(value: $refreshInterval, in: 1...10, step: 1)
                    Text("Controls how often CPU and Memory are sampled. Other tabs (Storage, Network, Processes) refresh on their own fixed schedules, since those involve heavier operations like directory scans.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading) {
                    Text("History retention").foregroundStyle(.secondary)
                    Text("Not built yet — CPU/Memory history is currently just the last 60 in-memory samples per tab, lost on quit. A real 24h/7d/30d history store (which this setting would control) is a planned follow-up, not implemented, so no slider is shown here rather than one that does nothing.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Permissions") {
                MacInfoRow(label: "Full Disk Access", value: hasFullDiskAccessHint)
                Text("Full Disk Access lets Maintenance scan folders like Mail, Messages, and other apps' containers. Grant it in System Settings ▸ Privacy & Security ▸ Full Disk Access if you want deeper scanning — Device Pulse works without it, just with less visibility into protected locations.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("Open Privacy Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
            }

            Section("About") {
                Text("Device Pulse for Mac reads only what macOS exposes through public APIs. Nothing is uploaded anywhere except network tests you explicitly run (which contact speed.cloudflare.com / your DNS resolver). No private APIs, no App Store review constraints assumed — this is a personal utility.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 560)
    }

    private var hasFullDiskAccessHint: String {
        let path = NSHomeDirectory() + "/Library/Mail"
        return FileManager.default.isReadableFile(atPath: path) ? "Likely Granted" : "Not Granted (or nothing to check)"
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "Couldn't update login item: \(error.localizedDescription)"
            launchAtLogin.toggle()
        }
    }
}

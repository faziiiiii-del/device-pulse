//
//  MacAlertMonitor.swift
//  DevicePulseMac
//
//  Background threshold watcher, independent of any open window — runs
//  from app launch (if enabled) so alerts fire even in menu-bar-only
//  mode. Owns its own CPU/Memory monitor instances rather than sharing
//  view-owned ones, since it must outlive whatever views happen to be
//  on screen — but critically, those instances (and their own internal
//  Timers) are only created while actually enabled. Turning "Watch this
//  Mac in the background" off calls stop(), which tears them down
//  entirely — this used to only gate the notification send, meaning
//  "off" still silently kept polling CPU/memory/storage/battery/ps and
//  scanning startup items every ~5 minutes.
//
//  Each condition is edge-triggered where it makes sense (fire once
//  when a state is entered, reset when it clears) rather than repeating
//  on a flat cooldown — a battery sitting at 100% overnight, or memory
//  pressure staying critical, would otherwise re-notify every 30
//  minutes for hours.
//

import Foundation
import UserNotifications

final class MacAlertMonitor {
    static let shared = MacAlertMonitor()

    private var cpu: MacCPUMonitor?
    private var memory: MacMemoryMonitor?
    private var checkTimer: Timer?
    private var tick = 0
    private(set) var isRunning = false

    private var cpuHighSince: Date?
    private var cpuAlerted = false
    private var pressureAlerted = false
    private var storageAlerted = false
    private var batteryFullAlerted = false
    private var lastLargeProcessNotified: [String: Date] = [:]
    private let largeProcessCooldown: TimeInterval = 30 * 60
    private var knownStartupLabels: Set<String>?

    private init() {}

    /// Starts polling if enabled in Settings. Safe to call at launch
    /// unconditionally — it checks the setting itself.
    func start() {
        guard alertsEnabled, !isRunning else { return }
        isRunning = true
        cpu = MacCPUMonitor()
        memory = MacMemoryMonitor()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        checkTimer?.invalidate()
        checkTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.evaluate()
        }
    }

    /// Fully tears down polling — no more CPU/memory timers, no more ps/
    /// nettop/startup-plist scans. Call when the user turns alerts off.
    func stop() {
        isRunning = false
        checkTimer?.invalidate()
        checkTimer = nil
        cpu = nil
        memory = nil
        cpuHighSince = nil
        cpuAlerted = false
        pressureAlerted = false
        storageAlerted = false
        batteryFullAlerted = false
    }

    /// Called from Settings when the toggle changes.
    func setEnabled(_ enabled: Bool) {
        if enabled { start() } else { stop() }
    }

    private var alertsEnabled: Bool {
        UserDefaults.standard.object(forKey: "alertsEnabled") == nil
            || UserDefaults.standard.bool(forKey: "alertsEnabled")
    }

    private func evaluate() {
        tick += 1
        checkCPU()
        checkMemoryPressure()
        checkStorage()
        checkBattery()
        checkLargeProcess()
        if tick % 10 == 0 { checkNewLoginItems() } // every ~5 minutes; plist scan is heavier
    }

    private func checkCPU() {
        guard let fraction = cpu?.load?.usedFraction else { return }
        if fraction > DevicePulseThresholds.cpuWarningFraction {
            if cpuHighSince == nil { cpuHighSince = Date() }
            if !cpuAlerted, let since = cpuHighSince, Date().timeIntervalSince(since) >= 10 * 60 {
                cpuAlerted = true
                notify(title: "Sustained high CPU usage", body: "CPU usage has been above \(Int(DevicePulseThresholds.cpuWarningFraction * 100))% for 10 minutes.")
            }
        } else {
            cpuHighSince = nil
            cpuAlerted = false
        }
    }

    /// Uses the kernel's actual memory pressure classification, not raw
    /// %-used — macOS can legitimately sit at 90%+ used (caching,
    /// compression) with pressure still normal, so thresholding the
    /// fraction directly used to produce false alarms.
    private func checkMemoryPressure() {
        guard let memory, let stats = memory.stats else { return }
        if memory.pressure == .critical {
            if !pressureAlerted {
                pressureAlerted = true
                notify(title: "High memory pressure", body: "macOS is under memory pressure (\(Int(stats.usedFraction * 100))% of \(ByteFormat.memoryString(stats.total)) used). Consider closing some apps.")
            }
        } else {
            pressureAlerted = false
        }
    }

    private func checkStorage() {
        guard let volume = MacStorageMonitor.mainVolume() else { return }
        let freeFraction = 1 - volume.usedFraction
        if freeFraction < DevicePulseThresholds.storageWarningFreeFraction {
            if !storageAlerted {
                storageAlerted = true
                notify(title: "Storage running low", body: "Only \(Int(freeFraction * 100))% free space remains on \(volume.name).")
            }
        } else if freeFraction > DevicePulseThresholds.storageWarningFreeFraction + 0.02 {
            storageAlerted = false // small hysteresis so it doesn't flap right at the line
        }
    }

    private func checkBattery() {
        guard let battery = MacBatteryMonitor.current() else { return }
        if battery.percentage >= 100 && battery.powerSourceState == "AC Power" {
            if !batteryFullAlerted {
                batteryFullAlerted = true
                notify(title: "Battery fully charged", body: "Your Mac is fully charged and connected to power.")
            }
        } else {
            batteryFullAlerted = false
        }
    }

    /// Only actionable combined with elevated memory pressure — a
    /// single process using 20%+ of RAM (Chrome, Xcode, Docker, a VM)
    /// is completely normal on its own and used to alert regardless,
    /// which was just noise on any Mac doing real work.
    ///
    /// `MacProcessMonitor.snapshot()` spawns `ps` and waits for it —
    /// this timer fires on the main run loop (see `start()`), so doing
    /// that inline used to block the main thread for a beat every 30
    /// seconds, the whole time alerts are enabled (the default). The
    /// guard check itself is cheap and stays on main; only the actual
    /// process spawn moves to a background queue.
    private func checkLargeProcess() {
        guard let memory, memory.pressure != .normal else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let entries = MacProcessMonitor.snapshot()
            guard let top = entries.max(by: { $0.memoryPercent < $1.memoryPercent }),
                  top.memoryPercent > DevicePulseThresholds.largeProcessMemoryFraction * 100
            else { return }

            DispatchQueue.main.async {
                let now = Date()
                if let last = self.lastLargeProcessNotified[top.name], now.timeIntervalSince(last) < self.largeProcessCooldown { return }
                self.lastLargeProcessNotified[top.name] = now
                self.notify(title: "Unusually large memory use", body: "Memory pressure is elevated, and \(top.name) accounts for \(Int(top.memoryPercent))% of physical memory (\(ByteFormat.memoryString(top.residentBytes))).")
            }
        }
    }

    /// Same reasoning as `checkLargeProcess` — `MacStartupMonitor.scan()`
    /// spawns a `launchctl print` per LaunchAgent/Daemon (could be dozens),
    /// entirely on the main thread if left inline here.
    private func checkNewLoginItems() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let currentLabels = Set(MacStartupMonitor.scan().map(\.label))
            DispatchQueue.main.async {
                defer { self.knownStartupLabels = currentLabels }
                guard let known = self.knownStartupLabels else { return } // first run: establish baseline, don't alert on existing items
                let newLabels = currentLabels.subtracting(known)
                for label in newLabels {
                    self.notify(title: "New login item detected", body: "\(label) was added to your startup items. Check Startup Optimiser to review it.")
                }
            }
        }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "\(title)-\(Date().timeIntervalSince1970)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

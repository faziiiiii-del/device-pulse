//
//  DevicePulseThresholds.swift
//  DevicePulseMac
//
//  Single source of truth for every warning/critical threshold used
//  across Dashboard, Diagnostics, Alerts, and RAM Optimiser. Before this
//  existed, the same concept (e.g. "storage running low") was checked
//  against different numbers in different files, so a user could see
//  "Normal" on one screen and "Warning" on another for the identical
//  underlying state. Every module should read from here instead of
//  hardcoding its own number.
//
//  These are all straightforward heuristics, not values from any Apple
//  API — nothing here claims to be an official Apple threshold.
//

import Foundation

enum DevicePulseThresholds {
    /// Sustained CPU usage above this fraction is "high."
    static let cpuWarningFraction: Double = 0.9

    /// Below this free-space fraction, storage is "warning."
    static let storageWarningFreeFraction: Double = 0.10
    /// Below this free-space fraction, storage is "critical."
    static let storageCriticalFreeFraction: Double = 0.05

    /// Swapped bytes above this amount is "heavy swap usage."
    static let swapWarningBytes: Int64 = 2_000_000_000

    /// Battery percent below this, while not charging, is "low."
    static let batteryLowPercent: Int = 15

    /// A single process using more than this fraction of physical RAM is
    /// "unusually large" — but per the large-process alert's own logic,
    /// this alone is only actionable combined with elevated memory
    /// pressure (see MacAlertMonitor). A big Chrome/Xcode/Docker process
    /// alone is normal, not a problem.
    static let largeProcessMemoryFraction: Double = 0.20
}

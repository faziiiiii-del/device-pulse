//
//  DevicePulseSettings.swift
//  DevicePulseMac
//

import Foundation

enum DevicePulseSettings {
    /// The user's configured sample rate for live monitors (CPU, Memory)
    /// — read fresh on every tick rather than cached, so dragging the
    /// Settings slider takes effect immediately without restarting any
    /// monitor. Falls back to 3s, matching the slider's own default.
    static var refreshInterval: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: "refreshIntervalSeconds")
        return stored > 0 ? stored : 3
    }
}

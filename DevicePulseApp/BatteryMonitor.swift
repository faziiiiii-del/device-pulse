//
//  BatteryMonitor.swift
//  DevicePulse
//
//  Wraps the PUBLIC UIDevice battery APIs. iOS does not expose battery
//  "health" (max capacity %, cycle count) to third-party apps at all —
//  that data only exists in Settings > Battery > Battery Health, and
//  there is no public API to read it. What we CAN read: charge level,
//  charging state, and Low Power Mode.
//

import UIKit
import Combine

final class BatteryMonitor: ObservableObject {
    @Published var level: Float = UIDevice.current.batteryLevel
    @Published var state: UIDevice.BatteryState = UIDevice.current.batteryState
    @Published var lowPowerMode: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled

    private var cancellables = Set<AnyCancellable>()

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        level = UIDevice.current.batteryLevel
        state = UIDevice.current.batteryState

        NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)
            .sink { [weak self] _ in self?.level = UIDevice.current.batteryLevel }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)
            .sink { [weak self] _ in self?.state = UIDevice.current.batteryState }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
            .sink { [weak self] _ in self?.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled }
            .store(in: &cancellables)
    }

    var levelPercentText: String {
        level < 0 ? "—" : "\(Int((level * 100).rounded()))%"
    }

    var stateText: String {
        switch state {
        case .charging: return "Charging"
        case .full: return "Full"
        case .unplugged: return "Not Charging"
        case .unknown: return "Unknown"
        @unknown default: return "Unknown"
        }
    }

    var isCharging: Bool {
        state == .charging || state == .full
    }
}

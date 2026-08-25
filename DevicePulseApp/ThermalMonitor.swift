//
//  ThermalMonitor.swift
//  DevicePulse
//
//  Wraps the PUBLIC ProcessInfo.thermalState API. iOS exposes a coarse
//  4-level thermal state (nominal/fair/serious/critical) to every app —
//  it does not expose a temperature in degrees; there is no public API
//  for that.
//

import Foundation
import Combine

final class ThermalMonitor: ObservableObject {
    @Published var state: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState

    private var cancellables = Set<AnyCancellable>()

    init() {
        NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .sink { [weak self] _ in self?.state = ProcessInfo.processInfo.thermalState }
            .store(in: &cancellables)
    }

    var text: String {
        switch state {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    var isElevated: Bool { state == .serious || state == .critical }
}

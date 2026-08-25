//
//  MacThermalMonitor.swift
//  DevicePulseMac
//
//  ProcessInfo.thermalState is public and cross-platform. macOS does not
//  expose CPU/GPU temperature in Celsius/Fahrenheit through any public
//  API, so this app never shows one — only Apple's own coarse 4-level
//  state.
//

import Foundation
import Combine

final class MacThermalMonitor: ObservableObject {
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

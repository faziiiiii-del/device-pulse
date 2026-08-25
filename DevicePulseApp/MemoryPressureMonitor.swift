//
//  MemoryPressureMonitor.swift
//  DevicePulse
//
//  Wraps the PUBLIC DispatchSource memory-pressure API. This is the same
//  signal apps use to decide when to free caches; it is a public,
//  documented GCD facility, not a private API.
//

import Foundation

final class MemoryPressureMonitor: ObservableObject {
    enum Level: String {
        case normal = "Normal"
        case warning = "Warning"
        case critical = "Critical"
    }

    @Published var level: Level = .normal

    private var source: DispatchSourceMemoryPressure?

    init() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let event = source?.data else { return }
            if event.contains(.critical) {
                self?.level = .critical
            } else if event.contains(.warning) {
                self?.level = .warning
            } else {
                self?.level = .normal
            }
        }
        source.resume()
        self.source = source
    }

    deinit {
        source?.cancel()
    }
}

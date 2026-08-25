//
//  NetworkMonitor.swift
//  DevicePulse
//
//  Uses the PUBLIC Network framework (NWPathMonitor) to report connection
//  TYPE (Wi-Fi / Cellular / none) and quality flags. iOS does NOT expose
//  Wi-Fi signal strength (RSSI in dBm) to third-party apps under any
//  public API — that was locked down years ago. If you see another app
//  claiming to show a signal-strength number, it is either estimating
//  from something indirect or it's not accurate.
//

import Network
import Combine

final class NetworkMonitor: ObservableObject {
    @Published var connectionType: String = "Checking…"
    @Published var isExpensive: Bool = false
    @Published var isConstrained: Bool = false
    @Published var isConnected: Bool = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.devicedashboard.networkmonitor")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isConnected = path.status == .satisfied
                if !self.isConnected {
                    self.connectionType = "No Connection"
                } else if path.usesInterfaceType(.wifi) {
                    self.connectionType = "Wi-Fi"
                } else if path.usesInterfaceType(.cellular) {
                    self.connectionType = "Cellular"
                } else if path.usesInterfaceType(.wiredEthernet) {
                    self.connectionType = "Ethernet"
                } else {
                    self.connectionType = "Connected"
                }
                self.isExpensive = path.isExpensive
                self.isConstrained = path.isConstrained
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}

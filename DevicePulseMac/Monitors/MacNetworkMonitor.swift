//
//  MacNetworkMonitor.swift
//  DevicePulseMac
//
//  Connection type/status via the PUBLIC Network framework (NWPathMonitor)
//  and local IPv4 addresses via the PUBLIC POSIX getifaddrs() API — the
//  same technique used on the iOS side of Device Pulse.
//

import Foundation
import Network
import Combine

final class MacNetworkMonitor: ObservableObject {
    @Published var connectionType: String = "Checking…"
    @Published var isConnected: Bool = false
    @Published var isExpensive: Bool = false
    @Published var interfaceName: String?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.devicepulse.mac.networkmonitor")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isConnected = path.status == .satisfied
                if !self.isConnected {
                    self.connectionType = "No Connection"
                } else if path.usesInterfaceType(.wifi) {
                    self.connectionType = "Wi-Fi"
                } else if path.usesInterfaceType(.wiredEthernet) {
                    self.connectionType = "Ethernet"
                } else if path.usesInterfaceType(.cellular) {
                    self.connectionType = "Cellular"
                } else if self.isConnected {
                    self.connectionType = "Connected"
                }
                self.isExpensive = path.isExpensive
                self.interfaceName = path.availableInterfaces.first?.name
            }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }

    static func localIPAddresses() -> [(interface: String, address: String)] {
        var results: [(String, String)] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return [] }
        defer { freeifaddrs(ifaddrPtr) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard current.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: current.pointee.ifa_name)
            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(
                current.pointee.ifa_addr, socklen_t(current.pointee.ifa_addr.pointee.sa_len),
                &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST
            )
            results.append((name, String(cString: hostBuffer)))
        }
        return results
    }
}

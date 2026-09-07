//
//  NetworkDiagnostics.swift
//  DevicePulse
//
//  Active network tests, run only when the user taps "Test Connection".
//  Everything here uses PUBLIC APIs:
//   - DNS resolution timing: CFHost (CFNetwork), a public framework.
//   - Latency: a TCP connect via the public Network framework. iOS does
//     NOT give third-party apps raw ICMP ping — this measures how long a
//     TCP handshake takes instead, which is the standard public-API
//     substitute and is labeled as such in the UI.
//   - Download/upload speed: real HTTP transfers against Cloudflare's
//     public speed-test endpoint (speed.cloudflare.com), the same
//     endpoint their own browser-based speed test uses. This transfers
//     a few megabytes of real data over the network when run.
//   - Local IP: read via getifaddrs, a public POSIX API.
//   - Public IP: only fetched if the user explicitly runs the test, via
//     the public ipify.org API.
//
//  Wi-Fi SSID/BSSID and signal strength (RSSI/dBm) are deliberately NOT
//  implemented — reading them requires either Location permission or the
//  "Access WiFi Information" entitlement, and even then iOS does not
//  expose signal strength to third-party apps at all. Rather than add a
//  Location permission this app doesn't otherwise need, that's left out.
//

import Foundation
import Network
import Darwin

enum NetworkDiagnostics {
    struct Result {
        var dnsMs: Double?
        var dnsSuccess: Bool
        var tcpLatencyMs: Double?
        var downloadMbps: Double?
        var uploadMbps: Double?
        var publicIP: String?
    }

    /// `CFHostStartInfoResolution` is a synchronous, blocking call with no timeout of its
    /// own — if the resolver stalls (bad network, DNS blackhole), it can block
    /// indefinitely, which would hang this `async` call forever. Bounded here the same
    /// way `tcpLatency` below bounds its own blocking wait: a timeout fires on a separate
    /// queue, guarded against a double-resume race with the real completion via the same
    /// NSLock pattern (both can fire close together if resolution completes right as the
    /// timeout does). `CFHostCancelInfoResolution` actively interrupts the in-flight
    /// resolution on timeout, rather than merely abandoning a background thread that
    /// stays blocked until the OS's own (potentially much longer) resolver timeout.
    static func resolveDNS(host: String = "www.apple.com", timeout: TimeInterval = 5) async -> (success: Bool, ms: Double?) {
        await withCheckedContinuation { continuation in
            let cfHost = CFHostCreateWithName(nil, host as CFString).takeRetainedValue()
            let start = Date()
            let resumeLock = NSLock()
            var didResume = false
            let resumeOnce: (Bool, Double?) -> Void = { success, ms in
                resumeLock.lock()
                let alreadyResumed = didResume
                didResume = true
                resumeLock.unlock()
                guard !alreadyResumed else { return }
                continuation.resume(returning: (success, ms))
            }
            DispatchQueue.global(qos: .userInitiated).async {
                var error = CFStreamError()
                let ok = CFHostStartInfoResolution(cfHost, .addresses, &error)
                let elapsedMs = Date().timeIntervalSince(start) * 1000
                resumeOnce(ok && error.error == 0, ok ? elapsedMs : nil)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                CFHostCancelInfoResolution(cfHost, .addresses)
                resumeOnce(false, nil)
            }
        }
    }

    static func tcpLatency(host: String = "www.apple.com", port: UInt16 = 443, timeout: TimeInterval = 5) async -> Double? {
        await withCheckedContinuation { continuation in
            let start = Date()
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port) ?? 443,
                using: .tcp
            )
            // `stateUpdateHandler` fires on the connection's own queue and
            // the timeout fallback fires on a separate global queue — both
            // can call this at once if the connection resolves right as the
            // timeout fires. An unsynchronized `didResume` flag is a data
            // race that can double-call `continuation.resume`, which is an
            // instant crash ("already resumed"). A lock closes that window.
            let resumeLock = NSLock()
            var didResume = false
            let resumeOnce: (Double?) -> Void = { value in
                resumeLock.lock()
                let alreadyResumed = didResume
                didResume = true
                resumeLock.unlock()
                guard !alreadyResumed else { return }
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumeOnce(Date().timeIntervalSince(start) * 1000)
                case .failed, .cancelled:
                    resumeOnce(nil)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                resumeOnce(nil)
            }
        }
    }

    static func downloadSpeedMbps(bytes: Int = 5_000_000) async -> Double? {
        guard let url = URL(string: "https://speed.cloudflare.com/__down?bytes=\(bytes)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let start = Date()
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              !data.isEmpty else { return nil }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 0 else { return nil }
        return (Double(data.count) * 8) / elapsed / 1_000_000
    }

    static func uploadSpeedMbps(bytes: Int = 2_000_000) async -> Double? {
        guard let url = URL(string: "https://speed.cloudflare.com/__up") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        let payload = Data(count: bytes)
        let start = Date()
        guard let (_, response) = try? await URLSession.shared.upload(for: request, from: payload),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 0 else { return nil }
        return (Double(bytes) * 8) / elapsed / 1_000_000
    }

    static func publicIPAddress() async -> String? {
        guard let url = URL(string: "https://api.ipify.org?format=json") else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return nil }
        return json["ip"]
    }

    /// Local IPv4 addresses per network interface, via the public getifaddrs() POSIX API.
    static func localIPAddresses() -> [(interface: String, address: String)] {
        var results: [(String, String)] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return [] }
        defer { freeifaddrs(ifaddrPtr) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0 else { continue }
            let addrFamily = current.pointee.ifa_addr.pointee.sa_family
            guard addrFamily == UInt8(AF_INET) else { continue }

            let name = String(cString: current.pointee.ifa_name)
            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(
                current.pointee.ifa_addr, socklen_t(current.pointee.ifa_addr.pointee.sa_len),
                &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST
            )
            let address = String(cString: hostBuffer)
            results.append((friendlyInterfaceName(name), address))
        }
        return results
    }

    private static func friendlyInterfaceName(_ raw: String) -> String {
        switch raw {
        case "en0": return "Wi-Fi (en0)"
        case "pdp_ip0": return "Cellular (pdp_ip0)"
        default: return raw
        }
    }
}

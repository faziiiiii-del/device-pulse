//
//  MacNetworkDiagnostics.swift
//  DevicePulseMac
//
//  Active connection tests, run only on demand. Same approach as the iOS
//  target: CFHost for DNS timing, Network framework for TCP-connect
//  latency (macOS has no public raw-ICMP-ping API for regular apps
//  either), and Cloudflare's public speed-test endpoint for throughput.
//

import Foundation
import Network

struct MacNetworkTestResult {
    var dnsMs: Double?
    var dnsSuccess: Bool
    var tcpLatencyMs: Double?
    var downloadMbps: Double?
    var uploadMbps: Double?
}

enum MacNetworkDiagnostics {
    static func resolveDNS(host: String = "www.apple.com") async -> (success: Bool, ms: Double?) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let cfHost = CFHostCreateWithName(nil, host as CFString).takeRetainedValue()
                let start = Date()
                var error = CFStreamError()
                let ok = CFHostStartInfoResolution(cfHost, .addresses, &error)
                let elapsedMs = Date().timeIntervalSince(start) * 1000
                continuation.resume(returning: (ok && error.error == 0, ok ? elapsedMs : nil))
            }
        }
    }

    private static func singleTcpLatency(host: String, port: UInt16, timeout: TimeInterval) async -> Double? {
        await withCheckedContinuation { continuation in
            let start = Date()
            let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 443, using: .tcp)
            // `stateUpdateHandler` fires on the connection's own queue;
            // the timeout fallback fires on a separate global queue —
            // both can call this at once if the connection resolves
            // right as the timeout fires. An unsynchronized flag here
            // is a data race that can double-resume the continuation,
            // which is an instant crash.
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
                case .ready: resumeOnce(Date().timeIntervalSince(start) * 1000)
                case .failed, .cancelled: resumeOnce(nil)
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { resumeOnce(nil) }
        }
    }

    /// Median of 3 samples rather than one — a single TCP-connect
    /// measurement is noisy (one sample can catch a momentary Wi-Fi
    /// retransmit or a slow DNS cache miss), and the median is far less
    /// skewed by a single bad sample than a mean would be.
    static func tcpLatency(host: String = "www.apple.com", port: UInt16 = 443, timeout: TimeInterval = 5) async -> Double? {
        var samples: [Double] = []
        for _ in 0..<3 {
            if let ms = await singleTcpLatency(host: host, port: port, timeout: timeout) {
                samples.append(ms)
            }
        }
        guard !samples.isEmpty else { return nil }
        return samples.sorted()[samples.count / 2]
    }

    /// Starting the clock before the request even begins used to count
    /// DNS + TCP + TLS handshake time as part of "transfer speed" — on a
    /// fast connection, a few hundred ms of one-time setup against a
    /// transfer that only takes a second or two meaningfully understates
    /// real throughput. A tiny warm-up request to the same host first
    /// (URLSession pools/reuses the connection via HTTP keep-alive) means
    /// the timed request below is measuring transfer, not connection setup.
    /// Not as exact as instrumenting with URLSessionTaskMetrics, but a real
    /// improvement with no new failure modes.
    /// 10 MB specifically — Cloudflare's speed-test endpoint 403s
    /// arbitrary byte counts outside its own known test-size buckets
    /// (confirmed by hand: 1M/5M/10M/25M/50M all succeed, but e.g.
    /// 15M consistently 403s). Stick to a size that matches their own
    /// speedtest tool's bucket rather than picking an arbitrary number.
    static func downloadSpeedMbps(bytes: Int = 10_000_000) async -> Double? {
        guard let url = URL(string: "https://speed.cloudflare.com/__down?bytes=\(bytes)"),
              let warmupURL = URL(string: "https://speed.cloudflare.com/__down?bytes=1000")
        else { return nil }
        _ = try? await URLSession.shared.data(from: warmupURL)

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let start = Date()
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else { return nil }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 0 else { return nil }
        return (Double(data.count) * 8) / elapsed / 1_000_000
    }

    static func uploadSpeedMbps(bytes: Int = 6_000_000) async -> Double? {
        guard let url = URL(string: "https://speed.cloudflare.com/__up") else { return nil }
        var warmupRequest = URLRequest(url: url)
        warmupRequest.httpMethod = "POST"
        _ = try? await URLSession.shared.upload(for: warmupRequest, from: Data(count: 1000))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        let payload = Data(count: bytes)
        let start = Date()
        guard let (_, response) = try? await URLSession.shared.upload(for: request, from: payload),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 0 else { return nil }
        return (Double(bytes) * 8) / elapsed / 1_000_000
    }
}

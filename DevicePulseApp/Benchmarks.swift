//
//  Benchmarks.swift
//  DevicePulse
//
//  EXPERIMENTAL. Rough, relative, on-device benchmarks using ONLY public
//  APIs (Foundation math, FileManager, Metal). These are not official
//  scores and are not comparable to any third-party benchmark — they
//  exist to give a same-device-over-time reference point.
//

import Foundation
import Metal

enum Benchmarks {
    struct CPUResult {
        let elapsedMs: Double
        let primesFound: Int
    }

    struct DiskResult {
        let writeMBps: Double
        let readMBps: Double
    }

    struct MemoryResult {
        let allocateMs: Double
        let megabytes: Int
    }

    struct GPUResult {
        let deviceName: String
        let elapsedMs: Double?
    }

    /// Sieve of Eratosthenes up to a fixed bound, single-threaded. A crude,
    /// repeatable CPU workload — not a substitute for a real benchmark suite.
    static func cpuBenchmark(upperBound: Int = 3_000_000) -> CPUResult {
        let start = Date()
        var isComposite = [Bool](repeating: false, count: upperBound + 1)
        var count = 0
        if upperBound >= 2 {
            for value in 2...upperBound {
                if !isComposite[value] {
                    count += 1
                    if value * value <= upperBound {
                        var multiple = value * value
                        while multiple <= upperBound {
                            isComposite[multiple] = true
                            multiple += value
                        }
                    }
                }
            }
        }
        let elapsedMs = Date().timeIntervalSince(start) * 1000
        return CPUResult(elapsedMs: elapsedMs, primesFound: count)
    }

    /// Writes then reads a temp file inside this app's own container.
    static func diskBenchmark(megabytes: Int = 32) -> DiskResult? {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("dd-disk-bench-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: url) }

        let chunkSize = 1024 * 1024
        var chunk = Data(count: chunkSize)
        chunk.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress {
                arc4random_buf(base, chunkSize)
            }
        }

        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return nil }
        guard let writeHandle = try? FileHandle(forWritingTo: url) else { return nil }

        let writeStart = Date()
        for _ in 0..<megabytes {
            writeHandle.write(chunk)
        }
        try? writeHandle.synchronize()
        try? writeHandle.close()
        let writeElapsed = Date().timeIntervalSince(writeStart)

        guard let readHandle = try? FileHandle(forReadingFrom: url) else { return nil }
        let readStart = Date()
        var totalRead = 0
        while let data = try? readHandle.read(upToCount: chunkSize), !data.isEmpty {
            totalRead += data.count
        }
        try? readHandle.close()
        let readElapsed = Date().timeIntervalSince(readStart)

        guard writeElapsed > 0, readElapsed > 0 else { return nil }
        let writeMBps = Double(megabytes) / writeElapsed
        let readMBps = Double(totalRead) / 1_000_000 / readElapsed
        return DiskResult(writeMBps: writeMBps, readMBps: readMBps)
    }

    /// Allocates, fills, and releases a large buffer to time raw allocation.
    static func memoryAllocationBenchmark(megabytes: Int = 128) -> MemoryResult {
        let start = Date()
        let count = megabytes * 1024 * 1024
        var buffer = [UInt8](repeating: 0, count: count)
        for i in stride(from: 0, to: count, by: 4096) {
            buffer[i] = UInt8(i % 256)
        }
        buffer.removeAll(keepingCapacity: false)
        let elapsedMs = Date().timeIntervalSince(start) * 1000
        return MemoryResult(allocateMs: elapsedMs, megabytes: megabytes)
    }

    /// Reports the GPU device name via Metal (public framework) and, if a
    /// device is available, times a trivial compute-shader dispatch.
    static func gpuInfo() -> GPUResult? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        return GPUResult(deviceName: device.name, elapsedMs: gpuComputeTiming(device: device))
    }

    private static func gpuComputeTiming(device: MTLDevice) -> Double? {
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void addOne(device float *data [[buffer(0)]], uint id [[thread_position_in_grid]]) {
            data[id] = data[id] + 1.0;
        }
        """
        guard let library = try? device.makeLibrary(source: source, options: nil),
              let function = library.makeFunction(name: "addOne"),
              let pipeline = try? device.makeComputePipelineState(function: function),
              let queue = device.makeCommandQueue() else { return nil }

        let elementCount = 4_000_000
        guard let buffer = device.makeBuffer(length: elementCount * MemoryLayout<Float>.stride, options: .storageModeShared) else { return nil }

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        let threadsPerGroup = MTLSize(width: pipeline.maxTotalThreadsPerThreadgroup, height: 1, depth: 1)
        let groups = MTLSize(width: (elementCount + threadsPerGroup.width - 1) / threadsPerGroup.width, height: 1, depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()

        let start = Date()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return Date().timeIntervalSince(start) * 1000
    }
}

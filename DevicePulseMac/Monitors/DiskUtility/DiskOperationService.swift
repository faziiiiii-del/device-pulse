//
//  DiskOperationService.swift
//  DevicePulseMac
//
//  Every destructive (or state-changing) disk action goes through here,
//  and every one of them follows the same sequence, no shortcuts:
//
//      Validate identity → (unmount if needed) → Execute → Verify →
//      Result → Audit log
//
//  Two safety layers that are NOT "diskutil will refuse it":
//   1. `assertNotBootDisk` hard-blocks in this app, before any process
//      is even launched, for erase/partition targeting the disk that
//      hosts the currently-running boot volume. diskutil's own refusal
//      ("You cannot erase the boot disk") is real and still applies as
//      a second, independent layer, but this app does not rely on it.
//   2. `DiskIdentityValidator.revalidate` re-enumerates the disk fresh,
//      immediately before the destructive command runs, and aborts if
//      anything about it (media name, size, internal/removable, UUID)
//      no longer matches what the user actually selected — because a
//      BSD identifier like "disk4" is not a stable name for a physical
//      disk across a disconnect/reconnect cycle.
//
//  Process execution: fixed argument arrays only, no shell, no `sh -c`,
//  no string interpolation into a command line — matching the rest of
//  this app's existing process-execution pattern. `/usr/sbin/diskutil`
//  is the same public, documented CLI Disk Utility.app itself is built
//  on top of.
//

import Foundation

enum DiskOperationStage: Equatable {
    case preparing, validating, unmounting, executing, verifying, completed, failed, cancelled

    var label: String {
        switch self {
        case .preparing: return "Preparing"
        case .validating: return "Validating disk identity"
        case .unmounting: return "Unmounting volumes"
        case .executing: return "Executing"
        case .verifying: return "Verifying"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}

struct DiskOperationStep: Identifiable {
    let id = UUID()
    let label: String
    var state: State
    enum State { case pending, running, done, failed }
}

enum DiskOperationError: LocalizedError {
    case bootDiskProtected(String)
    case identityMismatch(String)
    case diskDisappeared
    case launchFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .bootDiskProtected(let name):
            return "\(name) contains your current startup disk. Device Pulse blocks destructive operations against the active boot disk — this is enforced by the app itself, not left to diskutil."
        case .identityMismatch(let reason):
            return "The selected disk could not be safely revalidated. \(reason) No changes were made."
        case .diskDisappeared:
            return "The selected disk could not be safely revalidated — it is no longer connected. No changes were made."
        case .launchFailed:
            return "Failed to launch diskutil."
        case .cancelled:
            return "Operation cancelled."
        }
    }
}

/// Live state for one running operation — drives the operation console UI. MainActor
/// since SwiftUI observes it directly; the actual process I/O happens off-main and
/// hops back via MainActor.run.
@MainActor
final class DiskOperationHandle: ObservableObject, Identifiable {
    let id = UUID()
    let title: String
    @Published private(set) var stage: DiskOperationStage = .preparing
    @Published private(set) var steps: [DiskOperationStep] = []
    @Published private(set) var liveOutput: String = ""
    @Published private(set) var isFinished = false
    @Published private(set) var succeeded = false
    @Published private(set) var summary: String = ""

    fileprivate var currentProcess: Process?
    fileprivate var cancelRequested = false

    init(title: String, plannedSteps: [String]) {
        self.title = title
        self.steps = plannedSteps.map { DiskOperationStep(label: $0, state: .pending) }
    }

    func cancel() {
        cancelRequested = true
        currentProcess?.terminate()
    }

    fileprivate func setStage(_ stage: DiskOperationStage) { self.stage = stage }
    fileprivate func beginStep(_ index: Int) { guard steps.indices.contains(index) else { return }; steps[index].state = .running }
    fileprivate func finishStep(_ index: Int, ok: Bool) { guard steps.indices.contains(index) else { return }; steps[index].state = ok ? .done : .failed }
    fileprivate func appendOutput(_ text: String) { liveOutput += text }
    fileprivate func finish(succeeded: Bool, summary: String) {
        self.succeeded = succeeded
        self.summary = summary
        self.stage = cancelRequested ? .cancelled : (succeeded ? .completed : .failed)
        self.isFinished = true
    }
}

@MainActor
enum DiskOperationService {
    // MARK: - Safety gates (see file header)

    /// Hard block, enforced by this app, independent of diskutil's own refusal.
    static func assertNotBootDisk(_ disk: DiskInfo) throws {
        guard disk.containsBootVolume else { return }
        throw DiskOperationError.bootDiskProtected(disk.mediaName)
    }

    /// Volume-scoped equivalent of `assertNotBootDisk`, used by eraseVolume: a non-boot
    /// volume can legitimately share a disk with the boot volume, so gating on the
    /// *disk's* boot status here would over-block a safe operation, not just under-block
    /// an unsafe one — this checks the specific volume instead.
    static func assertNotBootVolume(_ volume: DiskVolumeInfo) throws {
        guard volume.isBootVolume else { return }
        throw DiskOperationError.bootDiskProtected(volume.name)
    }

    /// Re-enumerates the disk fresh and confirms it still matches what the user selected.
    static func revalidateOrThrow(_ disk: DiskInfo) async throws {
        switch await DiskIdentityValidator.revalidate(disk.fingerprint) {
        case .verified: return
        case .disappeared: throw DiskOperationError.diskDisappeared
        case .mismatch(let reason): throw DiskOperationError.identityMismatch(reason)
        }
    }

    /// Volume-scoped equivalent of `revalidateOrThrow`.
    static func revalidateVolumeOrThrow(_ volume: DiskVolumeInfo) async throws {
        switch await DiskIdentityValidator.revalidateVolume(volume.fingerprint) {
        case .verified: return
        case .disappeared: throw DiskOperationError.diskDisappeared
        case .mismatch(let reason): throw DiskOperationError.identityMismatch(reason)
        }
    }

    // MARK: - High-level operations

    static func eraseDisk(_ disk: DiskInfo, newName: String, format: MacDiskFormat, passphrase: String?, handle: DiskOperationHandle) async {
        await run(handle: handle, target: disk.deviceIdentifier, targetName: disk.mediaName) {
            try assertNotBootDisk(disk)
            handle.setStage(.validating); handle.beginStep(0)
            try await revalidateOrThrow(disk)
            handle.finishStep(0, ok: true)

            handle.setStage(.executing); handle.beginStep(1)
            let result = try await runProcess(["/usr/sbin/diskutil", "eraseDisk", format.diskutilName, newName, disk.deviceIdentifier], handle: handle)
            guard result.succeeded else { handle.finishStep(1, ok: false); throw DiskOperationServiceRunError.diskutilFailed(result.output) }
            handle.finishStep(1, ok: true)

            if format.needsPassphrase, let passphrase {
                handle.beginStep(2)
                try await encryptNewlyCreatedVolume(onDisk: disk.deviceIdentifier, passphrase: passphrase, handle: handle)
                handle.finishStep(2, ok: true)
            }
            return "Erased \(disk.mediaName) as \(format.displayName)."
        }
    }

    static func eraseVolume(_ volume: DiskVolumeInfo, newName: String, format: MacDiskFormat, passphrase: String?, handle: DiskOperationHandle) async {
        await run(handle: handle, target: volume.deviceIdentifier, targetName: volume.name) {
            try assertNotBootVolume(volume)
            handle.setStage(.validating); handle.beginStep(0)
            try await revalidateVolumeOrThrow(volume)
            handle.finishStep(0, ok: true)

            handle.setStage(.executing); handle.beginStep(1)
            let result = try await runProcess(["/usr/sbin/diskutil", "eraseVolume", format.diskutilName, newName, volume.deviceIdentifier], handle: handle)
            guard result.succeeded else { handle.finishStep(1, ok: false); throw DiskOperationServiceRunError.diskutilFailed(result.output) }
            handle.finishStep(1, ok: true)

            if format.needsPassphrase, let passphrase {
                handle.beginStep(2)
                // eraseVolume reformats in place, so diskutil reuses the same volume
                // device identifier — passing it as the exact target to match against,
                // rather than assuming the disk's first volume (which isn't necessarily
                // the one just erased on a multi-volume disk).
                try await encryptNewlyCreatedVolume(onDisk: volume.deviceIdentifier, exactVolumeReplacing: volume.deviceIdentifier, passphrase: passphrase, handle: handle)
                handle.finishStep(2, ok: true)
            }
            return "Erased \u{201C}\(volume.name)\u{201D} as \(format.displayName)."
        }
    }

    static func partitionDisk(_ disk: DiskInfo, partitions: [(name: String, format: MacDiskFormat, sizeSpec: String)], handle: DiskOperationHandle) async {
        await run(handle: handle, target: disk.deviceIdentifier, targetName: disk.mediaName) {
            try assertNotBootDisk(disk)
            handle.setStage(.validating); handle.beginStep(0)
            try await revalidateOrThrow(disk)
            handle.finishStep(0, ok: true)

            handle.setStage(.executing); handle.beginStep(1)
            var args = ["/usr/sbin/diskutil", "partitionDisk", disk.deviceIdentifier, "GPT"]
            for p in partitions { args += [p.format.diskutilName, p.name, p.sizeSpec] }
            let result = try await runProcess(args, handle: handle)
            guard result.succeeded else { handle.finishStep(1, ok: false); throw DiskOperationServiceRunError.diskutilFailed(result.output) }
            handle.finishStep(1, ok: true)
            return "Partitioned \(disk.mediaName) into \(partitions.count) volume(s)."
        }
    }

    static func mount(deviceIdentifier: String, name: String, handle: DiskOperationHandle) async {
        await run(handle: handle, target: deviceIdentifier, targetName: name) {
            handle.setStage(.executing); handle.beginStep(0)
            let result = try await runProcess(["/usr/sbin/diskutil", "mount", deviceIdentifier], handle: handle)
            guard result.succeeded else { handle.finishStep(0, ok: false); throw DiskOperationServiceRunError.diskutilFailed(result.output) }
            handle.finishStep(0, ok: true)
            return "Mounted \u{201C}\(name)\u{201D}."
        }
    }

    static func unmount(deviceIdentifier: String, name: String, force: Bool, handle: DiskOperationHandle) async {
        await run(handle: handle, target: deviceIdentifier, targetName: name) {
            handle.setStage(.unmounting); handle.beginStep(0)
            var args = ["/usr/sbin/diskutil", "unmount"]
            if force { args.append("force") }
            args.append(deviceIdentifier)
            let result = try await runProcess(args, handle: handle)
            guard result.succeeded else {
                handle.finishStep(0, ok: false)
                throw DiskOperationServiceRunError.diskutilFailed(result.output)
            }
            handle.finishStep(0, ok: true)
            return "Unmounted \u{201C}\(name)\u{201D}."
        }
    }

    /// Checks for still-mounted volumes first and explains rather than blindly forcing,
    /// per the spec: "Do not blindly force operations."
    static func eject(_ disk: DiskInfo, handle: DiskOperationHandle) async {
        await run(handle: handle, target: disk.deviceIdentifier, targetName: disk.mediaName) {
            handle.setStage(.unmounting); handle.beginStep(0)
            let result = try await runProcess(["/usr/sbin/diskutil", "eject", disk.deviceIdentifier], handle: handle)
            guard result.succeeded else {
                handle.finishStep(0, ok: false)
                if result.output.lowercased().contains("busy") || result.output.lowercased().contains("in use") {
                    throw DiskOperationServiceRunError.custom("The disk could not be ejected because one or more volumes are still in use.")
                }
                throw DiskOperationServiceRunError.diskutilFailed(result.output)
            }
            handle.finishStep(0, ok: true)
            return "Ejected \(disk.mediaName)."
        }
    }

    static func verify(deviceIdentifier: String, name: String, handle: DiskOperationHandle) async {
        await run(handle: handle, target: deviceIdentifier, targetName: name) {
            handle.setStage(.verifying); handle.beginStep(0)
            let result = try await runProcess(["/usr/sbin/diskutil", "verifyVolume", deviceIdentifier], handle: handle)
            handle.finishStep(0, ok: result.succeeded)
            if !result.succeeded { throw DiskOperationServiceRunError.diskutilFailed(result.output) }
            return "Verification completed — \u{201C}\(name)\u{201D} appears to be OK."
        }
    }

    static func repair(deviceIdentifier: String, name: String, handle: DiskOperationHandle) async {
        await run(handle: handle, target: deviceIdentifier, targetName: name) {
            handle.setStage(.executing); handle.beginStep(0)
            let result = try await runProcess(["/usr/sbin/diskutil", "repairVolume", deviceIdentifier], handle: handle)
            handle.finishStep(0, ok: result.succeeded)
            if !result.succeeded { throw DiskOperationServiceRunError.diskutilFailed(result.output) }
            return "Repair completed for \u{201C}\(name)\u{201D}."
        }
    }

    static func rename(deviceIdentifier: String, oldName: String, newName: String, handle: DiskOperationHandle) async {
        await run(handle: handle, target: deviceIdentifier, targetName: oldName) {
            handle.setStage(.executing); handle.beginStep(0)
            let result = try await runProcess(["/usr/sbin/diskutil", "renameVolume", deviceIdentifier, newName], handle: handle)
            guard result.succeeded else { handle.finishStep(0, ok: false); throw DiskOperationServiceRunError.diskutilFailed(result.output) }
            handle.finishStep(0, ok: true)
            return "Renamed \u{201C}\(oldName)\u{201D} to \u{201C}\(newName)\u{201D}."
        }
    }

    // MARK: - Encryption (second step after a plain APFS erase — see DiskUtilityModels)

    /// Finds the single volume `diskutil eraseDisk`/`eraseVolume` just created on the
    /// given disk and encrypts it, piping the passphrase via stdin — never as a CLI
    /// argument (visible to any process via `ps aux`), never stored by this app.
    private static func encryptNewlyCreatedVolume(onDisk deviceIdentifier: String, exactVolumeReplacing: String? = nil, passphrase: String, handle: DiskOperationHandle) async throws {
        let disks = await Task.detached { DiskDiscoveryService.listDisks() }.value
        let targetDisk = disks.first { $0.deviceIdentifier == deviceIdentifier || $0.partitions.contains { $0.deviceIdentifier == deviceIdentifier } }
        let candidates = targetDisk?.allVolumes ?? []
        // When erasing one specific existing volume in place, diskutil reuses that same
        // device identifier for the reformatted result — match on it exactly rather than
        // assuming "first volume on the disk", which isn't necessarily the one just
        // erased when the disk has more than one volume.
        let volume = exactVolumeReplacing.flatMap { id in candidates.first { $0.deviceIdentifier == id } } ?? candidates.first
        guard let volume else {
            throw DiskOperationServiceRunError.custom("Erased successfully, but the new volume could not be found to encrypt it. Encrypt it manually from Disk Utility.")
        }
        let result = try await runProcess(
            ["/usr/sbin/diskutil", "apfs", "encryptVolume", volume.deviceIdentifier, "-user", "disk", "-stdinpassphrase"],
            handle: handle, stdinText: passphrase
        )
        guard result.succeeded else { throw DiskOperationServiceRunError.diskutilFailed(result.output) }
    }

    // MARK: - Shared run wrapper (validation/audit-log plumbing common to every operation)

    private enum DiskOperationServiceRunError: LocalizedError {
        case diskutilFailed(String)
        case custom(String)
        var errorDescription: String? {
            switch self {
            case .diskutilFailed(let output): return DiskUtilityErrorTranslator.translate(output)
            case .custom(let message): return message
            }
        }
    }

    private static func run(handle: DiskOperationHandle, target: String, targetName: String, _ body: @escaping () async throws -> String) async {
        do {
            let summary = try await body()
            await MainActor.run {
                handle.finish(succeeded: true, summary: summary)
            }
            DiskUtilityAuditLog.record(title: handle.title, target: targetName, succeeded: true)
        } catch is CancellationError {
            await MainActor.run { handle.finish(succeeded: false, summary: "Cancelled.") }
            DiskUtilityAuditLog.record(title: handle.title, target: targetName, succeeded: false, note: "Cancelled")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await MainActor.run { handle.finish(succeeded: false, summary: message) }
            DiskUtilityAuditLog.record(title: handle.title, target: targetName, succeeded: false, note: message)
        }
    }

    // MARK: - Process execution: async, cancellable, streaming

    /// Thread-safe accumulator for a process's combined stdout/stderr text — stdout and
    /// stderr readability handlers fire on independent, unordered GCD queues, so a plain
    /// `var` mutated from both would be a genuine data race, not a theoretical one.
    private final class OutputAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        func append(_ s: String) { lock.lock(); text += s; lock.unlock() }
        var value: String { lock.lock(); defer { lock.unlock() }; return text }
    }

    private struct ProcessResult { let succeeded: Bool; let output: String }

    /// Runs one diskutil invocation with real stdout/stderr streaming into the operation
    /// handle's live console, cooperative cancellation via `Process.terminate()`, and no
    /// shell — a fixed argument array only. `stdinText`, when provided, is written and
    /// the pipe closed immediately (used only for `-stdinpassphrase`), never logged to
    /// `liveOutput` or the audit log.
    private static func runProcess(_ args: [String], handle: DiskOperationHandle, stdinText: String? = nil) async throws -> ProcessResult {
        if handle.cancelRequested { throw CancellationError() }

        return try await withCheckedThrowingContinuation { continuation in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: args[0])
            task.arguments = Array(args.dropFirst())

            let outPipe = Pipe()
            let errPipe = Pipe()
            task.standardOutput = outPipe
            task.standardError = errPipe
            if stdinText != nil { task.standardInput = Pipe() }

            // stdout and stderr readability handlers can fire concurrently on different
            // GCD queues — a plain `var` mutated from both would be a real data race, not
            // a theoretical one, since both pipes are genuinely independent and unordered
            // relative to each other. OutputAccumulator serializes access with a lock.
            let accumulator = OutputAccumulator()
            let appendToLiveConsole = stdinText == nil // never echo passphrase-adjacent stdin operations verbatim beyond diskutil's own stdout, which contains no passphrase text
            outPipe.fileHandleForReading.readabilityHandler = { fh in
                let data = fh.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                accumulator.append(text)
                if appendToLiveConsole { Task { @MainActor in handle.appendOutput(text) } }
            }
            errPipe.fileHandleForReading.readabilityHandler = { fh in
                let data = fh.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                accumulator.append(text)
                if appendToLiveConsole { Task { @MainActor in handle.appendOutput(text) } }
            }

            task.terminationHandler = { proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                // Any bytes written by the process but not yet delivered to the
                // readability handler at the exact moment it exits would otherwise be
                // silently dropped — drain both pipes directly before resuming, since
                // this output feeds error translation, and a truncated message would be
                // actively misleading rather than merely incomplete.
                let remainingOut = outPipe.fileHandleForReading.readDataToEndOfFile()
                let remainingErr = errPipe.fileHandleForReading.readDataToEndOfFile()
                if let text = String(data: remainingOut, encoding: .utf8), !text.isEmpty { accumulator.append(text) }
                if let text = String(data: remainingErr, encoding: .utf8), !text.isEmpty { accumulator.append(text) }
                let succeeded = proc.terminationStatus == 0
                let output = accumulator.value.trimmingCharacters(in: .whitespacesAndNewlines)
                Task { @MainActor in
                    // A cancelled process is terminated with a signal, which exits
                    // non-zero — read as a genuine diskutil failure, that showed up in
                    // the audit log as e.g. "Terminated: 15" rather than "Cancelled".
                    // Check cancelRequested (only safely readable on MainActor) before
                    // deciding which way to resume.
                    let wasCancelled = handle.cancelRequested
                    handle.currentProcess = nil
                    if wasCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(returning: ProcessResult(succeeded: succeeded, output: output))
                    }
                }
            }

            do {
                try task.run()
                // Set synchronously, not via a Task hop — a cancel() call in the gap
                // before an async hop actually runs would find currentProcess still nil
                // and silently do nothing. This function's closure runs on the MainActor
                // already (DiskOperationService is @MainActor), so this is safe to do
                // directly. The explicit recheck immediately below closes the remaining
                // sliver of a race: if cancel() was requested on a previous run loop
                // turn between this function being entered and task.run() completing.
                handle.currentProcess = task
                if handle.cancelRequested {
                    task.terminate()
                }
                if let stdinText, let stdinPipe = task.standardInput as? Pipe {
                    let handle = stdinPipe.fileHandleForWriting
                    handle.write(Data((stdinText + "\n").utf8))
                    try? handle.close()
                }
            } catch {
                continuation.resume(throwing: DiskOperationError.launchFailed)
            }
        }
    }
}

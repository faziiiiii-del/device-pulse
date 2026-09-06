//
//  MacDiskUtilityManager.swift
//  DevicePulseMac
//
//  Full disk erase/format/partition support via `diskutil` — the same
//  public, documented CLI Disk Utility.app itself is built on. There is
//  no framework API for any of this; every operation here is a real
//  `diskutil` subcommand, run with an explicit, fixed argument array
//  (never a shell, never string interpolation into a shell command).
//
//  SAFETY NOTE, not a restriction this code enforces itself: `diskutil`
//  refuses to erase the boot disk or boot volume at the OS level
//  ("You cannot erase the boot disk" / "You cannot erase the boot
//  volume" — confirmed directly from `diskutil eraseDisk`/`eraseVolume`'s
//  own usage text). This app does not additionally block any disk by
//  type — every disk is shown and every action is offered for every
//  disk, including internal ones — but that OS-level refusal is real
//  and independent of anything here. `containsBootVolume` below is
//  purely informational, surfaced in the UI so the user knows before
//  they act, never used to hide or disable an action.
//
//  Storage model this reflects (confirmed by direct inspection, not
//  assumed): a whole disk (e.g. "disk0") has GPT-level partitions
//  (e.g. "disk0s2"). A non-APFS partition (ExFAT/FAT32/HFS+) IS itself
//  one mountable volume. An APFS partition is instead a *container* that
//  can host several independently-named volumes (e.g. "Macintosh HD",
//  "Macintosh HD - Data") sharing that one partition's space — those
//  are only visible via `diskutil apfs list`, not the plain partition
//  map, which is why both are queried and merged below.
//

import Foundation

struct DiskVolumeInfo: Identifiable {
    var id: String { deviceIdentifier }
    let deviceIdentifier: String
    let name: String
    let sizeBytes: Int64?
    let filesystemName: String?
    let mountPoint: String?
}

struct DiskPartitionInfo: Identifiable {
    var id: String { deviceIdentifier }
    let deviceIdentifier: String
    /// Raw `diskutil` partition type, e.g. "Apple_APFS", "Windows_FAT_32", "Apple_HFS".
    let content: String
    let sizeBytes: Int64
    /// Populated when this partition is an APFS container hosting named volumes.
    let apfsVolumes: [DiskVolumeInfo]
    /// Populated only when `apfsVolumes` is empty — this partition IS the one volume.
    let plainVolume: DiskVolumeInfo?

    var isFreeSpace: Bool { content == "Apple_Free" || content.isEmpty }
}

struct DiskInfo: Identifiable {
    var id: String { deviceIdentifier }
    let deviceIdentifier: String
    let mediaName: String
    let totalSizeBytes: Int64
    let partitionScheme: String?
    let isInternal: Bool
    let isRemovable: Bool
    let partitions: [DiskPartitionInfo]
    /// Informational only — see the file-level note above. Never used to block anything.
    let containsBootVolume: Bool
}

/// Formats offered for erase/partition actions. `diskutilName` is the exact personality
/// name `diskutil` expects (see `diskutil listFilesystems`), confirmed against this
/// machine's own output rather than assumed from documentation alone.
enum MacDiskFormat: String, CaseIterable, Identifiable {
    case apfs, macOSExtendedJournaled, exFAT, msDosFAT32

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apfs: return "APFS"
        case .macOSExtendedJournaled: return "Mac OS Extended (Journaled)"
        case .exFAT: return "ExFAT"
        case .msDosFAT32: return "MS-DOS (FAT32)"
        }
    }

    var diskutilName: String {
        switch self {
        case .apfs: return "APFS"
        case .macOSExtendedJournaled: return "JHFS+"
        case .exFAT: return "ExFAT"
        case .msDosFAT32: return "MS-DOS FAT32"
        }
    }
}

struct DiskUtilityActionResult {
    let succeeded: Bool
    /// Real, unmodified `diskutil` output — including its own error text (e.g. "You
    /// cannot erase the boot disk") verbatim, never paraphrased or hidden.
    let output: String
}

enum MacDiskUtilityManager {
    // MARK: - Scanning (read-only)

    static func listDisks() -> [DiskInfo] {
        guard let listPlist = runPlist(["/usr/sbin/diskutil", "list", "-plist"]),
              let allDisksAndPartitions = listPlist["AllDisksAndPartitions"] as? [[String: Any]]
        else { return [] }

        let containersByPhysicalStore = apfsContainersByPhysicalStore()
        let bootContainerDisk = bootAPFSContainerDiskIdentifier()

        return allDisksAndPartitions.compactMap { diskDict in
            guard let deviceIdentifier = diskDict["DeviceIdentifier"] as? String else { return nil }
            let info = diskDetails(for: deviceIdentifier)

            // Skip "Virtual" whole-disk entries — the same signal MacDiskHealthMonitor
            // already relies on, and for the same underlying reason: `diskutil list`
            // includes both an APFS container's *own* whole-disk identifier (e.g. the
            // container backing the internal SSD's real volumes) and any hdiutil-mounted
            // disk image (Simulator runtime images, mounted .dmg installers, etc.) as
            // separate top-level "WholeDisks" entries, alongside the real physical disk
            // that actually hosts them. Both report VirtualOrPhysical == "Virtual" and
            // MediaName inherited from whatever's underneath (confirmed by direct
            // inspection: an APFS container inherits the real physical disk's own model
            // name, e.g. "APPLE SSD AP1024R", not a distinct one) — without this filter
            // they show up as confusing phantom "disks" with zero real partitions of
            // their own, while a disk image mount (also Virtual) shows up as if it were
            // a real external/removable drive worth formatting, which it never is. The
            // container's actual volumes are already surfaced correctly through the real
            // physical disk's GPT partition below, via `containersByPhysicalStore`.
            guard info?.virtualOrPhysical != "Virtual" else { return nil }

            let rawPartitions = diskDict["Partitions"] as? [[String: Any]] ?? []

            var containsBoot = false
            let partitions: [DiskPartitionInfo] = rawPartitions.compactMap { partDict in
                guard let partID = partDict["DeviceIdentifier"] as? String,
                      let size = (partDict["Size"] as? NSNumber)?.int64Value
                else { return nil }
                let content = partDict["Content"] as? String ?? ""

                if let container = containersByPhysicalStore[partID] {
                    if container.containerDisk == bootContainerDisk { containsBoot = true }
                    return DiskPartitionInfo(deviceIdentifier: partID, content: content, sizeBytes: size, apfsVolumes: container.volumes, plainVolume: nil)
                }
                let volume = plainVolumeInfo(for: partID)
                return DiskPartitionInfo(deviceIdentifier: partID, content: content, sizeBytes: size, apfsVolumes: [], plainVolume: volume)
            }

            return DiskInfo(
                deviceIdentifier: deviceIdentifier,
                mediaName: info?.mediaName ?? deviceIdentifier,
                totalSizeBytes: (diskDict["Size"] as? NSNumber)?.int64Value ?? 0,
                partitionScheme: diskDict["Content"] as? String,
                isInternal: info?.isInternal ?? true,
                isRemovable: info?.isRemovable ?? false,
                partitions: partitions,
                containsBootVolume: containsBoot
            )
        }
    }

    private struct DiskDetails { let mediaName: String; let isInternal: Bool; let isRemovable: Bool; let virtualOrPhysical: String? }

    private static func diskDetails(for identifier: String) -> DiskDetails? {
        guard let plist = runPlist(["/usr/sbin/diskutil", "info", "-plist", identifier]) else { return nil }
        return DiskDetails(
            mediaName: plist["MediaName"] as? String ?? identifier,
            isInternal: plist["Internal"] as? Bool ?? true,
            isRemovable: plist["RemovableMedia"] as? Bool ?? false,
            virtualOrPhysical: plist["VirtualOrPhysical"] as? String
        )
    }

    private static func plainVolumeInfo(for identifier: String) -> DiskVolumeInfo? {
        guard let plist = runPlist(["/usr/sbin/diskutil", "info", "-plist", identifier]) else { return nil }
        let name = plist["VolumeName"] as? String
        guard name != nil, !(name?.isEmpty ?? true) else { return nil }
        return DiskVolumeInfo(
            deviceIdentifier: identifier, name: name!,
            sizeBytes: (plist["Size"] as? NSNumber)?.int64Value,
            filesystemName: plist["FilesystemUserVisibleName"] as? String ?? plist["FilesystemName"] as? String,
            mountPoint: (plist["MountPoint"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    private struct APFSContainer { let containerDisk: String; let volumes: [DiskVolumeInfo] }

    /// Maps each APFS container's underlying GPT partition (e.g. "disk0s2") to its
    /// container disk id and real named volumes — the only way to see actual volume
    /// names/sizes for an APFS-formatted partition, per the file-level note above.
    private static func apfsContainersByPhysicalStore() -> [String: APFSContainer] {
        guard let plist = runPlist(["/usr/sbin/diskutil", "apfs", "list", "-plist"]),
              let containers = plist["Containers"] as? [[String: Any]]
        else { return [:] }

        var result: [String: APFSContainer] = [:]
        for container in containers {
            guard let physicalStore = container["DesignatedPhysicalStore"] as? String,
                  let containerDisk = container["ContainerReference"] as? String
            else { continue }
            let volumes = (container["Volumes"] as? [[String: Any]] ?? []).compactMap { v -> DiskVolumeInfo? in
                guard let volID = v["DeviceIdentifier"] as? String, let name = v["Name"] as? String else { return nil }
                return DiskVolumeInfo(
                    deviceIdentifier: volID, name: name,
                    sizeBytes: (v["CapacityInUse"] as? NSNumber)?.int64Value,
                    filesystemName: "APFS", mountPoint: nil
                )
            }
            result[physicalStore] = APFSContainer(containerDisk: containerDisk, volumes: volumes)
        }
        return result
    }

    /// The APFS container disk (e.g. "disk3") backing the currently-booted volume ("/"),
    /// used only to mark `containsBootVolume` for display — informational, never
    /// enforced. Falls back to `nil` (nothing marked) if it can't be determined, rather
    /// than guessing.
    private static func bootAPFSContainerDiskIdentifier() -> String? {
        guard let plist = runPlist(["/usr/sbin/diskutil", "info", "-plist", "/"]) else { return nil }
        return plist["ParentWholeDisk"] as? String
    }

    // MARK: - Actions (mutating — never invoked except from an explicit user confirmation)

    /// (Re)partitions a whole disk, destroying every existing volume on it. `diskutil`
    /// itself refuses this for the boot disk (see file-level note).
    static func eraseDisk(deviceIdentifier: String, newName: String, format: MacDiskFormat) -> DiskUtilityActionResult {
        run(["/usr/sbin/diskutil", "eraseDisk", format.diskutilName, newName, deviceIdentifier])
    }

    /// Reformats one existing partition/volume in place, leaving the rest of the disk's
    /// other partitions untouched. `diskutil` itself refuses this for the boot volume.
    static func eraseVolume(deviceIdentifier: String, newName: String, format: MacDiskFormat) -> DiskUtilityActionResult {
        run(["/usr/sbin/diskutil", "eraseVolume", format.diskutilName, newName, deviceIdentifier])
    }

    /// Repartitions a whole disk into the given partitions (destroys all existing
    /// content on the disk, same as `eraseDisk`, but creates more than one partition).
    /// Each partition's `sizeSpec` follows `diskutil`'s own syntax: a number with a
    /// B/K/M/G/T/P or "%" suffix, or "R" for exactly one partition to mean "everything
    /// left over" — validated by the caller (the confirmation UI), not re-validated here,
    /// so the real `diskutil` error surfaces verbatim if it's malformed.
    static func partitionDisk(deviceIdentifier: String, partitions: [(name: String, format: MacDiskFormat, sizeSpec: String)]) -> DiskUtilityActionResult {
        var args = ["/usr/sbin/diskutil", "partitionDisk", deviceIdentifier, "GPT"]
        for partition in partitions {
            args += [partition.format.diskutilName, partition.name, partition.sizeSpec]
        }
        return run(args)
    }

    // MARK: - Process plumbing

    private static func run(_ args: [String]) -> DiskUtilityActionResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: args[0])
        task.arguments = Array(args.dropFirst())
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        guard (try? task.run()) != nil else {
            return DiskUtilityActionResult(succeeded: false, output: "Failed to launch diskutil.")
        }
        task.waitUntilExit()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let combined = (String(data: outData, encoding: .utf8) ?? "") + (String(data: errData, encoding: .utf8) ?? "")
        return DiskUtilityActionResult(succeeded: task.terminationStatus == 0, output: combined.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func runPlist(_ args: [String]) -> [String: Any]? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: args[0])
        task.arguments = Array(args.dropFirst())
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return nil }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }
}

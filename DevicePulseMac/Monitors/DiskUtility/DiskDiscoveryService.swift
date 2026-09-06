//
//  DiskDiscoveryService.swift
//  DevicePulseMac
//
//  Read-only disk/volume enumeration via `diskutil` — Apple's own
//  documented CLI, the same one Disk Utility.app is built on. Nothing
//  in this file mutates anything; see DiskOperationService for actions.
//
//  Storage model this reflects (confirmed by direct inspection, not
//  assumed): a whole disk (e.g. "disk0") has GPT-level partitions
//  (e.g. "disk0s2"). A non-APFS partition (ExFAT/FAT32/HFS+) IS itself
//  one mountable volume. An APFS partition is instead a *container* that
//  can host several independently-named, independently-roled volumes
//  (System/Data/Preboot/Recovery/VM) sharing that one partition's space
//  — only visible via `diskutil apfs list`, not the plain partition map,
//  which is why both are queried and merged below. `diskutil list`
//  additionally lists each APFS container's own whole-disk identifier,
//  and any hdiutil-mounted disk image, as separate top-level "WholeDisks"
//  entries — both report VirtualOrPhysical == "Virtual" and are excluded
//  here, matching MacDiskHealthMonitor's existing filter for the same
//  reason (confirmed directly: without it, the internal SSD's own APFS
//  container shows up as a phantom zero-partition "disk", and every
//  mounted Simulator runtime image shows up as if it were a real drive).
//

import Foundation

enum DiskDiscoveryService {
    static func listDisks() -> [DiskInfo] {
        guard let listPlist = runPlist(["/usr/sbin/diskutil", "list", "-plist"]),
              let allDisksAndPartitions = listPlist["AllDisksAndPartitions"] as? [[String: Any]]
        else { return [] }

        let containersByPhysicalStore = apfsContainersByPhysicalStore()
        let bootVolumeUUID = bootAPFSVolumeUUID()
        let bootContainerDisk = bootAPFSContainerDiskIdentifier()

        return allDisksAndPartitions.compactMap { diskDict in
            guard let deviceIdentifier = diskDict["DeviceIdentifier"] as? String else { return nil }
            let info = diskDetails(for: deviceIdentifier)

            // Skip "Virtual" whole-disk entries — see file header for why.
            guard info?.virtualOrPhysical != "Virtual" else { return nil }

            let rawPartitions = diskDict["Partitions"] as? [[String: Any]] ?? []
            var containsBoot = false

            let partitions: [DiskPartitionInfo] = rawPartitions.compactMap { partDict in
                guard let partID = partDict["DeviceIdentifier"] as? String,
                      let size = (partDict["Size"] as? NSNumber)?.int64Value
                else { return nil }
                let content = partDict["Content"] as? String ?? ""

                if let container = containersByPhysicalStore[partID] {
                    let volumes = container.volumes.map { vol -> DiskVolumeInfo in
                        var vol = vol
                        if vol.volumeUUID != nil, vol.volumeUUID == bootVolumeUUID {
                            containsBoot = true
                            vol = DiskVolumeInfo(
                                deviceIdentifier: vol.deviceIdentifier, name: vol.name, sizeBytes: vol.sizeBytes,
                                freeBytes: vol.freeBytes, filesystemName: vol.filesystemName, mountPoint: vol.mountPoint,
                                volumeUUID: vol.volumeUUID, role: vol.role, encryption: vol.encryption, isBootVolume: true
                            )
                        }
                        return vol
                    }
                    if container.containerDisk == bootContainerDisk { containsBoot = true }
                    return DiskPartitionInfo(deviceIdentifier: partID, content: content, sizeBytes: size, apfsVolumes: volumes, plainVolume: nil, containerUUID: container.containerUUID)
                }
                let volume = plainVolumeInfo(for: partID)
                return DiskPartitionInfo(deviceIdentifier: partID, content: content, sizeBytes: size, apfsVolumes: [], plainVolume: volume, containerUUID: nil)
            }

            return DiskInfo(
                deviceIdentifier: deviceIdentifier,
                mediaName: info?.mediaName ?? deviceIdentifier,
                totalSizeBytes: (diskDict["Size"] as? NSNumber)?.int64Value ?? 0,
                partitionScheme: diskDict["Content"] as? String,
                isInternal: info?.isInternal ?? true,
                isRemovable: info?.isRemovable ?? false,
                isSolidState: info?.isSolidState,
                busProtocol: info?.busProtocol,
                partitions: partitions,
                containsBootVolume: containsBoot,
                mediaUUID: info?.diskUUID,
                smart: MacDiskHealthMonitor.smartStatus(forWholeDisk: deviceIdentifier)
            )
        }
    }

    // MARK: - Whole-disk details

    struct DiskDetails {
        let mediaName: String
        let isInternal: Bool
        let isRemovable: Bool
        let virtualOrPhysical: String?
        let isSolidState: Bool?
        let busProtocol: String?
        let diskUUID: String?
    }

    static func diskDetails(for identifier: String) -> DiskDetails? {
        guard let plist = runPlist(["/usr/sbin/diskutil", "info", "-plist", identifier]) else { return nil }
        return DiskDetails(
            mediaName: plist["MediaName"] as? String ?? identifier,
            isInternal: plist["Internal"] as? Bool ?? true,
            isRemovable: plist["RemovableMedia"] as? Bool ?? false,
            virtualOrPhysical: plist["VirtualOrPhysical"] as? String,
            isSolidState: plist["SolidState"] as? Bool,
            busProtocol: (plist["BusProtocol"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            diskUUID: (plist["DiskUUID"] as? String).flatMap { $0.isEmpty || $0 == "None" ? nil : $0 }
        )
    }

    // MARK: - Plain (non-APFS) volumes

    private static func plainVolumeInfo(for identifier: String) -> DiskVolumeInfo? {
        guard let plist = runPlist(["/usr/sbin/diskutil", "info", "-plist", identifier]) else { return nil }
        guard let name = plist["VolumeName"] as? String, !name.isEmpty else { return nil }
        // `DiskVolumeInfo.sizeBytes` means "capacity in use" consistently across both
        // volume kinds (matching APFS's CapacityInUse, which IS actual usage) — but
        // diskutil's plain "Size" key is the volume's TOTAL capacity, not usage. Confirmed
        // by direct inspection: passing raw Size here showed a volume as "used" ≈ its
        // full size even when nearly empty, because Size and FreeSpace were nearly equal
        // (an almost-empty card). For plain (non-APFS) volumes only — unlike APFS, where
        // FreeSpace is unreliable/often reports 0, since space is shared at the container
        // level rather than per-volume — Size and FreeSpace are both genuinely meaningful,
        // so used = Size - FreeSpace is the real number.
        let totalSize = (plist["Size"] as? NSNumber)?.int64Value
        let free = (plist["FreeSpace"] as? NSNumber)?.int64Value
        let used: Int64? = (totalSize != nil && free != nil) ? max(totalSize! - free!, 0) : totalSize
        let encrypted = plist["Encryption"] as? Bool
        return DiskVolumeInfo(
            deviceIdentifier: identifier, name: name,
            sizeBytes: used, freeBytes: free,
            filesystemName: plist["FilesystemUserVisibleName"] as? String ?? plist["FilesystemName"] as? String,
            mountPoint: (plist["MountPoint"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            volumeUUID: (plist["VolumeUUID"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            role: .unknown,
            encryption: encrypted == nil ? .unavailable : (encrypted! ? .encrypted : .notEncrypted),
            isBootVolume: false
        )
    }

    // MARK: - APFS containers/volumes

    private struct APFSContainer { let containerDisk: String; let containerUUID: String?; let volumes: [DiskVolumeInfo] }

    /// Maps each APFS container's underlying GPT partition (e.g. "disk0s2") to its
    /// container disk id and real named volumes — the only way to see actual volume
    /// names/sizes/roles for an APFS-formatted partition, per the file header.
    private static func apfsContainersByPhysicalStore() -> [String: APFSContainer] {
        guard let plist = runPlist(["/usr/sbin/diskutil", "apfs", "list", "-plist"]),
              let containers = plist["Containers"] as? [[String: Any]]
        else { return [:] }

        var result: [String: APFSContainer] = [:]
        for container in containers {
            guard let physicalStore = container["DesignatedPhysicalStore"] as? String,
                  let containerDisk = container["ContainerReference"] as? String
            else { continue }
            let containerUUID = container["APFSContainerUUID"] as? String

            let volumes = (container["Volumes"] as? [[String: Any]] ?? []).compactMap { v -> DiskVolumeInfo? in
                guard let volID = v["DeviceIdentifier"] as? String, let name = v["Name"] as? String else { return nil }
                let locked = v["Locked"] as? Bool ?? false
                let encrypted = v["Encryption"] as? Bool ?? false
                let mountPoint = mountPointForMountedVolume(deviceIdentifier: volID)
                return DiskVolumeInfo(
                    deviceIdentifier: volID, name: name,
                    sizeBytes: (v["CapacityInUse"] as? NSNumber)?.int64Value,
                    freeBytes: (v["CapacityFree"] as? NSNumber)?.int64Value ?? (container["CapacityFree"] as? NSNumber)?.int64Value,
                    filesystemName: "APFS", mountPoint: mountPoint,
                    volumeUUID: v["APFSVolumeUUID"] as? String,
                    role: DiskVolumeRole.from(rawRoles: v["Roles"] as? [String] ?? []),
                    encryption: locked ? .locked : (encrypted ? .encrypted : .notEncrypted),
                    isBootVolume: false
                )
            }
            result[physicalStore] = APFSContainer(containerDisk: containerDisk, containerUUID: containerUUID, volumes: volumes)
        }
        return result
    }

    /// `diskutil apfs list` doesn't report a mount point per volume; a lightweight
    /// `diskutil info` call fills it in only when actually needed (mounted volumes only —
    /// most APFS system volumes like Preboot/Recovery/VM are never user-mounted).
    private static func mountPointForMountedVolume(deviceIdentifier: String) -> String? {
        guard let plist = runPlist(["/usr/sbin/diskutil", "info", "-plist", deviceIdentifier]) else { return nil }
        return (plist["MountPoint"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The real UUID of the currently-booted volume ("/"), used to mark the exact
    /// `isBootVolume` entry precisely (rather than only the whole disk) — never guessed
    /// from a name like "Macintosh HD", which the user could have renamed.
    private static func bootAPFSVolumeUUID() -> String? {
        guard let plist = runPlist(["/usr/sbin/diskutil", "info", "-plist", "/"]) else { return nil }
        return plist["VolumeUUID"] as? String
    }

    /// The APFS container disk (e.g. "disk3") backing the currently-booted volume,
    /// used to mark `containsBootVolume` on the whole disk that hosts it. This is used
    /// for a real hard-block in DiskOperationService, not merely informational display.
    private static func bootAPFSContainerDiskIdentifier() -> String? {
        guard let plist = runPlist(["/usr/sbin/diskutil", "info", "-plist", "/"]) else { return nil }
        return plist["ParentWholeDisk"] as? String
    }

    // MARK: - Process plumbing (read-only calls only — see DiskOperationService for actions)

    static func runPlist(_ args: [String]) -> [String: Any]? {
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

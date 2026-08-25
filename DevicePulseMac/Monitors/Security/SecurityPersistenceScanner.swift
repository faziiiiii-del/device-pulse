//
//  SecurityPersistenceScanner.swift
//  DevicePulseMac
//
//  Reads the same standard, world-readable LaunchAgent/LaunchDaemon
//  plist locations Startup Optimiser does, but as its own small,
//  self-contained reader — kept separate from MacStartupMonitor
//  deliberately, so Security has no dependency on Maintenance/Startup
//  code and can evolve independently. `launchctl print` (loaded-state
//  check) is the same public, documented command Startup Optimiser
//  already relies on.
//

import Foundation

struct PersistenceItem {
    let label: String
    let plistPath: String
    let programPath: String?
    /// Human-readable description of which launchd domain this
    /// belongs to, e.g. "User LaunchAgent".
    let owner: String
    let isLoaded: Bool
}

enum SecurityPersistenceScanner {
    static func scanLocations() -> [(path: String, owner: String, isDaemon: Bool)] {
        let home = NSHomeDirectory()
        return [
            ("\(home)/Library/LaunchAgents", "User LaunchAgent", false),
            ("/Library/LaunchAgents", "Global LaunchAgent", false),
            ("/Library/LaunchDaemons", "LaunchDaemon", true),
        ]
    }

    static func scan() -> [PersistenceItem] {
        var items: [PersistenceItem] = []
        for (dir, owner, isDaemon) in scanLocations() {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for file in files where file.hasSuffix(".plist") {
                let fullPath = (dir as NSString).appendingPathComponent(file)
                guard let data = FileManager.default.contents(atPath: fullPath),
                      let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
                else { continue }

                let label = plist["Label"] as? String ?? (file as NSString).deletingPathExtension
                let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first

                items.append(PersistenceItem(
                    label: label, plistPath: fullPath, programPath: program, owner: owner,
                    isLoaded: isLoaded(label: label, isDaemon: isDaemon)
                ))
            }
        }
        return items
    }

    private static func isLoaded(label: String, isDaemon: Bool) -> Bool {
        let domain = isDaemon ? "system" : "gui/\(getuid())"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["print", "\(domain)/\(label)"]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }
}

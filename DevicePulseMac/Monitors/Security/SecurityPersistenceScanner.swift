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
    /// The exact `launchctl` domain target this item loads into (e.g.
    /// "gui/501" or "system") — carried through to `SecurityFinding` so a
    /// "Disable" action can unload the real running job via
    /// `launchctl bootout <domainTarget>/<label>`, not just move the plist
    /// file (which does nothing to a job launchd already has loaded).
    let domainTarget: String
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

                let domain = isDaemon ? "system" : "gui/\(getuid())"
                items.append(PersistenceItem(
                    label: label, plistPath: fullPath, programPath: program, owner: owner,
                    isLoaded: isLoaded(label: label, domain: domain), domainTarget: domain
                ))
            }
        }
        return items
    }

    private static func isLoaded(label: String, domain: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["print", "\(domain)/\(label)"]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    /// Unloads a running launchd job via the standard, documented `launchctl bootout`
    /// command — the same mechanism Startup Optimiser's `MacStartupMonitor.disable(_:)`
    /// uses. Necessary because just moving/quarantining the plist file does nothing to a
    /// job launchd has already loaded into memory: launchd reads the plist once at load
    /// time and keeps running from its own in-memory copy, so the flagged program keeps
    /// running until reboot unless it's explicitly booted out. A LaunchDaemon (`system`
    /// domain) requires the app to be running with admin privileges; that failure is
    /// surfaced to the caller as `false` rather than silently doing nothing.
    @discardableResult
    static func disable(domainTarget: String, label: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["bootout", "\(domainTarget)/\(label)"]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }
}

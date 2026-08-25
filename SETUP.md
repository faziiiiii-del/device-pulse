# DevicePulse — setup guide

An honest iPhone "device stats" app: battery %, charging state, Low Power
Mode, system memory, storage, network type, and clearing **this app's own**
cache/temp files. See the in-app disclaimer card for exactly what iOS does
and doesn't allow any third-party app to do (no battery health API, no
Wi-Fi signal strength API, no clearing other apps'/system caches — these
are Apple sandbox restrictions, not something a smarter implementation
gets around without jailbreaking).

## 1. Create the Xcode project

1. Open Xcode → **File ▸ New ▸ Project**
2. Choose **iOS ▸ App**, click Next
3. Product Name: `DevicePulse`
4. Interface: **SwiftUI**, Language: **Swift**
5. Uncheck "Use Core Data" and "Include Tests" (not needed)
6. Save it anywhere you like

## 2. Set the deployment target

Select the project in the navigator → the DevicePulse target →
**General** tab → set **Minimum Deployments** to **iOS 16.0** (the UI uses
`NavigationStack`, which needs 16+).

## 3. Drop in these files

In the `DevicePulseApp` folder you were sent, there are 8 Swift files:

- `DevicePulseApp.swift`
- `ContentView.swift`
- `BatteryMonitor.swift`
- `MemoryMonitor.swift`
- `StorageMonitor.swift`
- `NetworkMonitor.swift`
- `AppCacheManager.swift`
- `DeviceInfo.swift`
- `Formatting.swift`

In Xcode's project navigator, **delete the auto-generated
`ContentView.swift` and the app's `...App.swift`** (move to trash), then
drag all 9 files above from Finder into the project navigator (check
"Copy items if needed" and make sure the DevicePulse target checkbox
is ticked in the dialog).

## 4. Sign it to your own account

1. Select the project → target → **Signing & Capabilities**
2. Team: pick your Apple ID (Xcode → Settings → Accounts to add it if it's
   not there yet — a free Apple ID works, no paid account needed to
   sideload)
3. Xcode will assign a Bundle Identifier automatically; if it collides,
   change it to something like `com.yourname.devicedashboard`

## 5. Run it on your iPhone

1. Plug your iPhone in (or pair over Wi-Fi), select it as the run
   destination in the toolbar
2. Press **⌘R** (Run)
3. First run: on the iPhone go to **Settings ▸ General ▸ VPN & Device
   Management** and trust your developer certificate
4. With a **free** Apple ID the app re-signs and needs a rebuild every
   **7 days**. A paid Apple Developer account ($99/yr) extends that to
   **1 year** and removes the need to keep Xcode plugged in — otherwise
   identical setup.

## What's real vs. not, at a glance

| Feature | Status |
|---|---|
| Battery % and charging state | ✅ Real, public API |
| Low Power Mode | ✅ Real, public API |
| Battery health / cycle count | ❌ No public API exists — Settings app only |
| System memory (used/free/wired/etc.) | ✅ Real, public Mach API |
| Per-app memory breakdown of other apps | ❌ Not accessible to any app |
| Storage total/used/free | ✅ Real, public API |
| Network type (Wi-Fi/Cellular/none) | ✅ Real, public API |
| Wi-Fi signal strength (RSSI/dBm) | ❌ No public API since iOS locked it down |
| Clear this app's own cache/temp | ✅ Real, actually deletes files |
| Clear other apps'/system caches | ❌ Impossible without jailbreak — sandboxing |

Want to go further? A jailbroken device (or a Mac companion app using
IOKit) can read some of the ❌ items, but that's a different, much riskier
project than a normal sideloaded app — happy to talk through it if you
want to go that route later.

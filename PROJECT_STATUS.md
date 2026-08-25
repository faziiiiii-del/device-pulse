# Device Pulse — Project Status

_Updated 2026-08-23 (later session): Security section, dual theming
(Classic/Frosted), three new Storage tools (Duplicate Finder, Space
Map, Saved Wi-Fi Networks), and a round of real bug fixes across both
targets. See "Later session" below for the full rundown — the original
theming/feature/hardening pass description further down is still
accurate for everything it covers, just no longer the latest state._

## Later session (2026-08-23, second pass)

**New: Security section** — `Security` sidebar item (Monitor group).
Real detection, no fabricated malware DB:
- Code-signing inspection via `SecStaticCode` (Security framework) —
  Apple-signed / valid third-party / unsigned / invalid, never treats
  "unsigned" as "malicious" on its own.
- Quarantine attribute inspection (`quarantineProperties`), launchd
  persistence scanning (LaunchAgents/LaunchDaemons), SHA-256 hashing of
  flagged files only (never bulk-hashes everything scanned).
- Risk model (Low/Medium/High) built purely from combining real signals
  (signature validity, location, recency, persistence) — Critical is
  reserved for a verified hash match against a configured threat DB,
  which doesn't exist, so this scanner never produces Critical on its
  own. `HashReputationResult` always resolves `.unavailable` rather than
  implying "clean."
- Quick Scan / Deep Scan with live progress, cancellation, a findings
  cap (300) with honest truncation messaging, and a persisted per-path
  **Ignore list** (`SecurityIgnoreList`) so reviewed items don't keep
  reappearing.
- Quarantine is Device Pulse's own managed folder (`SecurityQuarantineManager`)
  — moves, never deletes; Restore/Delete Permanently both explicit.
- Security Health (FileVault/Firewall/Gatekeeper/SIP/Automatic Updates
  via `fdesetup`/`socketfilterfw`/`spctl`/`csrutil`/`defaults`), a
  Security Score separate from the Dashboard Health Score (never "100"
  pre-scan), and a Privacy Audit that only ever reports **Device
  Pulse's own** TCC-visible permissions (Camera/Mic/Accessibility/Screen
  Recording) — explicitly refuses to fake a cross-app permissions
  matrix, since that needs reading the undocumented `TCC.db`.
- Menu bar shows a cached 🟢/🟡/🔴 indicator (`SecurityStatusCache`) —
  reads the last scan's cache only, never triggers a scan itself.

**Fixed a real freeze bug** in the scanner: `spctl --assess` (Gatekeeper
check) was being called for *every* validly-signed app during a scan —
expensive network-backed calls thrown away for the ~99% that aren't
flagged. Now only fetched lazily for actually-flagged apps, with a
5-second timeout guard. Also added directory exclusions (`node_modules`,
`.git`, venvs, `DerivedData`, etc.) and a findings cap, plus switched
the findings/quarantine lists to `LazyVStack` — the combination of
unbounded findings + a plain `VStack` was causing AppKit's Auto Layout
to peg the main thread (`NSBitSetFindNext` spinning at 80% CPU),
confirmed via Xcode's debugger.

**New: dual theming (Classic / Frosted)** — `AppTheme.swift` +
`ThemeReader`. Classic is the original native look, untouched pixel for
pixel. Frosted is a translucent dark-glass look (`FrostedBackground`,
`.ultraThinMaterial` cards) applied app-wide via one change to the
shared `MacCard`/`MacOverviewCard` components plus `.preferredColorScheme`
in `MacRootView` — not a per-screen reskin. Toggle lives in Settings ▸
Appearance and as a small sun/moon icon in the window toolbar (a
persistent sidebar footer was tried first and reverted — it altered
Classic's look, which the toggle is explicitly not supposed to do).
Dashboard has two distinct layouts (`classicBody`/`frostedBody`)
sharing the same state, since Frosted's hero-ring/live-graph design is
a structural change, not just a recolor.

**New: three Storage tools**
- **Duplicate Finder** — `MacDuplicateScanner` (size-bucket first, then
  SHA-256 only within same-size groups — never hashes indiscriminately).
  Scan → Review → Clean; each group's oldest file is pre-kept, everything
  else pre-selected for Trash, all reversible via `MacTrashUndo`.
- **Space Map** — `Treemap.swift`, a from-scratch squarified-treemap
  layout algorithm (verified by hand: tile areas sum exactly to the
  container area, no gaps/overlaps) rendered over the same real
  category-size data `MacStorageCategoryScanner` already computes for
  Storage's breakdown. Click a tile to drill one level down into its
  own subfolders as a nested treemap.
- **Saved Wi-Fi Networks** — card added to the existing Network tab
  (`MacWiFiNetworksMonitor`), via `networksetup` (the same tool System
  Settings uses). Explicitly labeled as the *remembered* network list,
  not a live scan of nearby networks (no public API for that without
  Location permission, and even then no signal strength is exposed).

**Explicitly declined, with reasons written into the assistant's
responses (worth remembering if asked again):**
- Browser history/data clearing (Safari/Chrome/Firefox) — no public
  API; would mean parsing each browser's private, undocumented storage
  format.
- Cross-app "Application Permissions" matrix — would need reading
  `~/Library/Application Support/com.apple.TCC/TCC.db` directly, an
  undocumented, version-fragile private database.
- System-wide audio EQ ("like Boom") — requires shipping an actual
  audio driver (Core Audio HAL plugin or DriverKit Audio Server Driver
  Extension) plus a privileged installer; fundamentally a different
  product, not a feature addable to this app's architecture. User
  decided to build this as a **separate app** instead.

**Other real fixes this session:**
- **RAM shown as 18GB instead of 16GB** — `ByteFormat` was using decimal
  (1000-based) formatting for RAM everywhere, same as storage. Added
  `ByteFormat.memoryString()` using `.memory` (1024-based) `ByteCountFormatter`
  style, matching Activity Monitor's convention. Applied everywhere RAM
  is shown (Dashboard, Memory tab, RAM Optimiser, Processes, Device,
  menu bar, alerts); storage/file sizes correctly left decimal.
- **`MacAlertMonitor`** (the always-on-by-default background watcher)
  was spawning `ps` every 30s and `launchctl print` per LaunchAgent
  every 5 minutes **on the main thread** via its `Timer`. Moved both to
  a background queue — was a silent, recurring stutter for every user
  the whole time the app runs, not just during an explicit scan.
- **Network speed test**: fixed a real crash bug (`tcpLatency`'s
  connection-ready handler and its timeout fallback ran on two
  different queues, both able to double-resume the same Swift
  continuation — instant crash under the right timing). Same bug
  existed and was independently fixed in the iOS target's copy.
  Also fixed download speed silently never reporting: Cloudflare's
  `speed.cloudflare.com/__down` endpoint 403s arbitrary byte counts
  outside its own known test-size buckets (confirmed by hand: 15MB is
  blocked, 10/25/50MB aren't) — switched to 10MB. Latency is now a
  median of 3 samples instead of one, and both tests do a small
  warm-up request first so connection-setup time isn't counted as part
  of the measured throughput.
- **iOS**: `StorageView`'s cache-size scan ran synchronously on the main
  thread every 5 seconds via a `Timer` — moved to background, same
  pattern as the Mac fix.

**Not done, explicitly deferred by the user:** Old Files and Similar
Photos (the last two of the originally-proposed Storage tools) —
user said not needed for now.

## macOS target

Second target `DevicePulseMac` in the same `DevicePulse.xcodeproj`
(via `project.yml`), bundle ID `com.faziii.devicepulse.mac`, no App
Sandbox (personal utility, needs to shell out to `/bin/ps`,
`/bin/launchctl`, `/usr/bin/nettop`). Sources: `DevicePulseMac/`
(Mac-specific monitors + SwiftUI views) and `Shared/` (cross-platform
`DiagnosticStatus`, `DiagnosticCheck`, `ByteFormat`,
`StatusLevel`/`StatusDot`/`StatusBadge` — currently only linked into
the Mac target, not iOS, so there's zero risk to the iOS build).

**Theme**: vibrant CleanMyMac-style — per-section colored gradient icon
tiles (`MacTheme.swift`), used consistently in the sidebar, card
headers, and overview cards. Dashboard leads with a circular
health-score ring (`MacHealthRing`) instead of a plain number list.

**Sidebar** (`MacRootView.swift`, `NavigationSplitView`), grouped into
four conceptual sections rather than one flat list (as of the later
session above — Security/Duplicate Finder/Space Map are new since this
paragraph was first written):
- **Care** — Dashboard, Smart Care
- **Monitor** — CPU & Thermal, Memory, Network, Battery, Processes, Device, Security
- **Storage** — Storage, Big Files Finder, Duplicate Finder, Space Map, Uninstaller, Maintenance
- **Optimise** — RAM Optimiser, Startup Optimiser

Settings is **not** in the sidebar — it's a real macOS Settings window
(⌘,), matching platform convention. ⌘1–9 jump to the first nine sidebar
sections. A `MenuBarExtra` (`MacMenuBarView.swift`) shows a live
CPU/Memory readout with a color-coded health dot, independent of the
main window — works in "menu bar only" mode (Dock icon/window hidden,
toggle in Settings).

**Built and working, real data:**
- **Dashboard** — health ring driven by diagnostic pass/warning counts, overview cards (tap to jump), Run Full Diagnostic
- **Smart Care** — Scan → Diagnose → Recommend → Review (checkboxes, pre-selected but editable) → Clean. Only ever offers the categories Maintenance already marks low-risk (User Caches, Logs, Xcode DerivedData, iOS DeviceSupport). Reports honestly as "Moved X to Trash" + "X can be reclaimed by emptying Trash" — never claims to have "freed" space, since Trash doesn't reclaim disk space until emptied.
- **CPU & Thermal** — aggregate + **per-core** utilization (`host_processor_info`/`PROCESSOR_CPU_LOAD_INFO`), performance/efficiency core counts (`hw.perflevel0/1.physicalcpu`), thermal pressure state, **GPU utilization + memory** via IORegistry's `IOAccelerator`/`PerformanceStatistics` (same source the open-source Stats app uses — verified directly against this Mac's `ioreg` output before shipping), CPU+GPU history sparklines. CPU frequency and any temperature in °C are shown honestly as unavailable — no public API exposes either on Apple Silicon, confirmed by direct inspection, not assumed.
- **Memory** — wired/active/inactive/compressed/free via `host_statistics64(HOST_VM_INFO64)`, swap via `sysctl vm.swapusage`, live pressure via `DispatchSourceMemoryPressure` cross-checked every refresh against `kern.memorystatus_vm_pressure_level` (the actual kernel pressure signal — high RAM % alone is not pressure), top memory users
- **Storage** — all mounted volumes, plus a real category breakdown (Applications/Photos/Documents/Desktop/Downloads/Movies/Music/Developer) built from actual folder scans, shown as a stacked bar + list, click-to-drill-down into a category's subfolders with Reveal-in-Finder. "Other" is the honest remainder after subtracting scanned categories from real volume-used space — explicitly labeled as not the same source as About This Mac's private-framework breakdown.
- **Big Files Finder** — pick a folder, pick a size threshold, sorted results with Reveal/Trash (with Undo)
- **Uninstaller** — lists `/Applications` + `~/Applications`, leftover-file detection is **tiered**: exact bundle-ID/name matches are pre-selected, substring-only "possible" matches are shown separately and never auto-selected — a per-item checklist lets you review before anything moves. Apple system apps (`com.apple.*` bundle ID) are protected from uninstall by default.
- **Network** — connection type/interface via `NWPathMonitor`, local IPs via `getifaddrs`, on-demand DNS/TCP-latency/speed test (Cloudflare)
- **Battery** — percentage/charging/power source via public IOKit `IOPSCopyPowerSourcesInfo`; cycle count, full-charge/design/current capacity (mAh), voltage, current (correctly sign-corrected from IOKit's raw bit pattern), computed wattage, estimated time remaining/to-full, and a self-measured discharge-rate trend (since app launch) all from IORegistry `AppleSmartBattery` — best-effort, not a formally-stable API. "Battery Health: Good/Fair/Poor" is an explicit capacity-ratio threshold, captioned as not being Apple's own private "Service Recommended" diagnostic. Temperature shown honestly as not exposed — confirmed absent from this hardware's IORegistry properties directly, not assumed.
- **Processes** — sortable table (click headers) for Process/CPU/RAM/Network; Network is real, via `nettop` sampled for a rate (same delta pattern as CPU ticks); GPU and Energy columns are present but honestly show unavailable (no public API on this OS). Click a process → Inspect (full path, PID, CPU/RAM/network) → Quit/Force Quit, scoped to regular user-facing apps only (never arbitrary background/system processes, to avoid destabilizing macOS) — same population `MacMemoryOptimizer` already used for RAM Optimiser's quit feature.
- **RAM Optimiser** — Analyse Memory (findings driven by the same real memory-pressure signal, not a raw % threshold), quit selected user apps via `NSRunningApplication` with confirmation, automatic before/after re-measurement. No fake "purge" — none exists via legitimate API
- **Startup Optimiser** — scans `~/Library/LaunchAgents`, `/Library/LaunchAgents`, `/Library/LaunchDaemons` (real plist files), classifies Apple/Known Third-Party/User-Installed/Unknown, "Loaded" status queried per-item via `launchctl print <domain>/<label>` (not a single blanket `launchctl list`, which under/over-reports for LaunchDaemons and some global agents) — verified against real loaded/not-loaded services before shipping. Enable/disable via `launchctl bootstrap`/`bootout` (never deletes files); LaunchDaemons requiring admin privileges show "Requires admin" instead of silently failing. Confirmation dialog shows exact source path before any change, local change history.
- **Maintenance** — scan → review → **clean** (implemented: moves a category's contents to Trash, reversible via Undo) → separately, **Empty Trash** for the Trash category itself, which is the one genuinely permanent action and gets its own stronger confirmation wording. "Access Required" shown honestly instead of fake 0 bytes.
- **Device** — model identifier, processor brand, architecture, RAM, displays, macOS version/build, uptime, thermal state
- **Settings** (⌘, window) — refresh interval (now actually controls CPU/Memory sample rate, live), launch-at-login (`SMAppService`), menu-bar-only mode, background alerts toggle (actually starts/stops the watcher, not just gates notification delivery), Full Disk Access hint + deep link to System Settings

**Background alerts** (`MacAlertMonitor.swift`) — runs from launch if
enabled (works in menu-bar-only mode), fully stops (no CPU/memory
timers, no `ps`/`nettop`/startup-plist scans) when the Settings toggle
is off. Six conditions, each edge-triggered (fires once when entered,
not repeatedly while it continues):
1. Memory pressure critical (real kernel signal)
2. Storage free < 10% (with hysteresis)
3. Battery fully charged while on AC
4. CPU > 90% sustained for 10 minutes
5. A single process >20% of RAM **while memory pressure is already elevated** (not either condition alone — a big Chrome/Xcode/Docker process is normal by itself)
6. A new LaunchAgent/Daemon appears (baseline established on first run, not alerted retroactively)

**Distribution**: `scripts/build_dmg.sh` builds + packages a DMG
(builds unsigned then signs locally, since this project's iCloud-synced
folder stamps extended attributes that break in-build codesign — fixed
and verified end to end, including mounting and launching the packaged
app). `DISTRIBUTION.md` documents the remaining steps (Developer ID
signing, notarization, optional Sparkle auto-update) that need your own
paid Apple Developer account credentials.

**Shared thresholds** (`DevicePulseThresholds.swift`) — CPU/storage/
swap/battery/large-process thresholds are defined once and used by
Dashboard, Diagnostics, Alerts, and RAM Optimiser, so the same
underlying state can't show "Normal" in one place and "Warning" in
another.

**Known, honest gaps (macOS doesn't expose these publicly):**
- No third-party Login Items list — the API that used to allow this (`LSSharedFileList`) is deprecated/locked down; only this app's own item is manageable via `SMAppService`. UI says so explicitly rather than faking a list.
- No CPU/GPU temperature in °C, no CPU frequency, no battery temperature — confirmed absent by direct inspection on this hardware (Apple Silicon), not assumed. Only `ProcessInfo.thermalState`'s 4-level state is available, same as iOS.
- No memory "purge" button — macOS doesn't expose a safe userland API for this; not implemented rather than faked.
- Battery cycle count/capacities/voltage/current, GPU utilization/memory, and startup-item introspection are all read from IORegistry/`ioreg`-adjacent APIs — public IOKit, but not documented/stable contracts. Treated as best-effort, shown as "Unavailable" if absent.
- Storage category breakdown won't pixel-match About This Mac's — that uses a private Apple framework third-party apps can't call. This app's breakdown is built from real filesystem scans instead (same approach DaisyDisk/CleanMyMac use).

**Not yet built:** real historical persistence for CPU/Memory/etc.
(24h/7d/30d trends) — currently just the last 60 in-memory samples per
tab, lost on quit; the Settings "history retention" slider was removed
rather than left as a control that did nothing. Dedicated Xcode Cleaner
module (per-project size breakdown, beyond the existing DerivedData/
Archives/Simulator categories in Maintenance). Developer ID signing/
notarization (needs your own Apple Developer account, see
`DISTRIBUTION.md`).

**Build from command line:**
```bash
cd ~/Desktop/Device\ Pulse
xcodegen generate
xcodebuild -project DevicePulse.xcodeproj -scheme DevicePulseMac -destination 'platform=macOS' build
```

**Build from Xcode:** the project has two schemes now — picking the wrong
one is an easy mistake since both are visible in the same picker.
1. Click the scheme selector in the toolbar (shows `DevicePulse › iPhone` by default).
2. Choose **DevicePulseMac** — not DevicePulse (that's the iOS target; running it with "My Mac (Designed for iPhone)" as the destination launches the iPhone app in compatibility mode, not the native Mac app).
3. Destination should auto-switch to **My Mac**; if not, pick it manually — a native macOS target only ever offers "My Mac".
4. ⌘R to build and run.
5. First run only: Xcode will likely ask for a signing Team under **Signing & Capabilities** for the `DevicePulseMac` target specifically (separate from the iOS target's signing) — pick your Apple ID same as before.

Verified: builds clean (0 errors, 0 non-cosmetic warnings), launches, ran
for 30s+ with no crashes/exceptions in Console. iOS target rebuilt
immediately after and still builds clean — untouched.

---

## iOS app (existing, unchanged by the above)

## What this is

A personal, sideloaded iPhone diagnostic/monitoring app. SwiftUI, iOS 16+,
built via XcodeGen (`project.yml` → `DevicePulse.xcodeproj`). Bundle ID
`com.faziii.devicepulse`. Not an App Store product — no private/jailbreak
APIs used, but also no App Store review constraints assumed.

Guiding rule baked into the whole codebase: **never fabricate a metric iOS
doesn't expose**. Every screen that hits a platform limitation (battery
health, Wi-Fi RSSI, per-app storage, other apps' memory) says so explicitly
in-app rather than faking a number.

## Architecture

- **6-item custom bottom bar** ([ContentView.swift](DevicePulseApp/ContentView.swift)) — Home, Battery, Memory,
  Storage, Network, Device. Deliberately NOT a plain SwiftUI `TabView`:
  with 6 items it auto-folds into an iOS "More" menu, which would hide
  Network/Device behind an extra tap. `DashboardTab` enum + hand-rolled
  `HStack` of buttons avoids that.
- **Home tab** ([HomeView.swift](DevicePulseApp/HomeView.swift)) — overview cards (tap to jump to that tab),
  Quick Check / Run Full Diagnostic actions, and a "More Tools" list
  pushing to 5 secondary screens via an explicit `NavigationPath`
  (`path.append(...)`), not `NavigationLink`. Uses `Button` + path
  mutation rather than `NavigationLink(value:)` — see **Known issue**
  below for why.
- **Shared engines** (no UI): [ThermalMonitor.swift](DevicePulseApp/ThermalMonitor.swift), [MemoryPressureMonitor.swift](DevicePulseApp/MemoryPressureMonitor.swift),
  [DiagnosticsEngine.swift](DevicePulseApp/DiagnosticsEngine.swift) (PASS/WARNING/INFO/UNAVAILABLE checks with
  documented thresholds, no blended "health score"), [NetworkDiagnostics.swift](DevicePulseApp/NetworkDiagnostics.swift)
  (DNS timing via CFHost, TCP-connect latency via Network framework,
  download/upload speed via speed.cloudflare.com, local IP via
  `getifaddrs`), [Benchmarks.swift](DevicePulseApp/Benchmarks.swift) (CPU/disk/memory/GPU — experimental,
  clearly labeled as relative/non-comparable).
- **Persistence**: [HistoryStore.swift](DevicePulseApp/HistoryStore.swift) (auto-recorded observations, throttled
  to 1/5min, JSON file in Application Support) and [SnapshotStore.swift](DevicePulseApp/SnapshotStore.swift)
  (manually-saved full snapshots, JSON in Documents, with a diff/compare
  view). Both local-only, nothing leaves the device except the
  user-initiated network tests (Cloudflare speed test, ipify public-IP
  lookup, both opt-in toggles).
- **Secondary screens** (pushed from Home): [DiagnosticView.swift](DevicePulseApp/DiagnosticView.swift),
  [InvestigateView.swift](DevicePulseApp/InvestigateView.swift) (5 canned "what's wrong" flows), [HistoryView.swift](DevicePulseApp/HistoryView.swift)
  (sparkline trends), [SnapshotsView.swift](DevicePulseApp/SnapshotsView.swift), [LiveMonitorView.swift](DevicePulseApp/LiveMonitorView.swift)
  (foreground-only 2s polling, explicitly labeled as such), [AdvancedView.swift](DevicePulseApp/AdvancedView.swift).

## Permissions in use

- **Photos** (`NSPhotoLibraryUsageDescription`) — Storage tab's photo/video
  size estimate. Gated behind explicit user tap, never auto-requested.
- Network access — no special entitlement needed (plain HTTPS).
- No Location, no Camera, no Microphone, no Bluetooth, no Contacts.

## Build

```bash
cd ~/Desktop/Device\ Pulse
xcodegen generate
xcodebuild -project DevicePulse.xcodeproj -scheme DevicePulse \
  -destination 'generic/platform=iOS Simulator' build
```

Regenerate (`xcodegen generate`) after adding/removing any Swift file —
`project.yml` drives the `.xcodeproj`, don't hand-edit the Xcode project.

## Known issue — unresolved

Home's "More Tools" row taps (Investigate / History / Snapshots / Live
Monitor / Advanced) were unresponsive to simulated taps late in the last
session, across three different implementations (`NavigationLink
(destination:)`, `NavigationLink(value:)` + `.navigationDestination`, and
finally `Button` + explicit `NavigationPath`). The last form is what's in
the code now and is the most standard/reliable pattern available, but it
was never confirmed working — the likely explanation is that the
automated tap coordinates were simply imprecise against a short
(~36pt-tall) row, not a real code defect, but this was not verified on a
real device. **Please tap through Home → More Tools → each of the 5 rows
once and confirm they push correctly.** If any don't, tell me which one
and I'll dig in with device-side debugging instead of simulator taps.

## What's real vs. estimated (quick reference)

| Data | Status |
|---|---|
| Battery %, charging state, thermal state, low power mode | Real |
| Battery health %, cycle count | Not available — no public API |
| System memory (used/free/wired/active/inactive/compressed), memory pressure | Real |
| Per-app memory of other apps | Not available |
| Storage total/used/free, this app's own Documents/Library/Cache/Temp | Real |
| Photos/videos count, size, screenshots, screen recordings, largest/recent items | Real but an ESTIMATE — iCloud-optimized libraries won't match Settings exactly |
| Per-app or per-category storage (Apps/Messages/System/etc.) | Not available — private API territory |
| Network type, local IP, DNS resolution time, TCP-connect latency | Real |
| Wi-Fi RSSI/signal strength, SSID | Not available without Location permission + special entitlement — deliberately omitted |
| Download/upload speed | Real, live test via speed.cloudflare.com (opt-in) |
| Public IP | Real, via ipify.org (opt-in) |
| CPU/disk/GPU/memory-alloc benchmarks | Real but experimental — relative numbers only, not industry-comparable |
| Uptime, device model, iOS version, screen size/scale, locale, timezone | Real |

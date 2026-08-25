# Distributing Device Pulse for Mac

`scripts/build_dmg.sh` builds a Release DMG you can run today. It's
signed only with whatever local identity Xcode is currently using
("Sign to Run Locally" or your personal Team) — that's enough to run it
on this Mac, or hand the DMG to yourself on another Mac you also control
and right-click ▸ Open through Gatekeeper's warning once.

To distribute it more broadly (so it opens with a plain double-click on
someone else's Mac, no warning), three more steps are needed. Each
requires your own Apple Developer account credentials, which I can't
enter or hold on your behalf — you'd run these yourself, one time:

## 1. Developer ID signing

Requires a **paid Apple Developer Program membership** ($99/yr — a free
Apple ID, like the one used for local sideloading today, isn't enough
for Developer ID).

1. In Xcode ▸ Settings ▸ Accounts, make sure your paid developer account
   is added.
2. In the DevicePulseMac target's Signing & Capabilities, switch from
   automatic "Sign to Run Locally" to your **Developer ID Application**
   certificate (Xcode will offer to create one if you don't have it
   yet).
3. Re-run `scripts/build_dmg.sh` — the resulting `.app` inside the DMG
   will now carry a Developer ID signature.

## 2. Notarization

Apple scans the signed build for malware and issues a notarization
ticket. This needs an app-specific password (not your main Apple ID
password) stored once in your keychain:

```bash
xcrun notarytool store-credentials "devicepulse-notary" \
  --apple-id "your-apple-id@example.com" \
  --team-id "YOUR_TEAM_ID"
```

This prompts interactively for the app-specific password (generate one
at appleid.apple.com ▸ Sign-In and Security ▸ App-Specific Passwords) —
run it yourself in a terminal, since entering credentials isn't
something I'll do even if asked. Once stored, notarizing a build is:

```bash
xcrun notarytool submit build/DevicePulse.dmg \
  --keychain-profile "devicepulse-notary" \
  --wait
xcrun stapler staple build/DevicePulse.dmg
```

## 3. (Optional) Auto-update via Sparkle

If you want the app to check for and install its own updates rather
than rebuilding manually each time, the standard tool is
[Sparkle](https://sparkle-project.org/). That needs a place to host an
`appcast.xml` feed and versioned DMG/zip downloads — a GitHub Releases
page works well and is free. This isn't wired up yet since it depends
on where you'd want to host that feed; happy to add the Sparkle
dependency and appcast generation once you pick a hosting spot.

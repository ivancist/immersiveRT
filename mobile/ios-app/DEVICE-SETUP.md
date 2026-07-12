# Device Setup — immersiveRT iOS Native Client

Repeatable, one-time-per-device setup for running and verifying the native iOS client
(`immersiveRT`) on a physical iPhone. Required before any of the on-device checkpoints
in `06.2-09-PLAN.md` (WebTransport spike, CoreMotion axis mapping, WebRTC fan-out).

None of these steps are needed to build for the iOS Simulator or to run the XCTest
suite — see "Running the full test suite" below, which works standalone.

---

## 1. Trust the mkcert root CA on the iPhone

The dev server (`server/`) serves TLS using an mkcert-issued certificate (see root
`CLAUDE.md` → TLS for Local Development). mkcert's root CA is trusted in your desktop
browser/OS trust store, but **not** on the iPhone. Unlike a desktop browser hitting an
untrusted cert, there is no "click through the warning" UX for `Network.framework` /
`URLSession` TLS validation on iOS — the connection simply fails outright. Both steps
below are required; installing the profile alone is **not** sufficient (see
`06.2-RESEARCH.md`, Pitfall 2).

1. **Export the root CA** on the dev Mac:
   ```bash
   mkcert -CAROOT
   ```
   This prints the directory containing `rootCA.pem`. That file is the one to install.

2. **Transfer `rootCA.pem` to the iPhone** — either:
   - AirDrop the file directly from the Mac's Finder to the iPhone, or
   - Serve it from a directory on the dev machine (e.g. `python3 -m http.server` in the
     `mkcert -CAROOT` directory) and download it in Safari on the iPhone over the same LAN.

3. **Install the configuration profile:**
   - Opening `rootCA.pem` on the iPhone prompts "Profile Downloaded."
   - Go to **Settings → General → VPN & Device Management** and install the profile.

4. **Enable full trust** (the step that's easy to miss):
   - Go to **Settings → General → About → Certificate Trust Settings**.
   - Toggle on **Full Trust** for the mkcert root CA.
   - Without this step the profile is installed but the cert chain still fails
     validation — connections will still fail with a TLS trust error.

Repeat this setup once per iPhone (and again if the mkcert root CA is ever regenerated
via `mkcert -uninstall` / `mkcert -install`).

---

## 2. Run the dev server reachable from the iPhone's LAN

The iPhone connects to the dev server over the local network, not `localhost` — the
Simulator can share the Mac's `localhost`, but a physical device cannot.

1. Start the dev server (`server/`, wtransport + WebSocket signaling) as usual.
2. Confirm the Mac's LAN IP address (e.g. `ipconfig getifaddr en0` on Wi-Fi).
3. Confirm the iPhone and the dev Mac are on the **same LAN** (same Wi-Fi network, not
   a guest network that isolates clients from each other).
4. Point the app at the Mac's LAN IP (via the QR pairing flow's host field, or however
   the app's connection screen is configured) — not `localhost` or `127.0.0.1`.
5. Verify reachability before launching the app, e.g.:
   ```bash
   curl -k https://<mac-lan-ip>:<port>/
   ```
   from a device on the same network, or confirm the port responds to a basic TCP
   connection check.

---

## 3. Deploy via Xcode-tethered debug build (D-06)

Per D-06, distribution for this phase is a free-Apple-ID Xcode-tethered debug build —
no TestFlight or paid Apple Developer Program membership required.

1. Connect the iPhone to the dev Mac via USB (or set up wireless debugging in
   **Xcode → Window → Devices and Simulators** after one USB pairing).
2. Open `mobile/ios-app/immersiveRT.xcodeproj` in Xcode.
3. Select the iPhone as the run destination (not a Simulator).
4. In **Signing & Capabilities**, sign in with your (free) Apple ID under
   **Xcode → Settings → Accounts** if not already configured, and select your personal
   team for automatic signing.
5. Build and run (⌘R). The first run on a new device will prompt you to trust the
   developer certificate on the iPhone: **Settings → General → VPN & Device
   Management → [your Apple ID] → Trust**.

**7-day expiry note:** apps signed with a free Apple ID expire after **7 days** and
must be rebuilt/reinstalled from Xcode to keep running (this is an Apple-imposed limit
on free-tier signing, not something the project can configure around). If a
verification session is more than a week after the last Xcode run, rebuild and
reinstall from Xcode before continuing.

---

## 4. Running the full test suite

The full XCTest suite (all unit tests across Plans 01–08 — signaling envelope,
HTTP/3 framing, sensor packet encoder, transport manager, peer connection manager,
session state, heartbeat timer, QR token parser, WebSocket signaling, ICE config,
AnyCodable) runs on the **Simulator** and requires none of the device-trust setup
above:

```bash
cd mobile/ios-app
xcodebuild test -scheme immersiveRT -destination 'platform=iOS Simulator,name=iPhone 17'
```

This must be green before any on-device checkpoint is attempted (it is the automated
precondition validated by `06.2-09-PLAN.md` Task 1).

---

## Summary checklist

- [ ] mkcert root CA exported (`mkcert -CAROOT`) and transferred to the iPhone
- [ ] Configuration profile installed (Settings → General → VPN & Device Management)
- [ ] Full trust enabled (Settings → General → About → Certificate Trust Settings)
- [ ] Dev server running and reachable from the iPhone's LAN (not `localhost`)
- [ ] App deployed to the iPhone via Xcode-tethered debug build (aware of 7-day expiry)
- [ ] Full XCTest suite green on the Simulator before on-device sign-off

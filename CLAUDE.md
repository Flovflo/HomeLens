# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

HomeLens is a narrow, reliability-first macOS tool that bridges **one** Reolink camera into Apple Home / HomeKit Secure Video (HSV). It is deliberately *not* a Scrypted clone. Apple's public Swift APIs (`HomeKit.framework`) can only control existing accessories, not publish one — so the actual HomeKit accessory, pairing, RTP/RTSP streaming, and HSV recording delegate all live in a small Node helper (`Helpers/HomeKitBridge`, HAP-NodeJS). Swift stays the supervisor: config, secrets, ONVIF/RTSP health checks, ONVIF event monitoring, and process supervision. See [docs/FEASIBILITY.md](docs/FEASIBILITY.md) for why the split exists.

## Build, run, test

Swift Package Manager (swift-tools 6.0, macOS 14+). There is no XCTest suite — "tests" are live network checks against a real camera via the CLI.

```bash
swift build                      # debug build of all three targets
./script/build_and_run.sh        # build + package dist/HomeLens.app + launch the GUI
./script/build_and_run.sh logs   # same, then stream os_log for the process
./script/package_app.sh          # release .app bundle (GUI + CLI + helper bundled in Resources)
./script/install_launch_agent.sh # install/start the packaged app as a launchd KeepAlive agent
./script/reset_homekit_pairing.sh# wipe hap-storage + config so the accessory can be re-paired in Apple Home
```

### CLI is the primary interface (`homelensctl`)

The GUI is a thin convenience wrapper; the CLI is the reliability boundary. Commands (see [docs/CLI.md](docs/CLI.md)):

```bash
swift run homelensctl init --host 192.168.0.6 --username admin --profile sub  # writes config; password -> Keychain
swift run homelensctl test rtsp | onvif | all | events-once | hsv-prebuffer   # live checks against the camera
swift run homelensctl run                                                     # long-running ONVIF event monitor
swift run homelensctl homekit-config                                          # generate homekit-bridge.json
swift run homelensctl homekit-run                                             # supervise Node helper + forward ONVIF events
```

Pass the camera password via `HOMELENS_PASSWORD` (not `--password`) for unattended/daemon use so macOS never blocks on an invisible Keychain prompt. `HOMELENS_LOG_LEVEL=debug` enables verbose SOAP/event diagnostics. The HAP helper config intentionally never contains the camera password — Swift passes the RTSP URL to the helper through the process environment.

The Node helper needs its deps installed once: `cd Helpers/HomeKitBridge && npm install`. Syntax check: `npm run check`.

## Architecture

Three SwiftPM targets plus the Node helper:

- **`HomeLensCore`** (library, [Sources/HomeLensCore/](Sources/HomeLensCore/)) — the shared engine: `CameraConfig`, `ConfigStore` (JSON in Application Support + password in Keychain), `RTSPStreamManager` (low-cost RTSP DESCRIBE reachability test), `ONVIFClient` (SOAP capabilities + pull-point events with WS-Addressing and exponential backoff), `HomeKitBridgeConfig` (the JSON shape handed to the Node helper), `Log`.
- **`HomeLensCLI`** ([Sources/HomeLensCLI/main.swift](Sources/HomeLensCLI/main.swift)) — `homelensctl`. **This is the only target that imports `HomeLensCore`.** Command dispatch, helper config generation, and the supervised `homekit-run` loop live here.
- **`HomeLens`** ([Sources/HomeLens/](Sources/HomeLens/)) — the SwiftUI GUI. ⚠️ Despite `Package.swift` declaring a dependency on `HomeLensCore`, the GUI does **not** import it — it carries its own parallel reimplementations (`Models/CameraConfig`, `Services/RTSPStreamManager`, `Services/AppConfigStore`, `Services/ONVIFEventManager`, `Services/HomeKitBridge`, `Services/AppLogger`). When changing core behavior, expect to touch *both* the Core copy and the GUI's `Services/` copy; they have drifted and are not auto-shared. The docs' claim that Core is "used by the CLI and the GUI" describes the intended end state, not the current one.
- **`Helpers/HomeKitBridge`** — Node/HAP-NodeJS helper publishing one IP camera accessory + motion sensor, an ffmpeg-backed RTSP→HomeKit live path, and a `CameraRecordingDelegate` backed by a rolling fragmented-MP4 prebuffer for HSV. `node_modules/` is committed but gitignored patterns apply elsewhere.

### Control flow (the bridge)

ONVIF motion/person events → Swift parses them → forwarded as **JSON lines over the helper's stdin** (`{"type":"motion","active":true}`) → helper maps to HomeKit `MotionDetected` and serves prebuffered fMP4 fragments on an HSV recording request. In `homekit-run`, the helper owns the ONVIF subscription; Swift supervises and restarts the Node process if it exits. GUI wiring is in [Services/BridgeController.swift](Sources/HomeLens/Services/BridgeController.swift) and [ViewModels/AppModel.swift](Sources/HomeLens/ViewModels/AppModel.swift).

### Runtime state locations

- Config + secrets: `~/Library/Application Support/HomeLens/` (`homekit-bridge.json`, `homekit-username.txt`, `hap-storage/`); camera password in macOS Keychain.
- HAP defaults: pairing PIN `031-45-154`, port `51826`, bundle id `com.homelens.app`.

## Current status / next step

Live camera publishing, motion characteristic updates, supervised restart, advertised HSV recording services, and the RTSP→fMP4 prebuffer all work and are validated locally (`test hsv-prebuffer`). The remaining unproven step: pair in Apple Home, enable **Stream & Allow Recording**, and confirm an Apple Home hub actually requests and accepts recording fragments after a motion trigger.

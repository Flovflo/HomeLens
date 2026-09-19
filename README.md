<div align="center">

# 🎥 HomeLens

### Turn any Reolink camera into a first-class Apple Home camera — **live video + audio, HomeKit Secure Video, up to 4K** — accelerated by the Apple Silicon media engine.

[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6.0-orange?logo=swift)](https://swift.org)
[![HomeKit](https://img.shields.io/badge/HomeKit-Secure%20Video-blue?logo=apple)](https://developer.apple.com/apple-home/)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-VideoToolbox-success)](https://developer.apple.com/videotoolbox/)

</div>

---

## Why HomeLens?

Apple's `HomeKit.framework` can **control** accessories — but it **cannot publish a camera**. So an ONVIF/RTSP camera like a Reolink simply can't appear in the Home app on its own. The usual answer (Scrypted, full Homebridge stacks) is heavy and general-purpose.

**HomeLens is the opposite: small, native, and laser-focused on one job — getting *your* camera into Apple Home, beautifully.** It pairs a tiny, reliable HomeKit bridge with a polished native macOS app for preview, status, and one-glance diagnostics.

```
   Reolink camera            Mac (HomeLens)                         Apple Home
   ┌────────────┐  RTSP/ONVIF ┌──────────────────────────┐   HAP   ┌──────────┐
   │  4K H.264   │────────────▶│  HomeKit bridge (HAP)     │────────▶│ iPhone   │
   │  + audio    │             │   • live video + audio   │  SRTP   │ HomePod  │
   │  sub stream │             │   • HomeKit Secure Video │◀───────▶│ Apple TV │
   └────────────┘             │   • ONVIF motion         │         └──────────┘
                              │   • Apple media engine   │
                              │                          │  HLS (local)
                              │  macOS app (SwiftUI)     │◀── live preview + diagnostics
                              └──────────────────────────┘
```

---

## ✨ Features

| | |
|---|---|
| 📺 **Live in Apple Home** | Real-time video **with audio** (Opus), streamed to iPhone / iPad / Apple TV. |
| 🔴 **HomeKit Secure Video** | HSV recording up to **native 4K on iOS/tvOS 27**, with camera audio when enabled in Home. |
| ⚡ **Apple-silicon optimized** | **VideoToolbox** for live/compatible encoding; **no video encoding** for original-quality recordings. |
| 🎞️ **Zero-loss 4K passthrough** | Original-quality recordings preserve **H.264 or H.265** video untouched. Live view uses hardware H.264 encoding. |
| 🖥️ **Native macOS app** | SwiftUI preview with **Fast / Quality** sources, mute toggle, live status pills. |
| 🩺 **End-to-end diagnostics** | One glance from **camera → relay → network/Apple → Home** — instantly see *where* it breaks. |
| 🔌 **Multi-NIC aware** | Pick the network interface; smart routing fixes the classic "stream negotiates but stays black" bug. |
| 🔒 **Secure by default** | Camera password in the **macOS Keychain**; credentials redacted from all logs. |
| 🏃 **Always on** | Runs 24/7 as a `launchd` agent with auto-restart — independent of the app window. |

---

## 🏗️ Architecture in 30 seconds

HomeLens is **two cleanly separated parts**:

1. **The bridge** (`homelensctl homekit-run`, managed by `launchd`) — the *reliability boundary*. It owns HomeKit pairing, live streaming, HSV recording, and ONVIF motion. It runs whether or not the app is open.
2. **The macOS app** (SwiftUI) — a *monitor*: live preview, status, and diagnostics. It never fights the bridge.

The bridge embeds a minimal [HAP-NodeJS](https://github.com/homebridge/HAP-NodeJS) helper (Apple has no public camera-accessory API), while everything else — config, secrets, health checks, supervision, diagnostics — is native Swift.

> 📖 Full write-up: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)

---

## 🚀 Quick start

### Option A — Download the app (nothing else to install)
Grab **`HomeLens.dmg`**, drag **HomeLens** to **Applications**, and open it.
**ffmpeg, ffprobe and Node.js are bundled inside the app** — there is nothing
else to install, no Homebrew required. On first launch, right‑click the app →
**Open** (it's signed ad‑hoc, so Gatekeeper asks once).

> Build the DMG yourself with `./script/package_app.sh && ./script/make_dmg.sh`
> → `dist/HomeLens.dmg` (Apple Silicon).

### Option B — Build from source

#### Requirements
- **macOS 14+** (Apple Silicon recommended for the hardware media engine)
- **Homebrew**, **Node.js**, **ffmpeg**: `brew install node ffmpeg`
- A **Reolink** (or ONVIF/RTSP) camera on your LAN
- An **Apple Home hub** (HomePod / Apple TV) for HomeKit Secure Video

#### Install
```bash
git clone https://github.com/<you>/HomeLens.git
cd HomeLens

# 1. Helper dependencies
( cd Helpers/HomeKitBridge && npm install )

# 2. Configure your camera (password is stored in the Keychain)
swift run homelensctl init --host 192.168.0.6 --username admin
#   …or keep it out of shell history:
#   HOMELENS_PASSWORD='secret' swift run homelensctl init --host 192.168.0.6 --username admin

# 3. Prove the camera is reachable
swift run homelensctl doctor

# 4. Build the app + start the 24/7 bridge
./script/package_app.sh
./script/install_bridge_agent.sh
```

### Pair in Apple Home
Open the **Home** app → **Add Accessory** → *More options* → **HomeLens / Front Door** → enter the PIN:

```
031-45-154
```

The camera appears in Home with live view, audio, and (with a hub) Secure Video. For original 4K recordings, update all Home hubs to version 27, then select **Enregistrement Maison → Originale / 4K → Appliquer au pont** in HomeLens settings. Existing configurations retain compatibility mode until you change this setting.

See [the video pipeline audit and validation](docs/VIDEO_PIPELINE.md) for the exact quality policy and test results.

---

## 🩺 Built-in diagnostics

Stop guessing. Run the full-chain check from the terminal or the app's **Diagnostic** tab:

```bash
swift run homelensctl doctor
```

```
▸ Caméra        ✓ Ping  ✓ RTSP 4K+audio  ✓ ONVIF  ✓ Image
▸ Relai         ✓ ffmpeg  ✓ node  ✓ Pont actif  ✓ Port 51826
▸ Réseau/Apple  ✓ Internet  ✓ Bonjour « Front Door »  ✓ iCloud/HSV
▸ Apple Home    ✓ 3 appareils appairés  ✓ HSV activé  ✓ Audio live
```

Each link is green / orange / red with timings, so you see exactly where a problem is — camera, the local relay, the network, or Apple Home.

---

## 🛠️ CLI — `homelensctl`

| Command | What it does |
|---|---|
| `init …` | Save camera config; store the password in Keychain |
| `doctor` | Full end-to-end health check (color output) |
| `test rtsp \| onvif \| all` | Probe camera reachability |
| `test hsv-prebuffer` | Validate the HomeKit Secure Video fragment pipeline |
| `homekit-config` | Generate the HAP helper config |
| `homekit-run` | Run + supervise the HomeKit bridge (this is what `launchd` runs) |
| `run` | Long-running ONVIF motion monitor |

Pass `HOMELENS_PASSWORD` via the environment for unattended runs; set `HOMELENS_LOG_LEVEL=debug` for verbose diagnostics.

---

## ❓ FAQ

**Can it stream 4K live to my iPhone?**
Apple supports 4K on compatible cameras with iOS 27. HomeLens currently uses the established H.264 live transport at negotiated HD resolutions, and preserves native 4K for recordings with the Original / 4K setting. All Home hubs must also run version 27.

**My camera is H.265 — is that supported?**
Yes. Original-quality recordings preserve either H.264 or HEVC/H.265 on iOS/tvOS 27. Live view and compatibility-mode recordings use VideoToolbox to convert HEVC to H.264 when needed. The Mac preview plays either format. Restart the bridge after changing the camera codec.

**Does it use a lot of CPU?**
Native recording copies compressed video without decoding or encoding it. Live view and compatibility mode use the Apple Silicon media engine; actual CPU usage depends on the camera and concurrent streams.

**Multiple cameras?**
HomeLens is intentionally focused on **one camera, done right**.

---

## 📁 Project layout

```
Sources/
  HomeLensCore/      Shared engine: config, Keychain, RTSP/ONVIF, diagnostics
  HomeLensCLI/       homelensctl — the reliability-first CLI
  HomeLens/          SwiftUI macOS app (preview · status · diagnostics)
Helpers/HomeKitBridge/   Tiny HAP-NodeJS helper (publishes the camera to HomeKit)
script/              package_app.sh · install_bridge_agent.sh · …
docs/                ARCHITECTURE.md · CLI.md · FEASIBILITY.md
```

---

## 🧰 Built with

**Swift 6 · SwiftUI · Swift Package Manager · AVFoundation / VideoToolbox · Network.framework · HAP-NodeJS · ffmpeg · ONVIF · RTSP**

---

> HomeLens is an independent project and is **not affiliated with, endorsed by, or sponsored by Apple Inc. or Reolink.** "Apple", "HomeKit", "Apple Home", and "HomeKit Secure Video" are trademarks of Apple Inc.

<div align="center">

**Made for people who just want their camera to *work* in Apple Home.** ❤️

</div>

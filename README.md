<div align="center">

# 🎥 HomeLens

### Turn any Reolink camera into a first-class Apple Home camera — **live video + audio, HomeKit Secure Video, up to 4K** — accelerated by the Apple Silicon media engine.

[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6.0-orange?logo=swift)](https://swift.org)
[![HomeKit](https://img.shields.io/badge/HomeKit-Secure%20Video-blue?logo=apple)](https://developer.apple.com/apple-home/)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-VideoToolbox-success)](https://developer.apple.com/videotoolbox/)
[![License](https://img.shields.io/badge/license-MIT-green)](#-license)

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
| 🔴 **HomeKit Secure Video** | True HSV recording with **real camera audio**, triggered by ONVIF motion, up to **4K**. |
| ⚡ **Apple-silicon optimized** | End-to-end **VideoToolbox** pipeline — hardware *decode → scale → encode* — at **~10% CPU**. |
| 🎞️ **Zero-loss 4K passthrough** | H.264 cameras are **copied untouched** (no re-encode); H.265 cameras are **auto hardware-transcoded** to H.264 for HomeKit. |
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

### Requirements
- **macOS 14+** (Apple Silicon recommended for the hardware media engine)
- **Homebrew**, **Node.js**, **ffmpeg**: `brew install node ffmpeg`
- A **Reolink** (or ONVIF/RTSP) camera on your LAN
- An **Apple Home hub** (HomePod / Apple TV) for HomeKit Secure Video

### Install
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

That's it. The camera appears in Home with live view, audio, and (with a hub) Secure Video.

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
HomeKit *caps live view* well below 4K (typically 720p–1080p — Apple's call, not ours). HomeLens advertises up to 4K and serves a **sharp, hardware-scaled** image at whatever Home requests. **True 4K is for HomeKit Secure Video recordings.**

**My camera is H.265 — is that supported?**
Yes — HomeLens auto-detects it and **hardware-transcodes H.265 → H.264** (HomeKit only accepts H.264). For best quality and lowest CPU, set the camera's main stream to **H.264** (it's then copied with zero re-encode); to save bandwidth, lower the H.264 bitrate.

**Does it use a lot of CPU?**
No. The live pipeline runs on the Apple Silicon media engine (~10% CPU for 4K→720p), and native-resolution HSV recording is a zero-CPU stream copy.

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

## 📜 License

MIT — see [`LICENSE`](LICENSE).

> HomeLens is an independent project and is **not affiliated with, endorsed by, or sponsored by Apple Inc. or Reolink.** "Apple", "HomeKit", "Apple Home", and "HomeKit Secure Video" are trademarks of Apple Inc.

<div align="center">

**Made for people who just want their camera to *work* in Apple Home.** ❤️

</div>

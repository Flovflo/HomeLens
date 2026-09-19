---
title: HomeLens — Reolink camera in Apple Home, 4K HomeKit Secure Video on macOS
description: Free, open-source macOS app that bridges a Reolink camera into Apple Home with true 4K live view, audio and HomeKit Secure Video recordings. Nothing to install besides the DMG.
---

<img src="https://raw.githubusercontent.com/Flovflo/HomeLens/main/Assets/Generated/social-preview.png" alt="HomeLens: your Reolink camera in Apple Home, 4K" style="max-width:100%;border-radius:12px">

# HomeLens

**Your Reolink camera in Apple Home — true 4K live view and 4K HomeKit Secure Video recordings — from a tiny native macOS app.**

**100% open source (MIT) · built for Apple: Swift, SwiftUI, VideoToolbox, Apple Silicon · no cloud, no account, no telemetry**

[**⬇ Download HomeLens.dmg**](https://github.com/Flovflo/HomeLens/releases/latest) · [Source on GitHub](https://github.com/Flovflo/HomeLens) · macOS 14+ · Apple Silicon · signed & notarized · MIT

## Why

Apple Home cannot add an RTSP/ONVIF camera by itself, and the usual bridges (Scrypted, Homebridge) re-encode video, need Docker or a Node server, and turn a 4K camera into a 1080p one. HomeLens sends the camera's **original 3840 × 2160 stream** to Apple Home for the live view and for HomeKit Secure Video recordings, with no re-encoding, from a `launchd` service supervised by a native SwiftUI app.

## What you get

- **Live view with audio** on iPhone, iPad, Apple TV and Mac, in the camera's original 4K H.264 on your Wi-Fi.
- **HomeKit Secure Video** clips in original quality, H.264 or HEVC, on iOS/tvOS 27 hubs (person detection from Reolink's own API).
- **Smooth playback**: Reolink cameras stream in bursts with erratic timestamps; HomeLens re-times and paces the packets.
- **Nothing to install**: ffmpeg and Node.js are inside the app. Download, drag to Applications, follow the wizard, pair with the Home app.
- **Diagnostics** that show exactly where the chain breaks: camera → bridge → network → Apple Home.

## Open source, optimized for Apple

Everything is in the [GitHub repository](https://github.com/Flovflo/HomeLens) under the MIT license: the SwiftUI app, the `homelensctl` CLI, the HomeKit helper and the release pipeline. Video encoding, when needed, runs on the Apple Silicon media engine through VideoToolbox; original-quality 4K paths do no encoding at all. Your camera password lives in the macOS Keychain and nothing leaves your network except what Apple Home itself encrypts.

## Install

1. Download [HomeLens.dmg](https://github.com/Flovflo/HomeLens/releases/latest).
2. Drag HomeLens to Applications and open it (signed and notarized by Apple).
3. Enter your camera's address and password, then add the accessory in the Home app with the displayed PIN.

Questions and other camera models: [GitHub Discussions](https://github.com/Flovflo/HomeLens/discussions). Bugs: [Issues](https://github.com/Flovflo/HomeLens/issues).

*HomeLens is an independent project, not affiliated with Apple Inc. or Reolink. Apple, HomeKit and HomeKit Secure Video are trademarks of Apple Inc.*

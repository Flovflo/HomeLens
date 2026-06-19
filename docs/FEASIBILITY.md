# HomeLens feasibility report

## What is feasible in a native macOS app

- A small SwiftUI macOS app can store one Reolink camera config, keep the password in Keychain, test RTSP reachability, test ONVIF device capabilities, subscribe to ONVIF pull-point events, and map motion/person events into an internal bridge event.
- RTSP forwarding should avoid transcoding whenever the camera can provide HomeKit-compatible H.264/AAC profiles. Reolink main/sub streams are a good first target.
- Scrypted metadata can be discovered locally from `~/.scrypted/volume/scrypted.db`, but the database is LevelDB/binary and password import should be treated as best-effort and sensitive. The MVP imports visible metadata and leaves secrets to Keychain entry.

## What is not feasible with public Apple Swift APIs alone

- `HomeKit.framework` lets an app coordinate and control accessories that are already in Apple Home. It is not an accessory server framework.
- Publishing a camera accessory requires implementing HomeKit Accessory Protocol services and pairing behavior. Apple says commercial HomeKit accessory development uses the MFi program, HAP specification, ADK, and certification tooling.
- HomeKit Secure Video is not exposed as a simple public macOS API. HSV-capable bridges use HAP camera recording services and recording delegates. Scrypted accomplishes this in its HomeKit plugin layer, not via `HomeKit.framework`.

## Pragmatic path

The native macOS app should remain the product surface: config, tests, logs, process supervision, ONVIF event handling, and Scrypted import. For real Home app pairing and HSV, attach a tiny local HAP helper dedicated only to:

1. one camera accessory,
2. RTP/RTSP session negotiation,
3. HSV recording delegate,
4. motion/person characteristic updates.

That helper now exists at `Helpers/HomeKitBridge` for live camera publishing, motion characteristic updates, and a HAP-NodeJS `CameraRecordingDelegate` backed by a rolling fragmented-MP4 prebuffer from RTSP. The prebuffer has been validated locally against the Reolink stream with `homelensctl test hsv-prebuffer`. Final HSV confidence still requires pairing in Apple Home and confirming an Apple Home hub accepts recording fragments after a motion trigger.

## References

- Apple Home overview: https://developer.apple.com/apple-home/
- Apple HomeKit framework docs: https://developer.apple.com/documentation/homekit/
- Apple iCloud HomeKit Secure Video setup: https://support.apple.com/guide/icloud/set-up-homekit-secure-video-mm7c90d21583/icloud
- Scrypted HomeKit Secure Video setup notes: https://github.com/koush/scrypted/wiki/HomeKit-Secure-Video-Setup
- Scrypted HomeKit plugin README: https://github.com/koush/scrypted/blob/main/plugins/homekit/README.md

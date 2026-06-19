# HomeLens CLI

The CLI is the reliability-first interface. The GUI should remain a thin wrapper over this same core.

## Setup

```bash
swift run homelensctl init --host 192.168.0.6 --username admin --password 'camera-password' --profile sub
```

The password is stored in macOS Keychain. To avoid putting the password in shell history:

```bash
HOMELENS_PASSWORD='camera-password' swift run homelensctl init --host 192.168.0.6 --username admin
```

## Tests

```bash
swift run homelensctl test rtsp
swift run homelensctl test onvif
swift run homelensctl test all
swift run homelensctl test events-once
swift run homelensctl test hsv-prebuffer
```

## Long-running monitor

```bash
swift run homelensctl run
```

For unattended use, prefer passing the password via the process environment so macOS cannot block the daemon on an invisible Keychain prompt:

```bash
HOMELENS_PASSWORD='camera-password' .build/debug/homelensctl run
```

`run` monitors ONVIF events with WS-Addressing enabled and reconnects with exponential backoff. Set `HOMELENS_LOG_LEVEL=debug` for verbose SOAP/event diagnostics. The next production layer is a tiny dedicated HAP helper that receives these events and exposes the camera/motion services to HomeKit.

## HomeKit helper

Install the helper dependencies once:

```bash
cd Helpers/HomeKitBridge
npm install
cd ../..
```

Generate the HAP helper config:

```bash
.build/debug/homelensctl homekit-config
```

Run the HomeKit bridge plus ONVIF event forwarder:

```bash
HOMELENS_PASSWORD='camera-password' .build/debug/homelensctl homekit-run
```

The helper publishes one IP camera accessory:

- pairing PIN: `031-45-154`
- default HAP username: `A2:44:5A:11:00:06`
- default port: `51826`

The config file intentionally does not contain the camera password. Swift passes the RTSP URL to the helper through the process environment.

Current HomeKit scope:

- live camera accessory publishing through HAP-NodeJS
- ffmpeg-backed RTSP-to-HomeKit live stream path
- HomeKit `MotionDetected` updates from ONVIF motion/person events
- supervised helper restart if the Node process exits unexpectedly
- HomeKit Secure Video recording services are now advertised through HAP-NodeJS
- a rolling fMP4 prebuffer can generate H.264/AAC init + fragments from the Reolink RTSP stream

Remaining HSV scope:

- pair in Apple Home and verify that `Stream & Allow Recording` appears
- validate that an Apple Home hub requests and accepts recording fragments on motion

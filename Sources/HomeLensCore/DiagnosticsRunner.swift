import Foundation

/// One step in the end-to-end health chain. `stage` groups checks; `status`
/// drives the colour in the UI / prefix in the CLI.
public struct DiagnosticResult: Identifiable, Sendable, Codable {
    public enum Status: String, Sendable, Codable {
        case ok       // green — works
        case warn     // orange — degraded / optional
        case fail     // red — broken, blocks the chain
        case info     // neutral — informational
    }

    public enum Stage: String, Sendable, Codable, CaseIterable {
        case camera = "Caméra"
        case relay = "Relai HomeLens"
        case network = "Réseau & Apple"
        case home = "Apple Home"
    }

    public var id: String
    public var stage: Stage
    public var title: String
    public var status: Status
    public var detail: String
    public var durationMs: Int

    public init(id: String, stage: Stage, title: String, status: Status, detail: String, durationMs: Int) {
        self.id = id
        self.stage = stage
        self.title = title
        self.status = status
        self.detail = detail
        self.durationMs = durationMs
    }
}

/// Runs the whole pipeline of checks — camera link, the local HomeLens relay,
/// network/Apple reachability, and Apple Home pairing — emitting each result as
/// soon as it completes so a UI can light up progressively. Shared by the CLI
/// (`homelensctl doctor`) and the GUI diagnostics panel.
public final class DiagnosticsRunner: @unchecked Sendable {
    public init() {}

    public func run(
        camera: CameraConfig,
        password: String?,
        supportPath: String,
        ffmpegPath: String = BundledBinaries.ffmpeg,
        helperDir: String? = nil,
        accessoryPort: Int = 51826,
        onResult: @escaping @Sendable (DiagnosticResult) -> Void
    ) async {
        // ── Caméra ──────────────────────────────────────────────────────────
        onResult(await pingCheck(host: camera.host))

        let mainProbe = await probeStream(url: camera.rtspURL(profile: .main, password: password)?.absoluteString, ffmpegPath: ffmpegPath)
        onResult(rtspResult(probe: mainProbe, title: "RTSP principal", stage: .camera, id: "rtsp-main"))
        onResult(audioResult(probe: mainProbe))

        let subProbe = await probeStream(url: camera.rtspURL(profile: .sub, password: password)?.absoluteString, ffmpegPath: ffmpegPath)
        onResult(rtspResult(probe: subProbe, title: "RTSP secondaire", stage: .camera, id: "rtsp-sub"))

        onResult(await onvifCheck(camera: camera, password: password))
        onResult(await detectionCheck(camera: camera, password: password))
        onResult(await snapshotCheck(camera: camera, password: password, ffmpegPath: ffmpegPath))

        // ── Relai HomeLens ──────────────────────────────────────────────────
        onResult(await binaryCheck(id: "ffmpeg", title: "ffmpeg", path: ffmpegPath, args: ["-version"], firstLineOnly: true))
        if let node = BundledBinaries.node {
            onResult(await binaryCheck(id: "node", title: "Node.js", path: node, args: ["--version"], firstLineOnly: true))
        } else {
            onResult(await binaryCheck(id: "node", title: "Node.js", path: "/usr/bin/env", args: ["node", "--version"], firstLineOnly: true))
        }
        onResult(depsCheck(helperDir: helperDir))
        onResult(await helperProcessCheck())
        onResult(await portCheck(port: accessoryPort))

        // ── Réseau & Apple ──────────────────────────────────────────────────
        onResult(await internetCheck())
        onResult(await bonjourCheck(accessoryName: camera.name))
        onResult(await appleCloudCheck())

        // ── Apple Home ──────────────────────────────────────────────────────
        onResult(pairingCheck(supportPath: supportPath))
        let bridge = bridgeConfig(supportPath: supportPath)
        onResult(DiagnosticResult(id: "hsv", stage: .home, title: "HomeKit Secure Video",
                                  status: bridge.hsv ? .ok : .info,
                                  detail: bridge.hsv ? "Enregistrement activé" : "Enregistrement désactivé",
                                  durationMs: 0))
        onResult(DiagnosticResult(id: "audio-adv", stage: .home, title: "Audio live annoncé",
                                  status: bridge.audio ? .ok : .info,
                                  detail: bridge.audio ? "Le micro est publié à HomeKit" : "Audio live désactivé",
                                  durationMs: 0))
    }

    // MARK: - Caméra

    private func pingCheck(host: String) async -> DiagnosticResult {
        let start = Date()
        let result = await runProcess("/sbin/ping", ["-c", "1", "-t", "2", host], timeout: 4)
        let ms = elapsed(start)
        if result.code == 0 {
            let rtt = firstMatch(in: result.out, pattern: #"time=([0-9.]+) ms"#)
            return DiagnosticResult(id: "ping", stage: .camera, title: "Ping caméra", status: .ok,
                                    detail: rtt.map { "Répond en \($0) ms (\(host))" } ?? "Joignable (\(host))", durationMs: ms)
        }
        return DiagnosticResult(id: "ping", stage: .camera, title: "Ping caméra", status: .fail,
                                detail: "\(host) ne répond pas — vérifie le réseau / l'IP.", durationMs: ms)
    }

    private struct StreamProbe {
        var ok: Bool
        var video: String?
        var audio: String?
        var error: String?
        var durationMs: Int
    }

    private func probeStream(url: String?, ffmpegPath: String) async -> StreamProbe {
        let start = Date()
        guard let url else {
            return StreamProbe(ok: false, video: nil, audio: nil, error: "URL invalide (mot de passe manquant ?)", durationMs: 0)
        }
        let ffprobe = ffmpegPath.replacingOccurrences(of: "ffmpeg", with: "ffprobe")
        let args = [
            "-v", "error",
            "-rtsp_transport", "tcp",
            "-timeout", "6000000",
            // Larger buffers make 4K main-stream probing reliable under load.
            "-analyzeduration", "5000000",
            "-probesize", "5000000",
            "-i", url,
            "-show_entries", "stream=codec_type,codec_name,width,height,sample_rate,channels",
            "-of", "json",
        ]
        // 4K RTSP can deliver a corrupt first GOP under concurrent load; retry once
        // so a transient blip never reports a scary failure.
        var result = await runProcess(ffprobe, args, timeout: 12)
        if result.code != 0 {
            result = await runProcess(ffprobe, args, timeout: 12)
        }
        let ms = elapsed(start)
        guard result.code == 0,
              let data = result.out.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(FFProbeOutput.self, from: data) else {
            let err = result.err.split(separator: "\n").last.map(String.init) ?? "flux injoignable"
            return StreamProbe(ok: false, video: nil, audio: nil, error: sanitizeError(err), durationMs: ms)
        }
        var video: String?
        var audio: String?
        for stream in parsed.streams {
            if stream.codec_type == "video" {
                let codec = (stream.codec_name ?? "?").uppercased()
                video = "\(codec) \(stream.width ?? 0)×\(stream.height ?? 0)"
            } else if stream.codec_type == "audio" {
                let codec = (stream.codec_name ?? "?").uppercased()
                let rate = stream.sample_rate.map { "\((Int($0) ?? 0) / 1000)kHz" } ?? ""
                audio = "\(codec) \(rate) \(stream.channels ?? 0)ch"
            }
        }
        return StreamProbe(ok: video != nil, video: video, audio: audio, error: nil, durationMs: ms)
    }

    private func rtspResult(probe: StreamProbe, title: String, stage: DiagnosticResult.Stage, id: String) -> DiagnosticResult {
        if probe.ok {
            return DiagnosticResult(id: id, stage: stage, title: title, status: .ok,
                                    detail: "Vidéo \(probe.video ?? "?")" + (probe.audio.map { " · audio \($0)" } ?? ""),
                                    durationMs: probe.durationMs)
        }
        return DiagnosticResult(id: id, stage: stage, title: title, status: .fail,
                                detail: probe.error ?? "Flux indisponible", durationMs: probe.durationMs)
    }

    private func audioResult(probe: StreamProbe) -> DiagnosticResult {
        if let audio = probe.audio {
            return DiagnosticResult(id: "cam-audio", stage: .camera, title: "Piste audio caméra", status: .ok,
                                    detail: "\(audio) — son disponible pour HomeKit", durationMs: 0)
        }
        if probe.ok {
            return DiagnosticResult(id: "cam-audio", stage: .camera, title: "Piste audio caméra", status: .warn,
                                    detail: "Aucune piste audio — active l'audio dans l'app Reolink.", durationMs: 0)
        }
        return DiagnosticResult(id: "cam-audio", stage: .camera, title: "Piste audio caméra", status: .info,
                                detail: "Non vérifié (flux principal indisponible).", durationMs: 0)
    }

    private func detectionCheck(camera: CameraConfig, password: String?) async -> DiagnosticResult {
        let start = Date()
        let probe = await ONVIFClient().detectionStatus(camera: camera, password: password)
        let ms = elapsed(start)
        // This is the trigger for HomeKit Secure Video: if no detection source
        // works, motion never fires and HSV never records — exactly the failure
        // that was previously invisible.
        return DiagnosticResult(
            id: "detection",
            stage: .camera,
            title: "Détection (déclencheur HSV)",
            status: probe.available ? .ok : .fail,
            detail: probe.available ? "\(probe.source) — \(probe.detail)" : "Aucun déclencheur — HSV n'enregistrera pas. \(probe.detail)",
            durationMs: ms
        )
    }

    private func onvifCheck(camera: CameraConfig, password: String?) async -> DiagnosticResult {
        let start = Date()
        let result = await ONVIFClient().test(camera: camera, password: password)
        return DiagnosticResult(id: "onvif", stage: .camera, title: "ONVIF (mouvement)",
                                status: result.ok ? .ok : .warn,
                                detail: result.detail, durationMs: elapsed(start))
    }

    private func snapshotCheck(camera: CameraConfig, password: String?, ffmpegPath: String) async -> DiagnosticResult {
        let start = Date()
        guard let url = camera.rtspURL(profile: .sub, password: password)?.absoluteString else {
            return DiagnosticResult(id: "snapshot", stage: .camera, title: "Image (snapshot)", status: .info,
                                    detail: "Non testé (mot de passe manquant).", durationMs: 0)
        }
        // Grab one frame over RTSP (what the camera tile uses). The Reolink HTTP
        // Snap API needs a token login and isn't reliable, so we don't use it.
        let args = ["-hide_banner", "-loglevel", "error", "-rtsp_transport", "tcp", "-timeout", "6000000",
                    "-i", url, "-frames:v", "1", "-f", "null", "-"]
        let result = await runProcess(ffmpegPath, args, timeout: 10)
        let ms = elapsed(start)
        if result.code == 0 {
            return DiagnosticResult(id: "snapshot", stage: .camera, title: "Image (snapshot)", status: .ok,
                                    detail: "Image disponible (via RTSP)", durationMs: ms)
        }
        return DiagnosticResult(id: "snapshot", stage: .camera, title: "Image (snapshot)", status: .warn,
                                detail: "Impossible de capturer une image.", durationMs: ms)
    }

    // MARK: - Relai HomeLens

    private func binaryCheck(id: String, title: String, path: String, args: [String], firstLineOnly: Bool) async -> DiagnosticResult {
        let start = Date()
        let result = await runProcess(path, args, timeout: 5)
        let ms = elapsed(start)
        if result.code == 0 {
            let line = result.out.split(separator: "\n").first.map(String.init) ?? "présent"
            return DiagnosticResult(id: id, stage: .relay, title: title, status: .ok, detail: line, durationMs: ms)
        }
        return DiagnosticResult(id: id, stage: .relay, title: title, status: .fail,
                                detail: "Introuvable — installe-le (Homebrew).", durationMs: ms)
    }

    private func depsCheck(helperDir: String?) -> DiagnosticResult {
        guard let helperDir else {
            return DiagnosticResult(id: "deps", stage: .relay, title: "Dépendances helper", status: .info,
                                    detail: "Emplacement du helper inconnu.", durationMs: 0)
        }
        let nodeModules = URL(fileURLWithPath: helperDir).appendingPathComponent("node_modules/@homebridge/hap-nodejs")
        if FileManager.default.fileExists(atPath: nodeModules.path) {
            return DiagnosticResult(id: "deps", stage: .relay, title: "Dépendances helper", status: .ok,
                                    detail: "hap-nodejs installé", durationMs: 0)
        }
        return DiagnosticResult(id: "deps", stage: .relay, title: "Dépendances helper", status: .fail,
                                detail: "Manquantes — lance `npm install` dans le helper.", durationMs: 0)
    }

    private func helperProcessCheck() async -> DiagnosticResult {
        let start = Date()
        let result = await runProcess("/usr/bin/pgrep", ["-f", "HomeKitBridge/src/index.mjs"], timeout: 4)
        let ms = elapsed(start)
        let pid = result.out.split(separator: "\n").first.map(String.init)
        if result.code == 0, let pid {
            return DiagnosticResult(id: "helper", stage: .relay, title: "Pont HAP actif", status: .ok,
                                    detail: "Helper en cours (pid \(pid))", durationMs: ms)
        }
        return DiagnosticResult(id: "helper", stage: .relay, title: "Pont HAP actif", status: .warn,
                                detail: "Helper arrêté — démarre le bridge.", durationMs: ms)
    }

    private func portCheck(port: Int) async -> DiagnosticResult {
        let start = Date()
        let result = await runProcess("/usr/bin/nc", ["-G", "1", "-z", "127.0.0.1", String(port)], timeout: 4)
        let ms = elapsed(start)
        if result.code == 0 {
            return DiagnosticResult(id: "port", stage: .relay, title: "Port HAP \(port)", status: .ok,
                                    detail: "Le pont écoute sur le port \(port).", durationMs: ms)
        }
        return DiagnosticResult(id: "port", stage: .relay, title: "Port HAP \(port)", status: .warn,
                                detail: "Aucune écoute sur \(port) (pont arrêté ?).", durationMs: ms)
    }

    // MARK: - Réseau & Apple

    private func internetCheck() async -> DiagnosticResult {
        let start = Date()
        let result = await runProcess("/usr/bin/curl",
                                      ["-s", "-m", "4", "-o", "/dev/null", "-w", "%{http_code}", "https://captive.apple.com/hotspot-detect.html"],
                                      timeout: 6)
        let ms = elapsed(start)
        let code = Int(result.out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        if code == 200 {
            return DiagnosticResult(id: "internet", stage: .network, title: "Accès Internet", status: .ok,
                                    detail: "Connecté", durationMs: ms)
        }
        return DiagnosticResult(id: "internet", stage: .network, title: "Accès Internet", status: .fail,
                                detail: "Pas d'accès Internet (HTTP \(code)).", durationMs: ms)
    }

    private func bonjourCheck(accessoryName: String) async -> DiagnosticResult {
        let start = Date()
        // dns-sd -B runs until killed; cap it and inspect what was advertised.
        let result = await runProcess("/usr/bin/dns-sd", ["-B", "_hap._tcp"], timeout: 3)
        let ms = elapsed(start)
        if result.out.contains(accessoryName) {
            return DiagnosticResult(id: "bonjour", stage: .network, title: "Diffusion Bonjour", status: .ok,
                                    detail: "« \(accessoryName) » est annoncé sur le réseau local.", durationMs: ms)
        }
        if result.out.contains("_hap._tcp") || result.out.contains("Add") {
            return DiagnosticResult(id: "bonjour", stage: .network, title: "Diffusion Bonjour", status: .warn,
                                    detail: "Des accessoires HomeKit sont vus, mais pas « \(accessoryName) ».", durationMs: ms)
        }
        return DiagnosticResult(id: "bonjour", stage: .network, title: "Diffusion Bonjour", status: .warn,
                                detail: "Aucun service _hap._tcp détecté (pont arrêté ?).", durationMs: ms)
    }

    private func appleCloudCheck() async -> DiagnosticResult {
        let start = Date()
        let result = await runProcess("/usr/bin/curl",
                                      ["-s", "-m", "5", "-o", "/dev/null", "-w", "%{http_code}", "https://www.icloud.com"],
                                      timeout: 7)
        let ms = elapsed(start)
        let code = Int(result.out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        if (200..<400).contains(code) {
            return DiagnosticResult(id: "icloud", stage: .network, title: "Serveurs Apple (iCloud/HSV)", status: .ok,
                                    detail: "Joignables — requis pour HomeKit Secure Video.", durationMs: ms)
        }
        return DiagnosticResult(id: "icloud", stage: .network, title: "Serveurs Apple (iCloud/HSV)", status: .warn,
                                detail: "iCloud injoignable (HTTP \(code)).", durationMs: ms)
    }

    // MARK: - Apple Home

    private struct AccessoryInfo: Decodable {
        let pairedClients: [String: String]?
        let pincode: String?
    }

    private func pairingCheck(supportPath: String) -> DiagnosticResult {
        let storage = URL(fileURLWithPath: supportPath).appendingPathComponent("hap-storage", isDirectory: true)
        var count = 0
        var pin: String?
        if let files = try? FileManager.default.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil) {
            for file in files where file.lastPathComponent.hasPrefix("AccessoryInfo.") && file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let info = try? JSONDecoder().decode(AccessoryInfo.self, from: data) else { continue }
                count = max(count, info.pairedClients?.count ?? 0)
                if pin == nil { pin = info.pincode }
            }
        }
        if count > 0 {
            return DiagnosticResult(id: "pairing", stage: .home, title: "Appairage Maison", status: .ok,
                                    detail: "\(count) appareil(s) Apple Home appairé(s).", durationMs: 0)
        }
        return DiagnosticResult(id: "pairing", stage: .home, title: "Appairage Maison", status: .warn,
                                detail: "Non appairé — ajoute l'accessoire avec le code \(pin ?? "031-45-154").", durationMs: 0)
    }

    private func bridgeConfig(supportPath: String) -> (hsv: Bool, audio: Bool) {
        struct Config: Decodable {
            struct Section: Decodable { let enabled: Bool? }
            let recording: Section?
            let audio: Section?
        }
        let path = URL(fileURLWithPath: supportPath).appendingPathComponent("homekit-bridge.json")
        guard let data = try? Data(contentsOf: path),
              let config = try? JSONDecoder().decode(Config.self, from: data) else {
            return (false, false)
        }
        return (config.recording?.enabled ?? false, config.audio?.enabled ?? false)
    }

    // MARK: - Helpers

    private struct FFProbeOutput: Decodable {
        struct Stream: Decodable {
            let codec_type: String?
            let codec_name: String?
            let width: Int?
            let height: Int?
            let sample_rate: String?
            let channels: Int?
        }
        let streams: [Stream]
    }

    private func elapsed(_ start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    /// Strip credentials from any rtsp URL ffmpeg echoes back in error text.
    private func sanitizeError(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"rtsp://[^:@/\s]+:[^@/\s]+@"#) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "rtsp://***@")
    }

    private func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private func runProcess(_ launchPath: String, _ args: [String], timeout: TimeInterval) async -> (code: Int32, out: String, err: String) {
        guard FileManager.default.isExecutableFile(atPath: launchPath) || launchPath.hasSuffix("/env") else {
            return (-1, "", "introuvable: \(launchPath)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = Pipe()

        do {
            try process.run()
        } catch {
            return (-1, "", error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if process.isRunning {
            process.terminate()
            try? await Task.sleep(nanoseconds: 250_000_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }

        let out = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        // Reap the process before reading terminationStatus. Reading it while the
        // task is still running (e.g. a long-running probe we just killed) raises
        // an ObjC NSException that cannot be caught in Swift and aborts the app.
        process.waitUntilExit()
        let code = process.isRunning ? -1 : process.terminationStatus
        return (code, out, err)
    }
}

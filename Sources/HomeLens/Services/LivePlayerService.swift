import AVFoundation
import Darwin
import Foundation

/// Drives a live, low-latency video+audio preview of an RTSP camera entirely
/// with native frameworks. AVPlayer cannot read RTSP, so ffmpeg remuxes the
/// stream (video + audio stream-copied, zero transcode) into HLS on disk, a
/// loopback `LocalHLSServer` serves it, and AVPlayer plays the playlist.
@MainActor
final class LivePlayerService: ObservableObject {
    enum LiveStatus: Equatable {
        case idle
        case starting
        case playing
        case failed(String)
    }

    @Published private(set) var player: AVPlayer?
    @Published private(set) var status: LiveStatus = .idle
    @Published var isMuted = false

    private var ffmpeg: Process?
    private var server: LocalHLSServer?
    private var sessionDir: URL?
    private var intentionalStop = false
    private var restartAttempt = 0
    private var generation = 0

    private let ffmpegPath = "/opt/homebrew/bin/ffmpeg"
    private var currentProfile: CameraPreviewProfile?

    init() {
        // One-time cleanup of dirs left by a previous crash. Never call this from
        // start(): it would delete a concurrent session's directory.
        sweepOrphanSessions()
    }

    func start(camera: CameraConfig, password: String?, profile: CameraPreviewProfile, force: Bool = false) async {
        // Skip redundant restarts (load() + view triggers can fire together).
        if !force, currentProfile == profile, status == .playing || status == .starting {
            return
        }
        stop()
        intentionalStop = false
        currentProfile = profile
        generation += 1
        let myGeneration = generation
        status = .starting

        guard let rtsp = camera.rtspURL(profile: profile.streamProfile, password: password)?.absoluteString else {
            status = .failed("URL RTSP invalide.")
            return
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("homelens-hls-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            status = .failed("Impossible de créer le dossier du flux.")
            return
        }
        sessionDir = dir

        let server = LocalHLSServer(rootDir: dir)
        do {
            try server.start()
        } catch {
            status = .failed(error.localizedDescription)
            cleanup(dir: dir)
            return
        }
        self.server = server

        let process = makeFFmpeg(rtsp: rtsp, dir: dir, profile: profile)
        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                self?.handleFFmpegExit(proc, generation: myGeneration, camera: camera, password: password, profile: profile)
            }
        }
        do {
            try process.run()
        } catch {
            status = .failed("ffmpeg n'a pas démarré: \(error.localizedDescription)")
            cleanup(dir: dir)
            return
        }
        ffmpeg = process

        // Wait for the playlist + at least one segment to appear.
        let playlist = dir.appendingPathComponent("index.m3u8")
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if myGeneration != generation { return } // superseded by a newer start()
            if isPlaylistReady(playlist) { break }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        guard myGeneration == generation else { return }
        guard isPlaylistReady(playlist) else {
            status = .failed("Flux indisponible (délai dépassé).")
            stop()
            return
        }

        let item = AVPlayerItem(url: URL(string: "http://127.0.0.1:\(server.port)/index.m3u8")!)
        item.preferredForwardBufferDuration = 1.0
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        player.isMuted = isMuted
        self.player = player
        player.play()
        restartAttempt = 0
        status = .playing
    }

    func setMuted(_ value: Bool) {
        isMuted = value
        player?.isMuted = value
    }

    func stop() {
        intentionalStop = true
        generation += 1
        player?.pause()
        player = nil
        if let process = ffmpeg, process.isRunning {
            let pid = process.processIdentifier
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            }
        }
        ffmpeg = nil
        server?.stop()
        server = nil
        if let dir = sessionDir {
            try? FileManager.default.removeItem(at: dir)
        }
        sessionDir = nil
        if status != .idle { status = .idle }
    }

    private func handleFFmpegExit(_ process: Process, generation: Int, camera: CameraConfig, password: String?, profile: CameraPreviewProfile) {
        guard generation == self.generation, !intentionalStop else { return }
        status = .failed("Flux interrompu, reconnexion…")
        restartAttempt += 1
        let delay = min(10.0, pow(2.0, Double(min(restartAttempt, 4))))
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard generation == self.generation, !self.intentionalStop else { return }
            await self.start(camera: camera, password: password, profile: profile)
        }
    }

    private func isPlaylistReady(_ playlist: URL) -> Bool {
        guard let text = try? String(contentsOf: playlist, encoding: .utf8) else { return false }
        // A usable playlist references at least one media segment.
        return text.contains(".ts") || text.contains(".m4s")
    }

    private func makeFFmpeg(rtsp: String, dir: URL, profile: CameraPreviewProfile) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        var args = [
            "-hide_banner", "-loglevel", "error",
            "-fflags", "nobuffer+genpts",
            "-flags", "low_delay",
            "-rtsp_transport", "tcp",
            "-timeout", "8000000",
            "-i", rtsp,
            "-map", "0:v:0",
            "-map", "0:a:0?",
        ]
        if profile == .main {
            // Main has ~2s keyframes, so copy can segment fine — keeps full quality.
            args += ["-c:v", "copy"]
        } else {
            // The sub stream has a very long GOP; copy would yield ~1 HLS segment
            // every several seconds (no fast preview). Transcode with a 1s keyframe
            // interval — trivial at 640×360 — for smooth, low-latency segments.
            args += [
                "-c:v", "libx264", "-preset", "veryfast", "-tune", "zerolatency",
                "-pix_fmt", "yuv420p",
                "-g", "10", "-keyint_min", "10",
                "-force_key_frames", "expr:gte(t,n_forced*1)",
            ]
        }
        args += [
            "-c:a", "copy",
            "-f", "hls",
            "-hls_time", profile == .main ? "2" : "1",
            "-hls_list_size", "6",
            "-hls_flags", "delete_segments+append_list+omit_endlist+independent_segments",
            "-hls_segment_type", "mpegts",
            "-hls_segment_filename", dir.appendingPathComponent("seg_%05d.ts").path,
            dir.appendingPathComponent("index.m3u8").path,
        ]
        process.arguments = args
        process.environment = ProcessInfo.processInfo.environment
        process.standardInput = Pipe()
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        return process
    }

    /// Remove leftover session directories from a previous crash.
    private func sweepOrphanSessions() {
        let tmp = FileManager.default.temporaryDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix("homelens-hls-") {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private func cleanup(dir: URL) {
        server?.stop()
        server = nil
        try? FileManager.default.removeItem(at: dir)
        sessionDir = nil
    }
}

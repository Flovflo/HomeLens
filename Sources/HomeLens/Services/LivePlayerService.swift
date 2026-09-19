import AVFoundation
import Darwin
import Foundation
import HomeLensCore

/// Drives a live, low-latency video+audio preview of an RTSP camera entirely
/// with native frameworks. AVPlayer cannot read RTSP, so ffmpeg remuxes the
/// original video into fragmented MP4 HLS and normalizes audio to AAC. A
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
    @Published private(set) var sourceDescription = ""

    private var ffmpeg: Process?
    private var server: LocalHLSServer?
    private var sessionDir: URL?
    private var intentionalStop = false
    private var restartAttempt = 0
    private var generation = 0

    private let ffmpegPath = BundledBinaries.ffmpeg
    private var currentProfile: CameraPreviewProfile?
    private var currentURL: String?
    private var playbackMonitor: Task<Void, Never>?

    func start(camera: CameraConfig, password: String?, profile: CameraPreviewProfile, force: Bool = false) async {
        let rtspURL = camera.rtspURL(profile: profile.streamProfile, password: password)?.absoluteString
        // Skip redundant restarts (load() + view triggers can fire together).
        if !force, currentURL == rtspURL, currentProfile == profile, status == .playing || status == .starting {
            return
        }
        stop()
        intentionalStop = false
        currentProfile = profile
        generation += 1
        let myGeneration = generation
        status = .starting

        guard let rtsp = rtspURL else {
            status = .failed("URL RTSP invalide.")
            return
        }

        currentURL = rtsp
        let source: VideoSource
        do {
            source = try await VideoSource.probe(rtspURL: rtsp)
        } catch {
            guard myGeneration == generation else { return }
            status = .failed(error.localizedDescription)
            return
        }
        guard myGeneration == generation, !Task.isCancelled else { return }
        sourceDescription = source.description

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

        let process = makeFFmpeg(rtsp: rtsp, dir: dir, profile: profile, source: source)
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
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if myGeneration != generation { return } // superseded by a newer start()
            if isPlaylistReady(playlist) { break }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        guard myGeneration == generation else { return }
        guard isPlaylistReady(playlist) else {
            stop()
            status = .failed("Flux indisponible (délai dépassé). Vérifiez l’intervalle des images-clés de la caméra.")
            return
        }

        let player = VideoPipeline.previewPlayer(
            url: URL(string: "http://127.0.0.1:\(server.port)/index.m3u8")!, isMuted: isMuted)
        let item = player.currentItem!
        self.player = player
        player.play()
        playbackMonitor = Task { @MainActor [weak self, weak player] in
            let deadline = Date().addingTimeInterval(15)
            while !Task.isCancelled {
                guard let self, let player, myGeneration == self.generation else { return }
                if item.status == .failed {
                    self.stop()
                    self.status = .failed("Le lecteur ne peut pas décoder le flux de la caméra.")
                    return
                }
                if player.timeControlStatus == .playing && player.rate > 0 && player.currentTime().seconds > 0 {
                    self.status = .playing
                    self.restartAttempt = 0
                } else if self.status == .starting && Date() > deadline {
                    self.stop()
                    self.status = .failed("Le lecteur n’a pas reçu d’image exploitable.")
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    func setMuted(_ value: Bool) {
        isMuted = value
        player?.isMuted = value
    }

    func stop() {
        intentionalStop = true
        generation += 1
        playbackMonitor?.cancel()
        playbackMonitor = nil
        player?.pause()
        player = nil
        if let process = ffmpeg, process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
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
        let dir = playlist.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("init.mp4").path) else { return false }
        return text.split(separator: "\n").contains { line in
            !line.hasPrefix("#") && line.hasSuffix(".m4s") &&
                FileManager.default.fileExists(atPath: dir.appendingPathComponent(String(line)).path)
        }
    }

    private func makeFFmpeg(rtsp: String, dir: URL, profile: CameraPreviewProfile, source: VideoSource) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = VideoPipeline.previewArguments(rtspURL: rtsp, directory: dir, source: source, lowBandwidth: profile == .sub)
        // No unread pipes: ffmpeg must never block because stderr filled up.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    private func cleanup(dir: URL) {
        server?.stop()
        server = nil
        try? FileManager.default.removeItem(at: dir)
        sessionDir = nil
    }
}

import AVFoundation
import Foundation

/// Real AVPlayer regression check: .playing alone can be reported with a frozen
/// clock when HLS is started before it is ready and automatic waiting is off.
@main
struct HLSPlaybackChecks {
    @MainActor
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("homelens-playback-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for codec in ["h264", "hevc"] {
            let dir = root.appendingPathComponent(codec)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let input = dir.appendingPathComponent("source.mp4")
            try ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=3840x2160:rate=25",
                        "-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=16000", "-t", "6",
                        "-c:v", "\(codec)_videotoolbox", "-allow_sw", "0", "-b:v", "6000k",
                        "-g", "25", "-bf", "0", "-c:a", "aac", input.path])
            var args = VideoPipeline.previewArguments(rtspURL: input.path, directory: dir,
                source: VideoSource(codec: codec, width: 3840, height: 2160, fps: 25), lowBandwidth: false)
            for flag in ["-rtsp_transport", "-timeout"] {
                let index = args.firstIndex(of: flag)!
                args.removeSubrange(index...index + 1)
            }
            try ffmpeg(args)
            let playlist = dir.appendingPathComponent("index.m3u8")
            let manifest = try String(contentsOf: playlist, encoding: .utf8) + "#EXT-X-ENDLIST\n"
            try manifest.write(to: playlist, atomically: true, encoding: .utf8)

            let server = LocalHLSServer(rootDir: dir)
            try server.start()
            let player = VideoPipeline.previewPlayer(
                url: URL(string: "http://127.0.0.1:\(server.port)/index.m3u8")!, isMuted: true)
            defer { player.pause(); server.stop() }
            player.play()
            let deadline = Date().addingTimeInterval(12)
            while player.currentTime().seconds < 1 && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                if player.currentItem?.status == .failed { throw player.currentItem!.error! }
            }
            precondition(player.currentTime().seconds >= 1, "\(codec) HLS playback clock is frozen")
            precondition(player.currentItem?.presentationSize == CGSize(width: 3840, height: 2160))
            print("PASS AVPlayer \(codec): 4K HLS decoded and playback clock advances")
        }
    }

    private static func ffmpeg(_ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: BundledBinaries.ffmpeg)
        process.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin"] + args
        try process.run()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0, "ffmpeg fixture failed")
    }
}

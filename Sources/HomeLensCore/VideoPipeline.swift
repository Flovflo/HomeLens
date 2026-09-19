import Foundation
import Darwin
import AVFoundation

/// The camera's actual stream, not the dimensions advertised to HomeKit.
public struct VideoSource: Equatable, Sendable {
    public let codec: String
    public let width: Int
    public let height: Int
    public let fps: Double

    public init(codec: String, width: Int, height: Int, fps: Double) {
        self.codec = codec
        self.width = width
        self.height = height
        self.fps = fps
    }

    public var description: String { "\(width) × \(height) · \(codec.uppercased())" }

    public static func probe(rtspURL: String, ffprobePath: String = BundledBinaries.ffprobe) async throws -> VideoSource {
        let task = Task.detached(priority: .userInitiated) {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("homelens-probe-\(UUID())")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let output = dir.appendingPathComponent("probe.json")
            FileManager.default.createFile(atPath: output.path, contents: nil)
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffprobePath)
            process.arguments = ["-v", "error", "-rtsp_transport", "tcp", "-timeout", "6000000",
                                 "-analyzeduration", "1000000", "-probesize", "2000000", "-i", rtspURL,
                                 "-select_streams", "v:0", "-show_entries", "stream=codec_name,width,height,avg_frame_rate",
                                 "-of", "json"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = handle
            process.standardError = FileHandle.nullDevice
            try Task.checkCancellation()
            try process.run()
            defer {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
            }
            let deadline = Date().addingTimeInterval(10)
            while process.isRunning, Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard !process.isRunning else { throw VideoPipelineError.unavailable }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw VideoPipelineError.unavailable }
            struct Response: Decodable {
                struct Stream: Decodable {
                    let codec_name: String
                    let width: Int
                    let height: Int
                    let avg_frame_rate: String?
                }
                let streams: [Stream]
            }
            let response = try JSONDecoder().decode(Response.self, from: Data(contentsOf: output))
            guard let stream = response.streams.first, stream.width > 0, stream.height > 0,
                  ["h264", "hevc"].contains(stream.codec_name) else { throw VideoPipelineError.unsupported }
            let rate = (stream.avg_frame_rate ?? "0/1").split(separator: "/").compactMap { Double($0) }
            let fps = rate.count == 2 && rate[1] > 0 ? rate[0] / rate[1] : 0
            return VideoSource(codec: stream.codec_name, width: stream.width, height: stream.height, fps: fps)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

public enum VideoPipeline {
    @MainActor
    public static func previewPlayer(url: URL, isMuted: Bool) -> AVPlayer {
        let item = AVPlayerItem(url: url)
        // The camera delivers ~2 s of frames per ~2.4 s burst; buffering less stalls.
        item.preferredForwardBufferDuration = 3
        let player = AVPlayer(playerItem: item)
        // Let AVPlayer start/resume HLS when data is ready. Disabling this before
        // the item loads can leave macOS reporting .playing with rate/time zero.
        player.automaticallyWaitsToMinimizeStalling = true
        player.isMuted = isMuted
        return player
    }

    /// Mirrors the Node helper's smoothedTimestampArgs: Reolink RTSP timestamps
    /// jump ~1.6 s after each 4K keyframe and then burst at ~20 ms. AVPlayer follows
    /// the (smooth) audio clock, so video froze and skipped. Re-time video packets
    /// before the demuxer output (input-side bitstream filter, must precede -i):
    /// nominal cadence for the first K frames, then the mean output rate, steered
    /// toward the source clock with gain 1/K. Anchored on the output (origin 0 when
    /// the first packet has no timestamp, as the first RTSP keyframe) so a missing
    /// input timestamp cannot poison the sequence. No packet is dropped or re-encoded.
    public static func smoothedTimestampArguments(fps: Double) -> [String] {
        let rate: Double = fps > 0 ? fps : 25  // typed first: an Int literal formats as 0.000
        let nominal = String(format: "%.3f", rate)
        let k = min(100, max(20, Int((rate * 2).rounded())))
        func missing(_ v: String) -> String { "gt(isnan(\(v))+eq(\(v),NOPTS),0)" }
        let origin = "if(\(missing("STARTPTS")),0,STARTPTS)"
        let mean = "if(lt(N,\(k)),1/\(nominal)/TB,(PREV_OUTPTS-\(origin))/N)"
        let steer = "if(\(missing("PTS")),\(mean)/\(k),(PTS-PREV_OUTPTS)/\(k))"
        let expr = "if(eq(N,0),\(origin),max(PREV_OUTPTS+1,PREV_OUTPTS+\(steer)+\(k - 1)/\(k)*\(mean)))"
        return ["-bsf:v", "setts=ts='\(expr)'"]
    }

    /// Apple requires fMP4 for HEVC HLS. hvc1 identifies out-of-band parameter sets.
    /// The quality path copies compressed packets; AVPlayer handles hardware decode.
    public static func previewArguments(rtspURL: String, directory: URL, source: VideoSource, lowBandwidth: Bool) -> [String] {
        var args = ["-hide_banner", "-loglevel", "error", "-nostdin",
                    "-rtsp_transport", "tcp", "-timeout", "8000000",
                    "-analyzeduration", "1000000", "-probesize", "2000000"]
        if lowBandwidth { args += ["-hwaccel", "videotoolbox", "-hwaccel_output_format", "videotoolbox_vld"] }
        args += smoothedTimestampArguments(fps: source.fps)
        args += ["-i", rtspURL, "-map", "0:v:0", "-map", "0:a:0?", "-sn", "-dn"]
        if lowBandwidth {
            let fps = max(1, min(15, Int(source.fps > 0 ? source.fps.rounded() : 15)))
            args += ["-vf", "fps=\(fps)", "-c:v", "h264_videotoolbox", "-allow_sw", "0",
                     "-realtime", "1", "-b:v", "1000k", "-profile:v", "high", "-bf", "0",
                     "-g", String(fps), "-force_key_frames", "expr:gte(t,n_forced*1)"]
        } else {
            args += ["-c:v", "copy"]
            if source.codec == "hevc" { args += ["-tag:v", "hvc1"] }
        }
        args += ["-c:a", "aac", "-b:a", "64k", "-ar", "48000",
                 "-f", "hls", "-hls_time", "1", "-hls_list_size", "6",
                 "-hls_flags", "delete_segments+omit_endlist+independent_segments+temp_file",
                 "-hls_segment_type", "fmp4", "-hls_fmp4_init_filename", "init.mp4",
                 "-hls_segment_filename", directory.appendingPathComponent("seg_%05d.m4s").path,
                 directory.appendingPathComponent("index.m3u8").path]
        return args
    }

}

public enum VideoPipelineError: LocalizedError {
    case unavailable, unsupported
    public var errorDescription: String? {
        switch self {
        case .unavailable: "Le flux de la caméra ne répond pas. Vérifiez sa connexion et ses identifiants."
        case .unsupported: "La caméra doit fournir un flux H.264 ou H.265."
        }
    }
}

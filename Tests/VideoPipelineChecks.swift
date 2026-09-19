import Foundation

@main
struct VideoPipelineTests {
    static func main() throws {
        let checks = VideoPipelineTests()
        checks.testQualityPreviewPreservesH264AndHEVC()
        checks.testLowBandwidthPreviewUsesHardwareWithOneSecondGOP()
        checks.testPreviewReTimesVideoBeforeDemuxOutput()
        try checks.testExistingConfigMigrationAndRecordingQualityRoundTrip()
        print("PASS: H.264/HEVC HLS, VideoToolbox preview, legacy config migration")
    }
    func testQualityPreviewPreservesH264AndHEVC() {
        for codec in ["h264", "hevc"] {
            let args = VideoPipeline.previewArguments(rtspURL: "rtsp://camera/main", directory: URL(fileURLWithPath: "/tmp/test"),
                source: VideoSource(codec: codec, width: 3840, height: 2160, fps: 25), lowBandwidth: false)
            expectEqual(value("-c:v", in: args), "copy")
            expectEqual(value("-hls_segment_type", in: args), "fmp4")
            expectEqual(args.contains("hvc1"), codec == "hevc")
            precondition(!args.contains("-vf"))
            precondition(!args.contains("-b:v"))
            precondition(!args.contains("nobuffer+genpts"))
        }
    }

    func testLowBandwidthPreviewUsesHardwareWithOneSecondGOP() {
        let args = VideoPipeline.previewArguments(rtspURL: "rtsp://camera/sub", directory: URL(fileURLWithPath: "/tmp/test"),
            source: VideoSource(codec: "h264", width: 640, height: 360, fps: 10), lowBandwidth: true)
        expectEqual(value("-c:v", in: args), "h264_videotoolbox")
        expectEqual(value("-g", in: args), "10")
        expectEqual(value("-vf", in: args), "fps=10")
    }

    func testPreviewReTimesVideoBeforeDemuxOutput() {
        for lowBandwidth in [false, true] {
            let args = VideoPipeline.previewArguments(rtspURL: "rtsp://camera/main", directory: URL(fileURLWithPath: "/tmp/test"),
                source: VideoSource(codec: "h264", width: 3840, height: 2160, fps: 21.4), lowBandwidth: lowBandwidth)
            let bsf = args.firstIndex(of: "-bsf:v")!
            precondition(bsf < args.firstIndex(of: "-i")!, "input-side bitstream filter must precede -i")
            precondition(args[bsf + 1].hasPrefix("setts=ts='") && args[bsf + 1].contains("1/21.400/TB"))
            precondition(!args[bsf + 1].contains(" "))
        }
        expectEqual(VideoPipeline.smoothedTimestampArguments(fps: 0)[1].contains("1/25.000/TB"), true)
    }

    func testExistingConfigMigrationAndRecordingQualityRoundTrip() throws {
        let encoder = JSONEncoder()
        var camera = CameraConfig()
        camera.recordingQuality = "native"
        let data = try encoder.encode(camera)
        expectEqual(try JSONDecoder().decode(CameraConfig.self, from: data).recordingQuality, "native")
        var legacy = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        legacy.removeValue(forKey: "recordingQuality")
        let decoded = try JSONDecoder().decode(CameraConfig.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(decoded.recordingQuality == nil)
        expectEqual(decoded.rtspMainPath, camera.rtspMainPath)
    }

    private func expectEqual<T: Equatable>(_ actual: T, _ expected: T) {
        precondition(actual == expected, "Expected \(expected), got \(actual)")
    }

    private func value(_ key: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: key), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}

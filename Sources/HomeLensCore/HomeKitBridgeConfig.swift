import Foundation

public struct HomeKitBridgeConfig: Codable, Sendable {
    public struct Video: Codable, Sendable {
        public var width: Int
        public var height: Int
        public var fps: Int
        public var maxBitrateKbps: Int
        public var packetSize: Int
        public var directCopy: Bool
        public var qualityMode: String

        public init(width: Int = 1920, height: Int = 1080, fps: Int = 15, maxBitrateKbps: Int = 2048, packetSize: Int = 1316, directCopy: Bool = true, qualityMode: String = "balanced") {
            self.width = width
            self.height = height
            self.fps = fps
            self.maxBitrateKbps = maxBitrateKbps
            self.packetSize = packetSize
            self.directCopy = directCopy
            self.qualityMode = qualityMode
        }
    }

    public struct Recording: Codable, Sendable {
        public var enabled: Bool
        public var prebufferMs: Int
        public var fragmentMs: Int
        public var maxSeconds: Int

        public init(enabled: Bool = true, prebufferMs: Int = 4000, fragmentMs: Int = 4000, maxSeconds: Int = 20) {
            self.enabled = enabled
            self.prebufferMs = prebufferMs
            self.fragmentMs = fragmentMs
            self.maxSeconds = maxSeconds
        }
    }

    public struct Audio: Codable, Sendable {
        public var enabled: Bool
        public var codec: String
        public var bitrateKbps: Int
        public var sampleRate: Int

        public init(enabled: Bool = true, codec: String = "opus", bitrateKbps: Int = 24, sampleRate: Int = 16000) {
            self.enabled = enabled
            self.codec = codec
            self.bitrateKbps = bitrateKbps
            self.sampleRate = sampleRate
        }
    }

    public var name: String
    public var host: String
    public var serialNumber: String
    public var username: String
    public var pin: String
    public var port: Int
    public var ffmpegPath: String
    public var storagePath: String
    public var interfaceName: String?
    public var video: Video
    public var recording: Recording
    public var audio: Audio

    public init(
        name: String,
        host: String,
        serialNumber: String,
        username: String = "A2:44:5A:11:00:06",
        pin: String = "031-45-154",
        port: Int = 51826,
        ffmpegPath: String = "/opt/homebrew/bin/ffmpeg",
        storagePath: String,
        interfaceName: String? = nil,
        video: Video = Video(),
        recording: Recording = Recording(),
        audio: Audio = Audio()
    ) {
        self.name = name
        self.host = host
        self.serialNumber = serialNumber
        self.username = username
        self.pin = pin
        self.port = port
        self.ffmpegPath = ffmpegPath
        self.storagePath = storagePath
        self.interfaceName = interfaceName
        self.video = video
        self.recording = recording
        self.audio = audio
    }
}

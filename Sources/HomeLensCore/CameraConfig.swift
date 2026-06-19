import Foundation

public struct CameraConfig: Codable, Equatable, Sendable {
    public enum StreamProfile: String, Codable, CaseIterable, Sendable {
        case main
        case sub
    }

    public var id: UUID
    public var name: String
    public var host: String
    public var username: String
    public var rtspMainPath: String
    public var rtspSubPath: String
    public var onvifPath: String
    public var onvifPort: Int
    public var streamProfile: StreamProfile
    public var passwordStored: Bool
    /// Optional macOS network interface name (e.g. "en0") the HomeKit bridge
    /// should publish on. nil/empty = automatic (all interfaces).
    public var networkInterface: String?

    public init(
        id: UUID = UUID(),
        name: String = "Front Door",
        host: String = "192.168.0.6",
        username: String = "admin",
        rtspMainPath: String = "/h264Preview_01_main",
        rtspSubPath: String = "/h264Preview_01_sub",
        onvifPath: String = "/onvif/device_service",
        onvifPort: Int = 8000,
        streamProfile: StreamProfile = .sub,
        passwordStored: Bool = false,
        networkInterface: String? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.username = username
        self.rtspMainPath = rtspMainPath
        self.rtspSubPath = rtspSubPath
        self.onvifPath = onvifPath
        self.onvifPort = onvifPort
        self.streamProfile = streamProfile
        self.passwordStored = passwordStored
        self.networkInterface = networkInterface
    }

    public var selectedRTSPPath: String {
        streamProfile == .main ? rtspMainPath : rtspSubPath
    }

    public func rtspURL(password: String?) -> URL? {
        rtspURL(profile: streamProfile, password: password)
    }

    public func rtspURL(profile: StreamProfile, password: String?) -> URL? {
        var components = URLComponents()
        components.scheme = "rtsp"
        components.host = host
        components.port = 554
        components.path = (profile == .main ? rtspMainPath : rtspSubPath).normalizedPath
        if !username.isEmpty {
            components.user = username
        }
        if let password, !password.isEmpty {
            components.password = password
        }
        return components.url
    }

    public var onvifURL: URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = onvifPort
        components.path = onvifPath.normalizedPath
        return components.url
    }
}

extension String {
    var normalizedPath: String {
        hasPrefix("/") ? self : "/" + self
    }
}

import Foundation

struct CameraConfig: Codable, Identifiable, Equatable {
    enum StreamProfile: String, Codable, CaseIterable, Identifiable {
        case main
        case sub

        var id: String { rawValue }
        var title: String {
            switch self {
            case .main: "Main"
            case .sub: "Sub"
            }
        }
    }

    var id: UUID
    var name: String
    var host: String
    var username: String
    var rtspMainPath: String
    var rtspSubPath: String
    var onvifPath: String
    var onvifPort: Int
    var streamProfile: StreamProfile
    var passwordStored: Bool
    var networkInterface: String?

    init(
        id: UUID = UUID(),
        name: String = "Front Door",
        host: String = "192.168.0.6",
        username: String = "admin",
        rtspMainPath: String = "/h264Preview_01_main",
        rtspSubPath: String = "/h264Preview_01_sub",
        onvifPath: String = "/onvif/device_service",
        onvifPort: Int = 8000,
        streamProfile: StreamProfile = .main,
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

    var selectedRTSPPath: String {
        streamProfile == .main ? rtspMainPath : rtspSubPath
    }

    func rtspURL(password: String?) -> URL? {
        rtspURL(profile: streamProfile, password: password)
    }

    func rtspURL(profile: StreamProfile, password: String?) -> URL? {
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

    var onvifURL: URL? {
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

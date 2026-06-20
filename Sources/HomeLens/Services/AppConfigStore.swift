import Foundation
import Security

struct StoredAppConfig: Codable {
    var cameras: [CameraConfig]

    init(cameras: [CameraConfig]) {
        self.cameras = cameras
    }

    private enum CodingKeys: String, CodingKey {
        case camera
        case cameras
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let cameras = try container.decodeIfPresent([CameraConfig].self, forKey: .cameras) {
            self.cameras = cameras
        } else if let camera = try container.decodeIfPresent(CameraConfig.self, forKey: .camera) {
            self.cameras = [camera]
        } else {
            self.cameras = [CameraConfig()]
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cameras.first ?? CameraConfig(), forKey: .camera)
    }
}

final class AppConfigStore {
    private let appSupportURL: URL
    private let configURL: URL
    private let keychainService = "com.homelens.app.camera"

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        appSupportURL = base.appendingPathComponent("HomeLens", isDirectory: true)
        configURL = appSupportURL.appendingPathComponent("config.json")
    }

    func load() throws -> StoredAppConfig {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return StoredAppConfig(cameras: [CameraConfig()])
        }
        let data = try Data(contentsOf: configURL)
        return try JSONDecoder().decode(StoredAppConfig.self, from: data)
    }

    func save(_ config: StoredAppConfig) throws {
        try FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: configURL, options: [.atomic])
    }

    func password(for cameraID: UUID) -> String? {
        passwordFromSecurityTool(for: cameraID)
    }

    private func passwordFromSecurityTool(for cameraID: UUID) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-s", keychainService,
            "-a", cameraID.uuidString,
            "-w"
        ]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    func setPassword(_ password: String, for cameraID: UUID) throws {
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: cameraID.uuidString
        ]

        SecItemDelete(query as CFDictionary)

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: cameraID.uuidString,
            kSecValueData as String: data
        ]

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ConfigStoreError.keychain(status)
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

enum ConfigStoreError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            "Keychain operation failed with status \(status)."
        }
    }
}

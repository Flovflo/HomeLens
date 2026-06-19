import Foundation
import Security

public struct StoredAppConfig: Codable, Sendable {
    public var camera: CameraConfig

    public init(camera: CameraConfig) {
        self.camera = camera
    }
}

public final class ConfigStore: @unchecked Sendable {
    private let appSupportURL: URL
    private let configURL: URL
    private let keychainService = "com.flo.HomeLens.camera"

    public init(appName: String = "HomeLens") {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        appSupportURL = base.appendingPathComponent(appName, isDirectory: true)
        configURL = appSupportURL.appendingPathComponent("config.json")
    }

    public var path: String {
        configURL.path
    }

    public var supportPath: String {
        appSupportURL.path
    }

    public var homeKitBridgeConfigPath: String {
        appSupportURL.appendingPathComponent("homekit-bridge.json").path
    }

    public func load() throws -> StoredAppConfig {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return StoredAppConfig(camera: CameraConfig())
        }
        let data = try Data(contentsOf: configURL)
        return try JSONDecoder().decode(StoredAppConfig.self, from: data)
    }

    public func save(_ config: StoredAppConfig) throws {
        try FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: configURL, options: [.atomic])
    }

    public func saveHomeKitBridgeConfig(_ bridgeConfig: HomeKitBridgeConfig) throws {
        try FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(bridgeConfig)
        try data.write(to: appSupportURL.appendingPathComponent("homekit-bridge.json"), options: [.atomic])
    }

    public func password(for cameraID: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: cameraID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func setPassword(_ password: String, for cameraID: UUID) throws {
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

public enum ConfigStoreError: LocalizedError {
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .keychain(let status):
            "Keychain operation failed with status \(status)."
        }
    }
}

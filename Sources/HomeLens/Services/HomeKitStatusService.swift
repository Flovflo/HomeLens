import Foundation

struct HomeKitStatus: Equatable {
    var pairedClientCount = 0
    var pin: String?
    var hsvEnabled = false
    var liveAudioEnabled = false
    var bridgeRunning = false

    var isPaired: Bool { pairedClientCount > 0 }
}

/// Reads the HAP helper's on-disk state (pairing + recording/audio config) so
/// the UI can show real HomeKit status without talking to the helper process.
final class HomeKitStatusService {
    private let appSupportURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        appSupportURL = base.appendingPathComponent("HomeLens", isDirectory: true)
    }

    func read() -> HomeKitStatus {
        var status = HomeKitStatus()
        readPairing(into: &status)
        readBridgeConfig(into: &status)
        status.bridgeRunning = isBridgeRunning()
        return status
    }

    /// The HomeKit bridge is the running HAP helper (whether launched by launchd
    /// `homekit-run` or by the GUI). Detect it by its process signature.
    private func isBridgeRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", "HomeKitBridge/src/index.mjs"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return process.terminationStatus == 0 && !data.isEmpty
    }

    private struct AccessoryInfo: Decodable {
        let pairedClients: [String: String]?
        let pincode: String?
    }

    private func readPairing(into status: inout HomeKitStatus) {
        let storage = appSupportURL.appendingPathComponent("hap-storage", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where file.lastPathComponent.hasPrefix("AccessoryInfo.") && file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let info = try? JSONDecoder().decode(AccessoryInfo.self, from: data) else {
                continue
            }
            status.pairedClientCount = max(status.pairedClientCount, info.pairedClients?.count ?? 0)
            if status.pin == nil, let pincode = info.pincode { status.pin = pincode }
        }
    }

    private struct BridgeConfig: Decodable {
        struct Section: Decodable { let enabled: Bool? }
        let recording: Section?
        let audio: Section?
    }

    private func readBridgeConfig(into status: inout HomeKitStatus) {
        let path = appSupportURL.appendingPathComponent("homekit-bridge.json")
        guard let data = try? Data(contentsOf: path),
              let config = try? JSONDecoder().decode(BridgeConfig.self, from: data) else {
            return
        }
        status.hsvEnabled = config.recording?.enabled ?? false
        status.liveAudioEnabled = config.audio?.enabled ?? false
    }
}

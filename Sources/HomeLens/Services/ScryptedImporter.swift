import Foundation

struct ScryptedImportCandidate: Identifiable, Equatable {
    let id = UUID()
    let camera: CameraConfig
    let note: String
}

final class ScryptedImporter {
    private let defaultDBURL: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        defaultDBURL = homeDirectory
            .appendingPathComponent(".scrypted")
            .appendingPathComponent("volume")
            .appendingPathComponent("scrypted.db")
    }

    func discover() -> [ScryptedImportCandidate] {
        guard FileManager.default.fileExists(atPath: defaultDBURL.path) else {
            return []
        }

        let fileURLs = ((try? FileManager.default.contentsOfDirectory(
            at: defaultDBURL,
            includingPropertiesForKeys: nil
        )) ?? [])
        .filter { ["ldb", "log"].contains($0.pathExtension) }

        var blobs: [String] = []
        for url in fileURLs {
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
            else {
                continue
            }
            if text.localizedCaseInsensitiveContains("reolink") ||
                text.localizedCaseInsensitiveContains("rtsp") ||
                text.localizedCaseInsensitiveContains("onvif") {
                blobs.append(text)
            }
        }

        let combined = blobs.joined(separator: "\n")
        guard !combined.isEmpty else {
            return []
        }

        let hosts = matches(#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, in: combined)
            .filter { $0.split(separator: ".").allSatisfy { (Int($0) ?? 999) < 256 } }
        let names = matches(#""name"\s*:\s*"([^"]+)""#, in: combined, capture: 1)
            + matches(#""Name"\s*:\s*"([^"]+)""#, in: combined, capture: 1)
        let users = matches(#""user"\s*:\s*"([^"]+)""#, in: combined, capture: 1)
            + matches(#""username"\s*:\s*"([^"]+)""#, in: combined, capture: 1)

        guard let host = hosts.first else {
            return []
        }

        var camera = CameraConfig(
            name: names.first ?? "Imported Reolink",
            host: host,
            username: users.first ?? "admin",
            passwordStored: false
        )

        if combined.contains("h264Preview_01_main") {
            camera.rtspMainPath = "/h264Preview_01_main"
        }
        if combined.contains("h264Preview_01_sub") {
            camera.rtspSubPath = "/h264Preview_01_sub"
        }

        return [
            ScryptedImportCandidate(
                camera: camera,
                note: "Imported visible camera metadata from \(defaultDBURL.path). Passwords remain in Scrypted's store and were not copied."
            )
        ]
    }

    private func matches(_ pattern: String, in text: String, capture: Int = 0) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > capture,
                  let swiftRange = Range(match.range(at: capture), in: text)
            else {
                return nil
            }
            return String(text[swiftRange])
        }
    }
}

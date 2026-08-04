import AppKit
import Darwin
import Foundation
import HomeLensCore

enum CameraPreviewProfile: String, CaseIterable, Identifiable {
    case sub
    case main

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sub: "Rapide"
        case .main: "Qualité"
        }
    }

    var streamProfile: CameraConfig.StreamProfile {
        switch self {
        case .sub: .sub
        case .main: .main
        }
    }

    var maxWidth: Int {
        switch self {
        case .sub: 960
        case .main: 1600
        }
    }
}

struct CameraPreviewFrame {
    let image: NSImage
    let profile: CameraPreviewProfile
    let timestamp: Date
    let pixelSize: CGSize
}

final class CameraPreviewService: @unchecked Sendable {
    func snapshot(
        camera: CameraConfig,
        password: String?,
        profile: CameraPreviewProfile,
        timeoutSeconds: TimeInterval = 8
    ) async throws -> CameraPreviewFrame {
        if profile == .main {
            return try await reolinkHTTPSnapshot(
                camera: camera,
                password: password,
                profile: profile,
                timeoutSeconds: timeoutSeconds
            )
        }

        guard let url = camera.rtspURL(profile: profile.streamProfile, password: password)?.absoluteString else {
            throw PreviewError.invalidURL
        }

        let data = try await runFFmpegSnapshot(rtspURL: url, maxWidth: profile.maxWidth, timeoutSeconds: timeoutSeconds)
        guard let image = NSImage(data: data) else {
            throw PreviewError.invalidImage
        }
        return CameraPreviewFrame(image: image, profile: profile, timestamp: Date(), pixelSize: image.pixelSize)
    }

    private func reolinkHTTPSnapshot(
        camera: CameraConfig,
        password: String?,
        profile: CameraPreviewProfile,
        timeoutSeconds: TimeInterval
    ) async throws -> CameraPreviewFrame {
        guard let password, !password.isEmpty else {
            throw PreviewError.invalidURL
        }

        let data = try await runCurlHTTPSnapshot(
            camera: camera,
            password: password,
            timeoutSeconds: timeoutSeconds
        )
        guard let image = NSImage(data: data) else {
            throw PreviewError.invalidImage
        }
        return CameraPreviewFrame(image: image, profile: profile, timestamp: Date(), pixelSize: image.pixelSize)
    }

    private func runCurlHTTPSnapshot(
        camera: CameraConfig,
        password: String,
        timeoutSeconds: TimeInterval
    ) async throws -> Data {
        try await Task.detached(priority: .utility) {
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("homelens-reolink-snapshot-\(UUID().uuidString).jpg")
            defer {
                try? FileManager.default.removeItem(at: outputURL)
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = ["-K", "-"]
            process.environment = ProcessInfo.processInfo.environment

            let stdin = Pipe()
            let stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = Pipe()
            process.standardError = stderr

            let url = reolinkSnapshotURL(camera: camera, password: password)
            let config = """
            url = "\(url.curlConfigEscaped)"
            output = "\(outputURL.path.curlConfigEscaped)"
            max-time = \(max(1, Int(timeoutSeconds)))
            fail
            silent
            show-error

            """

            try process.run()
            stdin.fileHandleForWriting.write(Data(config.utf8))
            try? stdin.fileHandleForWriting.close()

            let deadline = Date().addingTimeInterval(timeoutSeconds + 1)
            while process.isRunning, Date() < deadline {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            if process.isRunning {
                process.terminate()
                try? await Task.sleep(nanoseconds: 300_000_000)
                if process.isRunning {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                }
                throw PreviewError.timeout
            }

            if process.terminationStatus == 0,
               FileManager.default.fileExists(atPath: outputURL.path) {
                return try Data(contentsOf: outputURL)
            }

            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw PreviewError.httpSnapshot(detail?.isEmpty == false ? detail! : "curl exited with status \(process.terminationStatus)")
        }.value
    }

    private func runFFmpegSnapshot(rtspURL: String, maxWidth: Int, timeoutSeconds: TimeInterval) async throws -> Data {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: BundledBinaries.ffmpeg)
            process.arguments = [
                "-hide_banner",
                "-loglevel", "error",
                "-rtsp_transport", "tcp",
                "-timeout", String(Int(timeoutSeconds * 1_000_000)),
                "-i", rtspURL,
                "-frames:v", "1",
                "-vf", "scale=min(\(maxWidth)\\,iw):-2",
                "-f", "mjpeg",
                "pipe:1",
            ]
            process.environment = ProcessInfo.processInfo.environment

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = Pipe()

            try process.run()
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while process.isRunning, Date() < deadline {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            if process.isRunning {
                process.terminate()
                try? await Task.sleep(nanoseconds: 300_000_000)
                if process.isRunning {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                }
                throw PreviewError.timeout
            }

            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            if process.terminationStatus == 0, !data.isEmpty {
                return data
            }

            let detail = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw PreviewError.ffmpeg(detail?.isEmpty == false ? detail! : "ffmpeg exited with status \(process.terminationStatus)")
        }.value
    }
}

enum PreviewError: LocalizedError {
    case invalidURL
    case invalidImage
    case timeout
    case httpStatus(Int)
    case httpSnapshot(String)
    case ffmpeg(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Could not build RTSP URL."
        case .invalidImage:
            "Camera preview returned invalid image data."
        case .timeout:
            "Timed out waiting for camera preview."
        case .httpStatus(let status):
            "Camera snapshot HTTP status \(status)."
        case .httpSnapshot(let detail):
            "Camera snapshot failed: \(detail)"
        case .ffmpeg(let detail):
            "Preview ffmpeg failed: \(detail)"
        }
    }
}

private func reolinkSnapshotURL(camera: CameraConfig, password: String) -> String {
    "http://\(camera.host)/cgi-bin/api.cgi?cmd=Snap&channel=0&rs=HomeLens&user=\(camera.username)&password=\(password)"
}

private extension String {
    var curlConfigEscaped: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }
}

private extension NSImage {
    var pixelSize: CGSize {
        guard let representation = representations.first else {
            return size
        }
        return CGSize(width: representation.pixelsWide, height: representation.pixelsHigh)
    }
}

import Foundation

/// Resolves the helper binaries (ffmpeg / ffprobe / node) and the HAP-NodeJS
/// helper that ship *inside* the packaged `HomeLens.app`, falling back to a
/// Homebrew install when running from a dev checkout.
///
/// In the packaged app both executables (`HomeLens` and `homelensctl`) live in
/// `HomeLens.app/Contents/MacOS/`, and the portable bundle produced by
/// `script/bundle_portable.py` puts the binaries in
/// `HomeLens.app/Contents/Resources/bin/`. We resolve relative to the running
/// executable so the same code works for both the GUI and the CLI.
public enum BundledBinaries {
    /// `…/HomeLens.app/Contents/Resources`, derived from the running executable,
    /// or `nil` when that layout isn't present (i.e. a dev build).
    public static var resourcesDirectory: URL? {
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        // exe = …/Contents/MacOS/<tool>  →  …/Contents/Resources
        let resources = exe
            .deletingLastPathComponent()        // …/Contents/MacOS
            .deletingLastPathComponent()        // …/Contents
            .appendingPathComponent("Resources", isDirectory: true)
        return FileManager.default.fileExists(atPath: resources.path) ? resources : nil
    }

    /// `…/Contents/Resources/bin` when present.
    public static var binDirectory: URL? {
        guard let bin = resourcesDirectory?.appendingPathComponent("bin", isDirectory: true),
              FileManager.default.fileExists(atPath: bin.path) else { return nil }
        return bin
    }

    /// Bundled executable path if it exists and is runnable, else `fallback`.
    public static func executable(_ name: String, fallback: String) -> String {
        if let dir = binDirectory {
            let path = dir.appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return fallback
    }

    public static var ffmpeg: String { executable("ffmpeg", fallback: "/opt/homebrew/bin/ffmpeg") }
    public static var ffprobe: String { executable("ffprobe", fallback: "/opt/homebrew/bin/ffprobe") }

    /// Bundled `node`, or `nil` to signal callers to fall back to `/usr/bin/env node`.
    public static var node: String? {
        guard let dir = binDirectory else { return nil }
        let path = dir.appendingPathComponent("node").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// The HAP-NodeJS helper entry point shipped inside the app bundle, if present.
    public static var helperEntryPoint: String? {
        guard let resources = resourcesDirectory else { return nil }
        let path = resources
            .appendingPathComponent("Helpers/HomeKitBridge/src/index.mjs")
            .path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }
}

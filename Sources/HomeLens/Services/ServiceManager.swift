import Foundation

/// Installs and manages the launchd background bridge **from inside the app**, so
/// an end user never has to touch the Terminal. It is the in-app equivalent of
/// `script/install_bridge_agent.sh` + `install_ui_login.sh`.
///
/// Why it shells out to the bundled `homelensctl init`: the 24/7 bridge
/// (`homelensctl homekit-run`) reads the camera password from the Keychain. By
/// having that same binary write the item, the bridge reads it back with no
/// cross-process Keychain prompt.
@MainActor
final class ServiceManager {
    static let bridgeLabel = "com.homelens.app"
    static let uiLabel = "com.homelens.app.ui"
    /// Labels from earlier builds, cleaned up on install so they don't linger.
    static let legacyLabels = ["com.flo.HomeLens", "com.flo.HomeLens.ui"]

    enum ServiceError: LocalizedError {
        case missingBinary(String)
        case command(String, Int32, String)

        var errorDescription: String? {
            switch self {
            case .missingBinary(let what):
                return "Composant introuvable: \(what). Réinstallez HomeLens."
            case .command(let what, let code, let detail):
                return "\(what) a échoué (code \(code)). \(detail)"
            }
        }
    }

    private var launchAgentsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    private var logDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/HomeLens", isDirectory: true)
    }

    var bridgePlistURL: URL { launchAgentsDir.appendingPathComponent("\(Self.bridgeLabel).plist") }
    var uiPlistURL: URL { launchAgentsDir.appendingPathComponent("\(Self.uiLabel).plist") }

    /// True once the background bridge agent has been installed.
    var isBridgeInstalled: Bool {
        FileManager.default.fileExists(atPath: bridgePlistURL.path)
    }

    // MARK: - Path resolution (packaged app, with a dev fallback)

    /// The `.app` bundle we live in (or, in a dev run, a best-effort guess).
    private var appBundleURL: URL? {
        let bundle = Bundle.main.bundleURL
        return bundle.pathExtension == "app" ? bundle : nil
    }

    private func resolveCTL() -> String? {
        var candidates: [String] = []
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(exeDir.appendingPathComponent("homelensctl").path)
        }
        if let env = ProcessInfo.processInfo.environment["HOMELENS_CTL"], !env.isEmpty {
            candidates.append(env)
        }
        candidates.append(FileManager.default.currentDirectoryPath + "/.build/release/homelensctl")
        candidates.append(FileManager.default.currentDirectoryPath + "/.build/debug/homelensctl")
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func resolveHelper() -> String? {
        var candidates: [String] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("Helpers/HomeKitBridge/src/index.mjs").path)
        }
        candidates.append(FileManager.default.currentDirectoryPath + "/Helpers/HomeKitBridge/src/index.mjs")
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: - Onboarding actions

    /// Write config.json + store the camera password in the Keychain via the
    /// bundled `homelensctl init`. Returns nothing; throws on failure.
    func writeConfig(host: String, username: String, password: String, name: String, profile: String) async throws {
        guard let ctl = resolveCTL() else { throw ServiceError.missingBinary("homelensctl") }
        var env = ProcessInfo.processInfo.environment
        env["HOMELENS_PASSWORD"] = password
        let (code, out) = await runProcess(
            ctl,
            ["init", "--host", host, "--username", username, "--name", name, "--profile", profile],
            env: env
        )
        guard code == 0 else { throw ServiceError.command("Enregistrement de la configuration", code, out) }
    }

    /// Install + start the 24/7 HomeKit bridge agent (KeepAlive) and the login
    /// agent that reopens the monitor window. Idempotent.
    func installAndStart() async throws {
        guard let ctl = resolveCTL() else { throw ServiceError.missingBinary("homelensctl") }
        guard let helper = resolveHelper() else { throw ServiceError.missingBinary("HomeKitBridge helper") }
        let appDir = appBundleURL?.deletingLastPathComponent().path
            ?? FileManager.default.homeDirectoryForCurrentUser.path

        try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        await cleanUpLegacyAgents()

        // --- Bridge agent (headless, KeepAlive) ---
        let binDir = Bundle.main.resourceURL?.appendingPathComponent("bin").path
        let path = [binDir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].compactMap { $0 }.joined(separator: ":")
        let bridgePlist = plist(
            label: Self.bridgeLabel,
            programArguments: [ctl, "homekit-run"],
            workingDirectory: appDir,
            environment: ["PATH": path, "HOMELENS_HOMEKIT_HELPER": helper],
            keepAlive: true,
            stdout: logDir.appendingPathComponent("bridge.out.log").path,
            stderr: logDir.appendingPathComponent("bridge.err.log").path
        )
        try bridgePlist.write(to: bridgePlistURL, atomically: true, encoding: .utf8)
        try await bootstrap(label: Self.bridgeLabel, plistURL: bridgePlistURL, kickstart: true)

        // --- UI login agent (reopens the monitor app at login) ---
        if let app = appBundleURL?.path {
            let uiPlist = plist(
                label: Self.uiLabel,
                programArguments: ["/usr/bin/open", app],
                workingDirectory: nil,
                environment: nil,
                keepAlive: false,
                stdout: logDir.appendingPathComponent("ui.out.log").path,
                stderr: logDir.appendingPathComponent("ui.err.log").path
            )
            try? uiPlist.write(to: uiPlistURL, atomically: true, encoding: .utf8)
            try? await bootstrap(label: Self.uiLabel, plistURL: uiPlistURL, kickstart: false)
        }
    }

    /// Restart the bridge so it re-reads config (e.g. after a settings change).
    func restartBridge() async {
        _ = await runProcess("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(Self.bridgeLabel)"])
    }

    /// Stop + remove both agents (does not delete config or the Keychain entry).
    func uninstall() async {
        for label in [Self.bridgeLabel, Self.uiLabel] {
            _ = await runProcess("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        }
        try? FileManager.default.removeItem(at: bridgePlistURL)
        try? FileManager.default.removeItem(at: uiPlistURL)
    }

    // MARK: - launchctl plumbing

    private func cleanUpLegacyAgents() async {
        for label in Self.legacyLabels {
            _ = await runProcess("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
            let plist = launchAgentsDir.appendingPathComponent("\(label).plist")
            try? FileManager.default.removeItem(at: plist)
        }
    }

    private func bootstrap(label: String, plistURL: URL, kickstart: Bool) async throws {
        let domain = "gui/\(getuid())"
        // Replace any previous instance.
        _ = await runProcess("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        let (code, out) = await runProcess("/bin/launchctl", ["bootstrap", domain, plistURL.path])
        guard code == 0 else { throw ServiceError.command("launchctl bootstrap \(label)", code, out) }
        _ = await runProcess("/bin/launchctl", ["enable", "\(domain)/\(label)"])
        if kickstart {
            _ = await runProcess("/bin/launchctl", ["kickstart", "-k", "\(domain)/\(label)"])
        }
    }

    private func plist(label: String,
                       programArguments: [String],
                       workingDirectory: String?,
                       environment: [String: String]?,
                       keepAlive: Bool,
                       stdout: String,
                       stderr: String) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        var lines: [String] = []
        lines.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        lines.append("<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">")
        lines.append("<plist version=\"1.0\">")
        lines.append("<dict>")
        lines.append("  <key>Label</key><string>\(esc(label))</string>")
        lines.append("  <key>ProgramArguments</key>")
        lines.append("  <array>")
        for arg in programArguments { lines.append("    <string>\(esc(arg))</string>") }
        lines.append("  </array>")
        if let workingDirectory {
            lines.append("  <key>WorkingDirectory</key><string>\(esc(workingDirectory))</string>")
        }
        if let environment, !environment.isEmpty {
            lines.append("  <key>EnvironmentVariables</key>")
            lines.append("  <dict>")
            for (k, v) in environment.sorted(by: { $0.key < $1.key }) {
                lines.append("    <key>\(esc(k))</key><string>\(esc(v))</string>")
            }
            lines.append("  </dict>")
        }
        lines.append("  <key>RunAtLoad</key><true/>")
        lines.append("  <key>KeepAlive</key><\(keepAlive ? "true" : "false")/>")
        lines.append("  <key>StandardOutPath</key><string>\(esc(stdout))</string>")
        lines.append("  <key>StandardErrorPath</key><string>\(esc(stderr))</string>")
        lines.append("</dict>")
        lines.append("</plist>")
        return lines.joined(separator: "\n") + "\n"
    }

    @discardableResult
    private func runProcess(_ launchPath: String, _ args: [String], env: [String: String]? = nil) async -> (Int32, String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: launchPath)
                process.arguments = args
                if let env { process.environment = env }
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: (-1, error.localizedDescription))
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: (process.terminationStatus, text))
            }
        }
    }
}

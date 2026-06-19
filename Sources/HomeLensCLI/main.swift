import Foundation
import HomeLensCore

@main
struct HomeLensCLI {
    static func main() async {
        do {
            try await run()
        } catch {
            printError("homelensctl: \(error.localizedDescription)")
            Foundation.exit(1)
        }
    }

    private static func run() async throws {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            printUsage()
            return
        }
        args.removeFirst()

        let store = ConfigStore()
        let logger = ConsoleLogger()

        switch command {
        case "init":
            try initConfig(args: args, store: store)
        case "show-config":
            let config = try store.load()
            printConfig(config.camera)
        case "test":
            try await test(args: args, store: store)
        case "run":
            logger.log(.info, "CLI", "Starting long-running monitor.")
            let config = try store.load()
            let password = effectivePassword(for: config.camera, store: store)
            await ONVIFClient().runEventLoop(camera: config.camera, password: password, logger: logger)
        case "homekit-config":
            let config = try store.load()
            try writeHomeKitConfig(camera: config.camera, store: store)
        case "homekit-run":
            try await runHomeKitBridge(store: store, logger: logger)
        case "doctor":
            try await runDoctor(store: store)
        case "help", "--help", "-h":
            printUsage()
        default:
            throw CLIError.usage("Unknown command '\(command)'.")
        }
    }

    private static func initConfig(args: [String], store: ConfigStore) throws {
        let parser = ArgumentParser(args)
        let host = parser.value(after: "--host") ?? "192.168.0.6"
        let username = parser.value(after: "--username") ?? "admin"
        let password = parser.value(after: "--password") ?? ProcessInfo.processInfo.environment["HOMELENS_PASSWORD"]
        let name = parser.value(after: "--name") ?? "Front Door"
        let profile = CameraConfig.StreamProfile(rawValue: parser.value(after: "--profile") ?? "sub") ?? .sub

        var camera = CameraConfig(name: name, host: host, username: username, streamProfile: profile)
        if let onvifPort = parser.int(after: "--onvif-port") {
            camera.onvifPort = onvifPort
        }
        if let rtspMain = parser.value(after: "--rtsp-main") {
            camera.rtspMainPath = rtspMain
        }
        if let rtspSub = parser.value(after: "--rtsp-sub") {
            camera.rtspSubPath = rtspSub
        }
        if let onvifPath = parser.value(after: "--onvif-path") {
            camera.onvifPath = onvifPath
        }

        if let password, !password.isEmpty {
            try store.setPassword(password, for: camera.id)
            camera.passwordStored = true
        }

        try store.save(StoredAppConfig(camera: camera))
        print("Saved config: \(store.path)")
        printConfig(camera)
    }

    private static func test(args: [String], store: ConfigStore) async throws {
        let target = args.first ?? "all"
        let config = try store.load()
        let password = effectivePassword(for: config.camera, store: store)

        switch target {
        case "rtsp":
            printResult(await RTSPStreamManager().test(camera: config.camera, password: password))
        case "onvif":
            printResult(await ONVIFClient().test(camera: config.camera, password: password))
        case "all":
            let rtsp = await RTSPStreamManager().test(camera: config.camera, password: password)
            printResult(rtsp)
            let onvif = await ONVIFClient().test(camera: config.camera, password: password)
            printResult(onvif)
            if !rtsp.ok || !onvif.ok {
                throw CLIError.failedCheck
            }
        case "events-once":
            try await withTimeout(seconds: 15) {
                await ONVIFClient().runEventLoop(
                    camera: config.camera,
                    password: password,
                    logger: ConsoleLogger(minLevel: .debug),
                    stopAfterOneCycle: true
                )
            }
        case "hsv-prebuffer":
            try await testHSVPrebuffer(store: store, logger: ConsoleLogger(minLevel: .debug))
        default:
            throw CLIError.usage("Unknown test target '\(target)'.")
        }
    }

    private static func printResult(_ result: ServiceTestResult) {
        let prefix = result.ok ? "OK" : "FAIL"
        print("[\(prefix)] \(result.title)")
        print("     \(result.detail)")
    }

    private static func printConfig(_ camera: CameraConfig) {
        print("Camera: \(camera.name)")
        print("Host: \(camera.host)")
        print("Username: \(camera.username)")
        print("Password: \(camera.passwordStored ? "stored in Keychain" : "missing")")
        print("RTSP profile: \(camera.streamProfile.rawValue)")
        print("RTSP main: \(camera.rtspMainPath)")
        print("RTSP sub: \(camera.rtspSubPath)")
        print("ONVIF: http://\(camera.host):\(camera.onvifPort)\(camera.onvifPath.normalizedCLIPath)")
    }

    private static func effectivePassword(for camera: CameraConfig, store: ConfigStore) -> String? {
        if let password = ProcessInfo.processInfo.environment["HOMELENS_PASSWORD"], !password.isEmpty {
            return password
        }
        guard camera.passwordStored else {
            return nil
        }
        return store.password(for: camera.id)
    }

    private static func printUsage() {
        print(
            """
            HomeLens CLI

            Commands:
              homelensctl init --host 192.168.0.6 --username admin --password '...' [--profile sub]
              homelensctl show-config
              homelensctl test rtsp
              homelensctl test onvif
              homelensctl test all
              homelensctl test events-once
              homelensctl test hsv-prebuffer
              homelensctl run
              homelensctl homekit-config
              homelensctl homekit-run
              homelensctl doctor

            Notes:
              - Passwords are stored in macOS Keychain.
              - You can pass the password via HOMELENS_PASSWORD instead of --password.
              - 'run' monitors ONVIF events with reconnect/backoff.
              - 'homekit-run' publishes the HomeKit camera helper and forwards ONVIF events.
            """
        )
    }

    private static func writeHomeKitConfig(camera: CameraConfig, store: ConfigStore) throws {
        let video = homeKitVideoConfig(for: camera)
        let recordingEnabled = ProcessInfo.processInfo.environment["HOMELENS_LIVE_FIRST"] != "1"
        let bridgeConfig = HomeKitBridgeConfig(
            name: camera.name,
            host: camera.host,
            serialNumber: camera.id.uuidString,
            username: homeKitUsername(store: store),
            ffmpegPath: BundledBinaries.ffmpeg,
            storagePath: URL(fileURLWithPath: store.supportPath)
                .appendingPathComponent("hap-storage", isDirectory: true)
                .path,
            interfaceName: camera.networkInterface?.isEmpty == false ? camera.networkInterface : nil,
            video: video,
            recording: HomeKitBridgeConfig.Recording(enabled: recordingEnabled),
            audio: HomeKitBridgeConfig.Audio(
                enabled: ProcessInfo.processInfo.environment["HOMELENS_LIVE_AUDIO"] != "0"
            )
        )
        try store.saveHomeKitBridgeConfig(bridgeConfig)
        print("Saved HomeKit helper config: \(store.homeKitBridgeConfigPath)")
        print("Pairing PIN: \(bridgeConfig.pin)")
        print("Pairing username: \(bridgeConfig.username)")
    }

    private static func homeKitUsername(store: ConfigStore) -> String {
        if let override = ProcessInfo.processInfo.environment["HOMELENS_HOMEKIT_USERNAME"], !override.isEmpty {
            return override
        }
        if let pairedUsername = pairedHomeKitUsername(store: store) {
            return pairedUsername
        }
        if let data = FileManager.default.contents(atPath: store.homeKitBridgeConfigPath),
           let existing = try? JSONDecoder().decode(HomeKitBridgeConfig.self, from: data),
           !existing.username.isEmpty {
            return existing.username
        }
        return generatedHomeKitUsername(store: store)
    }

    private static func generatedHomeKitUsername(store: ConfigStore) -> String {
        let url = URL(fileURLWithPath: store.supportPath).appendingPathComponent("homekit-username.txt")
        if let value = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           isValidHomeKitUsername(value) {
            return value
        }

        let bytes = (0..<3).map { _ in UInt8.random(in: 0...255) }
        let value = (["A2", "44", "5A"] + bytes.map { String(format: "%02X", $0) }).joined(separator: ":")
        try? FileManager.default.createDirectory(atPath: store.supportPath, withIntermediateDirectories: true)
        try? value.write(to: url, atomically: true, encoding: .utf8)
        return value
    }

    private static func isValidHomeKitUsername(_ value: String) -> Bool {
        value.range(of: #"^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$"#, options: .regularExpression) != nil
    }

    private static func pairedHomeKitUsername(store: ConfigStore) -> String? {
        let storageURL = URL(fileURLWithPath: store.supportPath)
            .appendingPathComponent("hap-storage", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: storageURL, includingPropertiesForKeys: nil) else {
            return nil
        }

        struct AccessoryInfo: Decodable {
            let pairedClients: [String: String]?
        }

        return files
            .compactMap { url -> (username: String, count: Int)? in
                guard url.lastPathComponent.hasPrefix("AccessoryInfo."),
                      url.pathExtension == "json",
                      let username = username(fromAccessoryInfoFilename: url.lastPathComponent),
                      let data = try? Data(contentsOf: url),
                      let info = try? JSONDecoder().decode(AccessoryInfo.self, from: data)
                else {
                    return nil
                }
                let count = info.pairedClients?.count ?? 0
                return count > 0 ? (username, count) : nil
            }
            .sorted { lhs, rhs in lhs.count > rhs.count }
            .first?
            .username
    }

    private static func username(fromAccessoryInfoFilename filename: String) -> String? {
        let prefix = "AccessoryInfo."
        let suffix = ".json"
        guard filename.hasPrefix(prefix), filename.hasSuffix(suffix) else {
            return nil
        }
        let compact = filename
            .dropFirst(prefix.count)
            .dropLast(suffix.count)
        guard compact.count == 12 else {
            return nil
        }
        return stride(from: 0, to: compact.count, by: 2)
            .map { index in
                let start = compact.index(compact.startIndex, offsetBy: index)
                let end = compact.index(start, offsetBy: 2)
                return String(compact[start..<end])
            }
            .joined(separator: ":")
    }

    private static func homeKitVideoConfig(for camera: CameraConfig) -> HomeKitBridgeConfig.Video {
        switch camera.streamProfile {
        case .main:
            HomeKitBridgeConfig.Video(width: 3840, height: 2160, fps: 15, maxBitrateKbps: 8192, packetSize: 1316, directCopy: true, qualityMode: "adaptive")
        case .sub:
            HomeKitBridgeConfig.Video(width: 1920, height: 1080, fps: 15, maxBitrateKbps: 2048, packetSize: 1316, directCopy: true, qualityMode: "balanced")
        }
    }

    private static func testHSVPrebuffer(store: ConfigStore, logger: ConsoleLogger) async throws {
        let config = try store.load()
        let camera = config.camera
        let password = effectivePassword(for: camera, store: store)
        guard let rtspURL = camera.rtspURL(profile: .main, password: password)?.absoluteString else {
            throw CLIError.usage("Could not build RTSP URL for HomeKit helper.")
        }
        try writeHomeKitConfig(camera: camera, store: store)

        let helperPath = try resolveHomeKitHelperPath()
        let helperDir = URL(fileURLWithPath: helperPath).deletingLastPathComponent().deletingLastPathComponent().path
        let nodeModules = URL(fileURLWithPath: helperDir).appendingPathComponent("node_modules")
        guard FileManager.default.fileExists(atPath: nodeModules.path) else {
            throw CLIError.usage("HomeKit helper dependencies are missing. Run npm install in \(helperDir).")
        }

        let process = Process()
        if let node = BundledBinaries.node {
            process.executableURL = URL(fileURLWithPath: node)
            process.arguments = [helperPath]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["node", helperPath]
        }
        process.currentDirectoryURL = URL(fileURLWithPath: helperDir)
        var environment = ProcessInfo.processInfo.environment
        environment["HOMELENS_BRIDGE_CONFIG"] = store.homeKitBridgeConfigPath
        environment["HOMELENS_RTSP_URL"] = rtspURL
        environment["HOMELENS_PREBUFFER_SELF_TEST"] = "1"
        environment["HOMELENS_PREBUFFER_SELF_TEST_SECONDS"] = "25"
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = Pipe()

        try process.run()
        let status = try await waitForProcess(process, timeoutSeconds: 30)
        let stdoutText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in stderrText.split(separator: "\n") {
            logger.log(.info, "HomeKit", String(line))
        }

        guard status == 0 else {
            throw CLIError.usage("HKSV prebuffer self-test failed with status \(status). \(stderrText.suffix(500))")
        }

        print("[OK] HKSV prebuffer")
        print("     \(stdoutText.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    private static func runDoctor(store: ConfigStore) async throws {
        let config = try store.load()
        let camera = config.camera
        let password = effectivePassword(for: camera, store: store)
        let helperDir = (try? resolveHomeKitHelperPath()).map {
            URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().path
        }

        print("HomeLens — diagnostic de bout en bout\n")
        let runner = DiagnosticsRunner()
        let currentStage = StageTracker()
        await runner.run(
            camera: camera,
            password: password,
            supportPath: store.supportPath,
            helperDir: helperDir
        ) { result in
            currentStage.printHeaderIfNeeded(result.stage)
            let symbol: String
            let color: String
            switch result.status {
            case .ok: symbol = "✓"; color = "\u{1B}[32m"
            case .warn: symbol = "⚠"; color = "\u{1B}[33m"
            case .fail: symbol = "✗"; color = "\u{1B}[31m"
            case .info: symbol = "·"; color = "\u{1B}[2m"
            }
            let reset = "\u{1B}[0m"
            let timing = result.durationMs > 0 ? " \u{1B}[2m(\(result.durationMs) ms)\u{1B}[0m" : ""
            print("  \(color)\(symbol) \(result.title)\(reset) — \(result.detail)\(timing)")
        }
    }

    private static func runHomeKitBridge(store: ConfigStore, logger: ConsoleLogger) async throws {
        let config = try store.load()
        let camera = config.camera
        let password = effectivePassword(for: camera, store: store)
        guard let rtspURL = camera.rtspURL(profile: .main, password: password)?.absoluteString else {
            throw CLIError.usage("Could not build RTSP URL for HomeKit helper.")
        }
        let rtspSubURL = camera.rtspURL(profile: .sub, password: password)?.absoluteString
        try writeHomeKitConfig(camera: camera, store: store)

        let helperPath = try resolveHomeKitHelperPath()
        let supervisor = HomeKitHelperSupervisor(
            helperPath: helperPath,
            configPath: store.homeKitBridgeConfigPath,
            rtspURL: rtspURL,
            rtspSubURL: rtspSubURL,
            logger: logger
        )
        try supervisor.start()
        let signalTrap = SignalTrap {
            supervisor.stop()
            Foundation.exit(0)
        }
        signalTrap.install()

        await ONVIFClient().runEventLoop(
            camera: camera,
            password: password,
            logger: logger,
            onEvent: { event in
                supervisor.send(event: event)
            }
        )
    }

    private static func resolveHomeKitHelperPath() throws -> String {
        if let override = ProcessInfo.processInfo.environment["HOMELENS_HOMEKIT_HELPER"], !override.isEmpty {
            return override
        }
        // Packaged app: the helper ships inside HomeLens.app/Contents/Resources.
        if let bundled = BundledBinaries.helperEntryPoint {
            return bundled
        }
        // Dev checkout: resolve relative to the working directory (repo root).
        let candidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Helpers/HomeKitBridge/src/index.mjs")
            .path
        guard FileManager.default.fileExists(atPath: candidate) else {
            throw CLIError.usage("HomeKit helper not found. Set HOMELENS_HOMEKIT_HELPER or run from the repo root.")
        }
        return candidate
    }

    private static func waitForProcess(_ process: Process, timeoutSeconds: UInt64) async throws -> Int32 {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                try? await Task.sleep(nanoseconds: 500_000_000)
                if process.isRunning {
                    process.interrupt()
                }
                throw CLIError.timeout("Timed out after \(timeoutSeconds) seconds.")
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        return process.terminationStatus
    }
}

private final class StageTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var printed = Set<String>()

    func printHeaderIfNeeded(_ stage: DiagnosticResult.Stage) {
        lock.lock()
        defer { lock.unlock() }
        guard !printed.contains(stage.rawValue) else { return }
        printed.insert(stage.rawValue)
        print("\n\u{1B}[1m▸ \(stage.rawValue)\u{1B}[0m")
    }
}

private struct ArgumentParser {
    let args: [String]

    init(_ args: [String]) {
        self.args = args
    }

    func value(after flag: String) -> String? {
        guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else {
            return nil
        }
        return args[index + 1]
    }

    func int(after flag: String) -> Int? {
        value(after: flag).flatMap(Int.init)
    }
}

private enum CLIError: LocalizedError {
    case usage(String)
    case failedCheck
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message):
            message
        case .failedCheck:
            "One or more checks failed."
        case .timeout(let message):
            message
        }
    }
}

private final class HomeKitHelperSupervisor: @unchecked Sendable {
    private let helperPath: String
    private let configPath: String
    private let rtspURL: String
    private let rtspSubURL: String?
    private let logger: ConsoleLogger
    private let lock = NSLock()
    private var process: Process?
    private var stdinPipe: Pipe?
    private var intentionalStop = false

    init(helperPath: String, configPath: String, rtspURL: String, rtspSubURL: String?, logger: ConsoleLogger) {
        self.helperPath = helperPath
        self.configPath = configPath
        self.rtspURL = rtspURL
        self.rtspSubURL = rtspSubURL
        self.logger = logger
    }

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        try startLocked()
    }

    func send(event: DetectionEvent) {
        let type = event.kind == .person ? "person" : "motion"
        let line = #"{"type":"\#(type)","active":\#(event.active)}"# + "\n"
        lock.lock()
        let handle = stdinPipe?.fileHandleForWriting
        lock.unlock()
        do {
            try handle?.write(contentsOf: Data(line.utf8))
        } catch {
            logger.log(.warning, "HomeKit", "Failed to forward event to helper: \(error.localizedDescription)")
        }
    }

    func stop() {
        lock.lock()
        intentionalStop = true
        let process = self.process
        self.process = nil
        self.stdinPipe = nil
        lock.unlock()

        if let process, process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.5)
            if process.isRunning {
                process.interrupt()
            }
        }
    }

    private func startLocked() throws {
        let helperDir = URL(fileURLWithPath: helperPath).deletingLastPathComponent().deletingLastPathComponent().path
        let nodeModules = URL(fileURLWithPath: helperDir).appendingPathComponent("node_modules")
        guard FileManager.default.fileExists(atPath: nodeModules.path) else {
            throw CLIError.usage("HomeKit helper dependencies are missing. Run npm install in \(helperDir).")
        }

        let process = Process()
        if let node = BundledBinaries.node {
            process.executableURL = URL(fileURLWithPath: node)
            process.arguments = [helperPath]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["node", helperPath]
        }
        process.currentDirectoryURL = URL(fileURLWithPath: helperDir)
        var environment = ProcessInfo.processInfo.environment
        environment["HOMELENS_BRIDGE_CONFIG"] = configPath
        environment["HOMELENS_RTSP_URL"] = rtspURL
        if let rtspSubURL {
            environment["HOMELENS_RTSP_SUB_URL"] = rtspSubURL
        }
        process.environment = environment

        let input = Pipe()
        let stderr = Pipe()
        process.standardInput = input
        process.standardError = stderr
        process.standardOutput = Pipe()
        process.terminationHandler = { [weak self] process in
            self?.handleExit(status: process.terminationStatus)
        }

        stderr.fileHandleForReading.readabilityHandler = { [logger] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
                return
            }
            for line in text.split(separator: "\n") {
                logger.log(.info, "HomeKit", String(line))
            }
        }

        try process.run()
        self.process = process
        self.stdinPipe = input
        logger.log(.info, "HomeKit", "Started HAP helper pid \(process.processIdentifier).")
    }

    private func handleExit(status: Int32) {
        lock.lock()
        process = nil
        stdinPipe = nil
        let shouldRestart = !intentionalStop
        lock.unlock()

        logger.log(status == 0 ? .info : .warning, "HomeKit", "HAP helper exited with status \(status).")
        guard shouldRestart else {
            return
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            do {
                self.lock.lock()
                defer { self.lock.unlock() }
                try self.startLocked()
            } catch {
                self.logger.log(.error, "HomeKit", "Failed to restart HAP helper: \(error.localizedDescription)")
            }
        }
    }
}

private final class SignalTrap {
    private let handler: @Sendable () -> Void
    private var sources: [DispatchSourceSignal] = []

    init(handler: @escaping @Sendable () -> Void) {
        self.handler = handler
    }

    func install() {
        for signalNumber in [SIGINT, SIGTERM] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler(handler: handler)
            source.resume()
            sources.append(source)
        }
    }
}

private func withTimeout(seconds: UInt64, operation: @escaping @Sendable () async -> Void) async throws {
    try await withCheckedThrowingContinuation { continuation in
        let oneShot = OneShot(continuation)
        let task = Task {
            await operation()
            oneShot.resume(.success(()))
        }
        Task {
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            task.cancel()
            oneShot.resume(.failure(CLIError.timeout("Timed out after \(seconds) seconds.")))
        }
    }
}

private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private let continuation: CheckedContinuation<Void, Error>

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<Void, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else {
            return
        }
        didResume = true
        continuation.resume(with: result)
    }
}

private extension String {
    var normalizedCLIPath: String {
        hasPrefix("/") ? self : "/" + self
    }
}

private func printError(_ string: String) {
    FileHandle.standardError.write(Data((string + "\n").utf8))
}

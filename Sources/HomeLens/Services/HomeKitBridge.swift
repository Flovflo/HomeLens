import Darwin
import Foundation

enum HomeKitBridgeState: Equatable {
    case stopped
    case running
    case unavailable(String)

    var title: String {
        switch self {
        case .stopped:
            "Stopped"
        case .running:
            "Running"
        case .unavailable:
            "Native HSV unavailable"
        }
    }

    var detail: String {
        switch self {
        case .stopped:
            "The bridge is stopped."
        case .running:
            "HomeLens is publishing the camera to Apple Home through the minimal local HAP helper."
        case .unavailable(let reason):
            reason
        }
    }
}

@MainActor
final class HomeKitBridge {
    private(set) var state: HomeKitBridgeState = .stopped
    private var process: Process?

    func start(camera: CameraConfig, password: String?, logger: AppLogger) async -> HomeKitBridgeState {
        guard process?.isRunning != true else {
            state = .running
            return state
        }

        guard let cliPath = resolveCLIPath() else {
            let reason = "Could not find homelensctl next to the app build. Build homelensctl first."
            logger.error("HomeKit", reason)
            state = .unavailable(reason)
            return state
        }

        terminateExistingBridgeProcesses(except: nil, logger: logger)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = ["homekit-run"]
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let password, !password.isEmpty {
            environment["HOMELENS_PASSWORD"] = password
        }
        if let helperPath = resolveBundledHelperPath() {
            environment["HOMELENS_HOMEKIT_HELPER"] = helperPath
        }
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak logger] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                for line in text.split(separator: "\n") {
                    logger?.info("HomeKit", String(line))
                }
            }
        }

        do {
            try process.run()
            self.process = process
            logger.info("HomeKit", "Started homelensctl homekit-run pid \(process.processIdentifier).")
            state = .running
        } catch {
            let reason = "Failed to start HomeKit helper: \(error.localizedDescription)"
            logger.error("HomeKit", reason)
            state = .unavailable(reason)
        }
        return state
    }

    func stop(logger: AppLogger) async -> HomeKitBridgeState {
        if let process, process.isRunning {
            process.terminate()
            try? await Task.sleep(nanoseconds: 500_000_000)
            if process.isRunning {
                process.interrupt()
            }
        }
        process = nil
        logger.info("HomeKit", "Bridge supervisor stopped.")
        state = .stopped
        return state
    }

    func forward(event: DetectionEvent, logger: AppLogger) async {
        logger.info("HSVEventTrigger", "\(event.kind.rawValue) \(event.active ? "active" : "inactive") forwarded by homelensctl.")
    }

    private func resolveCLIPath() -> String? {
        var candidates: [String] = []
        if let executableDir = Bundle.main.executableURL?.deletingLastPathComponent().path {
            candidates.append(URL(fileURLWithPath: executableDir).appendingPathComponent("homelensctl").path)
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/homelensctl").path)
        if let env = ProcessInfo.processInfo.environment["HOMELENS_CTL"], !env.isEmpty {
            candidates.append(env)
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func resolveBundledHelperPath() -> String? {
        guard let resources = Bundle.main.resourceURL else {
            return nil
        }
        let path = resources
            .appendingPathComponent("Helpers/HomeKitBridge/src/index.mjs")
            .path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    private func terminateExistingBridgeProcesses(except currentPID: Int32?, logger: AppLogger) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid,ppid,command"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            logger.warning("HomeKit", "Could not inspect running bridge processes: \(error.localizedDescription)")
            return
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return }

        let processes = output.split(separator: "\n").compactMap(ProcessSnapshot.init(line:))
        var pidsToTerminate = Set<Int32>()

        for process in processes {
            if process.isHomeLensBridgeProcess {
                pidsToTerminate.insert(process.pid)
            }
        }

        var added = true
        while added {
            added = false
            for process in processes where pidsToTerminate.contains(process.ppid) && !pidsToTerminate.contains(process.pid) {
                pidsToTerminate.insert(process.pid)
                added = true
            }
        }

        pidsToTerminate.remove(ProcessInfo.processInfo.processIdentifier)
        if let currentPID {
            pidsToTerminate.remove(currentPID)
        }

        for pid in pidsToTerminate.sorted() {
            Darwin.kill(pid, SIGTERM)
        }
        if !pidsToTerminate.isEmpty {
            usleep(300_000)
        }
        for pid in pidsToTerminate.sorted() where Darwin.kill(pid, 0) == 0 {
            Darwin.kill(pid, SIGKILL)
        }
    }
}

private struct ProcessSnapshot {
    let pid: Int32
    let ppid: Int32
    let command: String

    var isHomeLensBridgeProcess: Bool {
        command.contains("/homelensctl homekit-run")
            || command == "homelensctl homekit-run"
            || (command.hasPrefix("node ") && command.contains("HomeKitBridge/src/index.mjs"))
            || (command.contains("/ffmpeg ") && command.contains("h264Preview_01"))
    }

    init?(line: Substring) {
        let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard fields.count == 3,
              let pid = Int32(fields[0]),
              let ppid = Int32(fields[1]) else {
            return nil
        }
        self.pid = pid
        self.ppid = ppid
        self.command = String(fields[2])
    }
}

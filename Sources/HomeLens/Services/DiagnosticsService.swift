import Foundation
import HomeLensCore

/// GUI wrapper around the shared `DiagnosticsRunner`. Streams results into a
/// `@Published` array so the Diagnostic panel lights up progressively.
@MainActor
final class DiagnosticsService: ObservableObject {
    @Published private(set) var results: [DiagnosticResult] = []
    @Published private(set) var isRunning = false
    @Published private(set) var lastRun: Date?

    private let appSupportPath: String

    init() {
        appSupportPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("HomeLens", isDirectory: true).path
    }

    var stages: [DiagnosticResult.Stage] {
        DiagnosticResult.Stage.allCases.filter { stage in results.contains { $0.stage == stage } }
    }

    func results(for stage: DiagnosticResult.Stage) -> [DiagnosticResult] {
        results.filter { $0.stage == stage }
    }

    func run(camera: CameraConfig, password: String?) async {
        guard !isRunning else { return }
        isRunning = true
        results = []

        let core = HomeLensCore.CameraConfig(
            id: camera.id,
            name: camera.name,
            host: camera.host,
            username: camera.username,
            rtspMainPath: camera.rtspMainPath,
            rtspSubPath: camera.rtspSubPath,
            onvifPath: camera.onvifPath,
            onvifPort: camera.onvifPort,
            streamProfile: camera.streamProfile == .main ? .main : .sub,
            passwordStored: camera.passwordStored
        )
        let support = appSupportPath
        let helper = resolveHelperDir()

        let runner = DiagnosticsRunner()
        await runner.run(camera: core, password: password, supportPath: support, helperDir: helper) { result in
            Task { @MainActor in
                self.results.append(result)
            }
        }
        lastRun = Date()
        isRunning = false
    }

    private func resolveHelperDir() -> String? {
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("Helpers/HomeKitBridge")
            if FileManager.default.fileExists(atPath: bundled.appendingPathComponent("src/index.mjs").path) {
                return bundled.path
            }
        }
        let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Helpers/HomeKitBridge")
        return FileManager.default.fileExists(atPath: repo.appendingPathComponent("src/index.mjs").path) ? repo.path : nil
    }
}

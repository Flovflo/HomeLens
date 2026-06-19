import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var cameras: [CameraConfig] = []
    @Published var selectedCameraID: UUID?
    @Published var draftPassword = ""
    @Published var rtspResult: ServiceTestResult?
    @Published var onvifResult: ServiceTestResult?
    @Published var previewFrame: CameraPreviewFrame?
    @Published var previewProfile: CameraPreviewProfile = .sub
    @Published var isPreviewLoading = false
    @Published var previewError: String?
    @Published var importCandidates: [ScryptedImportCandidate] = []
    @Published var feasibilitySummary = FeasibilitySummary.current
    @Published var homeKitStatus = HomeKitStatus()
    @Published var networkInterfaces: [NetworkInterfaceInfo] = []

    let logger = AppLogger()
    let bridge: BridgeController
    let live = LivePlayerService()
    let diagnostics = DiagnosticsService()

    private let store = AppConfigStore()
    private let importer = ScryptedImporter()
    private let rtspManager = RTSPStreamManager()
    private let onvifManager = ONVIFEventManager()
    private let previewService = CameraPreviewService()
    private let statusService = HomeKitStatusService()
    private var didLoad = false

    init() {
        let homeKitBridge = HomeKitBridge()
        bridge = BridgeController(onvifManager: onvifManager, homeKitBridge: homeKitBridge, logger: logger)
    }

    var selectedCamera: CameraConfig? {
        get {
            cameras.first { $0.id == selectedCameraID } ?? cameras.first
        }
        set {
            guard let newValue, let index = cameras.firstIndex(where: { $0.id == newValue.id }) else {
                return
            }
            cameras[index] = newValue
        }
    }

    func load() async {
        guard !didLoad else { return }
        didLoad = true
        do {
            let config = try store.load()
            cameras = config.cameras
            selectedCameraID = cameras.first?.id
            networkInterfaces = NetworkInterfaceService.list()
            refreshHomeKitStatus()
            logger.info("Config", "Loaded \(cameras.count) camera config(s).")
            discoverScrypted()
            // The HomeKit bridge runs independently (launchd `homekit-run`); the GUI
            // only monitors it, so we don't spawn a competing helper here.
            startStatusRefreshTimer()
            await startLive()
        } catch {
            logger.error("Config", "Failed to load config: \(error.localizedDescription)")
            cameras = [CameraConfig()]
            selectedCameraID = cameras.first?.id
        }
    }

    func updateSelected(_ edit: (inout CameraConfig) -> Void) {
        guard var camera = selectedCamera else { return }
        edit(&camera)
        selectedCamera = camera
    }

    func save() async {
        do {
            if let camera = selectedCamera, !draftPassword.isEmpty {
                try store.setPassword(draftPassword, for: camera.id)
                updateSelected { $0.passwordStored = true }
                draftPassword = ""
            }
            try store.save(StoredAppConfig(cameras: cameras))
            logger.info("Config", "Saved configuration.")
        } catch {
            logger.error("Config", "Save failed: \(error.localizedDescription)")
        }
    }

    func testRTSP() async {
        guard let camera = selectedCamera else { return }
        logger.info("RTSP", "Testing RTSP stream \(camera.streamProfile.rawValue) for \(camera.host).")
        let result = await rtspManager.test(camera: camera, password: effectivePassword(for: camera))
        rtspResult = result
        log(result, subsystem: "RTSP")
    }

    func testONVIF() async {
        guard let camera = selectedCamera else { return }
        logger.info("ONVIF", "Testing ONVIF device service at \(camera.host):\(camera.onvifPort).")
        let result = await onvifManager.test(camera: camera, password: effectivePassword(for: camera))
        onvifResult = result
        log(result, subsystem: "ONVIF")
    }

    func refreshPreview(profile: CameraPreviewProfile? = nil) async {
        guard let camera = selectedCamera, !isPreviewLoading else { return }
        let targetProfile = profile ?? previewProfile
        previewProfile = targetProfile
        isPreviewLoading = true
        previewError = nil
        do {
            let frame = try await previewService.snapshot(
                camera: camera,
                password: effectivePassword(for: camera),
                profile: targetProfile
            )
            previewFrame = frame
            logger.info("Preview", "Updated \(targetProfile.title) preview at \(Int(frame.pixelSize.width))x\(Int(frame.pixelSize.height)).")
        } catch {
            previewError = error.localizedDescription
            logger.warning("Preview", error.localizedDescription)
        }
        isPreviewLoading = false
    }

    func startBridge() async {
        guard let camera = selectedCamera else { return }
        await save()
        await bridge.start(camera: camera, password: effectivePassword(for: camera))
        refreshHomeKitStatus()
    }

    func stopBridge() async {
        await bridge.stop()
        refreshHomeKitStatus()
    }

    func startLive(force: Bool = false) async {
        guard let camera = selectedCamera else { return }
        await live.start(camera: camera, password: effectivePassword(for: camera), profile: previewProfile, force: force)
    }

    func stopLive() {
        live.stop()
    }

    func refreshHomeKitStatus() {
        homeKitStatus = statusService.read()
    }

    /// Restart the launchd-managed HomeKit bridge so it re-reads config.json
    /// (e.g. after changing the network interface). The bridge regenerates its
    /// helper config on each launch, so this applies the new settings.
    func restartBridge() async {
        await save()
        let uid = getuid()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "-k", "gui/\(uid)/com.flo.HomeLens"]
        do {
            try process.run()
            process.waitUntilExit()
            logger.info("Bridge", "Pont HomeKit redémarré pour appliquer les réglages.")
        } catch {
            logger.error("Bridge", "Impossible de redémarrer le pont: \(error.localizedDescription)")
        }
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        refreshHomeKitStatus()
    }

    private var statusTask: Task<Void, Never>?
    private func startStatusRefreshTimer() {
        statusTask?.cancel()
        statusTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                self?.refreshHomeKitStatus()
            }
        }
    }

    func runDiagnostics() async {
        guard let camera = selectedCamera else { return }
        await diagnostics.run(camera: camera, password: effectivePassword(for: camera))
        refreshHomeKitStatus()
    }

    func discoverScrypted() {
        importCandidates = importer.discover()
        if importCandidates.isEmpty {
            logger.info("Scrypted", "No importable Scrypted camera metadata found.")
        } else {
            logger.info("Scrypted", "Found \(importCandidates.count) Scrypted import candidate(s).")
        }
    }

    func importCandidate(_ candidate: ScryptedImportCandidate) {
        var camera = candidate.camera
        camera.id = UUID()
        cameras = [camera]
        selectedCameraID = camera.id
        logger.info("Scrypted", candidate.note)
    }

    func exportLogs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "HomeLens-logs.txt"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let text = self?.logger.exportText() else {
                return
            }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                Task { @MainActor in
                    self?.logger.error("Logger", "Export failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func effectivePassword(for camera: CameraConfig) -> String? {
        if !draftPassword.isEmpty {
            return draftPassword
        }
        return store.password(for: camera.id)
    }

    private func log(_ result: ServiceTestResult, subsystem: String) {
        if result.ok {
            logger.info(subsystem, "\(result.title): \(result.detail)")
        } else {
            logger.error(subsystem, "\(result.title): \(result.detail)")
        }
    }
}

struct FeasibilitySummary {
    let possible: [String]
    let blocked: [String]
    let recommendation: String

    static let current = FeasibilitySummary(
        possible: [
            "Native macOS UI, config storage, Keychain secrets, RTSP validation, ONVIF device/event plumbing.",
            "Forwarding ONVIF motion/person state to a HomeKit-like bridge boundary.",
            "Importing visible metadata from a local Scrypted LevelDB store for faster setup."
        ],
        blocked: [
            "Apple's public HomeKit.framework controls homes/accessories; it does not publish a camera accessory.",
            "HomeKit Secure Video camera recording requires HAP/ADK-style services and recording delegates, not a simple public Swift API."
        ],
        recommendation: "Keep this app native and small, but attach a minimal HAP camera helper for real Home app pairing and HSV. That helper can be far smaller than Scrypted and still reuse the proven HomeKit camera protocol approach."
    )
}

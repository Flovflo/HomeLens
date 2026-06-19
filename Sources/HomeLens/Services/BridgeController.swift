import Foundation

@MainActor
final class BridgeController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var homeKitState: HomeKitBridgeState = .stopped
    @Published private(set) var lastDetection: DetectionEvent?

    private let onvifManager: ONVIFEventManager
    private let homeKitBridge: HomeKitBridge
    private let logger: AppLogger

    init(onvifManager: ONVIFEventManager, homeKitBridge: HomeKitBridge, logger: AppLogger) {
        self.onvifManager = onvifManager
        self.homeKitBridge = homeKitBridge
        self.logger = logger
    }

    func start(camera: CameraConfig, password: String?) async {
        guard !isRunning else { return }
        isRunning = true
        logger.info("Bridge", "Starting bridge for \(camera.name) at \(camera.host).")
        homeKitState = await homeKitBridge.start(camera: camera, password: password, logger: logger)
        logger.info("ONVIF", "HomeKit helper owns the ONVIF event subscription for motion/person forwarding.")
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false
        onvifManager.stop()
        homeKitState = await homeKitBridge.stop(logger: logger)
    }
}

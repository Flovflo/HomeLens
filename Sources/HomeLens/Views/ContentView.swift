import HomeLensCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var bridge: BridgeController
    @ObservedObject private var logger: AppLogger
    @ObservedObject private var live: LivePlayerService

    init(model: AppModel) {
        self.model = model
        self._bridge = ObservedObject(wrappedValue: model.bridge)
        self._logger = ObservedObject(wrappedValue: model.logger)
        self._live = ObservedObject(wrappedValue: model.live)
    }

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model, bridge: bridge)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    StatusHeader(model: model, status: model.homeKitStatus)
                    LivePanel(model: model, live: live)
                    InspectorTabs(model: model, logger: logger)
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        Task { await model.startLive(force: true) }
                    } label: {
                        Label("Reconnecter le flux", systemImage: "arrow.clockwise")
                    }
                    Button {
                        Task { await model.runDiagnostics() }
                    } label: {
                        Label("Diagnostic", systemImage: "stethoscope")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .onDisappear { model.stopLive() }
    }
}

private struct Sidebar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var bridge: BridgeController

    var body: some View {
        List(selection: $model.selectedCameraID) {
            Section("Caméras") {
                ForEach(model.cameras) { camera in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(camera.name)
                                .font(.headline)
                            Text(camera.host)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: bridge.isRunning ? "video.fill" : "video")
                            .foregroundStyle(bridge.isRunning ? .green : .secondary)
                    }
                    .tag(camera.id)
                }
            }

            if !model.importCandidates.isEmpty {
                Section("Import Scrypted") {
                    ForEach(model.importCandidates) { candidate in
                        Button(candidate.camera.name) {
                            model.importCandidate(candidate)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            Button {
                model.discoverScrypted()
            } label: {
                Label("Importer", systemImage: "square.and.arrow.down")
            }
        }
    }
}

// MARK: - Status header

private struct StatusHeader: View {
    @ObservedObject var model: AppModel
    let status: HomeKitStatus

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    Image(systemName: "video.badge.waveform.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 54, height: 54)
                        .background(.blue.gradient, in: RoundedRectangle(cornerRadius: 10))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.selectedCamera?.name ?? "HomeLens")
                            .font(.largeTitle.weight(.bold))
                            .lineLimit(1)
                        Text(model.selectedCamera?.host ?? "Aucune caméra")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    StatusPill(
                        title: status.bridgeRunning ? "En ligne" : "Arrêté",
                        icon: status.bridgeRunning ? "checkmark.circle.fill" : "pause.circle",
                        tint: status.bridgeRunning ? .green : .secondary
                    )
                }

                HStack(spacing: 10) {
                    StatusPill(
                        title: status.bridgeRunning ? "Pont actif" : "Pont arrêté",
                        icon: "bonjour",
                        tint: status.bridgeRunning ? .green : .secondary
                    )
                    StatusPill(
                        title: status.isPaired ? "Appairé · \(status.pairedClientCount)" : "Non appairé",
                        icon: status.isPaired ? "person.2.fill" : "person.crop.circle.badge.questionmark",
                        tint: status.isPaired ? .green : .orange
                    )
                    StatusPill(
                        title: status.hsvEnabled ? "HSV activé" : "HSV désactivé",
                        icon: status.hsvEnabled ? "record.circle.fill" : "record.circle",
                        tint: status.hsvEnabled ? .red : .secondary
                    )
                    StatusPill(
                        title: status.liveAudioEnabled ? "Audio live" : "Audio coupé",
                        icon: status.liveAudioEnabled ? "speaker.wave.2.fill" : "speaker.slash",
                        tint: status.liveAudioEnabled ? .blue : .secondary
                    )
                    Spacer()
                }

                if !status.isPaired {
                    HStack(spacing: 10) {
                        Image(systemName: "homekit")
                            .foregroundStyle(.blue)
                        Text("Ajoute l’accessoire dans l’app Maison avec le code")
                            .foregroundStyle(.secondary)
                        Text(status.pin ?? "031-45-154")
                            .font(.system(.body, design: .monospaced).weight(.bold))
                            .textSelection(.enabled)
                    }
                    .font(.callout)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}

// MARK: - Live preview

private struct LivePanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var live: LivePlayerService

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Label("Aperçu en direct", systemImage: "dot.radiowaves.left.and.right")
                        .font(.title2.weight(.semibold))

                    Spacer()

                    Picker("Source", selection: $model.previewProfile) {
                        ForEach(CameraPreviewProfile.allCases) { profile in
                            Text(profile.title).tag(profile)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                    .labelsHidden()
                    .onChange(of: model.previewProfile) {
                        Task { await model.startLive(force: true) }
                    }

                    Button {
                        live.setMuted(!live.isMuted)
                    } label: {
                        Image(systemName: live.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    .help(live.isMuted ? "Activer le son" : "Couper le son")
                }

                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.black)

                    LivePlayerView(service: live)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    overlay
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)

                HStack {
                    Label(captionText, systemImage: captionIcon)
                    Spacer()
                    Text(model.previewProfile == .sub ? "Flux sub · faible latence" : "Flux principal · pleine qualité")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var overlay: some View {
        switch live.status {
        case .starting:
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.large)
                Text("Connexion au flux…")
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        case .failed(let message):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.orange)
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Reconnecter") {
                    Task { await model.startLive(force: true) }
                }
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        case .idle, .playing:
            EmptyView()
        }
    }

    private var captionText: String {
        switch live.status {
        case .playing: "En direct"
        case .starting: "Démarrage…"
        case .failed: "Flux interrompu"
        case .idle: "Inactif"
        }
    }

    private var captionIcon: String {
        switch live.status {
        case .playing: "livephoto"
        case .starting: "hourglass"
        case .failed: "wifi.exclamationmark"
        case .idle: "pause"
        }
    }
}

// MARK: - Inspector tabs

private struct InspectorTabs: View {
    @ObservedObject var model: AppModel
    @ObservedObject var logger: AppLogger
    @State private var tab: Tab = .diagnostic

    enum Tab: String, CaseIterable, Identifiable {
        case diagnostic = "Diagnostic"
        case settings = "Réglages"
        case streaming = "Streaming"
        case logs = "Journaux"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 460)

            switch tab {
            case .diagnostic:
                DiagnosticsPanel(model: model, diagnostics: model.diagnostics)
            case .settings:
                CameraSettings(model: model)
            case .streaming:
                StreamPolicy(camera: model.selectedCamera)
            case .logs:
                LogsPanel(model: model, logger: logger)
            }
        }
    }
}

// MARK: - Diagnostics (mode debug)

private struct DiagnosticsPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var diagnostics: DiagnosticsService

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Label("Diagnostic de la chaîne", systemImage: "stethoscope")
                        .font(.title3.weight(.semibold))
                    if diagnostics.isRunning {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    summaryBadges
                    Button {
                        Task { await model.runDiagnostics() }
                    } label: {
                        Label(diagnostics.isRunning ? "Analyse…" : "Lancer le diagnostic", systemImage: "play.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(diagnostics.isRunning)
                }

                if diagnostics.results.isEmpty && !diagnostics.isRunning {
                    Text("Lance le diagnostic pour vérifier toute la chaîne : caméra → relai HomeLens → réseau/Apple → app Maison. Tu verras tout de suite où ça coince.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    ForEach(diagnostics.stages, id: \.self) { stage in
                        DiagnosticStageView(stage: stage, results: diagnostics.results(for: stage))
                    }
                }
            }
        }
        .task {
            if diagnostics.results.isEmpty { await model.runDiagnostics() }
        }
    }

    private var summaryBadges: some View {
        let counts = Dictionary(grouping: diagnostics.results, by: { $0.status }).mapValues(\.count)
        return HStack(spacing: 8) {
            if let fail = counts[.fail], fail > 0 {
                CountBadge(count: fail, tint: .red, icon: "xmark.octagon.fill")
            }
            if let warn = counts[.warn], warn > 0 {
                CountBadge(count: warn, tint: .orange, icon: "exclamationmark.triangle.fill")
            }
            if let ok = counts[.ok], ok > 0 {
                CountBadge(count: ok, tint: .green, icon: "checkmark.circle.fill")
            }
        }
    }
}

private struct CountBadge: View {
    let count: Int
    let tint: Color
    let icon: String

    var body: some View {
        Label("\(count)", systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

private struct DiagnosticStageView: View {
    let stage: DiagnosticResult.Stage
    let results: [DiagnosticResult]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(stage.rawValue.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            ForEach(results) { result in
                DiagnosticRow(result: result)
            }
        }
    }
}

private struct DiagnosticRow: View {
    let result: DiagnosticResult

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(result.title)
                    .font(.subheadline.weight(.medium))
                Text(result.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if result.durationMs > 0 {
                Text("\(result.durationMs) ms")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
        .background(tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    private var icon: String {
        switch result.status {
        case .ok: "checkmark.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .fail: "xmark.octagon.fill"
        case .info: "info.circle"
        }
    }

    private var tint: Color {
        switch result.status {
        case .ok: .green
        case .warn: .orange
        case .fail: .red
        case .info: .secondary
        }
    }
}

private struct StreamPolicy: View {
    let camera: CameraConfig?

    var body: some View {
        GlassPanel {
            HStack(alignment: .top, spacing: 16) {
                Label("Streaming adaptatif", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.title3.weight(.semibold))
                    .frame(width: 210, alignment: .leading)

                PolicyColumn(title: "Aperçu rapide", value: "Flux sub", detail: "360p · faible latence")
                PolicyColumn(title: "Live HomeKit", value: "Flux main", detail: "jusqu’à 4K + audio")
                PolicyColumn(title: "Enregistrement", value: "HSV", detail: "fMP4 + audio AAC")
                PolicyColumn(title: "Chemins", value: camera?.rtspMainPath ?? "/h264Preview_01_main", detail: camera?.rtspSubPath ?? "/h264Preview_01_sub")
            }
        }
    }
}

private struct CameraSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                Label("Réglages caméra", systemImage: "slider.horizontal.3")
                    .font(.title3.weight(.semibold))

                if let camera = model.selectedCamera {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                        GridRow {
                            FieldTitle("Nom")
                            TextField("Front Door", text: binding(for: camera.name) { $0.name = $1 })
                        }
                        GridRow {
                            FieldTitle("IP")
                            TextField("192.168.0.6", text: binding(for: camera.host) { $0.host = $1 })
                        }
                        GridRow {
                            FieldTitle("Utilisateur")
                            TextField("admin", text: binding(for: camera.username) { $0.username = $1 })
                        }
                        GridRow {
                            FieldTitle("Mot de passe")
                            SecureField(camera.passwordStored ? "Stored in Keychain" : "Not stored", text: $model.draftPassword)
                        }
                        GridRow {
                            FieldTitle("RTSP main")
                            TextField("/h264Preview_01_main", text: binding(for: camera.rtspMainPath) { $0.rtspMainPath = $1 })
                                .font(.system(.body, design: .monospaced))
                        }
                        GridRow {
                            FieldTitle("RTSP sub")
                            TextField("/h264Preview_01_sub", text: binding(for: camera.rtspSubPath) { $0.rtspSubPath = $1 })
                                .font(.system(.body, design: .monospaced))
                        }
                        GridRow {
                            FieldTitle("ONVIF")
                            HStack(spacing: 8) {
                                TextField("/onvif/device_service", text: binding(for: camera.onvifPath) { $0.onvifPath = $1 })
                                    .font(.system(.body, design: .monospaced))
                                Stepper(value: binding(for: camera.onvifPort) { $0.onvifPort = $1 }, in: 1...65535) {
                                    Text("\(camera.onvifPort)")
                                        .monospacedDigit()
                                        .frame(width: 58, alignment: .trailing)
                                }
                            }
                        }
                        GridRow {
                            FieldTitle("Carte réseau")
                            Picker("", selection: networkBinding) {
                                Text("Automatique").tag(String?.none)
                                ForEach(model.networkInterfaces) { iface in
                                    Text(iface.label).tag(String?.some(iface.name))
                                }
                            }
                            .labelsHidden()
                        }
                    }

                    Text("« Automatique » choisit l’interface qui atteint Apple Home. Fixe-la seulement si ton Mac a plusieurs cartes réseau. Changer la carte redémarre le pont.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)

                    HStack {
                        Button {
                            Task {
                                await model.testRTSP()
                                await model.testONVIF()
                            }
                        } label: {
                            Label("Tester la caméra", systemImage: "checklist")
                        }
                        Spacer()
                        Button {
                            Task {
                                await model.save()
                                await model.startLive()
                            }
                        } label: {
                            Label("Enregistrer", systemImage: "externaldrive")
                        }
                        Button {
                            Task { await model.restartBridge() }
                        } label: {
                            Label("Appliquer au pont", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private func binding<Value>(for value: Value, set: @escaping (inout CameraConfig, Value) -> Void) -> Binding<Value> {
        Binding {
            value
        } set: { newValue in
            model.updateSelected { camera in
                set(&camera, newValue)
            }
        }
    }

    private var networkBinding: Binding<String?> {
        Binding {
            model.selectedCamera?.networkInterface
        } set: { newValue in
            model.updateSelected { $0.networkInterface = newValue }
        }
    }
}

private struct LogsPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var logger: AppLogger

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Journaux", systemImage: "list.bullet.rectangle")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Button {
                        model.exportLogs()
                    } label: {
                        Label("Exporter", systemImage: "square.and.arrow.up")
                    }
                }

                List(logger.events.reversed()) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(event.timestamp, style: .time)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 72, alignment: .leading)
                        Text(event.level.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(color(for: event.level))
                            .frame(width: 64, alignment: .leading)
                        Text(event.subsystem)
                            .foregroundStyle(.secondary)
                            .frame(width: 104, alignment: .leading)
                        Text(event.message)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    .font(.caption)
                }
                .frame(minHeight: 240)
            }
        }
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .debug: .secondary
        case .info: .blue
        case .warning: .orange
        case .error: .red
        }
    }
}

// MARK: - Reusable pieces

private struct GlassPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            }
    }
}

private struct PolicyColumn: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FieldTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(width: 110, alignment: .leading)
    }
}

private struct StatusPill: View {
    let title: String
    let icon: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: icon)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
    }
}

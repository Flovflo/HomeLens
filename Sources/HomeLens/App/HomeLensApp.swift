import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Reliable startup: fire load() from the app lifecycle rather than relying
        // solely on a SwiftUI view `.task`, which may not run when the window is
        // launched without focus (launchd / `open` from a non-foreground context).
        Task { @MainActor in
            await AppModel.shared.load()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        true
    }
}

@main
struct HomeLensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup("HomeLens", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 1220, minHeight: 820)
                .task {
                    await model.load()
                }
        }
        .defaultSize(width: 1320, height: 880)

        MenuBarExtra {
            MenuBarView(model: model)
                .task {
                    await model.load()
                }
        } label: {
            Image(systemName: model.homeKitStatus.bridgeRunning ? "video.fill" : "video")
        }
    }
}

private struct MenuBarView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    init(model: AppModel) {
        self.model = model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("HomeLens", systemImage: model.homeKitStatus.bridgeRunning ? "checkmark.circle.fill" : "pause.circle")
                .foregroundStyle(model.homeKitStatus.bridgeRunning ? .green : .secondary)
            Text(model.homeKitStatus.bridgeRunning ? "Pont HomeKit actif" : "Pont HomeKit arrêté")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Button("Ouvrir HomeLens") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
                for window in NSApp.windows {
                    window.makeKeyAndOrderFront(nil)
                }
            }

            Button("Lancer le diagnostic") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
                Task { await model.runDiagnostics() }
            }

            Divider()

            Button("Quitter") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(.vertical, 6)
        .frame(width: 220)
    }
}

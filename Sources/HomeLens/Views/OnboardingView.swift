import SwiftUI

/// Guided first-run setup so anyone with a Reolink camera can go from a fresh
/// install to a working Apple Home accessory without touching the Terminal:
/// enter the camera → test → the app installs its own background service →
/// pair in the Home app.
struct OnboardingView: View {
    @ObservedObject var model: AppModel

    enum Step { case welcome, camera, activating, pairing }

    @State private var step: Step = .welcome
    @State private var host = ""
    @State private var username = "admin"
    @State private var password = ""
    @State private var profile: CameraConfig.StreamProfile = .main
    @State private var testResult: ServiceTestResult?
    @State private var testing = false
    @State private var errorText: String?

    private var canContinue: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.09, green: 0.11, blue: 0.18), Color(red: 0.05, green: 0.06, blue: 0.10)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                content
                    .frame(maxWidth: 560)
                    .padding(40)
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: welcomeStep
        case .camera: cameraStep
        case .activating: activatingStep
        case .pairing: pairingStep
        }
    }

    // MARK: - Welcome

    private var welcomeStep: some View {
        VStack(spacing: 24) {
            Image(systemName: "video.fill.badge.checkmark")
                .font(.system(size: 64))
                .foregroundStyle(.white, .blue)
            Text("Bienvenue dans HomeLens")
                .font(.system(size: 30, weight: .bold))
            Text("Ajoutez votre caméra Reolink à l'app Maison d'Apple — vidéo en direct avec audio et HomeKit Secure Video. Tout est inclus, rien d'autre à installer.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 12) {
                bullet("camera.fill", "Vous entrez l'adresse et le mot de passe de la caméra")
                bullet("gearshape.2.fill", "HomeLens installe son service en arrière-plan tout seul")
                bullet("homekit", "Vous appairez dans l'app Maison — c'est prêt")
            }
            .padding(.vertical, 8)
            primaryButton("Commencer") { step = .camera }
        }
    }

    // MARK: - Camera

    private var cameraStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            header("Votre caméra", "Réglages réseau Reolink (visibles dans l'app Reolink › Réglages › Réseau › Informations).")

            VStack(spacing: 14) {
                field("Adresse IP", systemImage: "network") {
                    TextField("192.168.1.x", text: $host)
                        .textFieldStyle(.plain)
                }
                field("Nom d'utilisateur", systemImage: "person.fill") {
                    TextField("admin", text: $username)
                        .textFieldStyle(.plain)
                }
                field("Mot de passe", systemImage: "key.fill") {
                    SecureField("Mot de passe de la caméra", text: $password)
                        .textFieldStyle(.plain)
                }
                field("Flux", systemImage: "rectangle.3.group.fill") {
                    Picker("", selection: $profile) {
                        Text("Principal (qualité maximale, jusqu'à 4K)").tag(CameraConfig.StreamProfile.main)
                        Text("Secondaire (léger)").tag(CameraConfig.StreamProfile.sub)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }

            if let testResult {
                Label(testResult.detail, systemImage: testResult.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(testResult.ok ? .green : .orange)
                    .font(.callout)
            }
            if let errorText {
                Label(errorText, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Button {
                    Task { await runTest() }
                } label: {
                    HStack(spacing: 6) {
                        if testing { ProgressView().controlSize(.small) }
                        Text(testing ? "Test en cours…" : "Tester la connexion")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!canContinue || testing)

                Spacer()

                Button("Continuer") {
                    errorText = nil
                    step = .activating
                    Task { await activate() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canContinue)
            }
        }
    }

    // MARK: - Activating

    private var activatingStep: some View {
        VStack(spacing: 24) {
            ProgressView().controlSize(.large)
            Text("Activation du service HomeLens…")
                .font(.title2.weight(.semibold))
            Text("Enregistrement de la configuration, démarrage du pont HomeKit en arrière-plan et connexion à la caméra.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Pairing

    private var pairingStep: some View {
        VStack(spacing: 22) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("Service actif ✓")
                .font(.system(size: 26, weight: .bold))
            Text("Dernière étape : appairer dans l'app Maison sur votre iPhone ou iPad.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 6) {
                Text("Code d'appairage HomeKit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(model.homeKitStatus.pin ?? "031-45-154")
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 24).padding(.vertical, 12)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }

            VStack(alignment: .leading, spacing: 10) {
                step("1.", "Ouvrez l'app **Maison** › **+** › **Ajouter un accessoire**.")
                step("2.", "Touchez **Plus d'options…** — « HomeLens » apparaît.")
                step("3.", "Saisissez le code ci-dessus pour appairer.")
                step("4.", "Activez **Diffuser et autoriser l'enregistrement** pour HomeKit Secure Video.")
            }
            .padding(16)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))

            primaryButton("Terminer") { model.showOnboarding = false }
        }
    }

    // MARK: - Actions

    private func runTest() async {
        testing = true
        testResult = nil
        testResult = await model.testConnection(host: host, username: username, password: password, profile: profile)
        testing = false
    }

    private func activate() async {
        do {
            try await model.finishOnboarding(host: host, username: username, password: password, profile: profile, name: "Front Door")
            step = .pairing
        } catch {
            errorText = error.localizedDescription
            step = .camera
        }
    }

    // MARK: - Building blocks

    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(.blue).frame(width: 26)
            Text(text).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func step(_ n: String, _ markdown: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(n).font(.callout.weight(.bold)).foregroundStyle(.blue)
            Text((try? AttributedString(markdown: markdown)) ?? AttributedString(markdown))
                .font(.callout)
            Spacer(minLength: 0)
        }
    }

    private func header(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 24, weight: .bold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func field<Content: View>(_ label: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption2).foregroundStyle(.secondary)
                content()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}

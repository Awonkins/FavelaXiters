import SwiftUI
import UIKit

@main
struct ThreeOneOSFiveApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var patchDraftCoordinator = PatchDraftCoordinator()
    @StateObject private var fileOperationCoordinator = FileOperationCoordinator()
    @StateObject private var patchStore = PatchProjectStore()
    @StateObject private var repositoryStore = PackageRepositoryStore()
    @StateObject private var fvSession = FVSession()
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.english.rawValue
    @State private var showOnboarding = OnboardingStore.shouldShow()
    @State private var showAttribution = false
    @State private var updateOffer: AppUpdateChecker.Offer?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init() {
        setupLogCapture()
        log("app: Favela launching — iOS \(AppInfo.osVersion) (\(AppInfo.osBuild)) \(AppInfo.machineName)")
    }

    private var language: AppLanguage {
        AppLanguage(rawValue: languageCode) ?? .english
    }

    private func checkForUpdate() {
        Task {
            guard let offer = await AppUpdateChecker.check() else { return }
            await MainActor.run { updateOffer = offer }
        }
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environmentObject(appState)
                    .environmentObject(patchDraftCoordinator)
                    .environmentObject(fileOperationCoordinator)
                    .environmentObject(patchStore)
                    .environmentObject(repositoryStore)
                    .environment(\.appLanguage, language)
                    .environment(\.locale, language.locale)
                    .opacity(showOnboarding ? 0 : 1)
                    .allowsHitTesting(!showOnboarding)

                if showOnboarding {
                    OnboardingView {
                        OnboardingStore.markCompleted()
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
                            showOnboarding = false
                        }
                        appState.detectSupport()
                        checkForUpdate()
                    }
                    .environment(\.appLanguage, language)
                    .environment(\.locale, language.locale)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .scale(scale: 0.98))
                    )
                    .zIndex(1)
                }

                if !fvSession.hidden {
                    FavelaGateView(session: fvSession)
                        .transition(.opacity)
                        .zIndex(2)
                    .environmentObject(patchDraftCoordinator)
                }
            }
            .displayIdentityAttribution(isPresented: $showAttribution, enabled: !showOnboarding)
            .sheet(isPresented: $showAttribution) {
                DisplayAttributionSheet()
            }
            .alert(item: $updateOffer) { offer in
                Alert(
                    title: Text(language.text("update.title")),
                    message: Text(language.text("update.message", offer.version)),
                    primaryButton: .default(Text(language.text("update.agree"))) {
                        UIApplication.shared.open(offer.url)
                    },
                    secondaryButton: .cancel(Text(language.text("update.dismiss"))) {
                        AppUpdateChecker.dismiss(version: offer.version)
                    }
                )
            }
            .onAppear {
                if !showOnboarding {
                    appState.detectSupport()
                    checkForUpdate()
                }
            }
            .onChange(of: scenePhase) { phase in
                guard phase == .active, !showOnboarding else { return }
                appState.detectSupport()
            }
            .onOpenURL { url in
                patchDraftCoordinator.presentImport(url)
            }
        }
    }
}

class AppState: ObservableObject {
    @Published var exploitStatus: ExploitStatus = .notStarted
    @Published var unsupportedMessage: String?
    @Published var kernelExploitRunning = false

    private var autoRunAttempted = false

    var kernelExploitApplicable: Bool {
        KernelExploit.isApplicable(
            major: AppInfo.versionTuple.major,
            minor: AppInfo.versionTuple.minor,
            patch: AppInfo.versionTuple.patch,
            build: AppInfo.osBuild
        )
    }

    var isSupported: Bool { unsupportedMessage == nil }

    func detectSupport() {
        let v = AppInfo.versionTuple
        let supported = ExploitSupportPolicy.isSupported(
            major: v.major,
            minor: v.minor,
            patch: v.patch,
            build: AppInfo.osBuild
        )
#if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--simulate-access") {
            exploitStatus = .success(method: "Simulator preview")
        }
#endif

        unsupportedMessage = supported ? nil : "iOS \(AppInfo.osVersion) (\(AppInfo.osBuild))"
        if let unsupportedMessage {
            exploitStatus = .unsupported(unsupportedMessage)
            return
        }

        let applicable = KernelExploit.isApplicable(
            major: v.major,
            minor: v.minor,
            patch: v.patch,
            build: AppInfo.osBuild
        )
        guard applicable else { return }

        refreshKernelExploitStatus()
        maybeAutoRunKernelExploit()
    }

    private func maybeAutoRunKernelExploit() {
        guard !kernelExploitRunning,
              !exploitStatus.isSuccess,
              !exploitStatus.isFailed,
              !autoRunAttempted else { return }
        autoRunAttempted = true
        log("app: starting kernel exploit automatically")
        runKernelExploitIfNeeded()
    }

    private func refreshKernelExploitStatus() {
        guard !kernelExploitRunning else { return }

        if KernelExploit.requiresSandboxEscape {
            if KernelExploit.hasSandboxAccess() {
                if !exploitStatus.isSuccess {
                    exploitStatus = .success(method: "kexploit")
                    log("app: existing sandbox access is still active; skipping kernel exploit")
                }
            } else if exploitStatus.isSuccess {
                exploitStatus = .notStarted
                log("app: sandbox access is no longer active")
            }
        }
    }

    func runKernelExploitIfNeeded() {
        refreshKernelExploitStatus()
        guard !kernelExploitRunning,
              !exploitStatus.isSuccess,
              !exploitStatus.isFailed else { return }
        kernelExploitRunning = true
        exploitStatus = .notStarted
        log("app: running kernel exploit on background...")
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = KernelExploit.run()
            DispatchQueue.main.async {
                self.kernelExploitRunning = false
                if ok {
                    self.exploitStatus = .success(method: "kexploit")
                    if KernelExploit.requiresSandboxEscape {
                        log("app: kernel exploit success — sandbox access verified")
                    } else {
                        log("app: kernel exploit success — kernel access active")
                    }
                } else {
                    self.exploitStatus = .failed(method: "kexploit", code: -1)
                    log("app: kernel exploit failed — relaunch the app before retrying")
                }
            }
        }
    }
}

// MARK: - Favela

enum FV {
    static let base = "https://vzfhzfqljnlirvibobwz.supabase.co"
    static let anon = "sb_publishable_X9vaC--1NEQjTtCe6ktc3Q_IiOTkDH8"
    static let raw = "https://raw.githubusercontent.com/Awonkins/FavelaXiters/main/"
    static let bgA = "Imagenes/file_00000000ac4c820ea5a677232b5941a5.png"
    static let bgB = "Imagenes/file_00000000c620820e83e609257c806f7e.png"
    static var device: String { UIDevice.current.identifierForVendor?.uuidString ?? "ios" }
}

enum FVGame: String, CaseIterable, Identifiable {
    case ff, ffmax
    var id: String { rawValue }
    var title: String { self == .ff ? "FREE FIRE" : "FREE FIRE MAX" }
    var sub: String { self == .ff ? "VERSIÓN NORMAL" : "VERSIÓN MAX" }
    var folder: String { self == .ff ? "Patches/ff/" : "Patches/ffmax/" }
}

struct FVPatch: Identifiable {
    let id = UUID()
    let label: String
    let file: String
}

enum FVData {
    static let aim = ["Pecho", "Cuello", "Cabeza", "Drag", "Balas Mágicas"]
    static let catNames = ["AIMBOT SIN ANTENA", "AIMBOT CON ANTENA", "HOLO ARM", "HOLO PJ"]

    static func items(_ g: FVGame, _ cat: Int) -> [FVPatch] {
        switch (g, cat) {
        case (.ff, 0):
            let f = ["AIMBOT PECHO SIN ANTENA.txt", "CUELLO SIN ANTENA.txt", "AIMBOT CABEZA SIN ANTENA.txt", "AIMBOT DRAG SIN ANTENA.txt", "AVATAR BALAS MAGICAS SIN ANTENA.txt"]
            return zip(aim, f).map { FVPatch(label: "AIMBOT " + $0.0.uppercased(), file: $0.1) }
        case (.ff, 1):
            let f = ["PECHO CON ANTENA FFTH.txt", "CUELLO CON ANTENA FF NORMAL.txt", "CABEZA CON ANTENA FF NORMAL.txt", "DRAG CON ANTENA FF NORMAL.txt", "BALA MAGICA CON ANTENA.txt"]
            return zip(aim, f).map { FVPatch(label: "AIMBOT " + $0.0.uppercased(), file: $0.1) }
        case (.ff, 2):
            return [FVPatch(label: "HOLO ARM RTX VERDE", file: "RTX FFTH VERDE.txt"),
                    FVPatch(label: "HOLO ARM ROJO X TURQUESA", file: "ROJO X TURQUESA BORDES.txt")]
        case (.ff, 3):
            return [FVPatch(label: "HOLO PJ ROSA", file: "PJ ROSA ROBOTICO FFTH.txt")]
        case (.ffmax, 0):
            let f = ["PECHO FF MAX SIN ANTENA.txt", "CUELLO FREE FIRE MAX SIN ANTENA.txt", "CABEZA FF MAX SIN ANTENA.txt", "DRAG FF MAX SIN ANTENA.txt", "BALA MAGICA FF MAX.txt"]
            return zip(aim, f).map { FVPatch(label: "AIMBOT " + $0.0.uppercased(), file: $0.1) }
        case (.ffmax, 1):
            let f = ["PECHO ANTENA FFMAX.txt", "AIMBOT CUELLO ANTENA FFMAX.txt", "AIMBOT CABEZA FFMAX.txt", "AIM DRAG ANTENA FFMAX.txt", "BALAS MAGICAS ANTENA FFMAX.txt"]
            return zip(aim, f).map { FVPatch(label: "AIMBOT " + $0.0.uppercased(), file: $0.1) }
        case (.ffmax, 2):
            return [FVPatch(label: "HOLO ARM BLANCO X CIAN", file: "CIAN X BLANCO FFMAX.txt"),
                    FVPatch(label: "HOLO ARM AMARILLO", file: "HOLO ARM AMARILLO FREE MAX .txt")]
        default:
            return [FVPatch(label: "HOLO PJ ROJO", file: "ROBOTICO ROJO PJ FFMAX.txt")]
        }
    }
}

enum FVStorage {
    static func dir() -> URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Patches", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static func url(_ file: String) -> URL {
        dir().appendingPathComponent((file as NSString).deletingPathExtension + ".3105")
    }
    static func remote(_ g: FVGame, _ file: String) -> URL? {
        let enc = file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file
        return URL(string: FV.raw + g.folder + enc)
    }
}

enum FVError: LocalizedError {
    case msg(String)
    var errorDescription: String? { if case let .msg(m) = self { return m }; return nil }
}

final class FVSession: ObservableObject {
    @Published var unlocked: Bool
    @Published var hidden = false

    init() {
        let saved = UserDefaults.standard.string(forKey: "fv_key")
        let when = UserDefaults.standard.double(forKey: "fv_when")
        unlocked = saved != nil && (Date().timeIntervalSince1970 - when) < 12 * 3600
    }

    func save(_ k: String) {
        UserDefaults.standard.set(k, forKey: "fv_key")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "fv_when")
        unlocked = true
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: "fv_key")
        UserDefaults.standard.removeObject(forKey: "fv_when")
        unlocked = false
    }
}

enum FVAPI {
    static func hdrs() -> [String: String] {
        ["apikey": FV.anon, "Content-Type": "application/json"]
    }

    static func validar(_ raw: String) async throws {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.hasPrefix("FLV-"), code.count >= 12 else { throw FVError.msg("Formato inválido") }

        var c = URLComponents(string: FV.base + "/rest/v1/keys")!
        c.queryItems = [URLQueryItem(name: "code", value: "eq.\(code)"),
                        URLQueryItem(name: "select", value: "*")]
        var req = URLRequest(url: c.url!)
        hdrs().forEach { req.setValue($1, forHTTPHeaderField: $0) }

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let row = rows.first else { throw FVError.msg("Key inexistente") }

        let status = row["status"] as? String ?? "activa"
        if status == "baneada" { throw FVError.msg("Key baneada") }
        if status == "pausada" { throw FVError.msg("Key pausada") }

        if let exp = row["expires_at"] as? String,
           let d = ISO8601DateFormatter().date(from: exp), d < Date() {
            throw FVError.msg("Key vencida")
        }

        let dev = row["device_id"] as? String
        let blk = row["blocked_device"] as? String

        if let dev, !dev.isEmpty {
            if dev != FV.device { throw FVError.msg("Key en uso en otro dispositivo") }
        } else {
            if let blk, blk == FV.device { throw FVError.msg("Key reseteada en este dispositivo") }
            try await bind(code)
        }
    }

    static func bind(_ code: String) async throws {
        var c = URLComponents(string: FV.base + "/rest/v1/keys")!
        c.queryItems = [URLQueryItem(name: "code", value: "eq.\(code)")]
        var req = URLRequest(url: c.url!)
        req.httpMethod = "PATCH"
        hdrs().forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "device_id": FV.device,
            "activated_at": ISO8601DateFormatter().string(from: Date())
        ])
        _ = try await URLSession.shared.data(for: req)
    }
}

final class FVImages: ObservableObject {
    static let shared = FVImages()
    @Published var bg: UIImage?

    func load() async {
        guard bg == nil else { return }
        var tall: UIImage?
        for path in [FV.bgA, FV.bgB] {
            guard let u = URL(string: FV.raw + path) else { continue }
            if let (d, _) = try? await URLSession.shared.data(from: u),
               let img = UIImage(data: d), img.size.height > img.size.width {
                tall = img
            }
        }
        if let t = tall { await MainActor.run { self.bg = t } }
    }
}

struct FVBackground: View {
    @ObservedObject private var imgs = FVImages.shared

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(red: 0.02, green: 0.03, blue: 0.06)
                if let bg = imgs.bg {
                    Image(uiImage: bg)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
                LinearGradient(
                    colors: [.black.opacity(0.35), .black.opacity(0.72), .black.opacity(0.94)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .ignoresSafeArea()
        .task { await imgs.load() }
    }
}

struct FavelaGateView: View {
    @ObservedObject var session: FVSession
    @State private var game: FVGame?

    var body: some View {
        ZStack {
            FVBackground()
            if !session.unlocked {
                FVKeyScreen(session: session)
            } else if let g = game {
                FVPatchScreen(game: g, session: session) { game = nil }
            } else {
                FVGameScreen(session: session) { game = $0 }
            }
        }
        .ignoresSafeArea()
    }
}

struct FVKeyScreen: View {
    @ObservedObject var session: FVSession
    @State private var code = ""
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 96)
            Text("Favela")
                .font(.system(size: 44, weight: .bold, design: .serif))
                .italic()
                .foregroundColor(.white)
            Text("2026")
                .font(.system(size: 11, weight: .bold))
                .tracking(6)
                .foregroundColor(.white.opacity(0.6))
                .padding(.top, 6)

            Spacer().frame(height: 40)

            VStack(alignment: .leading, spacing: 10) {
                Text("ACCESO")
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(2)
                    .foregroundColor(Color(red: 0.37, green: 0.85, blue: 1))

                Text("Ingresá tu key")
                    .font(.system(size: 27, weight: .black))
                    .foregroundColor(.white)

                Text("Una key por dispositivo. La primera vez necesita internet, después funciona hasta 12 horas sin conexión.")
                    .font(.system(size: 12.5))
                    .foregroundColor(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Text("FLV-")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundColor(Color(red: 0.37, green: 0.85, blue: 1))
                    TextField("XXXXXXXX", text: $code)
                        .font(.system(size: 15, weight: .bold))
                        .tracking(3)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .foregroundColor(.white)
                }
                .padding(15)
                .background(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Color(red: 0.37, green: 0.85, blue: 1).opacity(0.35), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 18))

                if let error {
                    Text(error)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(red: 1, green: 0.48, blue: 0.54))
                }

                Button {
                    entrar()
                } label: {
                    HStack {
                        if loading { ProgressView().tint(.black) }
                        Text(loading ? "VERIFICANDO" : "INGRESAR")
                            .font(.system(size: 12.5, weight: .black))
                            .tracking(1.6)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(16)
                    .background(LinearGradient(colors: [Color(red: 0, green: 0.88, blue: 1), Color(red: 0.3, green: 0.49, blue: 1)], startPoint: .leading, endPoint: .trailing))
                    .foregroundColor(Color(red: 0.01, green: 0.07, blue: 0.11))
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                }
                .disabled(loading)

                Text("Favela Software")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(2)
                    .foregroundColor(.white.opacity(0.3))
                    .padding(.top, 24)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func entrar() {
        var clean = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !clean.isEmpty else {
            error = "Ingresá una key"
            return
        }
        if !clean.hasPrefix("FLV-") { clean = "FLV-" + clean }
        error = nil
        loading = true
        Task {
            do {
                try await FVAPI.validar(clean)
                await MainActor.run {
                    session.save(clean)
                    loading = false
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    loading = false
                }
            }
        }
    }
}
struct FVRemoteImage: View {
    let path: String
    @State private var img: UIImage?

    var body: some View {
        ZStack {
            Color.white.opacity(0.06)
            if let img {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            }
        }
        .clipped()
        .task {
            guard img == nil,
                  let u = URL(string: FV.raw + path),
                  let (d, _) = try? await URLSession.shared.data(from: u),
                  let loaded = UIImage(data: d) else { return }
            img = loaded
        }
    }
}
struct FVGameScreen: View {
    @ObservedObject var session: FVSession
    let onPick: (FVGame) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 92)
            Text("ELEGÍ EL JUEGO")
                .font(.system(size: 10, weight: .heavy))
                .tracking(3)
                .foregroundColor(Color(red: 0.37, green: 0.85, blue: 1))
            Text("¿Dónde vas a aplicar?")
                .font(.system(size: 24, weight: .black))
                .foregroundColor(.white)
                .padding(.top, 8)

            HStack(spacing: 14) {
                card(.ff)
                card(.ffmax)
            }
            .padding(.horizontal, 20)
            .padding(.top, 30)

            Spacer()

            Button {
                session.clear()
            } label: {
                Text("CERRAR SESIÓN")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(2)
                    .foregroundColor(.white.opacity(0.55))
            }
            .padding(.bottom, 34)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func card(_ g: FVGame) -> some View {
        Button {
            onPick(g)
        } label: {
            VStack(spacing: 12) {
                FVRemoteImage(path: g == .ff ? "Imagenes/Ff.png" : "Imagenes/Ffmax.png")
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )
                Text(g.title)
                    .font(.system(size: 12, weight: .black))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                Text(g.sub)
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1)
                    .foregroundColor(.white.opacity(0.4))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .background(Color.white.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 26)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 26))
        }
    }
}

struct FVPatchScreen: View {
    let game: FVGame
    @ObservedObject var session: FVSession
    let onBack: () -> Void

    @EnvironmentObject private var drafts: PatchDraftCoordinator
    @State private var cat = 0
    @State private var active: Set<String> = []
    @State private var busy: String?
    @State private var msg: String?

    private var items: [FVPatch] { FVData.items(game, cat) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            tabs
            ScrollView(showsIndicators: false) {
                VStack(spacing: 9) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, p in
                        row(idx + 1, p)
                    }
                    infoBox
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 44)
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { onBack() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(game.title)
                    .font(.system(size: 13, weight: .black))
                    .foregroundColor(.white)
                Text("PARCHES")
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(2)
                    .foregroundColor(Color(red: 0.37, green: 0.85, blue: 1))
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 58)
        .padding(.bottom, 12)
    }

    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(FVData.catNames.enumerated()), id: \.offset) { i, n in
                    Button { cat = i } label: {
                        Text(n)
                            .font(.system(size: 9.5, weight: .heavy))
                            .foregroundColor(cat == i ? .black : .white.opacity(0.6))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(cat == i ? Color(red: 0.37, green: 0.85, blue: 1) : Color.white.opacity(0.07))
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 4)
    }

    private func row(_ n: Int, _ p: FVPatch) -> some View {
        let on = active.contains(p.id.uuidString)
        return HStack(spacing: 12) {
            Text("\(n)")
                .font(.system(size: 11, weight: .black))
                .foregroundColor(.black)
                .frame(width: 22, height: 22)
                .background(Color.white.opacity(0.85))
                .clipShape(Circle())
            Text(p.label)
                .font(.system(size: 11.5, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(2)
            Spacer()
            if busy == p.id.uuidString {
                ProgressView().tint(.white)
            } else {
                Button { toggle(p) } label: {
                    Text(on ? "ON" : "OFF")
                        .font(.system(size: 10, weight: .black))
                        .foregroundColor(on ? .black : .white.opacity(0.7))
                        .frame(width: 44, height: 26)
                        .background(on ? Color(red: 0.35, green: 0.95, blue: 0.55) : Color.white.opacity(0.1))
                        .clipShape(Capsule())
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(Color.white.opacity(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var infoBox: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("CÓMO SE USA")
                .font(.system(size: 9.5, weight: .heavy))
                .tracking(2)
                .foregroundColor(Color(red: 0.37, green: 0.85, blue: 1))
            Text("1. Abrí el juego y salí en el 40% sin cerrarlo.\n2. Volvé acá y activá el parche.\n3. Elegí el contenedor del juego.\n4. Volvé al lobby y desactivá el parche.")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            if let msg {
                Text(msg)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(red: 0.37, green: 0.85, blue: 1))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.top, 8)
    }

    private func toggle(_ p: FVPatch) {
        let key = p.id.uuidString
        if active.contains(key) {
            active.remove(key)
            msg = "\(p.label) desactivado"
            return
        }
        guard let remote = FVStorage.remote(game, p.file) else { return }
        busy = key
        msg = nil
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: remote)
                try data.write(to: FVStorage.url(p.file))
                await MainActor.run {
                    busy = nil
                    active.insert(key)
                    msg = "\(p.label) descargado"
                    drafts.presentImport(FVStorage.url(p.file))
                }
            } catch {
                await MainActor.run {
                    busy = nil
                    msg = "Error al descargar"
                }
            }
        }
    }
}

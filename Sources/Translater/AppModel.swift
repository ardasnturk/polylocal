import AppKit
import Engines
import ModelManager
import Observation
import SystemIntegration
import TranslaterCore

/// Wires the pieces together: settings → engine, shortcuts → capture → popup.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let settings = AppSettings()
    let store = ModelStore(catalog: ModelStore.bundledCatalog())
    let engine = EngineController()
    let mainTranslator: TranslatorModel
    private(set) var accessibilityTrusted = Permissions.isAccessibilityTrusted
    private(set) var ollamaModels: [String]?

    @ObservationIgnored private let hotkeys = HotkeyMonitor()
    @ObservationIgnored private(set) lazy var popup = PopupController(app: self)
    @ObservationIgnored private(set) lazy var windows = WindowManager(app: self)
    @ObservationIgnored private var permissionTimer: Timer?

    private init() {
        mainTranslator = TranslatorModel(settings: settings, engine: engine)
    }

    private(set) var hotkeysRunning = false

    var hotkeysActive: Bool { hotkeysRunning && settings.hotkeysEnabled }

    func start() {
        hotkeys.onTrigger = { [weak self] trigger in
            Task { await self?.handle(trigger) }
        }
        watchAccessibility()
        Task {
            await refreshOllama()
            chooseDefaultEngineIfNeeded()
            applyEngine()
        }
        if !settings.hasCompletedOnboarding {
            windows.showOnboarding()
        }
    }

    func shutdown() {
        engine.shutdown()
    }

    func applyEngine() {
        engine.configure(settings: settings, store: store)
    }

    func refreshOllama() async {
        ollamaModels = await Ollama.installedModels()
    }

    func requestAccessibility() {
        Permissions.requestAccessibility()
        Permissions.openAccessibilitySettings()
    }

    /// First launch: prefer an already-installed built-in model, then an Ollama model, so it works without a download.
    private func chooseDefaultEngineIfNeeded() {
        guard settings.builtInModelID == nil, settings.ollamaModel == nil else { return }
        if let installed = store.installedModels.first {
            settings.engineKind = .builtIn
            settings.builtInModelID = installed.id
        } else if let models = ollamaModels, let pick = Self.preferredOllamaModel(models) {
            settings.engineKind = .ollama
            settings.ollamaModel = pick
        } else {
            settings.engineKind = .builtIn
            settings.builtInModelID = CatalogModel.recommended(from: store.catalog, ramGB: Hardware.memoryGB)?.id
        }
    }

    static func preferredOllamaModel(_ models: [String]) -> String? {
        models.first { $0.hasPrefix("gemma4") } ?? models.first { $0.hasPrefix("translategemma") } ?? models.first
    }

    private func watchAccessibility() {
        checkAccessibility()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAccessibility() }
        }
    }

    private func checkAccessibility() {
        accessibilityTrusted = Permissions.isAccessibilityTrusted
        if accessibilityTrusted, !hotkeys.isRunning { hotkeys.start() }
        hotkeysRunning = hotkeys.isRunning
    }

    private func handle(_ trigger: HotkeyMonitor.Trigger) async {
        guard settings.hotkeysEnabled else { return }
        // ⌘C+C inside our own windows is just copying.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return
        }
        guard let captured = await TextCapture.captureSelection(
            pasteboardChangeCount: trigger.pasteboardChangeCount,
            allowSimulatedCopy: trigger.action == .replace)
        else {
            Log.capture.notice("capture app=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?", privacy: .public) action=\(String(describing: trigger.action), privacy: .public) result=none")
            NSSound.beep()
            return
        }
        // Never log the text itself.
        Log.capture.notice("""
            capture app=\(captured.bundleID ?? "?", privacy: .public) action=\(String(describing: trigger.action), privacy: .public) \
            via=\(captured.source.rawValue, privacy: .public) role=\(captured.role ?? "-", privacy: .public) \
            replaceable=\(captured.isReplaceable, privacy: .public) rect=\(captured.selectionRect != nil, privacy: .public)
            """)
        popup.show(captured, mode: trigger.action == .replace ? .replace : .translate)
    }
}

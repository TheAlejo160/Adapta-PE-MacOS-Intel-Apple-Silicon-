import Combine
import SwiftUI
import AppKit
import ServiceManagement
import CoreServices
import AVFoundation
import Speech

@main
struct Adapta_PEApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared
    @ObservedObject private var textos = Textos.shared
    var body: some Scene {
        Window("Adapta PE", id: "settings") {
            ContentView(model: model)
                .background(WindowReference { model.attachSettingsWindow($0) })
        }
        .defaultSize(width: 620, height: 670)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(textos.t("menu.detenerModulos")) { model.stopAll() }.keyboardShortcut(".", modifiers: [.command, .shift])
                Button(textos.t("menu.mostrarFlotante")) { model.showFloating() }
            }
        }
        MenuBarExtra("Adapta PE", systemImage: "figure.roll") {
            Button(textos.t("menu.abrirAjustes")) { model.showSettings() }
            Button(textos.t("menu.tutorial")) { model.showTutorial() }
            Button(model.floatingVisible ? textos.t("menu.ocultarFlotante") : textos.t("menu.mostrarFlotante")) { model.floatingVisible ? model.hideFloating() : model.showFloating() }
            Divider()
            Button(model.tracker.isTracking ? textos.t("menu.apagarCursor") : textos.t("menu.activarCursor")) { model.toggleTracking() }
            Button(model.voice.isListening ? textos.t("menu.apagarVoz") : textos.t("menu.activarVoz")) { model.toggleVoice() }
            Button(model.tracker.isPaused ? textos.t("menu.reanudarCursor") : textos.t("menu.pausarCursor")) { model.tracker.isPaused.toggle() }
            Button(textos.t("menu.detenerTodo")) { model.stopAll() }
            Divider()
            Button(textos.t("menu.salir")) { model.stopAll(remember: false); NSApp.terminate(nil) }.keyboardShortcut("q")
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    let tracker = TrackingManager()
    let voice = VoiceManager()
    let talkBack = TalkBackManager()
    let colorFilter = ColorFilterManager()
    let mascot = MascotManager()
    let actions = ActionManager.shared
    let ai = OptionalAI.shared
    @Published var floatingVisible = false { didSet { UserDefaults.standard.set(floatingVisible, forKey: "FloatingVisible") } }
    @Published var floatingCorner = PanelCorner(rawValue: UserDefaults.standard.string(forKey: "FloatingCorner") ?? "") ?? .lowerRight {
        didSet { UserDefaults.standard.set(floatingCorner.rawValue, forKey: "FloatingCorner"); UserDefaults.standard.set(false, forKey: "FloatingFree"); positionFloating() }
    }
    @Published var floatingScreenID = UserDefaults.standard.string(forKey: "FloatingScreenID") ?? "" {
        didSet { UserDefaults.standard.set(floatingScreenID, forKey: "FloatingScreenID"); positionFloating() }
    }
    @Published var previewVisible = UserDefaults.standard.object(forKey: "PanelPreview") as? Bool ?? true {
        didSet { UserDefaults.standard.set(previewVisible, forKey: "PanelPreview"); positionFloating() }
    }
    @Published var controlScale: ControlScale = {
        let saved = UserDefaults.standard.double(forKey: "ControlScale")
        if saved == 1.25 { return .medium }
        if saved == 1.5 { return .large }
        return .normal
    }() {
        didSet {
            UserDefaults.standard.set(controlScale.rawValue, forKey: "ControlScale")
            positionFloating()
        }
    }
    @Published var accessibilityGranted = AXIsProcessTrusted()
    @Published var screenGranted = CGPreflightScreenCaptureAccess()
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var notice = ""
    @Published var screens = NSScreen.screens
    var settingsWindow: NSWindow? { didSet { settingsWindow?.level = colorFilter.selected == .ninguno ? .normal : .statusBar } }
    private var tutorialWindow: NSWindow?
    private var floatingPanel: NSPanel?
    private(set) var launchedAtLogin = false
    private var settingsRequested = false
    private var filterObserver: AnyCancellable?
    private var stateObservers: [AnyCancellable] = []
    private var suspending = false
    private var observers: [NSObjectProtocol] = []
    private var resumeCamera = false
    private var resumeVoice = false
    private var resumeTalkBack = false
    private var resumeFilter: ColorFilter = .ninguno

    private init() {
        mascot.layoutChanged = { [weak self] in self?.positionFloating() }
        mascot.movePanel = { [weak self] in self?.moveFloating($0) }
        mascot.savePanel = { [weak self] in self?.saveFloatingPosition() }
        mascot.nextPanelScreen = { [weak self] in self?.nextFloatingScreen() }
        tracker.fetchCameras(); voice.fetchMics(); ApplicationCatalog.shared.prewarm()
        Publishers.MergeMany(tracker.$isTracking.map { _ in () }.eraseToAnyPublisher(), tracker.$isPaused.map { _ in () }.eraseToAnyPublisher(), voice.$isListening.map { _ in () }.eraseToAnyPublisher(), voice.$isStarting.map { _ in () }.eraseToAnyPublisher(), tracker.$isStarting.map { _ in () }.eraseToAnyPublisher()).sink { [weak self] in self?.objectWillChange.send() }.store(in: &stateObservers)
        talkBack.$isEnabled.dropFirst().sink { [weak self] enabled in if self?.suspending == false { UserDefaults.standard.set(enabled, forKey: "TalkBackActive") } }.store(in: &stateObservers)
        filterObserver = colorFilter.$selected.sink { [weak self] selected in self?.settingsWindow?.level = selected == .ninguno ? .normal : .statusBar }
        actions.kineticAction = { [weak self] in self?.tracker.action($0) }
        actions.speechReading = { [weak self] in self?.mascot.react("idle"); self?.mascot.prepareSpeech(reading: $0) }
        actions.speechOutput = { [weak self] active, failed in self?.voice.setSpeechOutput(active, failed: failed); self?.mascot.speaking(active) }
        actions.appAction = { [weak self] in self?.appAction($0) }
        actions.targetsSelf = { [weak self] in self?.tutorialWindow?.isKeyWindow == true }
        // Los títulos de ventana también siguen el idioma elegido en vivo.
        Textos.shared.$currentLanguage.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            self?.tutorialWindow?.title = Textos.t("tutorial.tituloVentana"); self?.floatingPanel?.title = Textos.t("panel.tituloVentana")
        }.store(in: &stateObservers)
        actions.onResult = { [weak self] result in
            switch result {
            case .ok: self?.mascot.happy()
            case .unknown, .failure: self?.mascot.confused()
            case .confirming: break
            }
        }
        voice.onWake = { [weak self] in self?.actions.callar(); self?.mascot.react("phone") }
        voice.executeCommand = { [weak self] text, done in
            self?.actions.execute(text) { result in
                switch result {
                case .ok: self?.mascot.happy()
                case .unknown, .failure: self?.mascot.confused()
                case .confirming: break
                }
                done(result)
            }
        }
        // Sin nombre: elecciones abiertas; durante una confirmación, sólo «confirmo …» o cancelar.
        voice.followUpAllowed = { [weak self] in self?.actions.hasChoices == true }
        voice.confirmationAllowed = { [weak self] in self?.actions.hasConfirmation == true }
        voice.onConversationClose = { [weak self] in self?.actions.cancelPendingActions(); self?.actions.callar() }
        actions.showFeedback = { [weak self] in self?.showFloating() }
        Publishers.CombineLatest(actions.$choices, actions.$confirmationPhrase).sink { [weak self] choices, phrase in self?.positionFloating(choiceCount: max(choices.count, phrase.isEmpty ? 0 : 3)) }.store(in: &stateObservers)
        Publishers.CombineLatest(tracker.$isTracking, tracker.$isStarting).sink { [weak self] tracking, starting in
            self?.positionFloating(cameraVisible: tracking || starting)
        }.store(in: &stateObservers)
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            Task { @MainActor [weak self] in guard let self, self.voice.isListening || self.tracker.isTracking || self.tracker.isStarting else { return }; self.showFloating(hideSettings: false) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            Task { @MainActor [weak self] in guard let self, window === self.settingsWindow, self.voice.isListening || self.tracker.isTracking || self.tracker.isStarting else { return }; self.showFloating(hideSettings: false) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.screens = NSScreen.screens; self?.positionFloating() }
        })
        colorFilter.$selected.dropFirst().sink { [weak self] selected in if self?.suspending == false { UserDefaults.standard.set(selected.rawValue, forKey: "ActiveColorFilter") } }.store(in: &stateObservers)
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshPermissions() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.resumeCamera = self.tracker.isTracking; self.resumeVoice = self.voice.isListening
                self.resumeTalkBack = self.talkBack.isEnabled; self.resumeFilter = self.colorFilter.selected
                self.stopAll(remember: false)
            }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshPermissions(); self.mascot.suspend(false)
                if self.resumeCamera { self.tracker.startTracking() }
                if self.resumeVoice { self.voice.startListening() }
                self.talkBack.isEnabled = self.resumeTalkBack
                if self.resumeFilter != .ninguno { self.colorFilter.apply(self.resumeFilter) }
                self.resumeCamera = false; self.resumeVoice = false; self.resumeTalkBack = false; self.resumeFilter = .ninguno
            }
        })
    }
    func refreshPermissions() {
        accessibilityGranted = AXIsProcessTrusted(); screenGranted = CGPreflightScreenCaptureAccess()
        tracker.fetchCameras(); voice.fetchMics(); ApplicationCatalog.shared.prewarm(); loginEnabled = SMAppService.mainApp.status == .enabled
        if !accessibilityGranted { tracker.stopTracking(remember: false); suspending = true; talkBack.isEnabled = false; suspending = false }
    }
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
        if !accessibilityGranted { openPrivacy("Accessibility") }
    }
    func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_" + pane) { NSWorkspace.shared.open(url) }
    }
    func toggleTracking() { mascot.react("laptop"); tracker.isTracking || tracker.isStarting ? tracker.stopTracking() : tracker.startTracking() }
    func toggleVoice() { mascot.react("phone"); voice.isListening || voice.isStarting ? voice.stopListening() : voice.startListening() }
    func stopAll(remember: Bool = true) {
        mascot.react("idle"); if !remember { mascot.suspend(true) }
        suspending = !remember
        actions.cancelPendingActions(); tracker.stopTracking(remember: remember); voice.stopListening(remember: remember)
        talkBack.isEnabled = false; colorFilter.stop(); ai.cancel(); actions.callar(); DesktopAccess.shared.cancelSelection()
        suspending = false
    }
    func restoreSession() {
        guard NSClassFromString("XCTestCase") == nil, !ProcessInfo.processInfo.arguments.contains("--uitesting") else { return }
        let defaults = UserDefaults.standard
        mascot.choose(defaults.string(forKey: "Mascot") ?? "ninguna")
        // Restaurar sólo accesos ya autorizados; nunca abrir permisos durante el inicio de sesión.
        if defaults.bool(forKey: "CameraActive"), AXIsProcessTrusted(), AVCaptureDevice.authorizationStatus(for: .video) == .authorized { tracker.startTracking() }
        if defaults.bool(forKey: "VoiceActive"), AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, SFSpeechRecognizer.authorizationStatus() == .authorized { voice.startListening() }
        if defaults.bool(forKey: "TalkBackActive"), AXIsProcessTrusted() { talkBack.isEnabled = true }
        if CGPreflightScreenCaptureAccess(), let filter = ColorFilter(rawValue: defaults.string(forKey: "ActiveColorFilter") ?? "ninguno"), filter != .ninguno { colorFilter.apply(filter) }
        if defaults.bool(forKey: "FloatingVisible") { showFloating() }
        if !defaults.bool(forKey: "TutorialVisto") { showTutorial() }
    }
    func setLogin(_ enabled: Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; loginEnabled = SMAppService.mainApp.status == .enabled; notice = "" }
        catch { notice = "No se pudo cambiar el inicio de sesión: \(error.localizedDescription)"; loginEnabled = SMAppService.mainApp.status == .enabled }
    }
    func attachSettingsWindow(_ window: NSWindow) {
        settingsWindow = window
        if launchedAtLogin && !settingsRequested { window.orderOut(nil) }
    }
    func prepareLaunch(_ event: NSAppleEventDescriptor?) {
        launchedAtLogin = Self.isLoginLaunch(event)
    }
    static func isLoginLaunch(_ event: NSAppleEventDescriptor?) -> Bool {
        event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
            || event?.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem) != nil
    }
    func showSettings() {
        settingsRequested = true
        hideFloating()
        settingsWindow?.level = colorFilter.selected == .ninguno ? .normal : .statusBar
        settingsWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func showTutorial() {
        if tutorialWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 680, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = Textos.t("tutorial.tituloVentana")
            window.minSize = NSSize(width: 580, height: 600)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: OnboardingView(model: self, isBase: true, onClose: { [weak self] in
                self?.tutorialWindow?.orderOut(nil)
            }))
            window.center()
            tutorialWindow = window
        }
        tutorialWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func showFloating(hideSettings: Bool = true) {
        if floatingScreenID.isEmpty, let screen = NSScreen.main ?? screens.first { floatingScreenID = Self.screenID(screen) }
        if floatingPanel == nil {
            let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = Textos.t("panel.tituloVentana")
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]; panel.isMovable = false; panel.isMovableByWindowBackground = false
            panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: FloatingView(model: self))
            floatingPanel = panel
        }
        floatingVisible = true
        positionFloating(); floatingPanel?.orderFrontRegardless()
        if hideSettings { settingsWindow?.orderOut(nil) }
    }
    static func screenID(_ screen: NSScreen) -> String { (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? "" }
    private func positionFloating(choiceCount: Int? = nil, cameraVisible: Bool? = nil) {
        guard let panel = floatingPanel, let screen = screens.first(where: { Self.screenID($0) == floatingScreenID }) ?? screens.first else { return }
        let count = choiceCount ?? max(actions.choices.count, actions.hasConfirmation ? 3 : 0)
        let camera = previewVisible && (cameraVisible ?? (tracker.isTracking || tracker.isStarting))
        let scale = CGFloat(controlScale.rawValue)
        let choices: CGFloat = count == 0 ? 312 : CGFloat(312 + count * 44 + 48)
        let cameraHeight: CGFloat = camera ? 188 : 0
        let baseWidth = round(320 * scale)
        let baseHeight = round((choices + cameraHeight) * scale)
        let size = CGSize(width: baseWidth, height: baseHeight)
        let defaults = UserDefaults.standard
        let free = defaults.bool(forKey: "FloatingFree") ? CGPoint(x: defaults.double(forKey: "FloatingX"), y: defaults.double(forKey: "FloatingY")) : nil
        let frame = floatingCorner.frame(size: size, visible: screen.visibleFrame, free: free, reservedHeight: mascot.linked && mascot.name != "ninguna" ? 164 : 0)
        panel.setFrame(frame, display: true)
        mascot.attach(to: floatingVisible ? frame : nil)
    }
    func moveFloating(_ delta: CGPoint) {
        guard let panel = floatingPanel else { return }
        let point = CGPoint(x: panel.frame.minX + delta.x, y: panel.frame.minY + delta.y)
        let dragging = NSApp.currentEvent?.type != .keyDown
        guard let screen = (dragging ? screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) : panel.screen) ?? panel.screen else { return }
        let visible = screen.visibleFrame, reserved: CGFloat = mascot.linked && mascot.name != "ninguna" ? 164 : 0
        let origin = CGPoint(x: max(visible.minX, min(visible.maxX - panel.frame.width, point.x)), y: max(visible.minY, min(visible.maxY - reserved - panel.frame.height, point.y)))
        panel.setFrameOrigin(origin); mascot.attach(to: panel.frame)
    }
    func saveFloatingPosition() {
        guard let panel = floatingPanel, let screen = panel.screen else { return }
        let visible = screen.visibleFrame, reserved: CGFloat = mascot.linked && mascot.name != "ninguna" ? 164 : 0
        let defaults = UserDefaults.standard
        defaults.set((panel.frame.minX - visible.minX) / max(1, visible.width - panel.frame.width), forKey: "FloatingX")
        defaults.set((panel.frame.minY - visible.minY) / max(1, visible.height - reserved - panel.frame.height), forKey: "FloatingY")
        defaults.set(true, forKey: "FloatingFree")
        floatingScreenID = Self.screenID(screen)
    }
    func nextFloatingScreen() {
        guard screens.count > 1 else { notice = Textos.t("panel.soloUnaPantalla"); return }
        let index = screens.firstIndex(where: { Self.screenID($0) == floatingScreenID }) ?? 0
        floatingScreenID = Self.screenID(screens[(index + 1) % screens.count])
    }
    func hideFloating() { floatingVisible = false; floatingPanel?.orderOut(nil); mascot.attach(to: nil) }
    private func appAction(_ command: String) {
        mascot.react("laptop")
        if command.hasPrefix("mascota:") {
            let value = String(command.dropFirst(8))
            if MascotManager.names.contains(value) { mascot.choose(value) } else { mascot.gesture(value) }
            actions.hablar(mascot.status); return
        }
        switch command {
        case "mostrar ajustes", "abrir adapta", "mostrar adapta": showSettings()
        case "tutorial", "abrir tutorial", "mostrar tutorial": showTutorial()
        case "modo flotante": showFloating()
        case "ocultar adapta": hideFloating(); settingsWindow?.orderOut(nil)
        case "detener todo": stopAll()
        case "desactivar voz": voice.stopListening()
        case "activar talkback": talkBack.isEnabled = true
        case "desactivar talkback": talkBack.isEnabled = false
        default:
            if command.hasPrefix("filtro:"), let filter = ColorFilter(rawValue: String(command.dropFirst(7))) { colorFilter.apply(filter) }
            if command.hasPrefix("esquina:"), let corner = PanelCorner.allCases.first(where: { CommandParser.normalize($0.title) == String(command.dropFirst(8)) }) { floatingCorner = corner; showFloating(hideSettings: false) }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        AppModel.shared.prepareLaunch(NSAppleEventManager.shared().currentAppleEvent)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.restoreSession()
        guard AppModel.shared.launchedAtLogin else { return }
        DispatchQueue.main.async { AppModel.shared.settingsWindow?.orderOut(nil) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { AppModel.shared.showSettings(); return true }
    func applicationWillTerminate(_ notification: Notification) { AppModel.shared.stopAll(remember: false) }
}

struct WindowReference: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView { let view = NSView(); DispatchQueue.main.async { if let window = view.window { window.isReleasedWhenClosed = false; window.level = .normal; onWindow(window) } }; return view }
    func updateNSView(_ view: NSView, context: Context) { DispatchQueue.main.async { if let window = view.window { onWindow(window) } } }
}

private final class FloatingPanel: NSPanel { override var canBecomeKey: Bool { true } }

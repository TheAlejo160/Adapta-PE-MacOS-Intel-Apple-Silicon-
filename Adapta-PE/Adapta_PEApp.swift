import Combine
import SwiftUI
import AppKit
import ServiceManagement
import CoreServices
import AVFoundation
import Speech

enum PanelCorner: String, CaseIterable {
    case upperLeft, upperRight, lowerLeft, lowerRight
    var title: String {
        switch self {
        case .upperLeft: return "Superior izquierda"
        case .upperRight: return "Superior derecha"
        case .lowerLeft: return "Inferior izquierda"
        case .lowerRight: return "Inferior derecha"
        }
    }
    func frame(size: CGSize, visible: CGRect) -> CGRect {
        let margin: CGFloat = 16
        let width = min(size.width, max(1, visible.width - margin * 2))
        let height = min(size.height, max(1, visible.height - margin * 2))
        let left = self == .upperLeft || self == .lowerLeft
        let upper = self == .upperLeft || self == .upperRight
        return CGRect(x: left ? visible.minX + margin : visible.maxX - margin - width,
                      y: upper ? visible.maxY - margin - height : visible.minY + margin,
                      width: width, height: height)
    }
}

@main
struct Adapta_PEApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared
    var body: some Scene {
        Window("Adapta PE", id: "settings") {
            ContentView(model: model)
                .background(WindowReference { model.attachSettingsWindow($0) })
        }
        .defaultSize(width: 620, height: 670)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Detener todos los módulos") { model.stopAll() }.keyboardShortcut(".", modifiers: [.command, .shift])
                Button("Mostrar panel flotante") { model.showFloating() }
            }
        }
        MenuBarExtra("Adapta PE", systemImage: "figure.roll") {
            Button("Abrir ajustes") { model.showSettings() }
            Button(model.floatingVisible ? "Ocultar panel flotante" : "Mostrar panel flotante") { model.floatingVisible ? model.hideFloating() : model.showFloating() }
            Divider()
            Button(model.tracker.isTracking ? "Apagar cursor" : "Activar cursor") { model.toggleTracking() }
            Button(model.voice.isListening ? "Apagar voz" : "Activar voz") { model.toggleVoice() }
            Button(model.tracker.isPaused ? "Reanudar cursor" : "Pausar cursor") { model.tracker.isPaused.toggle() }
            Button("Detener todo") { model.stopAll() }
            Divider()
            Button("Salir de Adapta PE") { model.stopAll(remember: false); NSApp.terminate(nil) }.keyboardShortcut("q")
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
    let actions = ActionManager.shared
    let ai = OptionalAI.shared
    @Published var floatingVisible = false { didSet { UserDefaults.standard.set(floatingVisible, forKey: "FloatingVisible") } }
    @Published var floatingCorner = PanelCorner(rawValue: UserDefaults.standard.string(forKey: "FloatingCorner") ?? "") ?? .lowerRight {
        didSet { UserDefaults.standard.set(floatingCorner.rawValue, forKey: "FloatingCorner"); positionFloating() }
    }
    @Published var floatingScreenID = UserDefaults.standard.string(forKey: "FloatingScreenID") ?? "" {
        didSet { UserDefaults.standard.set(floatingScreenID, forKey: "FloatingScreenID"); positionFloating() }
    }
    @Published var accessibilityGranted = AXIsProcessTrusted()
    @Published var screenGranted = CGPreflightScreenCaptureAccess()
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var notice = ""
    @Published var screens = NSScreen.screens
    var settingsWindow: NSWindow? { didSet { settingsWindow?.level = colorFilter.selected == .ninguno ? .normal : .statusBar } }
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
        tracker.fetchCameras(); voice.fetchMics()
        Publishers.MergeMany(tracker.$isTracking.map { _ in () }.eraseToAnyPublisher(), tracker.$isPaused.map { _ in () }.eraseToAnyPublisher(), voice.$isListening.map { _ in () }.eraseToAnyPublisher(), voice.$isStarting.map { _ in () }.eraseToAnyPublisher(), tracker.$isStarting.map { _ in () }.eraseToAnyPublisher()).sink { [weak self] in self?.objectWillChange.send() }.store(in: &stateObservers)
        talkBack.$isEnabled.dropFirst().sink { [weak self] enabled in if self?.suspending == false { UserDefaults.standard.set(enabled, forKey: "TalkBackActive") } }.store(in: &stateObservers)
        filterObserver = colorFilter.$selected.sink { [weak self] selected in self?.settingsWindow?.level = selected == .ninguno ? .normal : .statusBar }
        actions.kineticAction = { [weak self] in self?.tracker.action($0) }
        actions.speechOutput = { [weak self] in self?.voice.setSpeechOutput($0) }
        actions.appAction = { [weak self] in self?.appAction($0) }
        voice.onWake = { [weak self] in self?.actions.callar() }
        voice.onCommand = { [weak self] in self?.actions.procesarIntencion($0) }
        voice.followUpAllowed = { [weak self] in self?.actions.hasChoices == true }
        actions.showFeedback = { [weak self] in self?.showFloating() }
        actions.$choices.sink { [weak self] choices in self?.positionFloating(choiceCount: choices.count) }.store(in: &stateObservers)
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
                self.refreshPermissions()
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
        tracker.fetchCameras(); voice.fetchMics(); loginEnabled = SMAppService.mainApp.status == .enabled
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
    func toggleTracking() { tracker.isTracking || tracker.isStarting ? tracker.stopTracking() : tracker.startTracking() }
    func toggleVoice() { voice.isListening || voice.isStarting ? voice.stopListening() : voice.startListening() }
    func stopAll(remember: Bool = true) {
        suspending = !remember
        actions.cancelPendingActions(); tracker.stopTracking(remember: remember); voice.stopListening(remember: remember)
        talkBack.isEnabled = false; colorFilter.stop(); ai.cancel(); actions.callar(); DesktopAccess.shared.cancelSelection()
        suspending = false
    }
    func restoreSession() {
        guard NSClassFromString("XCTestCase") == nil, !ProcessInfo.processInfo.arguments.contains("--uitesting") else { return }
        let defaults = UserDefaults.standard
        // Restaurar sólo accesos ya autorizados; nunca abrir permisos durante el inicio de sesión.
        if defaults.bool(forKey: "CameraActive"), AXIsProcessTrusted(), AVCaptureDevice.authorizationStatus(for: .video) == .authorized { tracker.startTracking() }
        if defaults.bool(forKey: "VoiceActive"), AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, SFSpeechRecognizer.authorizationStatus() == .authorized { voice.startListening() }
        if defaults.bool(forKey: "TalkBackActive"), AXIsProcessTrusted() { talkBack.isEnabled = true }
        if CGPreflightScreenCaptureAccess(), let filter = ColorFilter(rawValue: defaults.string(forKey: "ActiveColorFilter") ?? "ninguno"), filter != .ninguno { colorFilter.apply(filter) }
        if defaults.bool(forKey: "FloatingVisible") { showFloating() }
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
    func showFloating(hideSettings: Bool = true) {
        if floatingScreenID.isEmpty, let screen = NSScreen.main ?? screens.first { floatingScreenID = Self.screenID(screen) }
        if floatingPanel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; panel.isMovable = false; panel.isMovableByWindowBackground = false
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
        let count = choiceCount ?? actions.choices.count
        let camera = cameraVisible ?? (tracker.isTracking || tracker.isStarting)
        let size = CGSize(width: 320, height: (count == 0 ? 240 : 240 + count * 44 + 48) + (camera ? 188 : 0))
        panel.setFrame(floatingCorner.frame(size: size, visible: screen.visibleFrame), display: true)
    }
    func hideFloating() { floatingVisible = false; floatingPanel?.orderOut(nil) }
    private func appAction(_ command: String) {
        switch command {
        case "mostrar ajustes", "abrir adapta", "mostrar adapta": showSettings()
        case "modo flotante": showFloating()
        case "ocultar adapta": hideFloating(); settingsWindow?.orderOut(nil)
        case "detener todo": stopAll()
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

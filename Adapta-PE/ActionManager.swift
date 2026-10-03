import Foundation
import AppKit
import CoreGraphics
import AVFoundation
import Combine

final class ActionManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = ActionManager()
    @Published private(set) var lastResponse = "Listo para ayudarte"
    @Published private(set) var choices: [String] = []
    @Published private(set) var choiceContext = ""
    private var prompt: ChoicePrompt?
    private var choiceHandler: ((Int) -> Void)?
    private var choiceTimeout: DispatchWorkItem?
    private var choicePID: pid_t?
    var hasChoices: Bool { prompt.map { ProcessInfo.processInfo.systemUptime < $0.expiresAt } ?? false }
    var showFeedback: (() -> Void)?
    let synthesizer = AVSpeechSynthesizer()
    var kineticAction: ((String) -> Void)?
    var speechOutput: ((Bool) -> Void)?
    var appAction: ((String) -> Void)?
    private let scriptQueue = DispatchQueue(label: "pe.adapta.scripts", qos: .userInitiated)
    private var lastExternalApp: NSRunningApplication?
    private var appObserver: NSObjectProtocol?
    private let actionLock = NSLock()
    private var generation = 0
    private var activeProcess: Process?
    private var speechWatchdog: DispatchWorkItem?
    private var currentUtterance: AVSpeechUtterance?
    private var actionGeneration: Int { actionLock.withLock { generation } }
    func cancelPendingActions() {
        cancelChoices()
        let process = actionLock.withLock { generation += 1; let old = activeProcess; activeProcess = nil; return old }
        if let process, process.isRunning { process.terminate() }
    }
    func cancelChoices() { choiceTimeout?.cancel(); choiceTimeout = nil; prompt = nil; choiceHandler = nil; choices = []; choicePID = nil; choiceContext = "" }
    func presentChoices(_ labels: [String], completion: @escaping (Int) -> Void) {
        cancelChoices()
        choices = labels; prompt = ChoicePrompt(labels: labels, expiresAt: ProcessInfo.processInfo.systemUptime + 45); choiceHandler = completion
        choicePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        choiceContext = NSWorkspace.shared.frontmostApplication?.localizedName ?? "la aplicación activa"
        showFeedback?()
        hablar(labels.enumerated().map { "\($0.offset + 1): \(String(($0.element.components(separatedBy: " > ").last ?? $0.element).prefix(50)))" }.joined(separator: ". ") + ". Di el número, siguiente o cancelar.")
        let work = DispatchWorkItem { [weak self] in guard let self, self.prompt != nil else { return }; self.cancelChoices(); self.lastResponse = "Elección cancelada por tiempo de espera" }
        choiceTimeout = work; DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: work)
    }
    func choose(_ answer: String) {
        guard let prompt, hasChoices else { cancelChoices(); hablar("No hay una elección pendiente"); return }
        if CommandParser.normalize(answer) == "siguiente" { let handler = choiceHandler; cancelChoices(); handler?(-1); return }
        guard let index = prompt.index(answer, at: ProcessInfo.processInfo.systemUptime) else { hablar("Di un número del 1 al \(choices.count), siguiente o cancelar."); return }
        let handler = choiceHandler; cancelChoices(); callar(); handler?(index)
    }

    private override init() {
        super.init(); synthesizer.delegate = self
        lastExternalApp = NSWorkspace.shared.frontmostApplication
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            if let self, let pid = self.choicePID, let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.processIdentifier != pid { self.cancelChoices(); self.callar(); self.lastResponse = "Elección cancelada al cambiar de aplicación" }
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier { self?.lastExternalApp = app }
        }
    }
    func hablar(_ text: String) {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.hablar(text) }; return }
        lastResponse = text
        speechWatchdog?.cancel()
        currentUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        speechOutput?(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "es-PE") ?? AVSpeechSynthesisVoice(language: "es-ES")
        utterance.rate = 0.5; currentUtterance = utterance; synthesizer.speak(utterance)
        watchSpeech(utterance)
    }
    private func watchSpeech(_ utterance: AVSpeechUtterance) {
        speechWatchdog?.cancel()
        // Renovado por progreso real: una lectura larga no bloquea la recuperación.
        let work = DispatchWorkItem { [weak self, weak utterance] in
            guard let self, let utterance, self.currentUtterance === utterance else { return }
            self.callar()
        }
        speechWatchdog = work; DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { if self.currentUtterance === utterance { self.watchSpeech(utterance) } }
    }
    func callar() {
        speechWatchdog?.cancel(); speechWatchdog = nil; currentUtterance = nil
        synthesizer.stopSpeaking(at: .immediate); speechOutput?(false)
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { outputFinished(utterance) }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { outputFinished(utterance) }
    private func outputFinished(_ utterance: AVSpeechUtterance) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard self.currentUtterance === utterance else { return }
            self.speechWatchdog?.cancel(); self.speechWatchdog = nil; self.currentUtterance = nil
            self.speechOutput?(false)
        }
    }
    func procesarIntencion(_ text: String) {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.procesarIntencion(text) }; return }
        let normalized = CommandParser.normalize(text)
        if let corner = CommandParser.tail("^(?:(?:mueve|coloca|pon) (?:el )?(?:panel|pip) (?:a|en) (?:la )?esquina|panel (?:en (?:la )?)?esquina)\\s+", in: text), PanelCorner.allCases.contains(where: { CommandParser.normalize($0.title) == CommandParser.normalize(corner) }) {
            appAction?("esquina:" + CommandParser.normalize(corner)); return
        }
        if ["mostrar ajustes", "abrir adapta", "mostrar adapta", "modo flotante", "ocultar adapta", "detener todo", "activar talkback", "desactivar talkback"].contains(normalized) { appAction?(normalized); return }
        if let filter = CommandParser.tail("^(?:filtro|activar filtro)\\s+", in: text) { appAction?("filtro:" + CommandParser.normalize(filter)); return }
        if ["quitar filtro", "desactivar filtro"].contains(normalized) { appAction?("filtro:ninguno"); return }
        if let question = CommandParser.tail("^(?:pregunta a la ia|consulta a la ia)\\s+", in: text) { OptionalAI.shared.ask(question); return }
        if normalized == "analiza pantalla con ia" { OptionalAI.shared.analyzeScreen(); return }
        let command = CommandParser.parse(text)
        if hasChoices {
            if case .choose(let answer) = command { choose(answer); return }
            if case .unknown = command { choose(text); return }
            if case .silence = command { callar(); return }
            cancelChoices()
        }
        if command != .silence {
            if case .choose = command {} else { cancelPendingActions(); DesktopAccess.shared.cancelPendingWork() }
        }
        switch command {
        case .choose(let answer): choose(answer)
        case .appShortcut(let name, let action): openApp(name, monitor: nil, afterOpen: action)
        case .keyChord(let text):
            guard let chord = KeyChord.parse(text) else { hablar("Indica modificadores y una tecla, por ejemplo comando shift N"); return }
            withTarget { if DesktopAccess.shared.requirePermission() { DesktopAccess.key(chord.code, flags: chord.flags); self.lastResponse = "Atajo enviado: \(text)" } }
        case .open(let target, let destination): openTarget(target, destination: destination)
        case .search(let query, let site, let destination):
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { hablar("Dime qué quieres buscar"); return }
            if let site, let url = VoiceSite.match(site)?.url(query: query) { openURL(url, destination: destination) }
            else if destination == "actual", let browser {
                currentBrowserURL(browser) { url in
                    let current = url.flatMap { currentURL in VoiceSite.catalog.first { site in
                        guard let host = URL(string: site.home)?.host, let currentHost = currentURL.host else { return false }
                        let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
                        return currentHost == domain || currentHost.hasSuffix("." + domain)
                    } }
                    if let url = (current ?? VoiceSite.match("google"))?.url(query: query) { self.openURL(url, destination: destination) }
                }
            } else if let url = VoiceSite.match("google")?.url(query: query) { openURL(url, destination: destination) }
        case .closeApp(let name): closeApp(name)
        case .kinetic(let action):
            if ["izquierdo", "derecho"].contains(action) {
                withTarget { if action == "izquierdo", DesktopAccess.shared.requirePermission() { DesktopAccess.click() }
                    else if DesktopAccess.shared.requirePermission() { DesktopAccess.click(right: true) } }
            } else {
                kineticAction?(action)
            }
        case .shortcut(let action): withTarget { self.shortcut(action) }
        case .dictate, .clearText, .select, .focus, .press, .pressSelection, .readScreen, .readElement, .listFields, .writeField, .selectText, .menu, .listActions: withTarget { DesktopAccess.shared.run(command) }
        case .cancel: cancelPendingActions(); DesktopAccess.shared.cancelSelection(); kineticAction?("cancelar")
            OptionalAI.shared.cancel()
            callar(); lastResponse = "Comando cancelado"
        case .silence: callar()
        case .unknown(let name): withTarget { DesktopAccess.shared.run(.menu(name)) }
        }
    }
    private func withTarget(_ action: @escaping () -> Void) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier else { action(); return }
        guard let app = lastExternalApp, !app.isTerminated, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { hablar("Activa primero la aplicación que quieres controlar"); return }
        app.activate(options: [])
        let token = actionGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard self.actionGeneration == token, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return }; action()
        }
    }
    private func currentBrowserURL(_ browser: String, completion: @escaping (URL?) -> Void) {
        let target = browser == "Safari" ? "URL of current tab of front window" : "URL of active tab of front window"
        runScript("tell application \(Self.quoted(browser)) to get \(target)", reportFailure: false) { output in
            completion(output.flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        }
    }
    private var browser: String? {
        let app = NSWorkspace.shared.frontmostApplication
        let target = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? lastExternalApp : app
        switch target?.bundleIdentifier {
        case "com.apple.Safari": return "Safari"
        case "com.google.Chrome": return "Google Chrome"
        case "com.brave.Browser": return "Brave Browser"
        case "com.microsoft.edgemac": return "Microsoft Edge"
        default: return nil
        }
    }
    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ") + "\""
    }
    private func runScript(_ script: String, reportFailure: Bool = true, completion: ((String?) -> Void)? = nil) {
        let token = actionGeneration
        scriptQueue.async {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript"); process.arguments = ["-e", script]
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            do {
                let launched = try self.actionLock.withLock {
                    guard self.generation == token else { return false }
                    try process.run(); self.activeProcess = process; return true
                }
                guard launched else { return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                self.actionLock.withLock { if self.activeProcess === process { self.activeProcess = nil } }
                DispatchQueue.main.async {
                    guard self.actionGeneration == token else { return }
                    if reportFailure, process.terminationStatus != 0 { self.hablar("El navegador rechazó la acción. Revisa el permiso de Automatización.") }
                    completion?(process.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil)
                }
            } catch { DispatchQueue.main.async { guard self.actionGeneration == token else { return }; if reportFailure { self.hablar("No se pudo ejecutar la acción del navegador") }; completion?(nil) } }
        }
    }
    private func openURL(_ url: URL, destination: String) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { hablar("Sólo se permiten direcciones HTTP o HTTPS"); return }
        guard let browser else { NSWorkspace.shared.open(url); return }
        let quoted = Self.quoted(url.absoluteString)
        let source: String
        if browser == "Safari" {
            switch destination {
            case "ventana": source = "make new document with properties {URL:\(quoted)}"
            case "pestana": source = "if (count windows) = 0 then\nmake new document with properties {URL:\(quoted)}\nelse\ntell front window to set current tab to (make new tab with properties {URL:\(quoted)})\nend if"
            default: source = "if (count documents) = 0 then\nmake new document with properties {URL:\(quoted)}\nelse\nset URL of current tab of front window to \(quoted)\nend if"
            }
        } else {
            switch destination {
            case "ventana": source = "make new window\nset URL of active tab of front window to \(quoted)"
            case "pestana": source = "if (count windows) = 0 then\nmake new window\nend if\ntell front window\nmake new tab with properties {URL:\(quoted)}\nset active tab index to count tabs\nend tell"
            default: source = "if (count windows) = 0 then\nmake new window\nend if\nset URL of active tab of front window to \(quoted)"
            }
        }
        runScript("tell application \(Self.quoted(browser))\n\(source)\nactivate\nend tell")
    }
    private func openTarget(_ target: String, destination: String) {
        let (name, monitor) = CommandParser.monitorTarget(target)
        if monitor == nil, let site = VoiceSite.match(name), let url = site.url() { openURL(url, destination: destination); return }
        if monitor == nil, name.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) != nil, let url = URL(string: name) { openURL(url, destination: destination); return }
        let fallback = monitor == nil && name.range(of: "^(?:[a-z0-9-]+\\.)+[a-z]{2,}(?:[/:?#][^\\s]*)?$", options: [.regularExpression, .caseInsensitive]) != nil ? URL(string: "https://" + name) : nil
        // Nombres reales como zoom.us tienen prioridad sobre la interpretación como dominio.
        openApp(name, monitor: monitor, fallbackURL: fallback, destination: destination)
    }
    private func openApp(_ name: String, monitor: Int?, fallbackURL: URL? = nil, destination: String = "actual", afterOpen: String? = nil) {
        let token = actionGeneration
        ApplicationCatalog.shared.resolve(name) { url in
            guard self.actionGeneration == token else { return }
            guard let url else {
                if let fallbackURL { self.openURL(fallbackURL, destination: destination) }
                else { self.hablar("No encontré una aplicación única llamada \(name). Di su nombre completo.") }
                return
            }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { app, error in
                DispatchQueue.main.async {
                    guard self.actionGeneration == token else { return }
                    guard let app, error == nil else { self.hablar("No se pudo abrir \(name)"); return }
                    if let action = afterOpen ?? (destination == "ventana" ? "nueva_ventana" : destination == "pestana" ? "nueva_pestana" : nil) {
                        app.activate(options: [])
                        self.appShortcut(action, app: app, token: token, attempt: 0); return
                    }
                    if let monitor { self.placeWindow(app, monitor: monitor, token: token, attempt: 0) }
                    else { self.hablar("Abriendo \(app.localizedName ?? name)") }
                }
            }
        }
    }
    private func appShortcut(_ name: String, app: NSRunningApplication, token: Int, attempt: Int) {
        guard actionGeneration == token else { return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
            shortcut(name); return
        }
        guard attempt < 6 else { hablar("Activa \(app.localizedName ?? "la aplicación") para ejecutar la acción"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.appShortcut(name, app: app, token: token, attempt: attempt + 1) }
    }
    private func placeWindow(_ app: NSRunningApplication, monitor: Int, token: Int, attempt: Int) {
        guard actionGeneration == token, DesktopAccess.shared.requirePermission() else { return }
        DesktopAccess.shared.moveWindow(app: app, monitor: monitor) { success, retry in
            guard self.actionGeneration == token else { return }
            if retry, attempt < 5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.placeWindow(app, monitor: monitor, token: token, attempt: attempt + 1) }
            } else { self.hablar(success ? "Ventana en el monitor \(monitor + 1)" : "No se pudo mover la ventana al monitor \(monitor + 1)") }
        }
    }
    private func closeApp(_ name: String) {
        let token = actionGeneration
        ApplicationCatalog.shared.resolve(name) { url in
            guard self.actionGeneration == token else { return }
            let normalized = CommandParser.normalize(name)
            guard let app = NSWorkspace.shared.runningApplications.first(where: { ($0.bundleURL == url && url != nil) || CommandParser.normalize($0.localizedName ?? "") == normalized }), app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { self.hablar("No encontré esa aplicación abierta"); return }
            self.hablar(app.terminate() ? "Solicitando cierre de \(name)" : "La aplicación no aceptó cerrar")
        }
    }
    private func shortcut(_ name: String) {
        guard DesktopAccess.shared.requirePermission() else { return }
        let menuActions = ["nueva_ventana", "nueva_pestana", "cerrar_ventana", "cerrar_pestana", "guardar", "guardar_como", "imprimir"]
        if menuActions.contains(name) { DesktopAccess.shared.run(.menu(name)); return }
        let browserActions = ["atras", "adelante", "recargar", "siguiente_pestana", "anterior_pestana", "zoom_mas", "zoom_menos", "zoom_normal"]
        if browserActions.contains(name), browser == nil { hablar("Activa Safari, Chrome, Brave o Edge para ese comando"); return }
        switch name {
        case "cortar": DesktopAccess.key(7, flags: .maskCommand)
        case "buscar_texto": DesktopAccess.key(3, flags: .maskCommand)
        case "minimizar": DesktopAccess.key(46, flags: .maskCommand)
        case "ocultar_app": DesktopAccess.key(4, flags: .maskCommand)
        case "pantalla_completa": DesktopAccess.key(3, flags: [.maskControl, .maskCommand])
        case "mission_control": DesktopAccess.key(126, flags: .maskControl)
        case "escritorio": DesktopAccess.key(103)
        case "spotlight": DesktopAccess.key(49, flags: .maskCommand)
        case "cambiar_app": DesktopAccess.key(48, flags: .maskCommand)
        case "escape": DesktopAccess.key(53)
        case "tabulador": DesktopAccess.key(48)
        case "tabulador_anterior": DesktopAccess.key(48, flags: .maskShift)
        case "direccion": DesktopAccess.key(37, flags: .maskCommand)
        case "atras": DesktopAccess.key(123, flags: .maskCommand)
        case "adelante": DesktopAccess.key(124, flags: .maskCommand)
        case "recargar": DesktopAccess.key(15, flags: .maskCommand)
        case "siguiente_pestana": DesktopAccess.key(48, flags: .maskControl)
        case "anterior_pestana": DesktopAccess.key(48, flags: [.maskControl, .maskShift])
        case "zoom_mas": DesktopAccess.key(24, flags: .maskCommand)
        case "zoom_menos": DesktopAccess.key(27, flags: .maskCommand)
        case "zoom_normal": DesktopAccess.key(29, flags: .maskCommand)
        case "copiar": DesktopAccess.key(8, flags: .maskCommand)
        case "pegar": DesktopAccess.key(9, flags: .maskCommand)
        case "enter": DesktopAccess.key(36)
        case "deshacer": DesktopAccess.key(6, flags: .maskCommand)
        case "rehacer": DesktopAccess.key(6, flags: [.maskCommand, .maskShift])
        case "seleccionar_todo": DesktopAccess.key(0, flags: .maskCommand)
        case "inicio": DesktopAccess.key(126, flags: .maskCommand)
        case "final": DesktopAccess.key(125, flags: .maskCommand)
        case "bajar", "subir": DesktopAccess.post(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: name == "bajar" ? -12 : 12, wheel2: 0, wheel3: 0))
        case "reproducir", "pausar":
            // Los reproductores exponen esta acción por AX; evitar una barra espaciadora que pueda escribir en formularios.
            DesktopAccess.shared.run(.press(name == "pausar" ? "pausa" : "reproducir"))
        default: break
        }
        lastResponse = "Acción enviada: " + name.replacingOccurrences(of: "_", with: " ")
    }
}

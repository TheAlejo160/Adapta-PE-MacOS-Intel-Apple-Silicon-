import AppKit
import ApplicationServices
import Combine

/// Lectura diferida de TalkBack: un objetivo se lee una vez cuando lleva 300 ms sin cambiar.
/// Salir de un control (id nil) lo olvida, así que volver a él lo lee de nuevo.
struct LecturaDiferida {
    static let espera = 0.3
    private(set) var actual: Int?
    private var desde = 0.0
    private var leido = false
    /// true si el objetivo cambió: reprogramar la lectura y mover el contorno.
    mutating func observar(_ id: Int?, en tiempo: Double) -> Bool {
        guard id != actual else { return false }
        actual = id; desde = tiempo; leido = false; return true
    }
    mutating func pendiente(en tiempo: Double) -> Int? {
        guard let actual, !leido, tiempo - desde >= Self.espera - 0.001 else { return nil }
        leido = true; return actual
    }
}

/// TalkBack de escritorio: lee el elemento bajo el puntero (también el cursor cinético) y el foco del teclado (AXObserver),
/// con contorno visual. No lee lo escrito en campos de texto: «lee el elemento»/«lee la pantalla» sí, porque se piden.
final class TalkBackManager: ObservableObject {
    @Published var isEnabled = false { didSet { configure() } }
    private var monitors: [Any] = []
    private var generation = 0
    private var lectura = LecturaDiferida()
    private var etiqueta = ""
    private var lecturaProgramada: DispatchWorkItem?
    private var observer: AXObserver?
    private var workspaceObserver: NSObjectProtocol?
    private let queue = DispatchQueue(label: "pe.adapta.talkback", qos: .utility)
    private var lookupInFlight = false
    private var latestPoint = CGPoint.zero
    deinit { monitors.forEach(NSEvent.removeMonitor); stopFocus() }

    private func configure() {
        generation += 1; lectura = LecturaDiferida(); lecturaProgramada?.cancel()
        monitors.forEach(NSEvent.removeMonitor); monitors.removeAll(); stopFocus()
        if !isEnabled { DesktopAccess.shared.showHighlight(nil); return }
        guard AXIsProcessTrusted() else { isEnabled = false; ActionManager.shared.fallar("TalkBack necesita Accesibilidad"); return }
        let receive: (NSEvent) -> Void = { [weak self] event in self?.hover(event.cgEvent?.location ?? CGEvent(source: nil)?.location ?? .zero) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: receive) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { event in receive(event); return event }) { monitors.append(local) }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            self?.observeFocus(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
        observeFocus(NSWorkspace.shared.frontmostApplication)
    }

    // MARK: Foco del teclado
    private func stopFocus() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
        observer = nil
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        workspaceObserver = nil
    }
    private func observeFocus(_ app: NSRunningApplication?) {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode); self.observer = nil }
        guard isEnabled, let pid = app?.processIdentifier, pid > 0 else { return }
        let callback: AXObserverCallback = { _, element, _, context in
            guard let context else { return }
            Unmanaged<TalkBackManager>.fromOpaque(context).takeUnretainedValue().focusChanged(element)
        }
        var created: AXObserver?
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }
        let application = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(application, 0.08)
        // Sin retener: el observador se retira al apagar TalkBack o al destruir el gestor.
        guard AXObserverAddNotification(created, application, kAXFocusedUIElementChangedNotification as CFString, Unmanaged.passUnretained(self).toOpaque()) == .success else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
    }
    private func focusChanged(_ element: AXUIElement) {
        let token = generation
        queue.async { [weak self] in
            let label = DesktopAccess.label(element, includeTextValue: false), frame = DesktopAccess.frame(element)
            DispatchQueue.main.async { guard let self, self.isEnabled, token == self.generation else { return }; self.present(element, label: label, frame: frame) }
        }
    }

    // MARK: Puntero
    private func hover(_ point: CGPoint) {
        latestPoint = point
        guard !lookupInFlight else { return }
        lookupInFlight = true
        let token = generation
        queue.async { [weak self] in
            let target = DesktopAccess.at(point)
            let label = target.map { DesktopAccess.label($0, includeTextValue: false) } ?? ""
            let frame = target.flatMap(DesktopAccess.frame)
            DispatchQueue.main.async {
                guard let self else { return }
                self.lookupInFlight = false
                guard self.isEnabled, token == self.generation else { return }
                // Recuperar el último movimiento sin acumular consultas AX.
                if hypot(self.latestPoint.x - point.x, self.latestPoint.y - point.y) > 2 { self.hover(self.latestPoint) }
                self.present(target, label: label, frame: frame)
            }
        }
    }

    private func present(_ target: AXUIElement?, label: String, frame: CGRect?) {
        let id = target.map { Int(bitPattern: CFHash($0)) }
        guard lectura.observar(id, en: ProcessInfo.processInfo.systemUptime) else { return }
        lecturaProgramada?.cancel() // Como clearTimeout en la extensión: sólo una lectura programada a la vez.
        etiqueta = label
        DesktopAccess.shared.showHighlight(target == nil ? nil : frame)
        guard id != nil, !label.isEmpty else { return }
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isEnabled, token == self.generation, let pending = self.lectura.pendiente(en: ProcessInfo.processInfo.systemUptime), pending == id else { return }
            ActionManager.shared.speechReading?(true)
            ActionManager.shared.hablar(self.etiqueta)
        }
        lecturaProgramada = work
        DispatchQueue.main.asyncAfter(deadline: .now() + LecturaDiferida.espera, execute: work)
    }
}

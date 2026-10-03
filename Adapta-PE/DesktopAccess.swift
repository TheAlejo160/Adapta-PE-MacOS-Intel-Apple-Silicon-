import Combine
import AppKit
import ApplicationServices

final class DesktopAccess {
    static let eventTag: Int64 = 0x41445045
    static let shared = DesktopAccess()
    let queue = DispatchQueue(label: "pe.adapta.accessibility", qos: .userInitiated)
    private let cancellationLock = NSLock()
    private var generation = 0
    private var executionToken = 0 // Exclusivo de queue.
    private func isCancelled(_ token: Int) -> Bool { cancellationLock.withLock { generation != token } }
    private var token: Int { cancellationLock.withLock { generation } }
    private var selected: AXUIElement?
    private var selectedPID: pid_t = 0
    private var highlight: NSPanel?
    private let system = AXUIElementCreateSystemWide()

    private init() { AXUIElementSetMessagingTimeout(system, 0.08) }
    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }
    static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    static func at(_ point: CGPoint) -> AXUIElement? {
        let root = AXUIElementCreateSystemWide(); AXUIElementSetMessagingTimeout(root, 0.05)
        var target: AXUIElement?
        guard AXUIElementCopyElementAtPosition(root, Float(point.x), Float(point.y), &target) == .success else { return nil }
        return target
    }
    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = value(element, kAXPositionAttribute), let size = value(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent), point.x.isFinite, point.y.isFinite, extent.width.isFinite, extent.height.isFinite, extent.width > 0, extent.height > 0 else { return nil }
        return CGRect(origin: point, size: extent)
    }
    static func label(_ element: AXUIElement) -> String {
        guard value(element, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole else { return "Campo protegido" }
        let attributes = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXValueAttribute]
        return attributes.compactMap { value(element, $0) as? String }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map { String($0.prefix(500)) } ?? ""
    }
    static func targetIdentity(at point: CGPoint) -> String? {
        guard AXIsProcessTrusted(), let target = at(point) else { return nil }
        var pid: pid_t = 0; AXUIElementGetPid(target, &pid)
        return "\(pid):\(CFHash(target))"
    }
    static func post(_ event: CGEvent?) {
        event?.setIntegerValueField(.eventSourceUserData, value: eventTag)
        event?.post(tap: .cghidEventTap)
    }
    static func move(to point: CGPoint) { post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)) }
    static func click(right: Bool = false) {
        guard AXIsProcessTrusted(), let point = CGEvent(source: nil)?.location else { return }
        post(CGEvent(mouseEventSource: nil, mouseType: right ? .rightMouseDown : .leftMouseDown, mouseCursorPosition: point, mouseButton: right ? .right : .left))
        post(CGEvent(mouseEventSource: nil, mouseType: right ? .rightMouseUp : .leftMouseUp, mouseCursorPosition: point, mouseButton: right ? .right : .left))
    }
    static func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
        guard AXIsProcessTrusted() else { return }
        for down in [true, false] { let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down); event?.flags = flags; post(event) }
    }
    func requirePermission() -> Bool {
        guard AXIsProcessTrusted() else { ActionManager.shared.hablar("Activa el permiso de Accesibilidad desde Ajustes del Sistema."); return false }; return true
    }
    func cancelSelection() { cancellationLock.withLock { generation += 1 }; queue.async { self.selected = nil; self.selectedPID = 0 }; showHighlight(nil) }
    func cancelPendingWork() { cancellationLock.withLock { generation += 1 } }
    func run(_ command: VoiceCommand) {
        guard requirePermission() else { return }
        let appPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let token = self.token
        queue.async {
            guard !self.isCancelled(token) else { return }; self.executionToken = token
            guard let appPID else { self.respond("No hay aplicación activa"); return }
            let app = AXUIElementCreateApplication(appPID); AXUIElementSetMessagingTimeout(app, 0.08)
            switch command {
            case .menu, .listActions:
                let items = self.menuItems(app)
                let candidates: [AXUIElement] = { if case .menu(let name) = command { return self.matchingMenus(name, items: items) }; return items }()
                guard !candidates.isEmpty else { self.respond("Esa acción no está disponible en el menú de la aplicación. Di muestra comandos o usa un atajo."); return }
                self.pick(candidates, pid: appPID, token: token, forceChoice: command == .listActions, menuLabels: true) { self.press($0, token: token) }
            case .listFields, .writeField:
                let fields = self.controls(app: app, fieldOnly: true)
                if case .writeField(let text, let name) = command {
                    let matches = self.matches(name, elements: fields)
                    guard !matches.isEmpty else { self.respond("No encontré ese campo. Di muestra campos."); return }
                    self.pick(matches, pid: appPID, token: token) { field in
                        if self.focus(field, token: token) { self.dictate(text, app: app, token: token) }
                    }
                } else {
                    guard !fields.isEmpty else { self.respond("No encontré campos de texto accesibles en esta ventana"); return }
                    self.pick(fields, pid: appPID, token: token, forceChoice: true) { field in _ = self.focus(field, token: token) }
                }
            case .selectText(let text):
                guard let field = Self.element(Self.value(app, kAXFocusedUIElementAttribute)), self.editable(field), Self.value(field, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole,
                      let value = Self.value(field, kAXValueAttribute) as? String,
                      let range = value.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]), self.canAct(pid: appPID, token: token) else { self.respond("No encontré ese texto en el campo activo"); return }
                let nsRange = NSRange(range, in: value)
                var selectedRange = CFRange(location: nsRange.location, length: nsRange.length)
                let success = AXValueCreate(.cfRange, &selectedRange).map { AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, $0) == .success } ?? false
                self.respond(success ? "Texto seleccionado" : "La aplicación no permite seleccionar ese texto")
            case .dictate(let text): self.dictate(text, app: app, token: token)
            case .clearText:
                guard let field = Self.element(Self.value(app, kAXFocusedUIElementAttribute)), self.editable(field), Self.value(field, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole else { self.respond("Enfoca un campo editable"); return }
                guard self.canAct(pid: appPID, token: token) else { return }; Self.key(0, flags: .maskCommand); Self.key(51)
            case .select(let name), .focus(let name), .press(let name), .readElement(let name):
                let fieldsOnly: Bool = { if case .focus = command { return true }; return false }()
                let candidates = self.matches(name, elements: self.controls(app: app, fieldOnly: fieldsOnly))
                guard !candidates.isEmpty else { self.respond("No encontré un elemento visible llamado \(name)"); return }
                self.pick(candidates, pid: appPID, token: token) { target in
                    if case .readElement = command { self.respond(Self.label(target)); return }
                    if case .press = command { self.press(target, token: token) }
                    else if case .focus = command { _ = self.focus(target, token: token) }
                    else { self.selected = target; self.selectedPID = appPID; self.showHighlight(Self.frame(target), token: token); self.respond("Seleccionado: \(self.controlLabel(target))") }
                }
            case .pressSelection:
                guard let selected = self.selected, self.selectedPID == appPID else { self.respond("Selecciona primero un elemento en la aplicación activa"); return }; self.press(selected, token: token)
            case .readScreen:
                let root = Self.element(Self.value(app, kAXFocusedWindowAttribute)) ?? app
                let texts = self.walk(root).map(Self.label).filter { !$0.isEmpty }
                var seen = Set<String>()
                let unique = texts.filter { seen.insert($0).inserted }
                self.respond(unique.isEmpty ? "La aplicación no expone texto accesible. Puedes usar VoiceOver." : String(unique.joined(separator: ". ").prefix(3500)))
            default: break
            }
        }
    }
    private func editable(_ element: AXUIElement) -> Bool {
        let role = Self.value(element, kAXRoleAttribute) as? String ?? ""
        return [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role)
    }
    private func dictate(_ text: String, app: AXUIElement, token: Int) {
        guard let focused = Self.element(Self.value(app, kAXFocusedUIElementAttribute)), editable(focused),
              Self.value(focused, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole else {
            var pid: pid_t = 0; AXUIElementGetPid(app, &pid)
            let fields = controls(app: app, fieldOnly: true)
            guard !fields.isEmpty else { respond("Enfoca un campo de texto no protegido antes de dictar"); return }
            pick(fields, pid: pid, token: token, forceChoice: true) { field in if self.focus(field, token: token) { self.dictate(text, app: app, token: token) } }
            return
        }
        var pid: pid_t = 0; AXUIElementGetPid(app, &pid)
        // Eventos Unicode evitan tocar o sobrescribir el portapapeles del usuario.
        for chunk in Self.unicodeChunks(text) {
            guard canAct(pid: pid, token: token), Self.element(Self.value(app, kAXFocusedUIElementAttribute)).map({ CFEqual($0, focused) }) == true else { respond("Dictado detenido: cambió el campo o la aplicación"); return }
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                chunk.withUnsafeBufferPointer { event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
                Self.post(event)
            }
        }
        respond("Texto escrito en " + controlLabel(focused))
    }
    static func unicodeChunks(_ text: String) -> [[UniChar]] {
        let units = Array(text.utf16)
        var result: [[UniChar]] = [], start = 0
        while start < units.count {
            var end = min(start + 20, units.count)
            if end < units.count, (0xD800...0xDBFF).contains(units[end - 1]) { end -= 1 }
            result.append(Array(units[start..<end])); start = end
        }
        return result
    }
    // ponytail: recorrido limitado a 1.800 nodos/0,8 s; apps con árboles mayores requieren búsqueda más específica.
    private func walk(_ root: AXUIElement, skipSystemMenu: Bool = false) -> [AXUIElement] {
        var result: [AXUIElement] = [], pending = [root], visited = Set<CFHashCode>()
        let deadline = ProcessInfo.processInfo.systemUptime + 0.8
        while let element = pending.popLast(), result.count < 1800, ProcessInfo.processInfo.systemUptime < deadline {
            guard visited.insert(CFHash(element)).inserted else { continue }
            if skipSystemMenu, Self.value(element, kAXRoleAttribute) as? String == kAXMenuBarItemRole, Self.label(element) == "Apple" { continue }
            result.append(element)
            if Self.value(element, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole { continue }
            let children = Self.value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
            pending.append(contentsOf: children.reversed())
        }
        return result
    }
    private func controls(app: AXUIElement, fieldOnly: Bool) -> [AXUIElement] {
        let root = Self.element(Self.value(app, kAXFocusedWindowAttribute)) ?? app
        let bounds = Self.frame(root)
        let elements = walk(root), deadline = ProcessInfo.processInfo.systemUptime + 0.8
        return elements.filter {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            guard let frame = Self.frame($0), frame.width > 0, frame.height > 0, Self.value($0, kAXEnabledAttribute) as? Bool != false else { return false }
            guard bounds.map({ $0.intersects(frame) }) != false, Self.value($0, "AXHidden") as? Bool != true else { return false }
            guard Self.value($0, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole else { return false }
            return (!fieldOnly || editable($0)) && (fieldOnly || !Self.label($0).isEmpty)
        }
    }
    private func controlLabel(_ element: AXUIElement) -> String {
        if editable(element) {
            let attributes = [kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue", kAXHelpAttribute]
            if let label = attributes.compactMap({ Self.value(element, $0) as? String }).first(where: { !$0.isEmpty }) { return String(label.prefix(80)) }
            if let title = Self.element(Self.value(element, kAXTitleUIElementAttribute)), !Self.label(title).isEmpty { return String(Self.label(title).prefix(80)) }
            if let field = Self.frame(element), let window = Self.element(Self.value(element, kAXWindowAttribute)), let bounds = Self.frame(window) {
                let row = min(2, max(0, Int((field.midY - bounds.minY) / bounds.height * 3)))
                let column = min(2, max(0, Int((field.midX - bounds.minX) / bounds.width * 3)))
                return "Campo \(["superior", "central", "inferior"][row]) \(["izquierdo", "central", "derecho"][column])"
            }
            return "Campo de texto"
        }
        return String(Self.label(element).prefix(80))
    }
    private func matches(_ name: String, elements: [AXUIElement]) -> [AXUIElement] {
        let text = NameMatch.key(name)
        guard !text.isEmpty else { return [] }
        let exact = elements.filter { NameMatch.key(controlLabel($0)) == text }
        if !exact.isEmpty { return exact }
        let contained = elements.filter { NameMatch.key(controlLabel($0)).contains(text) }
        if !contained.isEmpty { return contained }
        return NameMatch.uniqueIndex(name, names: elements.map { [controlLabel($0)] }).map { [elements[$0]] } ?? []
    }
    private func canAct(pid: pid_t, token: Int) -> Bool { !isCancelled(token) && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }
    private func focus(_ field: AXUIElement, token: Int) -> Bool {
        var pid: pid_t = 0; AXUIElementGetPid(field, &pid)
        guard canAct(pid: pid, token: token), editable(field), Self.value(field, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole else { return false }
        guard AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else { respond("La aplicación no permite enfocar ese campo"); return false }
        selected = field; selectedPID = pid; showHighlight(Self.frame(field), token: token); respond("Campo activo: " + controlLabel(field)); return true
    }
    private func pick(_ elements: [AXUIElement], pid: pid_t, token: Int, forceChoice: Bool = false, menuLabels: Bool = false, offset: Int = 0, action: @escaping (AXUIElement) -> Void) {
        guard canAct(pid: pid, token: token), !elements.isEmpty else { return }
        if elements.count == 1 && !forceChoice { action(elements[0]); return }
        let end = min(elements.count, offset + 6), page = Array(elements[offset..<end])
        let titles = menuLabels ? page.map(menuLabel) : page.map(controlLabel)
        DispatchQueue.main.async {
            guard self.canAct(pid: pid, token: token) else { return }
            ActionManager.shared.presentChoices(titles) { index in
                self.queue.async {
                    guard self.canAct(pid: pid, token: token) else { self.respond("Elección cancelada: cambió la aplicación"); return }
                    self.executionToken = token
                    if index == -1 { self.pick(elements, pid: pid, token: token, forceChoice: true, menuLabels: menuLabels, offset: end == elements.count ? 0 : end, action: action) }
                    else if page.indices.contains(index) { action(page[index]) }
                }
            }
        }
    }
    private func menuItems(_ app: AXUIElement) -> [AXUIElement] {
        guard let menu = Self.element(Self.value(app, kAXMenuBarAttribute)) else { return [] }
        let elements = walk(menu, skipSystemMenu: true), deadline = ProcessInfo.processInfo.systemUptime + 0.8
        return elements.filter {
            ProcessInfo.processInfo.systemUptime < deadline && Self.value($0, kAXRoleAttribute) as? String == kAXMenuItemRole && Self.value($0, kAXEnabledAttribute) as? Bool != false &&
            !Self.label($0).isEmpty && (Self.value($0, kAXChildrenAttribute) as? [AXUIElement] ?? []).isEmpty
        }
    }
    private func menuLabel(_ item: AXUIElement) -> String {
        var path = [String(Self.label(item).prefix(80))], parent = Self.element(Self.value(item, kAXParentAttribute))
        for _ in 0..<6 {
            guard let element = parent else { break }
            if Self.value(element, kAXRoleAttribute) as? String == kAXMenuBarItemRole || Self.value(element, kAXRoleAttribute) as? String == kAXMenuItemRole {
                let title = Self.label(element); if !title.isEmpty { path.insert(title, at: 0) }
            }
            parent = Self.element(Self.value(element, kAXParentAttribute))
        }
        return path.joined(separator: " > ")
    }
    private func matchingMenus(_ name: String, items: [AXUIElement]) -> [AXUIElement] {
        let aliases: [String: [String]] = ["nueva_ventana": ["Nueva ventana", "New Window", "Nueva ventana de Finder", "New Finder Window"], "nueva_pestana": ["Nueva pestaña", "New Tab"], "cerrar_ventana": ["Cerrar ventana", "Close Window", "Close"], "cerrar_pestana": ["Cerrar pestaña", "Close Tab"], "guardar": ["Guardar", "Save"], "guardar_como": ["Guardar como", "Save As"], "imprimir": ["Imprimir", "Print"]]
        let keys = (aliases[name] ?? [name]).map(NameMatch.key)
        let exact = items.filter { keys.contains(NameMatch.key(Self.label($0))) || (name.contains(">") && keys.contains(NameMatch.key(menuLabel($0)))) }
        if !exact.isEmpty { return exact }
        return matches(name, elements: items)
    }
    private func press(_ element: AXUIElement, token: Int) {
        var pid: pid_t = 0; AXUIElementGetPid(element, &pid)
        guard canAct(pid: pid, token: token) else { return }
        guard Self.value(element, kAXEnabledAttribute) as? Bool != false else { respond("Elemento desactivado"); return }
        guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else { respond("La aplicación no permite activar ese elemento por Accesibilidad. Usa el cursor."); return }
        showHighlight(nil); selected = nil
        respond("Activado: " + controlLabel(element))
    }
    private func respond(_ message: String) { let token = executionToken; DispatchQueue.main.async { if !self.isCancelled(token) { ActionManager.shared.hablar(message) } } }
    func showHighlight(_ frame: CGRect?, token: Int? = nil) {
        DispatchQueue.main.async {
            if let token, self.isCancelled(token) { return }
            guard let frame else { self.highlight?.orderOut(nil); return }
            if self.highlight == nil {
                let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isOpaque = false; panel.backgroundColor = .clear; panel.ignoresMouseEvents = true
                panel.level = .statusBar; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                panel.hasShadow = false; panel.isReleasedWhenClosed = false
                let view = NSView(); view.wantsLayer = true; view.layer?.borderColor = NSColor.systemRed.cgColor
                view.layer?.borderWidth = 3; view.layer?.cornerRadius = 6; panel.contentView = view; self.highlight = panel
            }
            let height = NSScreen.screens.first?.frame.height ?? 0
            self.highlight?.setFrame(CGRect(x: frame.minX - 3, y: height - frame.maxY - 3, width: frame.width + 6, height: frame.height + 6), display: true)
            self.highlight?.orderFrontRegardless()
        }
    }
    func moveWindow(app: NSRunningApplication, monitor: Int, completion: @escaping (Bool, Bool) -> Void) {
        let screens = NSScreen.screens
        guard monitor >= 0, screens.indices.contains(monitor), let id = screens[monitor].deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { completion(false, false); return }
        let display = CGDisplayBounds(id), visible = screens[monitor].visibleFrame
        let frame = screens[monitor].frame
        var position = CGPoint(x: display.minX + visible.minX - frame.minX + 20, y: display.minY + frame.maxY - visible.maxY + 20)
        let token = self.token
        queue.async {
            guard !self.isCancelled(token) else { return }; self.executionToken = token
            let target = AXUIElementCreateApplication(app.processIdentifier); AXUIElementSetMessagingTimeout(target, 0.15)
            guard let window = Self.element(Self.value(target, kAXFocusedWindowAttribute)) ?? (Self.value(target, kAXWindowsAttribute) as? [AXUIElement])?.first else { DispatchQueue.main.async { if !self.isCancelled(token) { completion(false, true) } }; return }
            guard !self.isCancelled(token) else { return }
            if let existing = Self.frame(window) {
                var size = CGSize(width: min(existing.width, max(100, visible.width - 40)), height: min(existing.height, max(100, visible.height - 40)))
                if existing.size != size, let value = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) }
            }
            let success = AXValueCreate(.cgPoint, &position).map { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, $0) == .success } ?? false
            DispatchQueue.main.async { if !self.isCancelled(token) { completion(success, !success) } }
        }
    }
}

final class TalkBackManager: ObservableObject {
    @Published var isEnabled = false { didSet { configure() } }
    private var monitors: [Any] = []
    private var pending: DispatchWorkItem?
    private var generation = 0
    private var current: AXUIElement?
    private let queue = DispatchQueue(label: "pe.adapta.talkback", qos: .utility)
    deinit { monitors.forEach(NSEvent.removeMonitor); pending?.cancel() }
    private func configure() {
        generation += 1; pending?.cancel(); current = nil
        monitors.forEach(NSEvent.removeMonitor); monitors.removeAll()
        if !isEnabled { DesktopAccess.shared.showHighlight(nil); return }
        guard AXIsProcessTrusted() else { isEnabled = false; ActionManager.shared.hablar("TalkBack necesita Accesibilidad"); return }
        let receive: (NSEvent) -> Void = { [weak self] event in self?.hover(event.cgEvent?.location ?? CGEvent(source: nil)?.location ?? .zero) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: receive) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { event in receive(event); return event }) { monitors.append(local) }
    }
    private var lookupInFlight = false
    private var latestPoint = CGPoint.zero
    private func hover(_ point: CGPoint) {
        latestPoint = point
        guard !lookupInFlight else { return }
        lookupInFlight = true
        let token = generation
        queue.async { [weak self] in
            let target = DesktopAccess.at(point)
            let label = target.map(DesktopAccess.label) ?? ""
            let frame = target.flatMap(DesktopAccess.frame)
            DispatchQueue.main.async {
                guard let self else { return }
                self.lookupInFlight = false
                guard self.isEnabled, token == self.generation else { return }
                // Recuperar el último movimiento sin acumular consultas AX.
                if hypot(self.latestPoint.x - point.x, self.latestPoint.y - point.y) > 2 { self.hover(self.latestPoint) }
                if let current = self.current, let target, CFEqual(current, target) { return }
                self.pending?.cancel(); self.current = target
                DesktopAccess.shared.showHighlight(frame)
                guard let target, !label.isEmpty else { return }
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.isEnabled, token == self.generation, let current = self.current, CFEqual(current, target) else { return }
                    ActionManager.shared.hablar(label)
                }
                self.pending = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            }
        }
    }
}

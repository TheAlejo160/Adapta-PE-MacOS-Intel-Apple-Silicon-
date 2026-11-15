import Combine
import AppKit
import ApplicationServices
import OSLog

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
    private var selectedWindow: AXUIElement?
    private var cachedRoot: AXUIElement?
    private var cachedControls: [AXUIElement] = []
    private var cachedAt = 0.0
    private let signposter = OSSignposter(subsystem: "pe.adapta.desktop", category: "AX")
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
    static let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"]
    /// `includeTextValue` en false (TalkBack) no lee lo escrito en campos de texto: sólo una petición explícita lo lee.
    static func label(_ element: AXUIElement, includeTextValue: Bool = true) -> String {
        guard value(element, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole else { return "Campo protegido" }
        let attributes = labelAttributes(role: value(element, kAXRoleAttribute) as? String, includeTextValue: includeTextValue)
        return attributes.compactMap { value(element, $0) as? String }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map { String($0.prefix(500)) } ?? ""
    }
    static func labelAttributes(role: String?, includeTextValue: Bool) -> [String] {
        let isText = textRoles.contains(role ?? "")
        return [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute] + (isText && !includeTextValue ? ["AXPlaceholderValue"] : [kAXValueAttribute])
    }
    static func surfaceIdentity(at point: CGPoint, windows: [[String: Any]], pid: pid_t) -> String? {
        guard point.x.isFinite, point.y.isFinite, pid > 0 else { return nil }
        for window in windows {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), frame.contains(point) else { continue }
            guard (window[kCGWindowOwnerPID as String] as? Int) == Int(pid), let id = window[kCGWindowNumber as String] as? Int else { return nil }
            return "pixel:\(pid):\(id):\(floor(point.x / 24)):\(floor(point.y / 24))"
        }
        return nil
    }
    static func cursorTarget(at point: CGPoint) -> (identity: String, center: CGPoint?)? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return nil }
        if let target = at(point) {
            var pid: pid_t = 0; AXUIElementGetPid(target, &pid)
            let role = value(target, kAXRoleAttribute) as? String
            if pid > 0, pid != app.processIdentifier, pid != ProcessInfo.processInfo.processIdentifier { return nil }
            if pid > 0, let role, ![kAXWindowRole, kAXApplicationRole, kAXUnknownRole].contains(role), value(target, kAXEnabledAttribute) as? Bool != false {
                let roles = [kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole, kAXTextFieldRole]
                let center = roles.contains(role) ? frame(target).map { CGPoint(x: $0.midX, y: $0.midY) } : nil
                // Identidad estable por control (rol y marco): el hash AX cambia en apps que recrean elementos.
                let identity = frame(target).map { "\(pid):\(role):\(Int($0.minX)):\(Int($0.minY)):\(Int($0.width)):\(Int($0.height))" } ?? "\(pid):\(CFHash(target))"
                return (identity, center)
            }
        }
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return surfaceIdentity(at: point, windows: windows, pid: app.processIdentifier).map { ($0, nil) }
    }
    static func targetIdentity(at point: CGPoint) -> String? { cursorTarget(at: point)?.identity }
    static func post(_ event: CGEvent?) {
        event?.setIntegerValueField(.eventSourceUserData, value: eventTag)
        event?.post(tap: .cghidEventTap)
    }
    static func move(to point: CGPoint) { post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)) }
    static func click(right: Bool = false, at position: CGPoint? = nil) {
        guard AXIsProcessTrusted(), let point = position ?? CGEvent(source: nil)?.location else { return }
        post(CGEvent(mouseEventSource: nil, mouseType: right ? .rightMouseDown : .leftMouseDown, mouseCursorPosition: point, mouseButton: right ? .right : .left))
        post(CGEvent(mouseEventSource: nil, mouseType: right ? .rightMouseUp : .leftMouseUp, mouseCursorPosition: point, mouseButton: right ? .right : .left))
    }
    static func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
        guard AXIsProcessTrusted() else { return }
        for down in [true, false] { let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down); event?.flags = flags; post(event) }
    }
    func requirePermission() -> Bool {
        guard AXIsProcessTrusted() else { ActionManager.shared.fallar("Activa el permiso de Accesibilidad desde Ajustes del Sistema."); return false }; return true
    }
    func cancelSelection() { cancellationLock.withLock { generation += 1 }; queue.async { self.selected = nil; self.selectedPID = 0; self.selectedWindow = nil }; showHighlight(nil) }
    func cancelPendingWork() { cancellationLock.withLock { generation += 1 } }
    func run(_ command: VoiceCommand) {
        guard requirePermission() else { return }
        let appPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let token = self.token
        let done = ActionManager.shared.deferResult()
        queue.async {
            defer { DispatchQueue.main.async { done() } }
            guard !self.isCancelled(token) else { return }; self.executionToken = token
            let interval = self.signposter.beginInterval("AXCommand")
            defer { self.signposter.endInterval("AXCommand", interval) }
            guard let appPID else { self.respond("No hay aplicación activa"); return }
            let app = AXUIElementCreateApplication(appPID); AXUIElementSetMessagingTimeout(app, 0.08)
            switch command {
            case .menu, .listActions:
                let items = self.menuItems(app)
                let candidates: [AXUIElement] = { if case .menu(let name) = command { return self.matchingMenus(name, items: items) }; return items }()
                guard !candidates.isEmpty else { self.respond("Esa acción no está disponible en el menú de la aplicación. Di muestra comandos o usa un atajo."); return }
                let key: String? = { if case .menu(let name) = command { return VoiceConfirmation.known(name) }; return nil }()
                self.pick(candidates, pid: appPID, token: token, forceChoice: command == .listActions, menuLabels: true) { self.press($0, token: token, key: key) }
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
                self.respond(success ? "Texto seleccionado" : "La aplicación no permite seleccionar ese texto", ok: success)
            case .dictate(let text): self.dictate(text, app: app, token: token)
            case .clearText:
                guard let field = Self.element(Self.value(app, kAXFocusedUIElementAttribute)), self.editable(field), Self.value(field, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole else { self.respond("Enfoca un campo editable"); return }
                guard self.canAct(pid: appPID, token: token) else { return }; Self.key(0, flags: .maskCommand); Self.key(51)
            case .select(let name), .focus(let name), .press(let name), .readElement(let name):
                let fieldsOnly: Bool = { if case .focus = command { return true }; return false }()
                let candidates = self.matches(name, elements: self.controls(app: app, fieldOnly: fieldsOnly))
                guard !candidates.isEmpty else { self.respond("No encontré un elemento visible llamado \(name)"); return }
                self.pick(candidates, pid: appPID, token: token) { target in
                    if case .readElement = command { self.respond(Self.label(target), ok: true); return }
                    if case .press = command { self.press(target, token: token) }
                    else if case .focus = command { _ = self.focus(target, token: token) }
                    else { self.selected = target; self.selectedPID = appPID; self.selectedWindow = Self.element(Self.value(app, kAXFocusedWindowAttribute)); self.showHighlight(Self.frame(target), token: token); self.respond("Seleccionado: \(self.controlLabel(target))") }
                }
            case .pressSelection:
                guard let selected = self.selected, self.selectedPID == appPID else { self.respond("Selecciona primero un elemento en la aplicación activa"); return }; self.press(selected, token: token)
            case .readScreen:
                let root = Self.element(Self.value(app, kAXFocusedWindowAttribute)) ?? app
                let texts = self.walk(root).map { Self.label($0) }.filter { !$0.isEmpty }
                var seen = Set<String>()
                let unique = texts.filter { seen.insert($0).inserted }
                self.respond(unique.isEmpty ? "La aplicación no expone texto accesible. Puedes usar VoiceOver." : String(unique.joined(separator: ". ").prefix(3500)), ok: !unique.isEmpty)
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
            guard !isCancelled(executionToken) else { return [] }
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
        let now = ProcessInfo.processInfo.systemUptime
        if now - cachedAt < 1.5, cachedRoot.map({ CFEqual($0, root) }) == true {
            return fieldOnly ? cachedControls.filter(editable) : cachedControls
        }
        let bounds = Self.frame(root), elements = walk(root)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.4
        var controls: [AXUIElement] = []
        for element in elements {
            guard !isCancelled(executionToken), ProcessInfo.processInfo.systemUptime < deadline else { return [] }
            guard let frame = Self.frame(element), Self.value(element, kAXEnabledAttribute) as? Bool != false,
                  bounds.map({ $0.intersects(frame) }) != false, Self.value(element, "AXHidden") as? Bool != true,
                  Self.value(element, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole else { continue }
            if editable(element) || !Self.label(element).isEmpty { controls.append(element) }
        }
        cachedRoot = root; cachedControls = controls; cachedAt = ProcessInfo.processInfo.systemUptime
        return fieldOnly ? controls.filter(editable) : controls
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
        let deadline = ProcessInfo.processInfo.systemUptime + 0.4
        var labels: [String] = []
        for element in elements {
            guard !isCancelled(executionToken), ProcessInfo.processInfo.systemUptime < deadline else { return [] }
            labels.append(controlLabel(element))
        }
        return VoiceSafety.menuIndices(name, labels: labels).map { elements[$0] }
    }
    // `ventana` es nil si no se verifica; `.some(nil)` indica que la app no exponía ventana enfocada y debe seguir sin exponerla.
    private func canAct(pid: pid_t, token: Int, ventana: AXUIElement?? = nil) -> Bool {
        guard !isCancelled(token), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        guard let esperada = ventana else { return true }
        let app = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(app, 0.08)
        let actual = Self.element(Self.value(app, kAXFocusedWindowAttribute))
        guard let esperada else { return actual == nil }
        return actual.map { CFEqual(esperada, $0) } ?? false
    }
    private func focus(_ field: AXUIElement, token: Int) -> Bool {
        var pid: pid_t = 0; AXUIElementGetPid(field, &pid)
        guard canAct(pid: pid, token: token), editable(field), Self.value(field, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole else { return false }
        guard AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else { respond("La aplicación no permite enfocar ese campo"); return false }
        selected = field; selectedPID = pid; selectedWindow = Self.element(Self.value(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute)); showHighlight(Self.frame(field), token: token); respond("Campo activo: " + controlLabel(field)); return true
    }
    private func pick(_ elements: [AXUIElement], pid: pid_t, token: Int, forceChoice: Bool = false, menuLabels: Bool = false, offset: Int = 0, ventana: AXUIElement?? = nil, action: @escaping (AXUIElement) -> Void) {
        guard canAct(pid: pid, token: token), !elements.isEmpty else { return }
        let app = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(app, 0.08)
        let ventana: AXUIElement? = ventana ?? Self.element(Self.value(app, kAXFocusedWindowAttribute))
        guard canAct(pid: pid, token: token, ventana: ventana) else { respond("Elección cancelada: cambió la ventana o la aplicación"); return }
        if elements.count == 1 && !forceChoice { action(elements[0]); return }
        let end = min(elements.count, offset + 6), page = Array(elements[offset..<end])
        let titles = menuLabels ? page.map(menuLabel) : page.map(controlLabel)
        guard canAct(pid: pid, token: token, ventana: ventana) else { respond("Elección cancelada: cambió la ventana o la aplicación"); return }
        DispatchQueue.main.async {
            guard self.canAct(pid: pid, token: token) else { return }
            ActionManager.shared.presentChoices(titles) { index in
                self.queue.async {
                    guard self.canAct(pid: pid, token: token, ventana: ventana) else { self.respond("Elección cancelada: cambió la ventana o la aplicación"); return }
                    self.executionToken = token
                    if index == -1 { self.pick(elements, pid: pid, token: token, forceChoice: true, menuLabels: menuLabels, offset: end == elements.count ? 0 : end, ventana: ventana, action: action) }
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
        let aliases: [String: [String]] = ["nueva_ventana": ["Nueva ventana", "New Window", "Nueva ventana de Finder", "New Finder Window"], "nueva_pestana": ["Nueva pestaña", "New Tab"], "cerrar_ventana": ["Cerrar ventana", "Close Window", "Close"], "cerrar_pestana": ["Cerrar pestaña", "Close Tab"], "guardar": ["Guardar", "Save"], "guardar_como": ["Guardar como", "Save As"], "imprimir": ["Imprimir", "Print"], "silenciar_pestana": ["Silenciar pestaña", "Silenciar sitio", "Mute Tab", "Mute Site"], "activar_sonido": ["Activar sonido de pestaña", "Unmute Tab", "Unmute Site"]]
        let deadline = ProcessInfo.processInfo.systemUptime + 0.4
        var labels: [String] = []
        for item in items {
            guard !isCancelled(executionToken), ProcessInfo.processInfo.systemUptime < deadline else { return [] }
            labels.append(name.contains(">") ? menuLabel(item) : Self.label(item))
        }
        return VoiceSafety.menuIndices(name, labels: labels, aliases: aliases[name] ?? []).map { items[$0] }
    }
    private func press(_ element: AXUIElement, token: Int, confirmed: Bool = false, key: String? = nil) {
        var pid: pid_t = 0; AXUIElementGetPid(element, &pid)
        guard canAct(pid: pid, token: token) else { return }
        guard Self.value(element, kAXEnabledAttribute) as? Bool != false else { respond("Elemento desactivado"); return }
        let label = controlLabel(element)
        if !confirmed, VoiceSafety.destructive(label) {
            let app = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(app, 0.08)
            let window = Self.element(Self.value(app, kAXFocusedWindowAttribute))
            let destination = (NSRunningApplication(processIdentifier: pid)?.localizedName ?? "aplicación") + (window.map { " ventana " + Self.label($0) } ?? "")
            DispatchQueue.main.async {
                guard self.canAct(pid: pid, token: token) else { return }
                ActionManager.shared.confirm(action: key ?? label, destination: destination, pid: pid) {
                    self.queue.async {
                        guard self.canAct(pid: pid, token: token, ventana: window), self.controlLabel(element) == label else { return }
                        self.press(element, token: token, confirmed: true)
                    }
                }
            }
            return
        }
        guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else { respond("La aplicación no permite activar ese elemento por Accesibilidad. Usa el cursor."); return }
        cachedAt = 0; showHighlight(nil); selected = nil; selectedWindow = nil
        respond("Activado: " + label)
    }
    func clickSelectionOrCursor(right: Bool = false) {
        guard requirePermission(), let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        let token = self.token
        let done = ActionManager.shared.deferResult()
        queue.async {
            defer { DispatchQueue.main.async { done() } }
            guard self.canAct(pid: pid, token: token) else { return }; self.executionToken = token
            guard let selected = self.selected else { Self.click(right: right); return }
            guard self.selectedPID == pid, self.canAct(pid: pid, token: token, ventana: self.selectedWindow) else { self.respond("La selección cambió. Selecciona de nuevo o cancela."); return }
            if right {
                guard let frame = Self.frame(selected) else { self.respond("La selección ya no está disponible"); return }
                Self.click(right: true, at: CGPoint(x: frame.midX, y: frame.midY))
            } else { self.press(selected, token: token) }
        }
    }
    // Todo mensaje hablado que no sea un resultado (`ok`) es un fallo del turno de voz.
    private func respond(_ message: String, ok: Bool = false) {
        let token = executionToken
        DispatchQueue.main.async {
            guard !self.isCancelled(token) else { return }
            if ["Activado:", "Seleccionado:", "Campo activo:", "Texto escrito"].contains(where: { message.hasPrefix($0) }) { ActionManager.shared.feedback(message) }
            else if ok { ActionManager.shared.hablar(message) } else { ActionManager.shared.fallar(message) }
        }
    }
    func showHighlight(_ frame: CGRect?, token: Int? = nil) {
        DispatchQueue.main.async {
            if let token, self.isCancelled(token) { return }
            guard let frame else { self.highlight?.orderOut(nil); return }
            if self.highlight == nil {
                let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isOpaque = false; panel.backgroundColor = .clear; panel.ignoresMouseEvents = true
                panel.level = .statusBar; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
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
            guard !self.isCancelled(token) else { DispatchQueue.main.async { completion(false, false) }; return }; self.executionToken = token
            let target = AXUIElementCreateApplication(app.processIdentifier); AXUIElementSetMessagingTimeout(target, 0.15)
            guard let window = Self.element(Self.value(target, kAXFocusedWindowAttribute)) ?? (Self.value(target, kAXWindowsAttribute) as? [AXUIElement])?.first else { DispatchQueue.main.async { completion(false, !self.isCancelled(token)) }; return }
            guard !self.isCancelled(token) else { DispatchQueue.main.async { completion(false, false) }; return }
            if let existing = Self.frame(window) {
                var size = CGSize(width: min(existing.width, max(100, visible.width - 40)), height: min(existing.height, max(100, visible.height - 40)))
                if existing.size != size, let value = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) }
            }
            let success = AXValueCreate(.cgPoint, &position).map { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, $0) == .success } ?? false
            DispatchQueue.main.async { completion(!self.isCancelled(token) && success, !self.isCancelled(token) && !success) }
        }
    }
}

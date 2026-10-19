import AppKit
import SwiftUI
import Combine

struct MascotAtlas: Decodable {
    struct Frame: Decodable { let x, y, w, h, duration: Int }
    struct Animation: Decodable { let name: String; let entry, loop, exit: [Int] }
    let frames: [Frame]
    let animations: [Animation]
    func animation(_ name: String) -> Animation { animations.first { $0.name == name } ?? animations.first { $0.name == "idle" }! }
}

struct MascotPlayback {
    let atlas: MascotAtlas
    private(set) var state = "idle"
    private(set) var frame = 0
    private var pending: [Int] = []
    private var index = 0
    mutating func set(_ state: String) {
        guard self.state != state else { return }
        pending = atlas.animation(self.state).exit + atlas.animation(state).entry
        self.state = state; index = 0
    }
    var resting: Bool { state == "sleep" && pending.isEmpty && index >= atlas.animation(state).loop.count }
    mutating func advance() {
        if !pending.isEmpty { frame = pending.removeFirst(); return }
        let animation = atlas.animation(state)
        if (state == "wave" || state == "wake" || state == "phone" || state == "laptop" || state == "happy" || state == "confused"), index >= animation.loop.count {
            pending = animation.exit; state = "idle"; index = 0; advance(); return
        }
        if animation.loop.isEmpty { state = "idle"; index = 0; advance(); return }
        frame = animation.loop[index % animation.loop.count]; index += 1
    }
}

struct MascotActivity {
    private(set) var lastInteraction: TimeInterval = 0
    var manualSleep = false
    var speaking = false
    mutating func touch(_ now: TimeInterval) { lastInteraction = now }
    func shouldSleep(_ now: TimeInterval) -> Bool { !manualSleep && !speaking && now - lastInteraction >= 90 }
}

@MainActor
final class MascotManager: ObservableObject {
    static let names = ["ninguna", "tinku", "cuchu", "yati"]
    static let titles = ["Sin mascota", "Tinku · gallito", "Cuchu · cuy", "Yati · llama"]
    @Published private(set) var name = "ninguna"
    @Published private(set) var status = "Sin mascota"
    private var playback: MascotPlayback?
    private var imagePanel: NSPanel?
    private var handlePanel: NSPanel?
    private var layer: CALayer?
    private var timer: Timer?
    @Published var linked = UserDefaults.standard.bool(forKey: "MascotLinked") {
        didSet { UserDefaults.standard.set(linked, forKey: "MascotLinked"); layoutChanged?() }
    }
    var layoutChanged: (() -> Void)?
    var movePanel: ((CGPoint) -> Void)?
    var savePanel: (() -> Void)?
    var nextPanelScreen: (() -> Void)?
    private var panelFrame: CGRect?
    private var inactivityTimer: Timer?
    private var activity = MascotActivity()
    private var sleeping = false
    private var suspended = false
    private var speechState = "talk"
    private var observers: [NSObjectProtocol] = []
    init() {
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.position() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshTimer() }
        })
    }
    deinit { inactivityTimer?.invalidate(); timer?.invalidate(); for observer in observers { NotificationCenter.default.removeObserver(observer); NSWorkspace.shared.notificationCenter.removeObserver(observer) } }
    func choose(_ value: String) {
        inactivityTimer?.invalidate(); inactivityTimer = nil; let speaking = activity.speaking; activity = MascotActivity(); activity.speaking = speaking;
        timer?.invalidate(); timer = nil; imagePanel?.orderOut(nil); handlePanel?.orderOut(nil)
        imagePanel = nil; handlePanel = nil; playback = nil; layer = nil; sleeping = false
        suspended = false
        name = Self.names.contains(value) ? value : "ninguna"
        UserDefaults.standard.set(name, forKey: "Mascot")
        guard name != "ninguna" else { status = "Sin mascota"; layoutChanged?(); return }
        do {
            guard let url = Bundle.main.url(forResource: "mascota-" + name, withExtension: "json"),
                  let imageURL = Bundle.main.url(forResource: "mascota-" + name, withExtension: "png"),
                  let image = NSImage(contentsOf: imageURL)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw CocoaError(.fileReadNoSuchFile) }
            let atlas = try JSONDecoder().decode(MascotAtlas.self, from: Data(contentsOf: url))
            guard atlas.frames.count == 144, atlas.animations.contains(where: { $0.name == "idle" && !$0.loop.isEmpty }), atlas.animations.contains(where: { $0.name == "look" && $0.loop.count == 9 }),
                  atlas.frames.allSatisfy({ $0.duration > 0 && $0.duration <= 10000 && $0.x >= 0 && $0.y >= 0 && $0.w > 0 && $0.h > 0 && $0.x <= image.width - $0.w && $0.y <= image.height - $0.h }),
                  atlas.animations.allSatisfy({ ($0.entry + $0.loop + $0.exit).allSatisfy(atlas.frames.indices.contains) }) else { throw CocoaError(.fileReadCorruptFile) }
            playback = MascotPlayback(atlas: atlas)
            let sprite = panel(size: CGSize(width: 96, height: 112)); sprite.title = "Mascota " + name.capitalized; sprite.ignoresMouseEvents = true
            let view = NSView(frame: sprite.contentView!.bounds); view.wantsLayer = true
            let layer = CALayer(); layer.contents = image; layer.frame = view.bounds; layer.contentsGravity = .resize
            view.layer?.addSublayer(layer); sprite.contentView = view; self.layer = layer; imagePanel = sprite
            let handle = panel(size: CGSize(width: 96, height: 44)); handle.title = "Mover " + name.capitalized
            let button = MascotHandle(title: name.capitalized, target: nil, action: nil)
            button.frame = CGRect(x: 0, y: 0, width: 96, height: 44)
            button.appearance = NSAppearance(named: .aqua); button.bezelStyle = .rounded; button.attributedTitle = NSAttributedString(string: name.capitalized, attributes: [.foregroundColor: NSColor.black, .font: NSFont.systemFont(ofSize: 13, weight: .semibold)]); button.setAccessibilityLabel("Mover " + name.capitalized + ": arrastra o usa las flechas")
            button.move = { [weak self] delta, dragging in self?.move(delta, dragging: dragging) }
            button.save = { [weak self] in self?.savePosition() }
            handle.contentView?.addSubview(button); handlePanel = handle
            position(); if !suspended { sprite.orderFrontRegardless(); handle.orderFrontRegardless() }
            status = name.capitalized + " visible · arrastra su nombre o usa las flechas"
            draw(); refreshTimer(); touch(); if activity.speaking { react(speechState) }; layoutChanged?()
        } catch { name = "ninguna"; UserDefaults.standard.set(name, forKey: "Mascot"); status = "No se cargó la mascota. Elige otra y vuelve a intentar." }
    }
    private func panel(size: CGSize) -> NSPanel {
        let panel = MascotPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .statusBar; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false; return panel
    }
    func attach(to frame: CGRect?) {
        panelFrame = linked ? frame : nil
        if let frame = panelFrame {
            let point = CGPoint(x: frame.midX - 48, y: frame.maxY + 8)
            handlePanel?.setFrameOrigin(point); imagePanel?.setFrameOrigin(CGPoint(x: point.x, y: point.y + 44))
        } else { position() }
    }
    private func position() {
        if let frame = panelFrame { attach(to: frame); return }
        let id = UserDefaults.standard.object(forKey: "MascotDisplay") as? UInt32
        guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == id }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let defaults = UserDefaults.standard
        let x = defaults.object(forKey: "MascotX") as? Double ?? 0.75
        let y = defaults.object(forKey: "MascotY") as? Double ?? 0.1
        moveTo(CGPoint(x: visible.minX + max(0, min(1, x)) * max(0, visible.width - 96), y: visible.minY + max(0, min(1, y)) * max(0, visible.height - 156)), in: visible)
    }
    private func move(_ delta: CGPoint, dragging: Bool) {
        touch(); if panelFrame != nil { movePanel?(delta); return }
        guard let handle = handlePanel else { return }
        let point = CGPoint(x: handle.frame.minX + delta.x, y: handle.frame.minY + delta.y)
        guard let screen = (dragging ? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) : handle.screen) ?? handle.screen ?? NSScreen.main else { return }
        moveTo(point, in: screen.visibleFrame)
    }
    private func moveTo(_ point: CGPoint, in visible: CGRect) {
        let point = CGPoint(x: max(visible.minX, min(visible.maxX - 96, point.x)), y: max(visible.minY, min(visible.maxY - 156, point.y)))
        handlePanel?.setFrameOrigin(point); imagePanel?.setFrameOrigin(CGPoint(x: point.x, y: point.y + 44))
    }
    private func savePosition() {
        if panelFrame != nil { savePanel?(); return }
        guard let handle = handlePanel, let screen = handle.screen else { return }
        let visible = screen.visibleFrame
        UserDefaults.standard.set(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")], forKey: "MascotDisplay")
        UserDefaults.standard.set((handle.frame.minX - visible.minX) / max(1, visible.width - 96), forKey: "MascotX")
        UserDefaults.standard.set((handle.frame.minY - visible.minY) / max(1, visible.height - 156), forKey: "MascotY")
    }
    func touch() {
        if sleeping, !activity.manualSleep { sleeping = false; playback?.set("wake"); draw(); refreshTimer() }
        activity.touch(ProcessInfo.processInfo.systemUptime)
        inactivityTimer?.invalidate(); inactivityTimer = nil
        guard playback != nil, !suspended, !activity.manualSleep, !activity.speaking else { return }
        inactivityTimer = Timer.scheduledTimer(withTimeInterval: 90, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.activity.shouldSleep(ProcessInfo.processInfo.systemUptime) else { return }
                self.sleeping = true; self.playback?.set("sleep"); self.status = self.name.capitalized + " · descansando por inactividad"
                self.draw(); self.refreshTimer()
            }
        }
    }
    func react(_ state: String) {
        guard !activity.manualSleep, playback != nil else { return }
        if state != "idle" { sleeping = false; touch() }
        guard !sleeping, playback?.state != state else { return }
        playback?.set(state)
        status = name.capitalized + " · " + (["read": "leyendo", "talk": "hablando", "phone": "escuchando", "laptop": "realizando tu acción", "idle": "visible"][state] ?? state)
        draw(); refreshTimer()
    }
    func gesture(_ state: String) {
        guard playback != nil else { status = "Elige una mascota primero"; return }
        if state == "join" || state == "separate" { linked = state == "join"; status = linked ? "Mascota unida al panel" : "Mascota independiente"; return }
        guard !activity.manualSleep || state == "wake" || state == "sleep" else { status = name.capitalized + " duerme · pulsa Despertar"; return }
        activity.manualSleep = state == "sleep"; sleeping = activity.manualSleep; touch(); playback?.set(state)
        status = name.capitalized + " · " + (["sleep": "durmiendo", "wake": "despertando", "wave": "saludando"][state] ?? "visible")
        draw(); refreshTimer()
    }
    func focusHandle() { guard let panel = handlePanel else { return }; NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(panel.contentView?.subviews.first) }
    func nextScreen() {
        let screens = NSScreen.screens
        guard screens.count > 1 else { status = "Sólo hay una pantalla conectada"; return }
        if linked, panelFrame != nil { nextPanelScreen?(); status = name.capitalized + " · panel en otra pantalla"; return }
        let index = screens.firstIndex(where: { $0 == handlePanel?.screen }) ?? 0
        UserDefaults.standard.set(screens[(index + 1) % screens.count].deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")], forKey: "MascotDisplay")
        position(); savePosition(); status = name.capitalized + " · pantalla \((index + 1) % screens.count + 1)"
    }
    func speaking(_ active: Bool) { activity.speaking = active; react(active ? speechState : "idle"); touch() }
    func prepareSpeech(reading: Bool) { speechState = reading ? "read" : "talk"; if !reading { react("laptop") } }
    func suspend(_ value: Bool) {
        suspended = value; inactivityTimer?.invalidate(); inactivityTimer = nil
        if value { imagePanel?.orderOut(nil); handlePanel?.orderOut(nil) }
        else { imagePanel?.orderFrontRegardless(); handlePanel?.orderFrontRegardless(); touch() }
        refreshTimer()
    }
    private func refreshTimer() {
        timer?.invalidate(); timer = nil
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            if let state = playback?.state, !["idle", "sleep", "read", "talk"].contains(state) { playback?.set("idle"); draw() }
            return
        }
        guard !suspended, let playback, !playback.resting else { return }
        let duration = Double(playback.atlas.frames[playback.frame].duration) / 1000
        timer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.draw(); self?.refreshTimer() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }
    private func draw() {
        guard var playback, let layer else { return }
        let previous = playback.state
        playback.advance(); self.playback = playback
        if previous != "idle", playback.state == "idle" { status = name.capitalized + " visible" }
        let frame = playback.atlas.frames[playback.frame]
        var index = playback.frame
        if playback.state == "idle", let panel = imagePanel {
            let mouse = NSEvent.mouseLocation, center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
            if hypot(mouse.x - center.x, mouse.y - center.y) < 500 {
                let x = mouse.x < center.x - 40 ? 0 : mouse.x > center.x + 40 ? 2 : 1
                let y = mouse.y > center.y + 40 ? 0 : mouse.y < center.y - 40 ? 2 : 1
                index = playback.atlas.animation("look").loop[y * 3 + x]
            }
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { index = playback.atlas.animation(playback.state).loop.first ?? playback.atlas.animation("idle").loop[0] }
        let selected = playback.atlas.frames[index]
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.contentsRect = CGRect(x: Double(selected.x) / 1178, y: Double(selected.y) / 1370, width: Double(frame.w) / 1178, height: Double(frame.h) / 1370)
        CATransaction.commit()
    }
}

private final class MascotPanel: NSPanel { override var canBecomeKey: Bool { true } }

private final class MascotHandle: NSButton {
    override var needsPanelToBecomeKey: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    var move: ((CGPoint, Bool) -> Void)?
    var save: (() -> Void)?
    override func mouseDown(with event: NSEvent) { window?.makeKey(); window?.makeFirstResponder(self) }
    override func mouseDragged(with event: NSEvent) { move?(CGPoint(x: event.deltaX, y: -event.deltaY), true) }
    override func mouseUp(with event: NSEvent) { save?() }
    override func keyDown(with event: NSEvent) {
        let moves: [UInt16: CGPoint] = [123: CGPoint(x: -24, y: 0), 124: CGPoint(x: 24, y: 0), 125: CGPoint(x: 0, y: -24), 126: CGPoint(x: 0, y: 24)]
        if event.keyCode == 53 { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first { $0.canBecomeMain && $0 != window }?.makeKeyAndOrderFront(nil); return }
        if let delta = moves[event.keyCode] { move?(delta, false); save?() } else { super.keyDown(with: event) }
    }
}

struct MascotSettings: View {
    @ObservedObject var mascot: MascotManager
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tu compañía peruana").font(.title2.bold())
            Text("Tinku, Cuchu o Yati. Puedes cambiarla u ocultarla cuando quieras.").foregroundStyle(.secondary)
            Picker("Tu mascota", selection: Binding(get: { mascot.name }, set: mascot.choose)) {
                ForEach(MascotManager.names, id: \.self) { name in
                    Text(MascotManager.titles[MascotManager.names.firstIndex(of: name)!]).tag(name)
                }
            }
            .tint(.primary)
            Text(mascot.status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Arrastra su nombre entre monitores o enfócalo y usa las flechas. Di «mascota Cuchu» después de llamar al asistente. El dibujo deja pasar tus clics.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if mascot.name != "ninguna" {
                Toggle("Mover mascota y panel juntos", isOn: $mascot.linked).toggleStyle(.switch).frame(minHeight: 44)
                Text("Unida: queda arriba del panel; arrastra cualquiera de sus títulos. Separada: conserva su lugar propio. Descansa tras 90 segundos sin uso y despierta al recibir una acción.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Saludar") { mascot.gesture("wave") }
                    Button("Dormir") { mascot.gesture("sleep") }
                    Button("Despertar") { mascot.gesture("wake") }
                }
                HStack {
                    Button("Mover con teclas") { mascot.focusHandle() }
                    Button("Otro monitor") { mascot.nextScreen() }
                }
            }
        }
    }
}

struct MascotCommand {
    static func parse(_ text: String) -> String? {
        let normalized = CommandParser.normalize(text)
        if ["une mascota al panel", "une la mascota al panel"].contains(normalized) { return "join" }
        if ["separa mascota del panel", "separa la mascota del panel"].contains(normalized) { return "separate" }
        if ["oculta mascota", "oculta la mascota", "quita mascota", "quita la mascota"].contains(normalized) { return "ninguna" }
        for (verb, state) in [("saluda", "wave"), ("duerme", "sleep"), ("despierta", "wake")] {
            if [verb + " mascota", verb + " la mascota"].contains(normalized) { return state }
        }
        guard let value = CommandParser.tail("^(?:(?:elige|cambia a)(?: la)? )?mascota\\s+", in: normalized) else { return nil }
        let name = value.replacingOccurrences(of: "[\\s.-]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "([a-z])\\1+", with: "$1", options: .regularExpression)
        let aliases = ["tinku": "tinku", "tincu": "tinku", "tinko": "tinku", "cuchu": "cuchu", "kuchu": "cuchu", "cucho": "cuchu", "cuy": "cuchu", "yati": "yati", "yaty": "yati", "yate": "yati"]
        return aliases[name]
    }
}

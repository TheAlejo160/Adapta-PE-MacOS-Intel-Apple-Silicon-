import Foundation
import AVFoundation
import Vision
import CoreGraphics
import AppKit
import Combine
import CoreImage

final class TrackingManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published private(set) var isTracking = false
    @Published private(set) var isStarting = false
    @Published private(set) var statusMessage = "Cámara apagada"
    @Published private(set) var detectedPointUI: CGPoint?
    @Published private(set) var trackingTypeUI = ""
    @Published private(set) var clickProgress = 0.0
    @Published private(set) var availableCameras: [AVCaptureDevice] = []
    @Published var selectedCameraID = UserDefaults.standard.string(forKey: "SelectedCameraID") ?? "" {
        didSet { UserDefaults.standard.set(selectedCameraID, forKey: "SelectedCameraID"); if isTracking || isStarting { stopTracking(remember: false); startTracking() } }
    }
    @Published var controlMode = ControlModes.normalize(UserDefaults.standard.string(forKey: "ControlMode") ?? "cabeza") { didSet { updateSettings(recalibrate: true) } }
    @Published var isParkinsonMode = UserDefaults.standard.bool(forKey: "isParkinsonMode") { didSet { updateSettings(recalibrate: true) } }
    @Published var sensitivity = UserDefaults.standard.object(forKey: "Sensitivity") as? Double ?? 1 { didSet { updateSettings() } }
    @Published var reducedMovement = UserDefaults.standard.bool(forKey: "ReducedMovement") { didSet { updateSettings(recalibrate: true) } }
    @Published var dwellEnabled = UserDefaults.standard.object(forKey: "DwellEnabled") as? Bool ?? true { didSet { updateSettings() } }
    @Published var dwellDuration = UserDefaults.standard.object(forKey: "DwellDuration") as? Double ?? 1 { didSet { updateSettings() } }
    @Published var isPaused = UserDefaults.standard.bool(forKey: "CursorPaused") { didSet { UserDefaults.standard.set(isPaused, forKey: "CursorPaused"); let value = isPaused; queue.async { self.paused = value; self.state.calibrate(); self.gesture.reset() }; statusMessage = value ? "Cursor pausado" : "Calibrando postura cómoda" } }
    var zonaMuertaRadioUI: Double { isParkinsonMode ? 0.07 : 0.045 }
    var zonaAtraccionUI: Double { zonaMuertaRadioUI + 0.02 }
    let captureSession = AVCaptureSession()
    private let queue = DispatchQueue(label: "pe.adapta.video", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private let hands = VNDetectHumanHandPoseRequest()
    private let face = VNDetectFaceLandmarksRequest()
    private let body = VNDetectHumanBodyPoseRequest()
    private var gesture = GestureState()
    private var zone = ZoneTracker()
    private let zoneContext = CIContext(options: [.cacheIntermediates: false])
    private var zonePixels = [UInt8](repeating: 0, count: 76800)
    private var grayPixels = [Float](repeating: 0, count: 19200)
    private var state = KineticState()
    private var mode = "cabeza"
    private var source = ""
    private var previousHand: CGPoint?
    private var sourceBackup: (CGPoint, String, CGPoint?, Bool, Double?)?
    private var candidateSource = ""
    private var candidateSince = 0.0
    private var candidateFrames = 0
    private var cursor = CGPoint.zero
    private var screenFrames: [CGRect] = []
    private var pauseUntil = 0.0
    private var paused = false
    private var running = false
    private var nextRightClick = false
    private var lastFrame = 0.0
    private var lastDetection = 0.0
    private var lastHUD = 0.0
    private var lastTargetLookup = 0.0
    private var targetIdentity: String?
    private var targetCenter: CGPoint?
    private var lastMove = 0.0
    private var edgeRest: (Double, CGPoint)?
    private var generation = 0
    private let lifecycleLock = NSLock()
    var currentGeneration: Int { lifecycleLock.withLock { generation } }
    private func nextGeneration() -> Int { lifecycleLock.withLock { generation += 1; return generation } }
    func whileCurrent(_ token: Int, _ action: () -> Void) { lifecycleLock.withLock { if generation == token { action() } } }
    private var monitors: [Any] = []
    private var screenObserver: NSObjectProtocol?
    private var runtimeObserver: NSObjectProtocol?

    override init() {
        super.init()
        hands.maximumHandCount = 2
        updateSettings()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.refreshScreens() }
        runtimeObserver = NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: captureSession, queue: .main) { [weak self] _ in
            self?.stopTracking(); self?.statusMessage = "Cámara interrumpida. Vuelve a activar el cursor."
        }
    }
    deinit { monitors.forEach(NSEvent.removeMonitor); if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }; if let runtimeObserver { NotificationCenter.default.removeObserver(runtimeObserver) } }

    nonisolated static func validatedCameraID(_ selected: String, available: [String]) -> String {
        selected.isEmpty || available.contains(selected) ? selected : ""
    }
    func fetchCameras() {
        availableCameras = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified).devices
        let selection = Self.validatedCameraID(selectedCameraID, available: availableCameras.map(\.uniqueID))
        if selection != selectedCameraID { selectedCameraID = selection }
    }
    private func refreshScreens() {
        let frames = NSScreen.screens.compactMap { screen -> CGRect? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
            return CGDisplayBounds(id)
        }
        queue.async { self.screenFrames = frames; self.state.calibrate(); self.gesture.reset() }
    }
    private func updateSettings(recalibrate: Bool = false) {
        let settings = (controlMode, isParkinsonMode, sensitivity, reducedMovement, dwellEnabled, dwellDuration, isPaused)
        UserDefaults.standard.set(settings.0, forKey: "ControlMode")
        UserDefaults.standard.set(settings.1, forKey: "isParkinsonMode")
        UserDefaults.standard.set(settings.2, forKey: "Sensitivity")
        UserDefaults.standard.set(settings.3, forKey: "ReducedMovement")
        UserDefaults.standard.set(settings.4, forKey: "DwellEnabled")
        UserDefaults.standard.set(settings.5, forKey: "DwellDuration")
        queue.async {
            let newMode = ControlModes.normalize(settings.0), modeChanged = self.mode != newMode
            self.mode = newMode; self.state.fixedCenter = self.mode != "cabeza"; self.state.tremor = settings.1; self.paused = settings.6
            self.state.sensitivity = max(0.3, min(2, settings.2)); self.state.amplitude = settings.3 ? 0.55 : 1
            self.state.dwellEnabled = settings.4; self.state.dwellDuration = max(0.4, min(3, settings.5))
            self.state.cancelClick()
            if modeChanged { self.resetSource() } else if recalibrate { self.state.calibrate(); if !self.state.fixedCenter { self.gesture.reset() } }
        }
    }
    func startTracking() {
        guard !isTracking, !isStarting else { return }
        guard AXIsProcessTrusted() else { statusMessage = "Activa Accesibilidad para controlar el cursor"; return }
        let token = nextGeneration()
        isStarting = true; statusMessage = "Solicitando cámara…"
        let authorize: (Bool) -> Void = { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self, self.currentGeneration == token, self.isStarting else { return }
                guard allowed else { self.isStarting = false; self.statusMessage = "Cámara sin permiso. Revisa Privacidad."; return }
                self.configureCamera(token: token)
            }
        }
        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized { authorize(true) }
        else { AVCaptureDevice.requestAccess(for: .video, completionHandler: authorize) }
    }
    private func configureCamera(token: Int) {
        refreshScreens()
        let id = selectedCameraID
        queue.async {
            self.captureSession.beginConfiguration()
            self.captureSession.sessionPreset = .vga640x480
            self.captureSession.inputs.forEach { self.captureSession.removeInput($0) }
            do {
                guard let device = (id.isEmpty ? AVCaptureDevice.default(for: .video) : AVCaptureDevice(uniqueID: id)) else { throw CaptureFailure.missingDevice }
                let input = try AVCaptureDeviceInput(device: device)
                guard self.captureSession.canAddInput(input) else { throw CaptureFailure.missingDevice }
                self.captureSession.addInput(input)
                if self.captureSession.outputs.isEmpty {
                    self.output.alwaysDiscardsLateVideoFrames = true
                    self.output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    self.output.setSampleBufferDelegate(self, queue: self.queue)
                    guard self.captureSession.canAddOutput(self.output) else { throw CaptureFailure.missingDevice }
                    self.captureSession.addOutput(self.output)
                }
                if let range = device.activeFormat.videoSupportedFrameRateRanges.first, range.minFrameRate <= 30, range.maxFrameRate >= 30 {
                    try device.lockForConfiguration()
                    device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                    device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                    device.unlockForConfiguration()
                }
                self.captureSession.commitConfiguration()
                self.resetSource(); self.cursor = CGEvent(source: nil)?.location ?? .zero
                guard self.currentGeneration == token else { return }
                self.captureSession.startRunning(); self.running = true
                DispatchQueue.main.async {
                    guard self.currentGeneration == token, self.isStarting else { return }
                    self.isStarting = false; self.isTracking = true; UserDefaults.standard.set(true, forKey: "CameraActive"); self.statusMessage = self.controlMode == "cabeza" ? "Calibrando: mantén una postura cómoda" : "Centro fijo listo · mueve ligeramente la zona visible"
                    self.installMouseMonitors()
                }
            } catch {
                self.captureSession.commitConfiguration()
                DispatchQueue.main.async { if self.currentGeneration == token { self.isStarting = false; self.statusMessage = "No se pudo abrir la cámara: \(error.localizedDescription)" } }
            }
        }
    }
    func stopTracking(remember: Bool = true) {
        if remember { UserDefaults.standard.set(false, forKey: "CameraActive") }
        _ = nextGeneration(); isStarting = false; isTracking = false
        monitors.forEach(NSEvent.removeMonitor); monitors.removeAll()
        statusMessage = "Cámara apagada"; detectedPointUI = nil; clickProgress = 0
        queue.async { self.running = false; self.captureSession.stopRunning(); self.resetSource() }
    }
    private func installMouseMonitors() {
        guard monitors.isEmpty else { return }
        let receive: (NSEvent) -> Void = { [weak self] event in
            guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != DesktopAccess.eventTag else { return }
            self?.queue.async { guard let self else { return }; self.pauseUntil = ProcessInfo.processInfo.systemUptime + 2; self.cursor = event.cgEvent?.location ?? self.cursor; self.state.calibrate(); self.gesture.reset() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged], handler: receive) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged], handler: { event in receive(event); return event }) { monitors.append(local) }
    }
    func calibrate() { queue.async { self.state.calibrate(); self.gesture.reset(); self.zone.reset(); self.edgeRest = nil }; statusMessage = controlMode == "cabeza" ? "Calibrando postura cómoda · sin clic" : "Centro fijo listo · mueve ligeramente la zona visible" }
    func action(_ command: String) {
        switch command {
        case "activar": startTracking()
        case "desactivar": stopTracking()
        case "pausar": isPaused = true
        case "reanudar": isPaused = false
        case "calibrar": calibrate()
        case "temblor": isParkinsonMode = true
        case "sin_temblor": isParkinsonMode = false
        case "movimiento_reducido": reducedMovement = true
        case "movimiento_normal": reducedMovement = false
        case "lento": sensitivity = max(0.3, sensitivity - 0.2)
        case "rapido": sensitivity = min(2, sensitivity + 0.2)
        case "preparar_derecho": queue.async { self.nextRightClick = true; self.state.cancelClick() }
        case "cancelar": queue.async { self.nextRightClick = false; self.state.cancelClick() }
        case "derecho", "izquierdo": queue.async { self.state.cancelClick(); DesktopAccess.click(right: command == "derecho") }
        default: if ["automatico", "manos", "cabeza", "torso", "brazo_izquierdo", "brazo_derecho", "zona"].contains(command) { controlMode = ControlModes.normalize(command) }
        }
    }
    private func resetSource() {
        source = ""; candidateSource = ""; candidateFrames = 0; lastFrame = 0; lastDetection = 0
        zone.reset(); gesture.reset(); previousHand = nil; sourceBackup = nil; targetIdentity = nil; targetCenter = nil; state.calibrate(); edgeRest = nil
    }
    private func detect(_ buffer: CVPixelBuffer, time: Double) throws -> (CGPoint, String, CGPoint?, Bool, Double?)? {
        sourceBackup = nil
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
        if mode == "zona" {
            let sx = 160.0 / Double(CVPixelBufferGetWidth(buffer)), sy = 120.0 / Double(CVPixelBufferGetHeight(buffer))
            let image = CIImage(cvPixelBuffer: buffer).transformed(by: CGAffineTransform(a: -sx, b: 0, c: 0, d: -sy, tx: 160, ty: 120))
            zonePixels.withUnsafeMutableBytes { bytes in zoneContext.render(image, toBitmap: bytes.baseAddress!, rowBytes: 640, bounds: CGRect(x: 0, y: 0, width: 160, height: 120), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()) }
            for i in grayPixels.indices { let j = i * 4; grayPixels[i] = Float(zonePixels[j]) * 0.299 + Float(zonePixels[j + 1]) * 0.587 + Float(zonePixels[j + 2]) * 0.114 }
            guard let point = zone.update(grayPixels, time: time) else { return nil }
            return (point, "zona:\(zone.revision)", nil, false, zone.angle)
        }
        if mode == "manos" {
            try handler.perform([hands])
            let candidates = (hands.results ?? []).compactMap { hand -> (CGPoint, VNHumanHandPoseObservation)? in
                guard let wrist = try? hand.recognizedPoint(.wrist), wrist.confidence >= 0.5 else { return nil }
                return (CGPoint(x: 1 - wrist.location.x, y: 1 - wrist.location.y), hand)
            }
            let selected = previousHand.flatMap { previous in candidates.min { hypot($0.0.x - previous.x, $0.0.y - previous.y) < hypot($1.0.x - previous.x, $1.0.y - previous.y) } } ?? candidates.first
            if let (wrist, hand) = selected, previousHand == nil || source != "manos" || hypot(wrist.x - previousHand!.x, wrist.y - previousHand!.y) <= 0.2 {
                previousHand = wrist
                if source.hasPrefix("brazo:") {
                    try handler.perform([body])
                    let names: [VNHumanBodyPoseObservation.JointName] = [.leftWrist, .rightWrist, .leftElbow, .rightElbow]
                    if let name = names.first(where: { source == "brazo:" + $0.rawValue.rawValue }), let p = try body.results?.first?.recognizedPoint(name), p.confidence >= 0.5 {
                        let backup = CGPoint(x: 1 - p.location.x, y: 1 - p.location.y)
                        if backup.x >= 0, backup.x <= 1, backup.y >= 0, backup.y <= 1 { sourceBackup = (backup, source, nil, false, nil) }
                    }
                }
                func vector(_ name: VNHumanHandPoseObservation.JointName) -> CGPoint? {
                    guard let p = try? hand.recognizedPoint(name), p.confidence >= 0.5 else { return nil }
                    return CGPoint(x: 1 - p.location.x - wrist.x, y: (1 - p.location.y - wrist.y) * 0.75)
                }
                let pairs: [(VNHumanHandPoseObservation.JointName, VNHumanHandPoseObservation.JointName)] = [(.indexMCP, .indexTip), (.middleMCP, .middleTip), (.ringMCP, .ringTip), (.littleMCP, .littleTip)]
                let extended = pairs.compactMap { pair -> CGPoint? in guard let base = vector(pair.0), let tip = vector(pair.1), hypot(tip.x, tip.y) > hypot(base.x, base.y) * 1.25 else { return nil }; return tip }
                let pointing = extended.count == 1 || extended.count == 2 && (extended[0].x * extended[1].x + extended[0].y * extended[1].y) / max(0.000001, hypot(extended[0].x, extended[0].y) * hypot(extended[1].x, extended[1].y)) > 0.85
                if pointing {
                    let direction = extended.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }, length = max(0.000001, hypot(direction.x, direction.y))
                    return (wrist, "manos", CGPoint(x: direction.x / length * 0.2, y: direction.y / length * 0.2), true, nil)
                }
                let direction = vector(.middleMCP)
                return (wrist, "manos", nil, false, direction.map { atan2($0.y, $0.x) })
            }
        } else {
            try handler.perform([face])
            if let observation = face.results?.first, observation.confidence >= 0.65 {
                let box = observation.boundingBox
                var point = CGPoint(x: box.midX, y: box.midY)
                if let nose = observation.landmarks?.nose?.normalizedPoints, !nose.isEmpty {
                    let center = nose.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
                    point = CGPoint(x: box.minX + center.x / Double(nose.count) * box.width, y: box.minY + center.y / Double(nose.count) * box.height)
                    if let yaw = observation.yaw { point.x += yaw.doubleValue * 0.12 }
                }
                return (CGPoint(x: 1 - point.x, y: 1 - point.y), "cabeza", nil, false, nil)
            }
        }
        try handler.perform([body])
        guard let observation = body.results?.first else { return nil }
        func joint(_ name: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
            guard let p = try? observation.recognizedPoint(name), p.confidence >= (mode == "manos" ? 0.5 : 0.65) else { return nil }
            let point = CGPoint(x: 1 - p.location.x, y: 1 - p.location.y)
            return point.x >= 0 && point.x <= 1 && point.y >= 0 && point.y <= 1 ? point : nil
        }
        if mode == "manos" {
            if source == "manos", let previousHand {
                let nearest = [joint(.leftWrist), joint(.rightWrist)].compactMap { $0 }.min { hypot($0.x - previousHand.x, $0.y - previousHand.y) < hypot($1.x - previousHand.x, $1.y - previousHand.y) }
                guard let nearest, hypot(nearest.x - previousHand.x, nearest.y - previousHand.y) <= 0.2 else { return nil }
                self.previousHand = nearest; return (nearest, source, nil, false, nil)
            }
            let joints: [VNHumanBodyPoseObservation.JointName] = [.leftWrist, .rightWrist, .leftElbow, .rightElbow]
            let retained = joints.first { source == "brazo:" + $0.rawValue.rawValue && joint($0) != nil }
            guard let name = retained ?? joints.first(where: { joint($0) != nil }), let point = joint(name) else { return nil }
            return (point, "brazo:" + name.rawValue.rawValue, nil, false, nil)
        }
        if let point = joint(.nose) { return (point, "cabeza corporal", nil, false, nil) }
        if let left = joint(.leftShoulder), let right = joint(.rightShoulder) { return (CGPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2), "torso", nil, false, nil) }
        return nil
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard running, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = ProcessInfo.processInfo.systemUptime, token = currentGeneration
        guard now - lastFrame >= 1.0 / 30 else { return }; lastFrame = now
        if paused || now < pauseUntil { state.cancelClick(); gesture.reset(); publish(point: nil, message: paused ? "Cursor pausado" : "Pausa por ratón físico", now: now, token: token); return }
        guard AXIsProcessTrusted() else { state.cancelClick(); publish(point: nil, message: "Falta permiso de Accesibilidad", now: now, token: token); return }
        do {
            guard let detection = try detect(buffer, time: now) else {
                state.lost(at: now); gesture.reset(); candidateFrames = 0; candidateSource = ""
                if lastDetection > 0, now - lastDetection >= 1.2 { source = ""; zone.reset(); previousHand = nil }
                publish(point: nil, message: "Buscando \(mode)…", now: now, token: token); return
            }
            guard currentGeneration == token else { return }
            var (point, detectedSource, tilt, pointing, angle) = detection
            guard CMClockGetTime(CMClockGetHostTimeClock()).seconds - CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds < 0.5 else { state.lost(at: now); return }
            lastDetection = now
            if source != detectedSource {
                state.cancelClick()
                if candidateSource != detectedSource { candidateSource = detectedSource; candidateSince = now; candidateFrames = 0 }
                candidateFrames += 1
                if candidateFrames >= 3, now - candidateSince >= 0.15 { source = detectedSource; state.calibrate(); gesture.reset() }
                else if let backup = sourceBackup, backup.1 == source { (point, detectedSource, tilt, pointing, angle) = backup }
                else { publish(point: nil, message: "Confirmando \(detectedSource)…", now: now, token: token); return }
            } else { candidateSource = ""; candidateFrames = 0 }
            if state.origin != nil, hypot(state.smooth.x - 0.5, state.smooth.y - 0.5) < state.attractionRadius {
                if now - lastTargetLookup >= 0.1 { let target = DesktopAccess.cursorTarget(at: cursor); targetIdentity = target?.identity; targetCenter = target?.center; lastTargetLookup = now }
            } else { targetIdentity = nil; targetCenter = nil }
            let target = targetIdentity
            let control = state.fixedCenter ? gesture.update(point, time: now, tilt: tilt, pointing: pointing, angle: angle) : point
            if state.fixedCenter, gesture.resetNow { state.cancelClick() }
            let result = state.update(control, time: now, aspect: state.fixedCenter ? 1 : Double(CVPixelBufferGetHeight(buffer)) / Double(CVPixelBufferGetWidth(buffer)), target: target)
            if state.calibratedNow { DispatchQueue.main.async { if self.currentGeneration == token, self.isTracking { ActionManager.shared.hablar("Cursor listo. Postura cómoda calibrada.") } } }
            let previous = cursor
            cursor = nearestScreenPoint(CGPoint(x: cursor.x + result.delta.x, y: cursor.y + result.delta.y))
            if let center = targetCenter, !state.fixedCenter || !gesture.resetNow { cursor = nearestScreenPoint(cursorAttraction(cursor, center: center, speed: hypot(state.velocity.x, state.velocity.y), dt: max(0, now - lastMove))) }; lastMove = now
            if hypot(cursor.x - previous.x, cursor.y - previous.y) > 0.5 { whileCurrent(token) { DesktopAccess.move(to: cursor) } }
            if result.click, let current = CGEvent(source: nil)?.location, hypot(current.x - cursor.x, current.y - cursor.y) <= 3, let target, DesktopAccess.targetIdentity(at: current) == target { whileCurrent(token) { DesktopAccess.click(right: nextRightClick) }; nextRightClick = false }
            if !state.fixedCenter, hypot(result.delta.x, result.delta.y) > 0, hypot(cursor.x - previous.x, cursor.y - previous.y) < 0.01 {
                if let rest = edgeRest, hypot(point.x - rest.1.x, point.y - rest.1.y) < (state.tremor ? 0.045 : 0.025) {
                    if now - rest.0 >= 1.2 { state.calibrate(); gesture.reset(); edgeRest = nil }
                } else { edgeRest = (now, point) }
            } else { edgeRest = nil }
            let message = state.origin == nil ? "Calibrando: mantén postura cómoda" : result.click ? "Clic realizado" : state.progress > 0 ? "Clic por permanencia" : result.delta == .zero ? "Zona segura · mueve para habilitar clic" : "Moviendo · \(source)"
            publish(point: state.origin == nil ? nil : state.smooth, message: message, now: now, token: token)
        } catch { state.lost(at: now); gesture.reset(); publish(point: nil, message: "No se pudo analizar la cámara", now: now, token: token) }
    }
    private func nearestScreenPoint(_ point: CGPoint) -> CGPoint {
        guard !screenFrames.isEmpty else { return cursor }
        return screenFrames.map { CGRect(x: $0.minX + 1, y: $0.minY + 1, width: $0.width - 2, height: $0.height - 2) }.map {
            CGPoint(x: max($0.minX, min($0.maxX, point.x)), y: max($0.minY, min($0.maxY, point.y)))
        }.min { hypot($0.x - point.x, $0.y - point.y) < hypot($1.x - point.x, $1.y - point.y) } ?? cursor
    }
    private func publish(point: CGPoint?, message: String, now: Double, token: Int) {
        guard now - lastHUD >= 0.1 else { return }; lastHUD = now
        let progress = state.progress, currentSource = source
        DispatchQueue.main.async { guard self.isTracking, self.currentGeneration == token else { return }; self.detectedPointUI = point; self.statusMessage = message; self.trackingTypeUI = currentSource; self.clickProgress = progress }
    }
}

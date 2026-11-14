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
    @Published var dwellDuration = min(KineticDefaults.dwellMaximo, max(KineticDefaults.dwellMinimo, UserDefaults.standard.object(forKey: "DwellDuration") as? Double ?? KineticDefaults.dwell)) { didSet { updateSettings() } }
    @Published var attractionEnabled = UserDefaults.standard.object(forKey: "AttractionEnabled") as? Bool ?? KineticDefaults.atraccionActiva { didSet { updateSettings() } }
    @Published var isPaused = UserDefaults.standard.bool(forKey: "CursorPaused") { didSet { UserDefaults.standard.set(isPaused, forKey: "CursorPaused"); let value = isPaused; queue.async { self.paused = value; self.state.calibrate(); self.gesture.reset(); self.clickGesture.reset(); self.reliableSince = nil }; statusMessage = value ? "Cursor pausado" : "Calibrando postura cómoda" } }
    var zonaMuertaRadioUI: Double { isParkinsonMode ? KineticDefaults.zonaMuertaTemblor : KineticDefaults.zonaMuerta }
    var zonaAtraccionUI: Double { zonaMuertaRadioUI + KineticDefaults.margenAtraccion }
    let captureSession = AVCaptureSession()
    // Captura, Vision/física y consultas AX en colas separadas: una inferencia lenta descarta imágenes en lugar de encolarlas.
    private let captureQueue = DispatchQueue(label: "pe.adapta.video", qos: .userInitiated)
    private let queue = DispatchQueue(label: "pe.adapta.vision", qos: .userInitiated)
    private let targetQueue = DispatchQueue(label: "pe.adapta.cursor-target", qos: .userInitiated)
    private let frameLock = NSLock()
    private var frameBusy = false // frameLock
    private var restUntil = 0.0   // frameLock
    private var load = AdaptiveLoad()
    private var clickGesture = ClickGesture()
    private var attraction = KineticDefaults.atraccionActiva
    private var reliableSince: Double?
    private var lostSince: Double?
    private var lastPoint: CGPoint?
    private var lastFallback = false
    private var targetLookupInFlight = false
    private var targetEpoch = 0
    private var targetLeftAt: Double?
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
    private var sourceBackup: Detection?
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
        let settings = (controlMode, isParkinsonMode, sensitivity, reducedMovement, dwellEnabled, dwellDuration, isPaused, attractionEnabled)
        UserDefaults.standard.set(settings.7, forKey: "AttractionEnabled")
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
            self.state.dwellEnabled = settings.4; self.state.dwellDuration = max(KineticDefaults.dwellMinimo, min(KineticDefaults.dwellMaximo, settings.5))
            self.gesture.deadRadius = self.state.deadRadius; self.gesture.amplitude = self.state.amplitude; self.attraction = settings.7
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
                    self.output.setSampleBufferDelegate(self, queue: self.captureQueue)
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
            self?.queue.async { guard let self else { return }; self.pauseUntil = ProcessInfo.processInfo.systemUptime + 2; self.cursor = event.cgEvent?.location ?? self.cursor; self.state.calibrate(); self.gesture.reset(); self.clickGesture.reset() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged], handler: receive) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged], handler: { event in receive(event); return event }) { monitors.append(local) }
    }
    func calibrate() { queue.async { self.state.calibrate(); self.gesture.reset(); self.clickGesture.reset(); self.zone.reset(); self.edgeRest = nil }; statusMessage = controlMode == "cabeza" ? "Calibrando postura cómoda · sin clic" : "Centro fijo listo · mueve ligeramente la zona visible" }
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
        zone.reset(); gesture.reset(); clickGesture.reset(); load.reset(); previousHand = nil; sourceBackup = nil; targetIdentity = nil; targetCenter = nil; targetEpoch += 1; targetLeftAt = nil; state.calibrate(); edgeRest = nil
        reliableSince = nil; lostSince = nil; lastPoint = nil; lastFallback = false
        frameLock.withLock { restUntil = 0 }
    }
    struct Detection {
        var point: CGPoint
        var source: String
        var pose: HandPose?
        var angle: Double?
        var click: ClickSignal?
        var fallback = false
    }
    /// Orden MediaPipe 0…20 a partir de las articulaciones de Vision.
    private static let handJoints: [VNHumanHandPoseObservation.JointName] = [.wrist, .thumbCMC, .thumbMP, .thumbIP, .thumbTip, .indexMCP, .indexPIP, .indexDIP, .indexTip, .middleMCP, .middlePIP, .middleDIP, .middleTip, .ringMCP, .ringPIP, .ringDIP, .ringTip, .littleMCP, .littlePIP, .littleDIP, .littleTip]
    private static func handPoints(_ hand: VNHumanHandPoseObservation) -> [CGPoint?] {
        let points = (try? hand.recognizedPoints(.all)) ?? [:]
        return handJoints.map { name in points[name].flatMap { $0.confidence >= 0.3 ? CGPoint(x: 1 - $0.location.x, y: 1 - $0.location.y) : nil } }
    }
    private func detect(_ buffer: CVPixelBuffer, time: Double) throws -> Detection? {
        sourceBackup = nil
        let width = Double(CVPixelBufferGetWidth(buffer)), height = Double(CVPixelBufferGetHeight(buffer)), aspect = height / width
        let scale = load.scale
        // Carga adaptativa: menos detalle en equipos lentos; nunca amplía.
        let handler = scale < 1 ? VNImageRequestHandler(ciImage: CIImage(cvPixelBuffer: buffer).transformed(by: CGAffineTransform(scaleX: scale, y: scale)), orientation: .up, options: [:])
                                : VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
        if mode == "zona" {
            let sx = 160.0 / width, sy = 120.0 / height
            let image = CIImage(cvPixelBuffer: buffer).transformed(by: CGAffineTransform(a: -sx, b: 0, c: 0, d: -sy, tx: 160, ty: 120))
            zonePixels.withUnsafeMutableBytes { bytes in zoneContext.render(image, toBitmap: bytes.baseAddress!, rowBytes: 640, bounds: CGRect(x: 0, y: 0, width: 160, height: 120), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()) }
            for i in grayPixels.indices { let j = i * 4; grayPixels[i] = Float(zonePixels[j]) * 0.299 + Float(zonePixels[j + 1]) * 0.587 + Float(zonePixels[j + 2]) * 0.114 }
            guard let point = zone.update(grayPixels, time: time) else { return nil }
            return Detection(point: point, source: "zona:\(zone.revision)", angle: zone.angle)
        }
        if mode == "manos" {
            try handler.perform([hands])
            // Mano falsa: adquirir exige confianza >=0,8; conservar la mano seguida sin pérdida, >=0,6.
            let tracking = source.hasPrefix("manos") && lostSince == nil
            let candidates = (hands.results ?? []).compactMap { hand -> (anchor: CGPoint, palm: Bool, points: [CGPoint?], confidence: Double)? in
                let points = Self.handPoints(hand)
                let knuckles = [5, 9, 13, 17].compactMap { HandGeometry.valid(points, $0) ? points[$0] : nil }
                let palm = knuckles.count >= 2 ? CGPoint(x: knuckles.map(\.x).reduce(0, +) / Double(knuckles.count), y: knuckles.map(\.y).reduce(0, +) / Double(knuckles.count)) : nil
                // El ancla de palma persiste aunque vuelva la muñeca: evita oscilar en el borde del cuadro.
                if source != "manos:palma", HandGeometry.valid(points, 0), let wrist = points[0] { return (wrist, false, points, Double(hand.confidence)) }
                return palm.map { ($0, true, points, Double(hand.confidence)) }
            }
            if let index = HandGeometry.choose(candidates.map { ($0.anchor, $0.confidence, HandGeometry.skeletonValid($0.points, aspect: aspect)) }, previous: previousHand, tracking: tracking) {
                let hand = candidates[index]
                previousHand = hand.anchor
                if source.hasPrefix("brazo:") {
                    try handler.perform([body])
                    let names: [VNHumanBodyPoseObservation.JointName] = [.leftWrist, .rightWrist, .leftElbow, .rightElbow]
                    if let name = names.first(where: { source == "brazo:" + $0.rawValue.rawValue }), let p = try body.results?.first?.recognizedPoint(name), p.confidence >= 0.5 {
                        let backup = CGPoint(x: 1 - p.location.x, y: 1 - p.location.y)
                        if backup.x >= 0, backup.x <= 1, backup.y >= 0, backup.y <= 1 { sourceBackup = Detection(point: backup, source: source) }
                    }
                }
                let pose = HandGeometry.pose(hand.points, aspect: aspect), pinch = HandGeometry.pinch(hand.points, aspect: aspect)
                // Un puño no inicia pinza por proximidad pulgar-índice; una pinza ya suelta conserva su liberación.
                return Detection(point: hand.anchor, source: hand.palm ? "manos:palma" : "manos", pose: pose, angle: pose.angle, click: pose.fist && pinch != .released ? nil : pinch)
            }
        } else {
            try handler.perform([face])
            if let observation = face.results?.first, observation.confidence >= 0.65 {
                let box = observation.boundingBox, landmarks = observation.landmarks
                func centroid(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
                    guard let points = region?.normalizedPoints, !points.isEmpty else { return nil }
                    let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
                    return CGPoint(x: box.minX + sum.x / Double(points.count) * box.width, y: box.minY + sum.y / Double(points.count) * box.height)
                }
                var point = centroid(landmarks?.nose) ?? CGPoint(x: box.midX, y: box.midY)
                // Nariz respecto al centro de los ojos (como la extensión): sustituye el yaw cuantizado que temblaba.
                if let left = centroid(landmarks?.leftEye), let right = centroid(landmarks?.rightEye), landmarks?.nose != nil {
                    let eyes = hypot(right.x - left.x, right.y - left.y)
                    if eyes >= 0.025 { point = CGPoint(x: point.x + (point.x - (left.x + right.x) / 2) / eyes * 0.12, y: point.y + (point.y - (left.y + right.y) / 2) / eyes * 0.12) }
                }
                let mouth = (landmarks?.innerLips?.normalizedPoints).flatMap { lips in
                    HandGeometry.mouth(lips.map { CGPoint(x: Double($0.x) * box.width * width, y: Double($0.y) * box.height * height) })
                }
                return Detection(point: CGPoint(x: 1 - point.x, y: 1 - point.y), source: "cabeza", click: HandGeometry.mouthSignal(mouth))
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
            if source.hasPrefix("manos"), let previousHand {
                let nearest = [joint(.leftWrist), joint(.rightWrist)].compactMap { $0 }.min { hypot($0.x - previousHand.x, $0.y - previousHand.y) < hypot($1.x - previousHand.x, $1.y - previousHand.y) }
                // Una pérdida de mano no elige otro codo incidental.
                guard let nearest, hypot(nearest.x - previousHand.x, nearest.y - previousHand.y) <= 0.2 else { return nil }
                self.previousHand = nearest; return Detection(point: nearest, source: source, fallback: true)
            }
            let joints: [VNHumanBodyPoseObservation.JointName] = [.leftWrist, .rightWrist, .leftElbow, .rightElbow]
            let retained = joints.first { source == "brazo:" + $0.rawValue.rawValue && joint($0) != nil }
            guard let name = retained ?? joints.first(where: { joint($0) != nil }), let point = joint(name) else { return nil }
            return Detection(point: point, source: "brazo:" + name.rawValue.rawValue)
        }
        if let point = joint(.nose) { return Detection(point: point, source: "cabeza corporal") }
        if let left = joint(.leftShoulder), let right = joint(.rightShoulder) { return Detection(point: CGPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2), source: "torso") }
        return nil
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // Una sola imagen en vuelo: mientras Vision trabaja (o descansa por carga) las demás se descartan.
        let accepted = frameLock.withLock { () -> Bool in
            guard !frameBusy, now >= restUntil else { return false }
            frameBusy = true; return true
        }
        guard accepted else { return }
        let presentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        queue.async {
            defer { self.frameLock.withLock { self.frameBusy = false } }
            self.process(buffer, presentation: presentation)
        }
    }
    private func process(_ buffer: CVPixelBuffer, presentation: Double) {
        guard running else { return }
        let now = ProcessInfo.processInfo.systemUptime, token = currentGeneration
        guard now - lastFrame >= 1.0 / 30 - 0.005 else { return }; lastFrame = now
        if paused || now < pauseUntil { state.cancelClick(); gesture.reset(); clickGesture.reset(); reliableSince = nil; publish(point: nil, message: paused ? "Cursor pausado" : "Pausa por ratón físico", now: now, token: token); return }
        guard AXIsProcessTrusted() else { state.cancelClick(); publish(point: nil, message: "Falta permiso de Accesibilidad", now: now, token: token); return }
        do {
            let started = ProcessInfo.processInfo.systemUptime
            let found = try detect(buffer, time: now)
            let finished = ProcessInfo.processInfo.systemUptime
            load.measure((finished - started) * 1000, maxLevel: mode == "manos" ? 2 : 1)
            frameLock.withLock { restUntil = finished + load.rest }
            guard let detection = found else {
                state.lost(at: now); gesture.forgetFist(); clickGesture.reset(); candidateFrames = 0; candidateSource = ""
                if lostSince == nil { lostSince = now }; reliableSince = nil
                // Manos: tras 500 ms una mano nueva vuelve a confirmarse (>=3 inferencias y >=150 ms).
                if lastDetection > 0, now - lastDetection >= (mode == "manos" ? KineticDefaults.manoOlvido : 1.2) { source = ""; previousHand = nil }
                publish(point: nil, message: "Buscando \(mode)…", now: now, token: token); return
            }
            guard currentGeneration == token else { return }
            var current = detection
            guard CMClockGetTime(CMClockGetHostTimeClock()).seconds - presentation < 0.5 else { state.lost(at: now); return }
            lastDetection = now
            if source != current.source {
                state.cancelClick(); clickGesture.reset()
                if candidateSource != current.source { candidateSource = current.source; candidateSince = now; candidateFrames = 0 }
                candidateFrames += 1
                if candidateFrames >= KineticDefaults.manoNuevaInferencias, now - candidateSince >= KineticDefaults.manoNuevaTiempo { source = current.source; state.calibrate(); gesture.reset(); reliableSince = nil; lastPoint = nil }
                else if let backup = sourceBackup, backup.source == source { current = backup }
                else { publish(point: nil, message: "Confirmando \(current.source)…", now: now, token: token); return }
            } else { candidateSource = ""; candidateFrames = 0 }
            let point = current.point
            if let last = lastPoint, source.hasPrefix("manos") {
                let separation = hypot(point.x - last.x, point.y - last.y)
                if lostSince != nil, separation > 0.1 { gesture.reset() }
                else if separation > 0.2 { gesture.reset(); state.recenter(); state.cancelClick(); clickGesture.reset() } // Otra mano o salto del modelo: nuevo reposo.
                else if current.fallback != lastFallback { gesture.shift(by: CGPoint(x: point.x - last.x, y: point.y - last.y)) }
            }
            lastFallback = current.fallback; lastPoint = point; lostSince = nil
            if reliableSince == nil { reliableSince = now }
            let reliable = now - (reliableSince ?? now) >= KineticDefaults.estabilizarClic
            if !reliable { state.cancelClick() } // Estabilizar el clic sin bloquear movimiento.
            lookUpTarget(now: now, token: token)
            if mode != "zona" {
                let (holding, output) = clickGesture.update(current.click, kind: mode == "manos" ? .pinch : .mouth, inference: now)
                if output != .none, reliable, state.origin != nil {
                    let right = output == .rightClick || nextRightClick
                    nextRightClick = false; state.cancelClick(); gesture.forgetFist()
                    whileCurrent(token) { DesktopAccess.click(right: right) }
                }
                if holding {
                    // Cursor quieto durante el gesto para que el clic no se desvíe del objetivo.
                    state.cancelFixation()
                    let input = mode == "manos" ? (clickGesture.rightDone ? "pinzaHecho" : nextRightClick ? "pinzaDerecho" : "pinza") : nextRightClick ? "bocaDerecho" : "boca"
                    publish(point: state.origin == nil ? nil : state.smooth, message: "", input: input, now: now, token: token); return
                }
            }
            let target = targetIdentity
            let pose = current.pose
            let control = state.fixedCenter ? gesture.update(point, time: now, tilt: pose?.pointing == true ? pose?.tilt : nil, pointing: pose?.pointing ?? false, angle: current.angle, open: pose?.open ?? false, fist: pose?.fist ?? false) : point
            if state.fixedCenter {
                if gesture.resetNow { state.cancelClick() }
                switch gesture.event {
                case .rest: state.recenter(); if reliable { state.armRest() } // Cerrar deliberadamente la mano arma el dwell.
                case .restExit: state.recenter(); state.cancelClick()
                case .inputChanged: state.recenter(); state.cancelFixation()
                case .none: break
                }
            }
            let result = state.update(control, time: now, aspect: state.fixedCenter ? 1 : Double(CVPixelBufferGetHeight(buffer)) / Double(CVPixelBufferGetWidth(buffer)), target: target)
            if state.calibratedNow { DispatchQueue.main.async { if self.currentGeneration == token, self.isTracking { ActionManager.shared.hablar("Cursor listo. Postura cómoda calibrada.") } } }
            let previous = cursor
            cursor = nearestScreenPoint(CGPoint(x: cursor.x + result.delta.x, y: cursor.y + result.delta.y))
            if attraction, let center = targetCenter, !state.fixedCenter || !gesture.resetNow { cursor = nearestScreenPoint(cursorAttraction(cursor, center: center, speed: hypot(state.velocity.x, state.velocity.y), dt: max(0, now - lastMove))) }; lastMove = now
            if hypot(cursor.x - previous.x, cursor.y - previous.y) > 0.5 { whileCurrent(token) { DesktopAccess.move(to: cursor) } }
            if result.click, let target {
                let at = cursor, right = nextRightClick
                // Verificación AX fuera de la cola de Vision.
                targetQueue.async {
                    guard let current = CGEvent(source: nil)?.location, hypot(current.x - at.x, current.y - at.y) <= 3, DesktopAccess.targetIdentity(at: current) == target else { return }
                    self.whileCurrent(token) { DesktopAccess.click(right: right) }
                    self.queue.async { if right { self.nextRightClick = false } }
                }
            }
            if !state.fixedCenter, hypot(result.delta.x, result.delta.y) > 0, hypot(cursor.x - previous.x, cursor.y - previous.y) < 0.01 {
                if let rest = edgeRest, hypot(point.x - rest.1.x, point.y - rest.1.y) < (state.tremor ? 0.045 : 0.025) {
                    if now - rest.0 >= 1.2 { state.calibrate(); gesture.reset(); edgeRest = nil }
                } else { edgeRest = (now, point) }
            } else { edgeRest = nil }
            let message = state.origin == nil ? "Calibrando: mantén postura cómoda" : result.click ? "Clic realizado" : state.progress > 0 ? "Clic por permanencia" : result.delta == .zero ? "Zona segura · mueve para habilitar clic" : "Moviendo"
            let input = !state.fixedCenter ? nil : gesture.fistActive ? "puno" : gesture.fistDetected && !gesture.openRecently ? "punoPreparar" : gesture.signalActive ? "senal" : "joystick"
            publish(point: state.origin == nil ? nil : state.smooth, message: message, input: input, now: now, token: token)
        } catch { state.lost(at: now); gesture.reset(); clickGesture.reset(); reliableSince = nil; publish(point: nil, message: "No se pudo analizar la cámara", now: now, token: token) }
    }
    /// Objetivo bajo el cursor para atracción y dwell, consultado fuera de la cola de Vision (10 Hz, una consulta en vuelo).
    private func lookUpTarget(now: Double, token: Int) {
        guard state.origin != nil, hypot(state.smooth.x - 0.5, state.smooth.y - 0.5) < state.attractionRadius else {
            // Salir del anillo suelta la atracción al instante; la identidad se conserva 0,25 s para que un regreso
            // rápido no deje el dwell sin objetivo hasta la siguiente consulta.
            if targetLeftAt == nil { targetLeftAt = now; targetCenter = nil; targetEpoch += 1 }
            if !Self.retainsTarget(leftAt: targetLeftAt, now: now) { targetIdentity = nil }
            return
        }
        targetLeftAt = nil
        guard !targetLookupInFlight, now - lastTargetLookup >= 0.1 else { return }
        targetLookupInFlight = true; lastTargetLookup = now
        let at = cursor, epoch = targetEpoch
        targetQueue.async {
            let target = self.currentGeneration == token ? DesktopAccess.cursorTarget(at: at) : nil
            self.queue.async {
                self.targetLookupInFlight = false
                guard self.targetEpoch == epoch, self.currentGeneration == token else { return }
                self.targetIdentity = target?.identity; self.targetCenter = target?.center
            }
        }
    }
    static func retainsTarget(leftAt: Double?, now: Double) -> Bool { leftAt.map { now - $0 < KineticDefaults.cambioObjetivo } ?? true }
    private func nearestScreenPoint(_ point: CGPoint) -> CGPoint {
        guard !screenFrames.isEmpty else { return cursor }
        return screenFrames.map { CGRect(x: $0.minX + 1, y: $0.minY + 1, width: $0.width - 2, height: $0.height - 2) }.map {
            CGPoint(x: max($0.minX, min($0.maxX, point.x)), y: max($0.minY, min($0.maxY, point.y)))
        }.min { hypot($0.x - point.x, $0.y - point.y) < hypot($1.x - point.x, $1.y - point.y) } ?? cursor
    }
    /// HUD: fuente (Mano/Brazo/…) · entrada (señal/joystick/puño/pinza/boca) · estado, en el idioma de la interfaz.
    private func publish(point: CGPoint?, message: String, input: String? = nil, now: Double, token: Int) {
        guard now - lastHUD >= 0.1 else { return }; lastHUD = now
        let progress = state.progress, kind = Self.sourceKind(source)
        DispatchQueue.main.async {
            guard self.isTracking, self.currentGeneration == token else { return }
            let name = kind.map { Self.hudText($0) } ?? ""
            self.detectedPointUI = point; self.trackingTypeUI = name; self.clickProgress = progress
            self.statusMessage = [name, input.map { Self.hudText($0) } ?? "", message].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }
    static func sourceKind(_ source: String) -> String? {
        if source.hasPrefix("manos") { return "mano" }
        if source.hasPrefix("brazo:") { return "brazo" }
        if source.hasPrefix("zona") { return "zona" }
        return ["cabeza": "cabeza", "cabeza corporal": "cabezaCorporal", "torso": "torso"][source]
    }
    // Textos propios del cursor (los mismos de KineticEngine.js); Textos.swift se comparte con Lite y no se toca.
    private static let hudTextos: [String: [String: String]] = [
        "es": ["mano": "Mano", "brazo": "Brazo", "zona": "Zona libre", "cabeza": "cabeza", "cabezaCorporal": "cabeza corporal", "torso": "torso", "senal": "señal", "joystick": "joystick", "puno": "puño · reposo", "punoPreparar": "puño · abre la mano para preparar reposo", "pinza": "pinza · suelta: clic · mantén: derecho", "pinzaDerecho": "pinza · suelta: clic derecho", "pinzaHecho": "pinza · clic derecho hecho, suelta", "boca": "boca abierta · cierra: clic", "bocaDerecho": "boca abierta · cierra: clic derecho", "atraccion": "Atracción suave a controles"],
        "en": ["mano": "Hand", "brazo": "Arm", "zona": "Free zone", "cabeza": "head", "cabezaCorporal": "body head", "torso": "torso", "senal": "signal", "joystick": "joystick", "puno": "fist · rest", "punoPreparar": "fist · open your hand to prepare rest", "pinza": "pinch · release: click · hold: right", "pinzaDerecho": "pinch · release: right click", "pinzaHecho": "pinch · right click done, release", "boca": "mouth open · close: click", "bocaDerecho": "mouth open · close: right click", "atraccion": "Gentle attraction to controls"],
        "pt": ["mano": "Mão", "brazo": "Braço", "zona": "Zona livre", "cabeza": "cabeça", "cabezaCorporal": "cabeça corporal", "torso": "tronco", "senal": "sinal", "joystick": "joystick", "puno": "punho · repouso", "punoPreparar": "punho · abra a mão para preparar repouso", "pinza": "pinça · solte: clique · mantenha: direito", "pinzaDerecho": "pinça · solte: clique direito", "pinzaHecho": "pinça · clique direito feito, solte", "boca": "boca aberta · feche: clique", "bocaDerecho": "boca aberta · feche: clique direito", "atraccion": "Atração suave para controles"],
        "de": ["mano": "Hand", "brazo": "Arm", "zona": "Freie Zone", "cabeza": "Kopf", "cabezaCorporal": "Kopf (Körper)", "torso": "Oberkörper", "senal": "Zeigen", "joystick": "Joystick", "puno": "Faust · Ruhe", "punoPreparar": "Faust · Hand öffnen, um Ruhe vorzubereiten", "pinza": "Griff · loslassen: Klick · halten: rechts", "pinzaDerecho": "Griff · loslassen: Rechtsklick", "pinzaHecho": "Griff · Rechtsklick erledigt, loslassen", "boca": "Mund offen · schließen: Klick", "bocaDerecho": "Mund offen · schließen: Rechtsklick", "atraccion": "Sanfte Anziehung zu Bedienelementen"],
        "fr": ["mano": "Main", "brazo": "Bras", "zona": "Zone libre", "cabeza": "tête", "cabezaCorporal": "tête (corps)", "torso": "torse", "senal": "signal", "joystick": "joystick", "puno": "poing · repos", "punoPreparar": "poing · ouvrez la main pour préparer le repos", "pinza": "pince · relâchez : clic · maintenez : droit", "pinzaDerecho": "pince · relâchez : clic droit", "pinzaHecho": "pince · clic droit fait, relâchez", "boca": "bouche ouverte · fermez : clic", "bocaDerecho": "bouche ouverte · fermez : clic droit", "atraccion": "Attraction douce vers les contrôles"],
        "it": ["mano": "Mano", "brazo": "Braccio", "zona": "Zona libera", "cabeza": "testa", "cabezaCorporal": "testa (corpo)", "torso": "busto", "senal": "segnale", "joystick": "joystick", "puno": "pugno · riposo", "punoPreparar": "pugno · apri la mano per preparare il riposo", "pinza": "pinza · rilascia: clic · tieni: destro", "pinzaDerecho": "pinza · rilascia: clic destro", "pinzaHecho": "pinza · clic destro fatto, rilascia", "boca": "bocca aperta · chiudi: clic", "bocaDerecho": "bocca aperta · chiudi: clic destro", "atraccion": "Attrazione delicata verso i controlli"],
    ]
    static func hudText(_ key: String, language: String = Textos.shared.currentLanguage) -> String {
        hudTextos[String(language.prefix(2))]?[key] ?? hudTextos["es"]?[key] ?? key
    }
}

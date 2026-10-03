import Foundation
import AVFoundation
import Vision
import CoreGraphics
import AppKit
import Combine

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
    @Published var controlMode = UserDefaults.standard.string(forKey: "ControlMode") ?? "automatico" { didSet { updateSettings(recalibrate: true) } }
    @Published var isParkinsonMode = UserDefaults.standard.bool(forKey: "isParkinsonMode") { didSet { updateSettings(recalibrate: true) } }
    @Published var sensitivity = UserDefaults.standard.object(forKey: "Sensitivity") as? Double ?? 1 { didSet { updateSettings() } }
    @Published var reducedMovement = UserDefaults.standard.bool(forKey: "ReducedMovement") { didSet { updateSettings(recalibrate: true) } }
    @Published var dwellEnabled = UserDefaults.standard.object(forKey: "DwellEnabled") as? Bool ?? true { didSet { updateSettings() } }
    @Published var dwellDuration = UserDefaults.standard.object(forKey: "DwellDuration") as? Double ?? 1 { didSet { updateSettings() } }
    @Published var isPaused = UserDefaults.standard.bool(forKey: "CursorPaused") { didSet { UserDefaults.standard.set(isPaused, forKey: "CursorPaused"); let value = isPaused; queue.async { self.paused = value; self.state.calibrate() }; statusMessage = value ? "Cursor pausado" : "Calibrando postura cómoda" } }
    var zonaMuertaRadioUI: Double { isParkinsonMode ? 0.07 : 0.045 }
    var zonaAtraccionUI: Double { zonaMuertaRadioUI + 0.02 }
    let captureSession = AVCaptureSession()
    private let queue = DispatchQueue(label: "pe.adapta.video", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private let hands = VNDetectHumanHandPoseRequest()
    private let face = VNDetectFaceLandmarksRequest()
    private let body = VNDetectHumanBodyPoseRequest()
    private var sequence = VNSequenceRequestHandler()
    private var objectRequest: VNTrackObjectRequest?
    private var state = KineticState()
    private var mode = "automatico"
    private var source = ""
    private var previousHand: CGPoint?
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
    private var edgeRest: (Double, CGPoint)?
    private var generation = 0
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

    func fetchCameras() {
        availableCameras = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified).devices
        if !availableCameras.contains(where: { $0.uniqueID == selectedCameraID }), let first = availableCameras.first { selectedCameraID = first.uniqueID }
    }
    private func refreshScreens() {
        let frames = NSScreen.screens.compactMap { screen -> CGRect? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
            return CGDisplayBounds(id)
        }
        queue.async { self.screenFrames = frames; self.state.calibrate() }
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
            self.mode = settings.0; self.state.tremor = settings.1; self.paused = settings.6
            self.state.sensitivity = max(0.3, min(2, settings.2)); self.state.amplitude = settings.3 ? 0.55 : 1
            self.state.dwellEnabled = settings.4; self.state.dwellDuration = max(0.4, min(3, settings.5))
            self.state.cancelClick()
            if recalibrate { self.resetSource() }
        }
    }
    func startTracking() {
        guard !isTracking, !isStarting else { return }
        guard AXIsProcessTrusted() else { statusMessage = "Activa Accesibilidad para controlar el cursor"; return }
        generation += 1; let token = generation
        isStarting = true; statusMessage = "Solicitando cámara…"
        let authorize: (Bool) -> Void = { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self, self.generation == token, self.isStarting else { return }
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
                guard let device = AVCaptureDevice(uniqueID: id) ?? AVCaptureDevice.default(for: .video) else { throw CaptureFailure.missingDevice }
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
                self.captureSession.startRunning(); self.running = true
                DispatchQueue.main.async {
                    guard self.generation == token, self.isStarting else { return }
                    self.isStarting = false; self.isTracking = true; UserDefaults.standard.set(true, forKey: "CameraActive"); self.statusMessage = "Calibrando: mantén una postura cómoda"
                    self.installMouseMonitors()
                }
            } catch {
                self.captureSession.commitConfiguration()
                DispatchQueue.main.async { if self.generation == token { self.isStarting = false; self.statusMessage = "No se pudo abrir la cámara: \(error.localizedDescription)" } }
            }
        }
    }
    func stopTracking(remember: Bool = true) {
        if remember { UserDefaults.standard.set(false, forKey: "CameraActive") }
        generation += 1; isStarting = false; isTracking = false
        monitors.forEach(NSEvent.removeMonitor); monitors.removeAll()
        statusMessage = "Cámara apagada"; detectedPointUI = nil; clickProgress = 0
        queue.async { self.running = false; self.captureSession.stopRunning(); self.resetSource() }
    }
    private func installMouseMonitors() {
        guard monitors.isEmpty else { return }
        let receive: (NSEvent) -> Void = { [weak self] event in
            guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != DesktopAccess.eventTag else { return }
            self?.queue.async { guard let self else { return }; self.pauseUntil = ProcessInfo.processInfo.systemUptime + 2; self.cursor = event.cgEvent?.location ?? self.cursor; self.state.calibrate() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged], handler: receive) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged], handler: { event in receive(event); return event }) { monitors.append(local) }
    }
    func calibrate() { queue.async { self.state.calibrate(); self.edgeRest = nil }; statusMessage = "Calibrando postura cómoda · sin clic" }
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
        default: if ["automatico", "manos", "cabeza", "torso", "brazo_izquierdo", "brazo_derecho", "zona"].contains(command) { controlMode = command }
        }
    }
    private func resetSource() {
        source = ""; candidateSource = ""; candidateFrames = 0; lastFrame = 0; lastDetection = 0
        objectRequest = nil; previousHand = nil; targetIdentity = nil; sequence = VNSequenceRequestHandler(); state.calibrate(); edgeRest = nil
    }
    private func detect(_ buffer: CVPixelBuffer) throws -> (CGPoint, String)? {
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
        if mode == "zona" {
            if objectRequest == nil {
                let request = VNGenerateObjectnessBasedSaliencyImageRequest(); try handler.perform([request])
                guard let rect = request.results?.first?.salientObjects?.max(by: { $0.confidence < $1.confidence })?.boundingBox else { return nil }
                objectRequest = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: rect))
                objectRequest?.trackingLevel = .fast
            }
            guard let request = objectRequest else { return nil }
            try sequence.perform([request], on: buffer, orientation: .up)
            guard let observation = request.results?.first as? VNDetectedObjectObservation, observation.confidence > 0.5 else { objectRequest = nil; return nil }
            request.inputObservation = observation
            return (CGPoint(x: 1 - observation.boundingBox.midX, y: 1 - observation.boundingBox.midY), "zona")
        }
        var requests: [VNRequest] = []
        if mode == "manos" || (mode == "automatico" && (source.isEmpty || source == "manos")) { requests.append(hands) }
        if mode == "cabeza" || (mode == "automatico" && (source.isEmpty || source == "cabeza")) { requests.append(face) }
        if mode == "torso" || mode.hasPrefix("brazo_") || (mode == "automatico" && (source.isEmpty || source == "torso" || source == "cabeza corporal")) { requests.append(body) }
        try handler.perform(requests)
        var candidates: [(CGPoint, String)] = []
        if requests.contains(where: { $0 === hands }) {
            let joints: [VNHumanHandPoseObservation.JointName] = [.wrist, .indexMCP, .middleMCP, .ringMCP, .littleMCP]
            let palms = (hands.results ?? []).compactMap { hand -> CGPoint? in
                let points = joints.compactMap { try? hand.recognizedPoint($0) }.filter { $0.confidence > 0.5 }
                guard points.count >= 3 else { return nil }
                return CGPoint(x: 1 - points.map { $0.location.x }.reduce(0, +) / Double(points.count), y: 1 - points.map { $0.location.y }.reduce(0, +) / Double(points.count))
            }
            let palm = previousHand.flatMap { previous in palms.min { hypot($0.x - previous.x, $0.y - previous.y) < hypot($1.x - previous.x, $1.y - previous.y) } } ?? palms.first
            if let palm { previousHand = palm; candidates.append((palm, "manos")) }
        }
        if requests.contains(where: { $0 === face }), let observation = face.results?.first {
            let box = observation.boundingBox
            var point = CGPoint(x: box.midX, y: box.midY)
            if let nose = observation.landmarks?.nose?.normalizedPoints, !nose.isEmpty {
                let center = nose.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
                point = CGPoint(x: box.minX + center.x / Double(nose.count) * box.width, y: box.minY + center.y / Double(nose.count) * box.height)
                if let yaw = observation.yaw { point.x += yaw.doubleValue * 0.12 }
            }
            candidates.append((CGPoint(x: 1 - point.x, y: 1 - point.y), "cabeza"))
        }
        if requests.contains(where: { $0 === body }), let observation = body.results?.first {
            func joint(_ name: VNHumanBodyPoseObservation.JointName) -> CGPoint? { guard let value = try? observation.recognizedPoint(name), value.confidence >= 0.65 else { return nil }; return CGPoint(x: 1 - value.location.x, y: 1 - value.location.y) }
            if mode.hasPrefix("brazo_") {
                let joints: [VNHumanBodyPoseObservation.JointName] = mode == "brazo_izquierdo" ? [.leftWrist, .leftElbow, .leftShoulder] : [.rightWrist, .rightElbow, .rightShoulder]
                let preferred = joints.first { source == mode + ":" + $0.rawValue.rawValue && joint($0) != nil }
                if let name = preferred ?? joints.first(where: { joint($0) != nil }), let point = joint(name) { candidates.append((point, mode + ":" + name.rawValue.rawValue)) }
            } else {
                if mode == "automatico", let point = joint(.nose) { candidates.append((point, "cabeza corporal")) }
                if let left = joint(.leftShoulder), let right = joint(.rightShoulder) { candidates.append((CGPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2), "torso")) }
            }
        }
        return candidates.first(where: { $0.1 == source }) ?? candidates.first
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard running, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFrame >= 1.0 / 30 else { return }; lastFrame = now
        if paused || now < pauseUntil { state.cancelClick(); publish(point: nil, message: paused ? "Cursor pausado" : "Pausa por ratón físico", now: now); return }
        guard AXIsProcessTrusted() else { state.cancelClick(); publish(point: nil, message: "Falta permiso de Accesibilidad", now: now); return }
        do {
            guard let (point, detectedSource) = try detect(buffer) else {
                state.lost(at: now)
                if lastDetection > 0, now - lastDetection >= 1.2 { source = ""; objectRequest = nil }
                publish(point: nil, message: "Buscando \(mode)…", now: now); return
            }
            guard CMClockGetTime(CMClockGetHostTimeClock()).seconds - CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds < 0.5 else { state.lost(at: now); return }
            lastDetection = now
            if source != detectedSource {
                state.cancelClick()
                if candidateSource != detectedSource { candidateSource = detectedSource; candidateSince = now; candidateFrames = 0 }
                candidateFrames += 1
                guard candidateFrames >= 3, now - candidateSince >= 1.2 else { publish(point: nil, message: "Confirmando \(detectedSource)…", now: now); return }
                source = detectedSource; state.calibrate()
            }
            if state.origin != nil, hypot(state.smooth.x - 0.5, state.smooth.y - 0.5) < state.attractionRadius {
                if now - lastTargetLookup >= 0.1 { targetIdentity = DesktopAccess.targetIdentity(at: cursor); lastTargetLookup = now }
            } else { targetIdentity = nil }
            let target = targetIdentity
            let result = state.update(point, time: now, aspect: Double(CVPixelBufferGetHeight(buffer)) / Double(CVPixelBufferGetWidth(buffer)), target: target)
            if state.calibratedNow { DispatchQueue.main.async { ActionManager.shared.hablar("Cursor listo. Postura cómoda calibrada.") } }
            let previous = cursor
            cursor = nearestScreenPoint(CGPoint(x: cursor.x + result.delta.x, y: cursor.y + result.delta.y))
            if result.delta != .zero { DesktopAccess.move(to: cursor) }
            if result.click { DesktopAccess.click(right: nextRightClick); nextRightClick = false }
            if hypot(result.delta.x, result.delta.y) > 0, hypot(cursor.x - previous.x, cursor.y - previous.y) < 0.01 {
                if let rest = edgeRest, hypot(point.x - rest.1.x, point.y - rest.1.y) < (state.tremor ? 0.045 : 0.025) {
                    if now - rest.0 >= 1.2 { state.calibrate(); edgeRest = nil }
                } else { edgeRest = (now, point) }
            } else { edgeRest = nil }
            let message = state.origin == nil ? "Calibrando: mantén postura cómoda" : result.click ? "Clic realizado" : state.progress > 0 ? "Clic por permanencia" : result.delta == .zero ? "Zona segura · mueve para habilitar clic" : "Moviendo · \(source)"
            publish(point: state.origin == nil ? nil : state.smooth, message: message, now: now)
        } catch { state.lost(at: now); publish(point: nil, message: "No se pudo analizar la cámara", now: now) }
    }
    private func nearestScreenPoint(_ point: CGPoint) -> CGPoint {
        guard !screenFrames.isEmpty else { return cursor }
        return screenFrames.map { CGRect(x: $0.minX + 1, y: $0.minY + 1, width: $0.width - 2, height: $0.height - 2) }.map {
            CGPoint(x: max($0.minX, min($0.maxX, point.x)), y: max($0.minY, min($0.maxY, point.y)))
        }.min { hypot($0.x - point.x, $0.y - point.y) < hypot($1.x - point.x, $1.y - point.y) } ?? cursor
    }
    private func publish(point: CGPoint?, message: String, now: Double) {
        guard now - lastHUD >= 0.1 else { return }; lastHUD = now
        let progress = state.progress, currentSource = source
        DispatchQueue.main.async { guard self.isTracking else { return }; self.detectedPointUI = point; self.statusMessage = message; self.trackingTypeUI = currentSource; self.clickProgress = progress }
    }
}

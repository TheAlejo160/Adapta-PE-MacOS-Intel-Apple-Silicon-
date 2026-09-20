import Foundation
import AVFoundation
import Vision
import CoreGraphics
import AppKit
import Combine

class TrackingManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var isTracking = false
    @Published var statusMessage = "Inactivo"
    
    @Published var detectedPointUI: CGPoint?
    @Published var basePointUI: CGPoint = CGPoint(x: 0.5, y: 0.5)
    @Published var trackingTypeUI = ""
    
    @Published var zonaMuertaRadioUI: CGFloat = 0.05
    @Published var zonaAtraccionUI: CGFloat = 0.12
    @Published var isParkinsonMode = false
    
    @Published var availableCameras: [AVCaptureDevice] = []
    @Published var selectedCameraID: String = "" { didSet { if isTracking { restartCamera() } } }
    
    let captureSession = AVCaptureSession()
    
    private var basePoint: CGPoint = CGPoint(x: 0.5, y: 0.5)
    private var smoothedPoint: CGPoint?
    private var tiempoFijado = 0
    private var virtualMouseX: CGFloat = NSScreen.main?.frame.width ?? 1920 / 2
    private var virtualMouseY: CGFloat = NSScreen.main?.frame.height ?? 1080 / 2
    
    private var physicalMouseMonitor: Any?
    private var pausaPorMouseFisico: Date = Date.distantPast
    
    private let zonaMuerta: CGFloat = 0.05
    private let zonaAtraccion: CGFloat = 0.12
    private let framesParaClick: Int = 50
    
    override init() {
        super.init()
        physicalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { _ in
            self.pausaPorMouseFisico = Date().addingTimeInterval(2.0)
        }
    }
    
    func fetchCameras() {
        var deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) { deviceTypes.append(.external) }
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes, mediaType: .video, position: .unspecified)
        DispatchQueue.main.async {
            self.availableCameras = session.devices
            if self.selectedCameraID.isEmpty, let first = session.devices.first { self.selectedCameraID = first.uniqueID }
        }
    }
    
    func startTracking() { checkPermissions() }
    func stopTracking() {
        captureSession.stopRunning()
        DispatchQueue.main.async {
            self.isTracking = false
            self.statusMessage = "Inactivo"
            self.detectedPointUI = nil
            self.smoothedPoint = nil
        }
    }
    private func restartCamera() { stopTracking(); setupCamera() }
    
    private func checkPermissions() {
        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized { setupCamera() }
        else { AVCaptureDevice.requestAccess(for: .video) { granted in if granted { self.setupCamera() } } }
    }
    
    private func setupCamera() {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .low
        captureSession.inputs.forEach { captureSession.removeInput($0) }
        
        guard let videoDevice = AVCaptureDevice(uniqueID: selectedCameraID) ?? AVCaptureDevice.default(for: .video),
              let videoInput = try? AVCaptureDeviceInput(device: videoDevice) else {
            captureSession.commitConfiguration(); return
        }
        
        if captureSession.canAddInput(videoInput) { captureSession.addInput(videoInput) }
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "videoQueue"))
        if captureSession.canAddOutput(videoOutput) { captureSession.addOutput(videoOutput) }
        
        captureSession.commitConfiguration()
        captureSession.startRunning()
        
        virtualMouseX = NSEvent.mouseLocation.x
        virtualMouseY = (NSScreen.main?.frame.height ?? 1080) - NSEvent.mouseLocation.y
        smoothedPoint = nil
        DispatchQueue.main.async { self.isTracking = true; self.statusMessage = "🎯 Listo" }
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        let handRequest = VNDetectHumanHandPoseRequest()
        handRequest.maximumHandCount = 1
        let faceRequest = VNDetectFaceRectanglesRequest()
        let bodyRequest = VNDetectHumanBodyPoseRequest()
        
        try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]).perform([handRequest, faceRequest, bodyRequest])
        
        var rawTargetPoint: CGPoint? = nil
        var hudSource = ""
        
        if let hand = handRequest.results?.first, let indexTip = try? hand.recognizedPoint(.indexTip), indexTip.confidence > 0.5 {
            rawTargetPoint = CGPoint(x: 1.0 - indexTip.location.x, y: 1.0 - indexTip.location.y)
            hudSource = "✋ Mano"
        } else if let body = bodyRequest.results?.first {
            if let wristR = try? body.recognizedPoint(.rightWrist), wristR.confidence > 0.5 {
                rawTargetPoint = CGPoint(x: 1.0 - wristR.location.x, y: 1.0 - wristR.location.y)
                hudSource = "💪 Brazo (Der)"
            } else if let wristL = try? body.recognizedPoint(.leftWrist), wristL.confidence > 0.5 {
                rawTargetPoint = CGPoint(x: 1.0 - wristL.location.x, y: 1.0 - wristL.location.y)
                hudSource = "💪 Brazo (Izq)"
            }
        }
        
        if rawTargetPoint == nil, let face = faceRequest.results?.first {
            rawTargetPoint = CGPoint(x: 1.0 - face.boundingBox.midX, y: 1.0 - face.boundingBox.midY)
            hudSource = "🧠 Cabeza"
        }
        
        guard let target = rawTargetPoint else { return }
        
        let alpha: CGFloat = isParkinsonMode ? 0.05 : 0.3
        
        // CÁLCULO SEGURO: Evita el uso de force-unwrap (!) para prevenir cierres
        let newSmoothed: CGPoint
        if let prev = smoothedPoint {
            newSmoothed = CGPoint(x: prev.x * (1 - alpha) + target.x * alpha, y: prev.y * (1 - alpha) + target.y * alpha)
        } else {
            newSmoothed = target
        }
        
        self.smoothedPoint = newSmoothed
        
        DispatchQueue.main.async {
            self.detectedPointUI = newSmoothed
            self.trackingTypeUI = hudSource
        }
        
        self.procesarCinematica(punto: newSmoothed, msg: hudSource)
    }
    
    private func procesarCinematica(punto: CGPoint, msg: String) {
        if Date() < pausaPorMouseFisico {
            DispatchQueue.main.async { self.statusMessage = "🖱️ Pausado (Ratón Físico)" }
            return
        }
        
        let deltaX = punto.x - basePoint.x
        let deltaY = punto.y - basePoint.y
        let distanciaFisica = hypot(deltaX, deltaY)
        
        if distanciaFisica < zonaMuerta {
            tiempoFijado += 1
            let progreso = min(100, Int((CGFloat(tiempoFijado) / CGFloat(framesParaClick)) * 100))
            DispatchQueue.main.async { self.statusMessage = "🛑 BLOQUEADO (\(progreso)%)" }
            
            if tiempoFijado >= framesParaClick {
                performClick()
                tiempoFijado = 0
                DispatchQueue.main.async { self.statusMessage = "🖱️ CLIC EJECUTADO" }
            }
        } else if distanciaFisica < zonaAtraccion {
            tiempoFijado = 0
            DispatchQueue.main.async { self.statusMessage = "🧲 Atracción" }
        } else {
            tiempoFijado = 0
            let activeDelta = distanciaFisica - zonaAtraccion
            
            let multiSensibilidad: CGFloat = (msg == "🧠 Cabeza" || msg.contains("Brazo")) ? 2.5 : 1.0
            let sensibilidadBase: CGFloat = isParkinsonMode ? 50.0 : 160.0
            let velocidadMax: CGFloat = isParkinsonMode ? 15.0 : 40.0
            let sensFinal = sensibilidadBase * multiSensibilidad
            
            let dirX = deltaX / distanciaFisica
            let dirY = deltaY / distanciaFisica
            
            var velX = dirX * activeDelta * sensFinal
            var velY = dirY * activeDelta * sensFinal
            
            velX = max(-velocidadMax, min(velocidadMax, velX))
            velY = max(-velocidadMax, min(velocidadMax, velY))
            
            virtualMouseX += velX
            virtualMouseY += velY
            
            let screenW = NSScreen.main?.frame.width ?? 1920
            let screenH = NSScreen.main?.frame.height ?? 1080
            virtualMouseX = max(0, min(screenW, virtualMouseX))
            virtualMouseY = max(0, min(screenH, virtualMouseY))
            
            CGWarpMouseCursorPosition(CGPoint(x: virtualMouseX, y: virtualMouseY))
            DispatchQueue.main.async { self.statusMessage = "🚀 \(msg)" }
        }
    }
    
    private func performClick() {
        guard let currentEvent = CGEvent(source: nil) else { return }
        let loc = currentEvent.location
        let md = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: loc, mouseButton: .left)
        let mu = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: loc, mouseButton: .left)
        md?.post(tap: .cghidEventTap)
        mu?.post(tap: .cghidEventTap)
    }
}

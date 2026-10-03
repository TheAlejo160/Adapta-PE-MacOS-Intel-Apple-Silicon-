import AppKit
import Foundation
import Speech
import AVFoundation
import Combine
import OSLog

final class VoiceManager: NSObject, ObservableObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    @Published private(set) var isListening = false
    @Published private(set) var isStarting = false
    @Published private(set) var transcript = ""
    @Published private(set) var status = "Micrófono apagado"
    @Published private(set) var availableMics: [AVCaptureDevice] = []
    @Published var selectedMicID = UserDefaults.standard.string(forKey: "SelectedMicID") ?? "" {
        didSet { UserDefaults.standard.set(selectedMicID, forKey: "SelectedMicID"); if isListening || isStarting { stopListening(remember: false); startListening() } }
    }
    @Published var allowAppleNetwork = UserDefaults.standard.bool(forKey: "AllowAppleNetwork") {
        didSet { UserDefaults.standard.set(allowAppleNetwork, forKey: "AllowAppleNetwork"); if isListening || isStarting { stopListening(remember: false); startListening() } }
    }
    var onWake: (() -> Void)?
    var onCommand: ((String) -> Void)?
    var followUpAllowed: (() -> Bool)?
    private let captureSession = AVCaptureSession()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let audioQueue = DispatchQueue(label: "pe.adapta.audio", qos: .userInitiated)
    private var request: SFSpeechAudioBufferRecognitionRequest? // Exclusivo de audioQueue.
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var silence: DispatchWorkItem?
    private var restart: DispatchWorkItem?
    private var safety: DispatchWorkItem?
    private var commandTimeout: DispatchWorkItem?
    private var generation = 0
    private var taskGeneration = 0
    private var failures = 0
    private var recognized = ""
    private var input = VoiceInputState()
    private var pendingWakeCue = false
    private let wakeSound = NSSound(named: "Glass")
    private var listeningActivity: NSObjectProtocol?
    private var appObserver: NSObjectProtocol?
    private var speaking = false
    private var runtimeObserver: NSObjectProtocol?
    private let logger = Logger(subsystem: "pe.adapta.desktop", category: "voice")
    private var health: DispatchWorkItem?
    private var lastAudio = 0.0 // Exclusivo de audioQueue.
    private var validBuffers = 0 // Exclusivo de audioQueue.
    private var invalidBuffers = 0 // Exclusivo de audioQueue.
    private var captureFailures = 0


    override init() {
        super.init()
        runtimeObserver = NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: captureSession, queue: .main) { [weak self] _ in
            self?.recoverCapture()
        }
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.isListening else { return }
            self.logger.info("Cambio de aplicación; escucha mantenida en segundo plano")
            // Una tarea acabada no implica que la captura de audio haya parado.
            self.ensureRecognition()
        }
    }
    deinit { if let activity = listeningActivity { ProcessInfo.processInfo.endActivity(activity) }; if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver) }; if let runtimeObserver { NotificationCenter.default.removeObserver(runtimeObserver) } }
    func fetchMics() {
        availableMics = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
        if !availableMics.contains(where: { $0.uniqueID == selectedMicID }), let first = availableMics.first { selectedMicID = first.uniqueID }
    }
    func startListening() {
        guard !isListening, !isStarting else { return }
        generation += 1; let token = generation; isStarting = true; status = "Solicitando micrófono…"
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in
            guard allowed else { DispatchQueue.main.async { guard let self, self.generation == token else { return }; self.isStarting = false; self.status = "Micrófono sin permiso" }; return }
            SFSpeechRecognizer.requestAuthorization { authorization in
                DispatchQueue.main.async {
                    guard let self, self.generation == token, self.isStarting else { return }
                    guard authorization == .authorized else { self.isStarting = false; self.status = "Reconocimiento de voz sin permiso"; return }
                    let local = ["es-PE", "es-ES", "es-MX"].compactMap { SFSpeechRecognizer(locale: Locale(identifier: $0)) }.first { $0.supportsOnDeviceRecognition && $0.isAvailable }
                    self.recognizer = local ?? (self.allowAppleNetwork ? SFSpeechRecognizer(locale: Locale(identifier: "es-PE")) : nil)
                    guard self.recognizer != nil else { self.isStarting = false; self.status = "Español local no disponible. Instala recursos de dictado o autoriza reconocimiento de Apple por red."; return }
                    self.setupHardware(token: token)
                }
            }
        }
    }
    private func setupHardware(token: Int) {
        let id = selectedMicID
        audioQueue.async {
            self.captureSession.beginConfiguration(); self.captureSession.inputs.forEach { self.captureSession.removeInput($0) }
            do {
                guard let device = AVCaptureDevice(uniqueID: id) ?? AVCaptureDevice.default(for: .audio) else { throw CaptureFailure.missingDevice }
                let input = try AVCaptureDeviceInput(device: device)
                guard self.captureSession.canAddInput(input) else { throw CaptureFailure.missingDevice }; self.captureSession.addInput(input)
                if self.captureSession.outputs.isEmpty {
                    self.audioOutput.setSampleBufferDelegate(self, queue: self.audioQueue)
                    guard self.captureSession.canAddOutput(self.audioOutput) else { throw CaptureFailure.missingDevice }; self.captureSession.addOutput(self.audioOutput)
                }
                self.captureSession.commitConfiguration(); self.lastAudio = ProcessInfo.processInfo.systemUptime; self.validBuffers = 0; self.invalidBuffers = 0; self.captureSession.startRunning()
                DispatchQueue.main.async {
                    guard self.generation == token, self.isStarting else { return }
                    self.isStarting = false; self.isListening = true; self.failures = 0
                    if self.listeningActivity == nil {
                        self.listeningActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Control accesible por voz en segundo plano")
                    }
                    UserDefaults.standard.set(true, forKey: "VoiceActive")
                    self.logger.info("Captura de voz iniciada")
                    self.beginRecognition(); self.checkHealth()
                }
            } catch {
                self.captureSession.commitConfiguration()
                DispatchQueue.main.async { if self.generation == token { self.isStarting = false; self.endListeningActivity(); self.status = "No se pudo abrir el micrófono: \(error.localizedDescription)" } }
            }
        }
    }
    private func endListeningActivity() {
        if let activity = listeningActivity { ProcessInfo.processInfo.endActivity(activity); listeningActivity = nil }
    }
    func stopListening(remember: Bool = true) {
        if remember { UserDefaults.standard.set(false, forKey: "VoiceActive") }
        health?.cancel(); health = nil; captureFailures = 0; endListeningActivity(); pendingWakeCue = false
        generation += 1; isStarting = false; isListening = false
        clearRecognition(); commandTimeout?.cancel(); commandTimeout = nil; input.cancel()
        recognized = ""; transcript = ""; status = "Micrófono apagado"
        audioQueue.async { self.captureSession.stopRunning() }
    }
    private func clearRecognition() {
        taskGeneration += 1; silence?.cancel(); restart?.cancel(); safety?.cancel()
        silence = nil; restart = nil; safety = nil
        audioQueue.async { self.request?.endAudio(); self.request = nil }
        task?.cancel(); task = nil
    }
    private func beginRecognition() {
        guard isListening, let recognizer, recognizer.isAvailable else { if isListening { scheduleRestart(failed: true) }; return }
        clearRecognition(); recognized = ""; input.beginUtterance()
        let token = taskGeneration
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true; request.requiresOnDeviceRecognition = !allowAppleNetwork || recognizer.supportsOnDeviceRecognition
        audioQueue.async { self.request = request }
        logger.info("Reconocimiento listo; sesión \(token)")
        let word = (UserDefaults.standard.string(forKey: "WakeWord") ?? "computadora").trimmingCharacters(in: .whitespacesAndNewlines)
        status = waiting ? "Dime el comando…" : "Di «\(word.isEmpty ? "computadora" : word)»"
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.taskGeneration == token, self.isListening else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    if text != self.recognized {
                        self.recognized = text; self.transcript = text; self.failures = 0
                        self.silence?.cancel()
                        let work = DispatchWorkItem { [weak self] in guard let self, self.taskGeneration == token else { return }; self.consume() }
                        self.silence = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + (Self.isWakeOnly(text) ? 0.45 : 1.0), execute: work)
                    }
                }
                if let error { self.logger.error("Reconocimiento finalizado: \(error.localizedDescription, privacy: .public)") }
                if result?.isFinal == true || error != nil {
                    // Consumir finales antes de invalidar la tarea; el reinicio nunca borra una orden pendiente.
                    self.consume()
                    guard self.taskGeneration == token else { return }
                    self.scheduleRestart(failed: error != nil && result == nil)
                }
            }
        }
        let work = DispatchWorkItem { [weak self] in guard let self, self.taskGeneration == token else { return }; self.consume(); if self.taskGeneration == token { self.scheduleRestart(failed: false) } }
        if pendingWakeCue {
            // El sonido confirma que la siguiente tarea ya puede recibir el comando.
            audioQueue.async { DispatchQueue.main.async {
                guard self.isListening, self.taskGeneration == token, self.pendingWakeCue, self.waiting else { return }
                self.pendingWakeCue = false
                if self.wakeSound?.play() != true { NSSound.beep() }
                self.logger.info("Activación confirmada; esperando comando")
            } }
        }
        safety = work; DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: work)
    }
    private static func isWakeOnly(_ text: String) -> Bool {
        let word = UserDefaults.standard.string(forKey: "WakeWord") ?? "computadora"
        return NameMatch.key(text) == NameMatch.key(word.isEmpty ? "computadora" : word)
    }
    private var waiting: Bool { ProcessInfo.processInfo.systemUptime < input.waitingUntil }
    private func consume() {
        guard isListening else { return }
        let result = input.consume(recognized, wakeWord: UserDefaults.standard.string(forKey: "WakeWord") ?? "computadora", time: ProcessInfo.processInfo.systemUptime, speaking: speaking, followUp: followUpAllowed?() == true)
        guard result.beep || result.command != nil else { return }
        if result.beep {
            onWake?(); pendingWakeCue = true; status = "Dime el comando…"
            commandTimeout?.cancel()
            let token = generation
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.generation == token else { return }
                self.input.cancel(); self.pendingWakeCue = false
                if self.isListening { self.status = "Esperando palabra de activación" }
            }
            commandTimeout = work; DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
        }
        if let command = result.command {
            commandTimeout?.cancel(); commandTimeout = nil
            logger.info("Comando completo entregado; rearmando escucha")
            onCommand?(command)
        }
        // Una orden por tarea, independiente de la aplicación que tome el primer plano.
        scheduleRestart(failed: false)
    }
    private func scheduleRestart(failed: Bool) {
        guard isListening else { return }
        clearRecognition()
        failures = failed ? min(failures + 1, 4) : 0
        if failed { status = "Reconectando voz…" }
        let token = generation
        let work = DispatchWorkItem { [weak self] in guard let self, self.generation == token, self.isListening else { return }; self.restart = nil; self.beginRecognition() }
        restart = work; DispatchQueue.main.asyncAfter(deadline: .now() + [0.1, 1, 2, 3, 5][failures], execute: work)
    }
    func setSpeechOutput(_ active: Bool) {
        guard speaking != active else { return }
        speaking = active
        logger.info("Salida de voz: \(active)")
        guard isListening else { return }
        if active { silence?.cancel(); status = "Leyendo · puedes decir tu nombre de activación y «silencio»" }
        else { scheduleRestart(failed: false) }
    }
    private func recoverCapture() {
        guard isListening || isStarting else { return }
        captureFailures += 1
        logger.error("Captura interrumpida; intento \(self.captureFailures)")
        health?.cancel(); clearRecognition()
        isListening = false; isStarting = true; status = "Reconectando micrófono…"
        let token = generation
        audioQueue.async { self.captureSession.stopRunning() }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token, self.isStarting else { return }
            self.setupHardware(token: token)
        }
        restart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + min(5, Double(captureFailures)), execute: work)
    }
    private func ensureRecognition() {
        guard isListening, restart == nil else { return }
        if task == nil || task?.state == .completed || task?.state == .canceling { scheduleRestart(failed: false) }
    }
    private func checkHealth() {
        health?.cancel()
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token, self.isListening else { return }
            self.audioQueue.async {
                let stalled = ProcessInfo.processInfo.systemUptime - self.lastAudio > 4
                DispatchQueue.main.async {
                    guard self.generation == token, self.isListening else { return }
                    if stalled { self.recoverCapture() } else { self.captureFailures = 0; self.ensureRecognition(); self.checkHealth() }
                }
            }
        }
        health = work; DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
    // Speech recibe PCM con memoria propia y todas las tramas, nunca paquetes vacíos.
    static func pcmBuffer(_ sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        let frames = CMSampleBufferGetNumSamples(sample)
        guard CMSampleBufferIsValid(sample), CMSampleBufferDataIsReady(sample), frames > 0, frames <= 192_000,
              let description = CMSampleBufferGetFormatDescription(sample),
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              stream.pointee.mFormatID == kAudioFormatLinearPCM,
              stream.pointee.mSampleRate.isFinite, stream.pointee.mSampleRate > 0,
              stream.pointee.mChannelsPerFrame > 0, stream.pointee.mChannelsPerFrame <= 32,
              let format = AVAudioFormat(streamDescription: stream),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr,
              UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList).allSatisfy({ $0.mData != nil && $0.mDataByteSize > 0 }) else { return nil }
        return buffer
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = Self.pcmBuffer(sample) else {
            invalidBuffers += 1
            if invalidBuffers == 1 || invalidBuffers % 200 == 0 { logger.warning("Audio vacío/inválido descartado: \(self.invalidBuffers)") }
            return
        }
        lastAudio = ProcessInfo.processInfo.systemUptime
        validBuffers += 1
        if validBuffers == 1 { logger.info("PCM válido: \(buffer.format.sampleRate) Hz, \(buffer.format.channelCount) canal(es), \(buffer.frameLength) tramas") }
        request?.append(buffer)
    }
}

enum CaptureFailure: LocalizedError {
    case missingDevice
    var errorDescription: String? { "Dispositivo no disponible" }
}

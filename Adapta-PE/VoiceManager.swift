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
    @Published var languagePreference = UserDefaults.standard.string(forKey: "VoiceLanguage") ?? "auto" {
        didSet {
            UserDefaults.standard.set(languagePreference, forKey: "VoiceLanguage")
            Textos.shared.fijarIdioma(languagePreference)
            if isListening || isStarting { stopListening(remember: false); startListening() }
        }
    }
    @Published private(set) var wakeName = WakeName.saved
    @Published private(set) var activationAliases = UserDefaults.standard.stringArray(forKey: "AliasActivacion") ?? []
    @Published var alsoComputer = UserDefaults.standard.bool(forKey: "TambienComputadora") {
        didSet { UserDefaults.standard.set(alsoComputer, forKey: "TambienComputadora"); refreshVocabulary() }
    }
    @Published var conversationMode = UserDefaults.standard.bool(forKey: "ModoConversacion") {
        didSet { UserDefaults.standard.set(conversationMode, forKey: "ModoConversacion"); conversation.cancel(); conversation.enabled = conversationMode }
    }
    @Published private(set) var nameTrialStatus = ""
    @Published private(set) var nameTrialSample = ""
    @Published private(set) var testingName = false
    private var nameTrial = VoiceNameTrial()
    private var trialTimeout: DispatchWorkItem?
    private var speechTimeout: DispatchWorkItem?
    private var conversation = VoiceConversation()
    private var turn = 0
    private var phraseDuringSpeech = false
    private func refreshVocabulary() {
        if isListening { beginRecognition() }
    }
    func saveAliases(_ values: [String]) -> String? {
        guard let aliases = VoiceActivation.aliases(values, name: wakeName) else { return Textos.t("popup.aliasInvalido") }
        activationAliases = aliases; UserDefaults.standard.set(aliases, forKey: "AliasActivacion"); refreshVocabulary(); return nil
    }
    func testWakeName() {
        guard isListening else { nameTrialStatus = "Activa el micrófono para probar el nombre."; return }
        turn += 1; conversation.cancel(); input.cancel(); trialTimeout?.cancel()
        nameTrial.start(at: ProcessInfo.processInfo.systemUptime); testingName = true; nameTrialSample = ""; nameTrialStatus = "Di tu nombre. La siguiente frase se mostrará sin ejecutar órdenes (15 s)."
        beginRecognition()
        let work = DispatchWorkItem { [weak self] in self?.expireNameTrial() }
        trialTimeout = work; DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
    }
    private func expireNameTrial() {
        guard nameTrial.expired(at: ProcessInfo.processInfo.systemUptime) else { return }
        testingName = false; nameTrialStatus = Textos.t("popup.pruebaCaducada"); recognized = ""
        // Invalida la tarea completa: un final tardío de la muestra nunca llega al ejecutor.
        if isListening { beginRecognition() }
    }
    func addTrialAlias() -> String? {
        guard !nameTrialSample.isEmpty else { return "Primero prueba el nombre." }
        let error = saveAliases(activationAliases + [nameTrialSample])
        if error == nil { nameTrialStatus = "Alias añadido: \(nameTrialSample)"; nameTrialSample = "" }
        return error
    }
    func saveWakeName(_ value: String) -> String? {
        if let error = WakeName.error(value) { return error }
        guard VoiceActivation.aliases(activationAliases, name: value) != nil else { return "Un alias coincide con el nombre. Retíralo antes de guardar." }
        wakeName = WakeName.normalized(value); UserDefaults.standard.set(wakeName, forKey: "WakeWord")
        if isListening || isStarting { stopListening(remember: false); startListening() }
        return nil
    }
    var onWake: (() -> Void)?
    var followUpAllowed: (() -> Bool)?
    var confirmationAllowed: (() -> Bool)?
    var onConversationClose: (() -> Void)?
    var executeCommand: ((String, @escaping (VoiceExecutionResult) -> Void) -> Void)?
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
    private var stream = VoiceTranscriptState()
    private var segments: [VoiceTranscriptState.Segment] = []
    private let signposter = OSSignposter(subsystem: "pe.adapta.desktop", category: "voice")
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
        conversation.enabled = conversationMode
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
    nonisolated static func validatedMicID(_ selected: String, available: [String]) -> String {
        selected.isEmpty || available.contains(selected) ? selected : ""
    }
    func fetchMics() {
        availableMics = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
        let selection = Self.validatedMicID(selectedMicID, available: availableMics.map(\.uniqueID))
        if selection != selectedMicID { selectedMicID = selection }
    }
    var solicitarMicrofono: (@escaping @Sendable (Bool) -> Void) -> Void = { AVCaptureDevice.requestAccess(for: .audio, completionHandler: $0) }
    var solicitarReconocimiento: (@escaping @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void) -> Void = { SFSpeechRecognizer.requestAuthorization($0) }
    func startListening() {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.startListening() }; return }
        guard !isListening, !isStarting else { return }
        guard VoiceCatalog.shared != nil else { status = "Catálogo de voz no disponible"; return }
        generation += 1; let token = generation; isStarting = true; status = "Solicitando micrófono…"
        let recibirMicrofono: @MainActor @Sendable (Bool) -> Void = { [weak self] allowed in
            guard let self, self.generation == token, self.isStarting else { return }
            guard allowed else { self.isStarting = false; self.status = "Micrófono sin permiso"; return }
            let recibirReconocimiento: @MainActor @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void = { [weak self] authorization in
                guard let self, self.generation == token, self.isStarting else { return }
                guard authorization == .authorized else { self.isStarting = false; self.status = "Reconocimiento de voz sin permiso"; return }
                let locale = VoiceCatalog.currentLocale
                let codes = [locale] + (VoiceCatalog.shared?.codigos.filter { $0.hasPrefix(String(locale.prefix(2)) + "-") && $0 != locale } ?? [])
                let local = codes.compactMap { SFSpeechRecognizer(locale: Locale(identifier: $0)) }.first { $0.supportsOnDeviceRecognition && $0.isAvailable }
                self.recognizer = local ?? (self.allowAppleNetwork ? SFSpeechRecognizer(locale: Locale(identifier: locale)) : nil)
                guard self.recognizer != nil else { self.isStarting = false; self.status = "Reconocimiento local del idioma no disponible. Instala recursos de dictado o autoriza reconocimiento de Apple por red."; return }
                self.setupHardware(token: token)
            }
            self.solicitarReconocimiento { authorization in
                DispatchQueue.main.async { recibirReconocimiento(authorization) }
            }
        }
        solicitarMicrofono { allowed in
            DispatchQueue.main.async { recibirMicrofono(allowed) }
        }
    }
    private func setupHardware(token: Int) {
        let id = selectedMicID
        audioQueue.async {
            self.captureSession.beginConfiguration(); self.captureSession.inputs.forEach { self.captureSession.removeInput($0) }
            do {
                guard let device = (id.isEmpty ? AVCaptureDevice.default(for: .audio) : AVCaptureDevice(uniqueID: id)) else { throw CaptureFailure.missingDevice }
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
        turn += 1; conversation.cancel(); nameTrial.cancel(); trialTimeout?.cancel(); speechTimeout?.cancel(); testingName = false
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
        clearRecognition(); recognized = ""; segments = []; stream.reset(); input.beginUtterance(); phraseDuringSpeech = speaking
        let token = taskGeneration
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.contextualStrings = VoiceActivation.contextualStrings(name: wakeName, aliases: activationAliases, alsoComputer: alsoComputer, language: VoiceCatalog.currentLanguage)
        request.taskHint = .confirmation
        request.shouldReportPartialResults = true; request.requiresOnDeviceRecognition = !allowAppleNetwork || recognizer.supportsOnDeviceRecognition
        audioQueue.async { self.request = request }
        logger.info("Reconocimiento listo; sesión \(token)")
        let word = wakeName
        status = waiting ? "Dime el comando…" : "Di «\(word.isEmpty ? "computadora" : word)»"
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.taskGeneration == token, self.isListening else { return }
                if let result {
                    let transcription = result.bestTranscription
                    self.segments = transcription.segments.map { VoiceTranscriptState.Segment(range: $0.substringRange, start: $0.timestamp, duration: $0.duration) }
                    let text = self.stream.suffix(transcription.formattedString, segments: self.segments)
                    if self.speaking { self.phraseDuringSpeech = true }
                    if text != self.recognized {
                        self.signposter.emitEvent("TranscriptUpdated")
                        self.recognized = text; self.transcript = text; self.failures = 0
                        self.silence?.cancel()
                        let work = DispatchWorkItem { [weak self] in guard let self, self.taskGeneration == token else { return }; self.consume() }
                        self.silence = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + (self.isWakeOnly(text) ? 0.35 : 0.5), execute: work)
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
    func isWakeOnly(_ text: String) -> Bool {
        let word = WakeName.saved
        var wake = WakePhraseState()
        return wake.consume(text, wakeWord: word, time: 0, aliases: activationAliases, alsoComputer: alsoComputer).beep
    }
    private var waiting: Bool { ProcessInfo.processInfo.systemUptime < input.waitingUntil }
    private func consume() {
        guard isListening else { return }
        let interval = signposter.beginInterval("DispatchCommand")
        defer { signposter.endInterval("DispatchCommand", interval) }
        let time = ProcessInfo.processInfo.systemUptime
        conversation.tick(at: time)
        if testingName {
            if nameTrial.expired(at: time) {
                testingName = false; nameTrialStatus = Textos.t("popup.pruebaCaducada"); beginRecognition(); return
            }
            guard !recognized.isEmpty, !speaking else { return }
            if let sample = nameTrial.capture(recognized, at: time) {
                trialTimeout?.cancel(); testingName = false; nameTrialSample = sample; nameTrialStatus = "He oído: \(sample)"
                stream.commit(segments); recognized = ""; input.cancel(); input.beginUtterance()
            }
            return
        }
        let result = input.consume(recognized, wakeWord: wakeName, time: time, speaking: speaking, followUp: followUpAllowed?() == true, confirming: confirmationAllowed?() == true, conversationWaiting: conversation.state == .waiting, aliases: activationAliases, alsoComputer: alsoComputer, beganDuringSpeech: phraseDuringSpeech)
        guard result.beep || result.command != nil else { return }
        if result.beep {
            onWake?(); status = "Dime el comando…"
            if wakeSound?.play() != true { NSSound.beep() }
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
            turn += 1; let currentTurn = turn
            if conversationMode && VoiceConversation.closes(command, language: VoiceCatalog.currentLanguage) {
                conversation.cancel(); input.cancel(); onConversationClose?(); status = "Conversación cerrada; micrófono activo"
            } else {
                conversation.begin()
                executeCommand?(command) { [weak self] result in
                    guard let self, self.turn == currentTurn else { return }
                    self.conversation.receive(result, at: ProcessInfo.processInfo.systemUptime)
                }
            }
        }
        stream.commit(segments); recognized = ""; input.beginUtterance(); phraseDuringSpeech = speaking
        signposter.emitEvent("CommandDispatched")
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
    func setSpeechOutput(_ active: Bool, failed: Bool = false) {
        guard speaking != active || active else { return }
        speaking = active
        conversation.speech(starting: active, at: ProcessInfo.processInfo.systemUptime, failed: failed)
        speechTimeout?.cancel()
        if active {
            let work = DispatchWorkItem { [weak self] in self?.setSpeechOutput(false, failed: true) }
            speechTimeout = work; DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
        }
        logger.info("Salida de voz: \(active)")
        guard isListening else { return }
        if active { phraseDuringSpeech = true; input.cancel(); silence?.cancel(); recognized = ""; status = "Leyendo · puedes decir tu nombre de activación y «silencio»" }
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

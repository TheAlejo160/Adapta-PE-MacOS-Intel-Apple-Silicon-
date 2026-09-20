import Foundation
import Speech
import AVFoundation
import Combine
import SwiftUI
import AppKit

class VoiceManager: NSObject, ObservableObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    @Published var isListening = false
    @Published var transcript = ""
    @Published var status = "Micrófono apagado"
    
    @Published var availableMics: [AVCaptureDevice] = []
    
    // MEMORIA: Guarda el micrófono elegido
    @AppStorage("SelectedMicID") var selectedMicID: String = "" {
        didSet {
            if isListening { cambiarMicrofonoEnVivo() }
        }
    }
    
    // HARDWARE DE AUDIO
    private let captureSession = AVCaptureSession()
    private let audioOutput = AVCaptureAudioDataOutput()
    
    // MOTOR DE INTELIGENCIA DE APPLE
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-PE"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    
    // TEMPORIZADORES
    private var silenceTimer: Timer?
    private var safetyResetTimer: Timer?
    private var commandTimeoutTimer: Timer?
    
    // LÓGICA DE PARSEO CONTINUO (ESTILO PYTHON)
    private var recognizedText = ""
    private var processedText = ""
    private var isWaitingForCommand = false
    private var isAcceptingAudio = false
    
    func fetchMics() {
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
        DispatchQueue.main.async {
            self.availableMics = session.devices.filter {
                let name = $0.localizedName.lowercased()
                return !name.contains("iphone") && !name.contains("ipad")
            }
            if self.selectedMicID.isEmpty, let first = self.availableMics.first {
                self.selectedMicID = first.uniqueID
            }
        }
    }
    
    func startListening() {
        SFSpeechRecognizer.requestAuthorization { authStatus in
            DispatchQueue.main.async {
                if authStatus == .authorized {
                    self.setupHardwareOnce()
                } else {
                    self.status = "Error: Permiso denegado."
                }
            }
        }
    }
    
    func stopListening() {
        isListening = false
        isAcceptingAudio = false
        captureSession.stopRunning()
        
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        DispatchQueue.main.async { self.status = "Micrófono apagado" }
    }
    
    // ---------------------------------------------------------
    // 1. CONFIGURACIÓN DE HARDWARE (Se ejecuta una sola vez)
    // ---------------------------------------------------------
    
    private func setupHardwareOnce() {
        guard !isListening else { return }
        
        captureSession.beginConfiguration()
        captureSession.inputs.forEach { captureSession.removeInput($0) }
        
        guard let audioDevice = AVCaptureDevice(uniqueID: selectedMicID) ?? AVCaptureDevice.default(for: .audio),
              let audioInput = try? AVCaptureDeviceInput(device: audioDevice) else {
            DispatchQueue.main.async { self.status = "Error: Micrófono no detectado" }
            captureSession.commitConfiguration()
            return
        }
        
        if captureSession.canAddInput(audioInput) { captureSession.addInput(audioInput) }
        
        if captureSession.outputs.isEmpty {
            audioOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "audioQueue"))
            if captureSession.canAddOutput(audioOutput) { captureSession.addOutput(audioOutput) }
        }
        
        captureSession.commitConfiguration()
        
        if !captureSession.isRunning {
            DispatchQueue.global(qos: .userInitiated).async {
                self.captureSession.startRunning()
            }
        }
        
        isListening = true
        iniciarTareaDeSiri()
    }
    
    private func cambiarMicrofonoEnVivo() {
        isAcceptingAudio = false
        captureSession.beginConfiguration()
        captureSession.inputs.forEach { captureSession.removeInput($0) }
        
        if let audioDevice = AVCaptureDevice(uniqueID: selectedMicID),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice) {
            if captureSession.canAddInput(audioInput) { captureSession.addInput(audioInput) }
        }
        captureSession.commitConfiguration()
        
        reiniciarSiriSilenciosamente()
    }
    
    // ---------------------------------------------------------
    // 2. TAREA DE RECONOCIMIENTO CONTINUO
    // ---------------------------------------------------------
    
    private func iniciarTareaDeSiri() {
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else { return }
        
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        
        let wakeWord = UserDefaults.standard.string(forKey: "WakeWord")?.lowercased() ?? "computadora"
        DispatchQueue.main.async {
            self.status = self.isWaitingForCommand ? "👂 Dime..." : "🎙️ Activo. Di '\(wakeWord.capitalized)'"
        }
        
        // Esperamos un instante a que SFSpeechRecognizer esté listo antes de inyectar audio
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.isAcceptingAudio = true
        }
        
        // Límite de seguridad: Reiniciamos la IA cada 45s porque Apple tiene un límite interno de 1 minuto
        safetyResetTimer = Timer.scheduledTimer(withTimeInterval: 45.0, repeats: false) { [weak self] _ in
            self?.reiniciarSiriSilenciosamente()
        }
        
        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            
            if let result = result {
                let textoCompleto = result.bestTranscription.formattedString.lowercased()
                
                DispatchQueue.main.async {
                    self.transcript = textoCompleto
                    self.recognizedText = textoCompleto
                    
                    // DEBOUNCE: Si deja de hablar por 1.2s, procesamos la frase.
                    self.silenceTimer?.invalidate()
                    self.silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { _ in
                        self.procesarFraseContinua()
                    }
                }
            }
            
            // Si la IA arroja error interno o corta por tiempo, reiniciamos el motor
            if error != nil || result?.isFinal == true {
                self.reiniciarSiriSilenciosamente()
            }
        }
    }
    
    // ---------------------------------------------------------
    // 3. LÓGICA DE INTENCIONES (TIPO PYTHON)
    // ---------------------------------------------------------
    
    private func procesarFraseContinua() {
        let wakeWord = UserDefaults.standard.string(forKey: "WakeWord")?.lowercased().trimmingCharacters(in: .whitespaces) ?? "computadora"
        
        // Aislar solo lo NUEVO que dijo el usuario
        var textoNuevo = self.recognizedText
        if !self.processedText.isEmpty {
            if textoNuevo.hasPrefix(self.processedText) {
                textoNuevo = String(textoNuevo.dropFirst(self.processedText.count)).trimmingCharacters(in: .whitespaces)
            } else {
                textoNuevo = textoNuevo.replacingOccurrences(of: self.processedText, with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        
        if textoNuevo.isEmpty { return }
        
        if isWaitingForCommand {
            // FASE 2: Estaba esperando la orden
            ActionManager.shared.procesarIntencion(textoNuevo)
            
            self.processedText = self.recognizedText // Marcamos todo como procesado
            self.isWaitingForCommand = false
            self.commandTimeoutTimer?.invalidate()
            
            DispatchQueue.main.async { self.status = "🎙️ Activo. Di '\(wakeWord.capitalized)'" }
            
        } else {
            // FASE 1: Buscando palabra clave
            if textoNuevo.contains(wakeWord) {
                let componentes = textoNuevo.components(separatedBy: wakeWord)
                let comando = componentes.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                
                if comando.count > 2 {
                    // Dijo todo de corrido: "Computadora abre safari"
                    ActionManager.shared.procesarIntencion(comando)
                    self.processedText = self.recognizedText // Lo marcamos procesado y seguimos grabando
                } else {
                    // Dijo solo: "Computadora" -> Reproduce Beep y entra en Fase 2
                    NSSound(named: "Glass")?.play()
                    self.isWaitingForCommand = true
                    self.processedText = self.recognizedText // Guardamos "computadora" para escuchar lo que viene
                    
                    DispatchQueue.main.async { self.status = "👂 Dime..." }
                    
                    // Si el usuario no dice nada en 8 segundos, se anula la espera
                    self.commandTimeoutTimer?.invalidate()
                    self.commandTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: false) { [weak self] _ in
                        self?.isWaitingForCommand = false
                        DispatchQueue.main.async { self?.status = "🎙️ Activo. Di '\(wakeWord.capitalized)'" }
                    }
                }
            } else {
                // Habló pero no dijo la palabra de activación, lo anotamos para ignorarlo
                self.processedText = self.recognizedText
            }
        }
    }
    
    // ---------------------------------------------------------
    // 4. LIMPIEZA Y DESACOPLE ANTI-CRASH (EL ARREGLO FINAL)
    // ---------------------------------------------------------
    
    private func reiniciarSiriSilenciosamente() {
        // 1. Apagamos la válvula INMEDIATAMENTE para que no entren más buffers
        isAcceptingAudio = false
        
        // 2. Esperamos 0.1s para que cualquier buffer que estuviera en pleno vuelo termine de procesarse
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            
            // 3. Ahora sí, cerramos Siri de forma limpia. (Cero crasheos de mDataByteSize)
            self.recognitionRequest?.endAudio()
            self.recognitionTask?.cancel()
            
            self.recognitionTask = nil
            self.recognitionRequest = nil
            
            self.silenceTimer?.invalidate()
            self.safetyResetTimer?.invalidate()
            
            // ¡OJO! NO BORRAMOS `processedText` NI `recognizedText` para no perder la memoria del Parseo Continuo
            
            // 4. Reactivamos Siri
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if self.isListening {
                    self.iniciarTareaDeSiri()
                }
            }
        }
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isAcceptingAudio, let request = recognitionRequest else { return }
        
        // BLINDAJE ABSOLUTO: Bloqueamos búferes vacíos desde el HAL de macOS
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        
        if let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
            let length = CMBlockBufferGetDataLength(blockBuffer)
            if length > 0 {
                request.appendAudioSampleBuffer(sampleBuffer)
            }
        }
    }
}

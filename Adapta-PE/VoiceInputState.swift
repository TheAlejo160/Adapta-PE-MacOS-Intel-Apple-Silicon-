import Foundation

enum VoiceExecutionResult: String { case ok, failure = "fallo", unknown = "desconocida", confirming = "confirmando" }

struct VoiceConversation {
    enum State: String { case inactive = "inactivo", waiting = "esperando", executing = "ejecutando", speaking = "hablando", confirming = "confirmando" }
    var enabled = false
    private(set) var state: State = .inactive
    private(set) var waitingUntil = 0.0
    private var speechUntil = 0.0
    private var result: VoiceExecutionResult?
    private var speechFailed = false
    mutating func cancel() { state = .inactive; waitingUntil = 0; speechUntil = 0; result = nil; speechFailed = false }
    mutating func begin() { cancel(); state = .executing }
    mutating func receive(_ result: VoiceExecutionResult, at time: Double) {
        self.result = result
        renew(at: time)
    }
    mutating func speech(starting: Bool, at time: Double, failed: Bool = false) {
        if starting { speechUntil = time + 60; waitingUntil = 0; state = .speaking }
        else {
            speechUntil = 0; speechFailed = speechFailed || failed
            renew(at: time); result = nil // Un fin de lectura posterior ajeno al turno no renueva otra vez.
        }
    }
    private mutating func renew(at time: Double) {
        guard speechUntil == 0 else { state = .speaking; return }
        if result == .confirming && !speechFailed { state = .confirming; waitingUntil = 0 }
        else if enabled && result == .ok && !speechFailed { state = .waiting; waitingUntil = time + 8 }
        else { state = .inactive; waitingUntil = 0 }
        // Sin fin de lectura aún, conserva el resultado: el inicio del TTS puede llegar después del éxito.
    }
    mutating func tick(at time: Double) {
        if !time.isFinite || (speechUntil > 0 && time >= speechUntil) { cancel() }
        else if state == .waiting && time >= waitingUntil { cancel() }
    }
    static func closes(_ text: String, language: String) -> Bool {
        let value = CommandParser.normalize(text).replacingOccurrences(of: #"[.!?]+$"#, with: "", options: .regularExpression)
        return (VoiceCatalog.shared?.activacion.cierres[String(language.prefix(2))] ?? ["gracias", "listo", "silencio"]).contains(value)
    }
}

struct VoiceNameTrial {
    private(set) var deadline: Double?
    mutating func start(at time: Double) { deadline = time + 15 }
    mutating func cancel() { deadline = nil }
    mutating func expired(at time: Double) -> Bool {
        guard let deadline, time >= deadline else { return false }
        cancel(); return true
    }
    mutating func capture(_ text: String, at time: Double) -> String? {
        guard let deadline, time < deadline else { return nil }
        cancel(); return text
    }
}

struct WakePhraseState {
    private(set) var waitingUntil: Double = 0
    mutating func cancel() { waitingUntil = 0 }
    mutating func consume(_ text: String, wakeWord: String, time: Double, language: String = VoiceCatalog.currentLanguage, aliases: [String] = [], alsoComputer: Bool = false) -> (command: String?, beep: Bool) {
        guard time.isFinite else { cancel(); return (nil, false) }
        var command: String
        let name = WakeName.effective(wakeWord)
        if let end = VoiceActivation.end(in: text, name: name, language: language, aliases: aliases, alsoComputer: alsoComputer) {
            command = String(text[end...].drop(while: { $0.isWhitespace || ",.:;!?".contains($0) })).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if time < waitingUntil { command = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        else { return (nil, false) }
        if CommandParser.prepare(command, language: language).isEmpty { waitingUntil = time + 8; return (nil, true) }
        cancel(); return (command, false)
    }
}

// Speech corrige la transcripción completa: nunca quitar palabras por su posición anterior.
struct VoiceInputState {
    private var wake = WakePhraseState()
    private var handled = false
    var waitingUntil: Double { wake.waitingUntil }
    mutating func beginUtterance() { handled = false }
    mutating func cancel() { wake.cancel(); handled = false }
    mutating func consume(_ text: String, wakeWord: String, time: Double, speaking: Bool = false, followUp: Bool = false, confirming: Bool = false, conversationWaiting: Bool = false, language: String = VoiceCatalog.currentLanguage, aliases: [String] = [], alsoComputer: Bool = false, beganDuringSpeech: Bool = false) -> (command: String?, beep: Bool) {
        guard time.isFinite else { cancel(); return (nil, false) }
        guard !handled, !text.isEmpty else { return (nil, false) }
        if CommandParser.normalize(CommandParser.prepare(text)).range(of: "\\b(abre|abrir|busca|buscar|escribe|dicta|ejecuta|mostrar|en|de|campo|atajo)$", options: .regularExpression) != nil { return (nil, false) }
        var candidate = speaking ? WakePhraseState() : wake
        var result = candidate.consume(text, wakeWord: wakeWord, time: time, language: language, aliases: aliases, alsoComputer: alsoComputer)
        let prepared = CommandParser.prepare(text, language: language)
        let confirmationAnswer = CommandParser.parse(prepared) == .cancel || CommandParser.normalize(text).range(of: #"^(?:confirmar|confirmo|confirm|bestatige|confirme|confermo)\s+"#, options: .regularExpression) != nil
        if !speaking && !beganDuringSpeech && result.command == nil && !result.beep && (conversationWaiting || followUp || (confirming && confirmationAnswer)) { result = (text, false) }
        if beganDuringSpeech && !speaking { return (nil, false) }
        if speaking, let command = result.command {
            let intent = CommandParser.parse(command)
            let stop = CommandParser.normalize(CommandParser.prepare(command)).replacingOccurrences(of: #"[\s,]+(?:ya pe|ya pues|pe|pues)$"#, with: "", options: .regularExpression)
            guard intent == .silence || intent == .cancel || ["detener todo", "deten todo", "apaga todo", "para todo", "para", "parar", "stop", "para la lectura", "desactiva voz", "apaga el microfono", "desactiva el microfono"].contains(stop) else { return (nil, false) }
        }
        guard result.beep || result.command != nil else { return (nil, false) }
        wake = candidate; handled = true
        return result
    }
}

// Cada tramo Speech tiene tiempo propio: una corrección del prefijo consumido nunca reejecuta la orden.
struct VoiceTranscriptState {
    struct Segment {
        let range: NSRange
        let start: Double
        let duration: Double
    }
    private(set) var consumedUntil = -Double.infinity
    private var consumedStart = -Double.infinity
    mutating func reset() { consumedUntil = -.infinity; consumedStart = -.infinity }
    func suffix(_ text: String, segments: [Segment]) -> String {
        guard let first = segments.first(where: { $0.start > consumedStart && $0.start >= consumedUntil - 0.02 }), first.range.location >= 0, first.range.location <= (text as NSString).length else { return "" }
        return (text as NSString).substring(from: first.range.location)
    }
    mutating func commit(_ segments: [Segment]) {
        if let end = segments.last {
            consumedUntil = max(consumedUntil, end.start + max(0.001, end.duration))
            consumedStart = max(consumedStart, end.start)
        }
    }
}

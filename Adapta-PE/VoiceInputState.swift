import Foundation

struct WakePhraseState {
    private(set) var waitingUntil: Double = 0
    mutating func cancel() { waitingUntil = 0 }
    mutating func consume(_ text: String, wakeWord: String, time: Double) -> (command: String?, beep: Bool) {
        let word = wakeWord.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: word.isEmpty ? "computadora" : word) + "(?![\\p{L}\\p{N}])"
        var command: String
        if let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive, .diacriticInsensitive]) {
            command = String(text[range.upperBound...].drop(while: { $0.isWhitespace || ",.:;!?".contains($0) })).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if time < waitingUntil { command = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        else { return (nil, false) }
        if command.isEmpty { waitingUntil = time + 8; return (nil, true) }
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
    mutating func consume(_ text: String, wakeWord: String, time: Double, speaking: Bool = false, followUp: Bool = false) -> (command: String?, beep: Bool) {
        guard !handled, !text.isEmpty else { return (nil, false) }
        if CommandParser.normalize(text).range(of: "\\b(abre|abrir|busca|buscar|escribe|dicta|ejecuta|mostrar|en|de|campo|atajo)$", options: .regularExpression) != nil { return (nil, false) }
        var candidate = speaking ? WakePhraseState() : wake
        var result = candidate.consume(text, wakeWord: wakeWord, time: time)
        if followUp && !speaking && result.command == nil && !result.beep { result = (text, false) }
        if speaking, let command = result.command {
            let intent = CommandParser.parse(command)
            guard intent == .silence || intent == .cancel || CommandParser.normalize(command) == "detener todo" else { return (nil, false) }
        }
        guard result.beep || result.command != nil else { return (nil, false) }
        wake = candidate; handled = true
        return result
    }
}

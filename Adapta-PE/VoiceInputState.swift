import Foundation

struct WakePhraseState {
    private(set) var waitingUntil: Double = 0
    mutating func cancel() { waitingUntil = 0 }
    mutating func consume(_ text: String, wakeWord: String, time: Double) -> (command: String?, beep: Bool) {
        guard time.isFinite else { cancel(); return (nil, false) }
        let word = wakeWord.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = word.isEmpty || CommandParser.normalize(word) == "computadora" ? "(?:computadoras?|computador)" : CommandParser.normalize(word)
            .split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s+")
        let pattern = "(?<![\\p{L}\\p{N}])" + name + "(?![\\p{L}\\p{N}])"
        // Las regex no pliegan acentos; cada unidad normalizada conserva el límite original.
        var folded = "", ends: [String.Index] = []
        for index in text.indices {
            let piece = String(text[index]).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es_PE"))
            folded += piece
            ends.append(contentsOf: repeatElement(text.index(after: index), count: piece.utf16.count))
        }
        let match = (try? NSRegularExpression(pattern: pattern))?.firstMatch(in: folded, range: NSRange(folded.startIndex..., in: folded))
        var command: String
        if let match, match.range.length > 0, ends.indices.contains(NSMaxRange(match.range) - 1) {
            command = String(text[ends[NSMaxRange(match.range) - 1]...].drop(while: { $0.isWhitespace || ",.:;!?".contains($0) })).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if time < waitingUntil { command = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        else { return (nil, false) }
        if CommandParser.prepare(command).isEmpty { waitingUntil = time + 8; return (nil, true) }
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
        guard time.isFinite else { cancel(); return (nil, false) }
        guard !handled, !text.isEmpty else { return (nil, false) }
        if CommandParser.normalize(text).range(of: "\\b(abre|abrir|busca|buscar|escribe|dicta|ejecuta|mostrar|en|de|campo|atajo)$", options: .regularExpression) != nil { return (nil, false) }
        var candidate = speaking ? WakePhraseState() : wake
        var result = candidate.consume(text, wakeWord: wakeWord, time: time)
        if followUp && !speaking && result.command == nil && !result.beep { result = (text, false) }
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

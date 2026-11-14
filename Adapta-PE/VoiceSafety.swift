import Foundation

struct VoiceSafety {
    static func destructive(_ text: String) -> Bool {
        let words = #"salir|sal|cierra|cierre|cerrar|termina|terminar|elimina|eliminar|borra|borrar|vacia|vaciar|limpia|limpiar|envia|enviar|manda|publica|publicar|compra|comprar|quit|exit|close|delete|remove|erase|empty|clear|send|submit|publish|buy|fechar|fecha|sair|apagar|excluir|exclui|apaga|esvaziar|esvazia|limpar|enviar|envie|comprar|beenden|schliessen|loschen|leeren|senden|veroffentlichen|kaufen|quitter|fermer|supprimer|effacer|vider|envoyer|publier|acheter|chiudi|chiudere|esci|uscire|elimina|eliminare|cancella|cancellare|svuota|svuotare|invia|inviare|pubblica|pubblicare|acquista|acquistare"#
        return CommandParser.normalize(text).range(of: "(?<![\\p{L}])(?:" + words + ")(?![\\p{L}])", options: .regularExpression) != nil
    }
    static func menuIndices(_ query: String, labels: [String], aliases: [String] = []) -> [Int] {
        guard !NameMatch.key(query).isEmpty, query.count <= 160 else { return [] }
        let keys = ([query] + aliases).map(NameMatch.key)
        let exact = labels.indices.filter { keys.contains(NameMatch.key(labels[$0])) }
        if !exact.isEmpty { return exact }
        guard !destructive(query) else { return [] }
        let safe = labels.indices.filter { !destructive(labels[$0]) }
        let contained = safe.filter { NameMatch.key(labels[$0]).contains(NameMatch.key(query)) }
        if !contained.isEmpty { return contained }
        return NameMatch.uniqueIndex(query, names: safe.map { [labels[$0]] }).map { [safe[$0]] } ?? []
    }
}

// Frase «<verbo> <acción>» del catálogo; el destino no se pronuncia: lo fija y revalida quien confirma (pid, ventana, pestañas).
struct VoiceConfirmation {
    static let timeout: Double = 8
    let action: String // Clave de `comportamiento.destructivas` (cerrar_pestana…) o etiqueta visible.
    let destination: String
    let pid: Int32
    let expiresAt: Double
    var language = VoiceCatalog.currentLanguage
    static func known(_ key: String?) -> String? { key.flatMap { VoiceCatalog.shared?.comportamiento.destructivas.contains($0) == true ? $0 : nil } }
    private var texts: [String: String] {
        let all = VoiceCatalog.shared?.comportamiento.confirmaciones
        return all?[String(language.prefix(2))] ?? all?["es"] ?? [:]
    }
    var phrase: String { (texts["verbo"] ?? "confirmo") + " " + (texts[action] ?? action) }
    var question: String { (texts["pregunta"] ?? "Di exactamente: {frase}.").replacingOccurrences(of: "{frase}", with: phrase) }
    private static func key(_ text: String) -> String { NameMatch.key(text.replacingOccurrences(of: "ß", with: "ss")) }
    func accepts(_ text: String, pid: Int32, time: Double) -> Bool {
        time.isFinite && expiresAt.isFinite && time < expiresAt && self.pid == pid && Self.key(text) == Self.key(phrase)
    }
}

struct WakeName {
    static let defaultName = "Computadora"
    static func literal(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.lowercased().map {
            let original = String($0), folded = String($0).folding(options: .diacriticInsensitive, locale: Locale(identifier: "es_PE"))
            return ["a", "e", "i", "o", "u"].contains(folded) ? folded : original
        }.joined()
    }
    // «Computadora» guardada equivale al nombre predeterminado: Computadora y la palabra del idioma.
    static func effective(_ value: String) -> String { literal(value) == "computadora" ? "" : value }
    static func normalized(_ value: String) -> String { value.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    static func error(_ value: String) -> String? {
        let name = normalized(value)
        guard (3...24).contains(name.utf16.count), name.unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count >= 3 else { return "Usa de 3 a 24 caracteres y al menos 3 letras." }
        guard name.range(of: #"^[\p{L}\p{M}' ’-]+$"#, options: .regularExpression) != nil else { return "Usa letras, espacios, apóstrofos o guiones." }
        guard name.split(separator: " ").count <= 3 else { return "Usa hasta tres palabras." }
        if VoiceCatalog.shared?.activacion.compuestosVocativos.contains(where: { $0.lowercased() == name.lowercased() }) == true { return nil }
        let parts = [name] + name.components(separatedBy: CharacterSet(charactersIn: " '-’"))
        guard !parts.contains(where: { reserved.contains(key($0)) }) else { return "El nombre contiene una orden, muletilla o nombre de mascota. Elige otro." }
        return nil
    }
    static var saved: String {
        let name = UserDefaults.standard.string(forKey: "WakeWord") ?? defaultName
        return error(name) == nil ? normalized(name) : defaultName
    }
    private static let reserved = Set((VoiceCatalog.shared?.activacion.reservadas ?? [:]).keys)

    static func letters(_ text: String) -> String { literal(text).replacingOccurrences(of: #"[^\p{L}\p{N}]"#, with: "", options: .regularExpression) }
    static func key(_ text: String) -> String {
        var result = "", previous: Character?, count = 0
        for letter in letters(text) {
            count = letter == previous ? count + 1 : 1
            if count == 1 || (count == 2 && "lr".contains(letter)) { result.append(letter) }
            previous = letter
        }
        return result
    }
}

enum VoiceActivation {
    static func aliases(_ values: [String], name: String) -> [String]? {
        guard values.count <= (VoiceCatalog.shared?.activacion.maxAlias ?? 3) else { return nil }
        var seen = Set([WakeName.key(name)]), result: [String] = []
        for value in values {
            guard WakeName.error(value) == nil, seen.insert(WakeName.key(value)).inserted else { return nil }
            result.append(WakeName.normalized(value))
        }
        return result
    }
    static func profile(_ text: String) -> String {
        (VoiceCatalog.shared?.activacion.perfilEspanol.reglas ?? []).reduce(WakeName.letters(text)) { $1.apply($0) }
    }
    private static func validPrefix(_ text: String, language: String, catalog: VoiceCatalog) -> Bool {
        var rest = CommandParser.normalize(text).trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?¿¡"))
        for _ in 0..<8 where !rest.isEmpty {
            let previous = rest
            if let pattern = catalog.idiomas[language]?.envoltorios, let regex = try? pattern.regex() {
                let input = rest + " "
                rest = regex.stringByReplacingMatches(in: input, range: NSRange(input.startIndex..., in: input), withTemplate: "").trimmingCharacters(in: .whitespaces)
            }
            for word in catalog.activacion.vocativos[language] ?? [] {
                if rest == word || rest.hasPrefix(word + " ") { rest = String(rest.dropFirst(word.count)).trimmingCharacters(in: .whitespaces) }
            }
            rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?"))
            if rest == previous { break }
        }
        return rest.isEmpty
    }
    static func end(in text: String, name: String, language: String = VoiceCatalog.currentLanguage, aliases values: [String] = [], alsoComputer: Bool = false) -> String.Index? {
        guard let catalog = VoiceCatalog.shared, let regex = try? NSRegularExpression(pattern: #"[\p{L}\p{M}\p{N}]+"#) else { return nil }
        let base = String(language.prefix(2)), fragments = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) }
        let starts = fragments.indices.prefix(32).filter { validPrefix(String(text[..<fragments[$0].lowerBound]), language: base, catalog: catalog) }
        let valid = WakeName.error(name) == nil
        if !valid || alsoComputer {
            let patterns = [catalog.idiomas["es"]?.activacion, catalog.idiomas[base]?.activacion].compactMap { $0 }
            for start in starts where WakeName.letters(String(text[fragments[start]])).range(of: "^(?:" + patterns.joined(separator: "|") + ")$", options: .regularExpression) != nil { return fragments[start].upperBound }
        }
        for chosen in (valid ? [WakeName.normalized(name)] : []) + (aliases(values, name: name) ?? []) {
            let target = WakeName.key(chosen), table = catalog.activacion.pronunciaciones[target] ?? []
            let allowsProfile = base == "es" && WakeName.letters(chosen).count >= catalog.activacion.perfilEspanol.minimoLetras
            for start in starts {
                var joined = "", best: String.Index?
                for index in start..<min(fragments.count, start + chosen.split(separator: " ").count * catalog.activacion.fragmentosPorPalabra) {
                    joined += WakeName.letters(String(text[fragments[index]]))
                    let key = WakeName.key(joined)
                    if key == target || key == target + "s" || table.contains(key) || (allowsProfile && profile(key) == profile(target)) { best = fragments[index].upperBound }
                    else if best != nil { break }
                }
                if let best { return best }
            }
        }
        return nil
    }
    static func contextualStrings(name: String, aliases values: [String], alsoComputer: Bool, language: String) -> [String] {
        let catalog = VoiceCatalog.shared, name = WakeName.effective(name)
        let names = (name.isEmpty ? [] : [name]) + (aliases(values, name: name) ?? [])
        return Array(Set(names + names.flatMap { catalog?.activacion.pronunciaciones[WakeName.key($0)] ?? [] } + (alsoComputer || WakeName.error(name) != nil ? ["Computadora", catalog?.idiomas[String(language.prefix(2))]?.palabra ?? "Computadora"] : []))).sorted()
    }
}

enum VoiceTolerance {
    enum Correction: Equatable { case text(String), repeatCommand }
    static func distance(_ a: String, _ b: String) -> Int {
        let b = Array(b); var previous = Array(0...b.count)
        for (i, letter) in a.enumerated() {
            var row = [i + 1]
            for j in b.indices { row.append(min(previous[j + 1] + 1, row[j] + 1, previous[j] + (letter == b[j] ? 0 : 1))) }
            previous = row
        }
        return previous[b.count]
    }
    static func correct(_ text: String, language: String = VoiceCatalog.currentLanguage) -> Correction? {
        guard let catalog = VoiceCatalog.shared else { return nil }
        let rules = catalog.tolerancia, original = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token = original.split(whereSeparator: \.isWhitespace).first else { return nil }
        let word = CommandParser.normalize(String(token))
        guard word.count >= rules.minimoLetras else { return nil }
        let candidates = ((rules.verbos[String(language.prefix(2))] ?? []).map { ($0, false) } + rules.excluidos.values.flatMap { $0 }.map { ($0, true) }).map { (verb: $0.0, excluded: $0.1, distance: distance(word, $0.0)) }.sorted { $0.distance < $1.distance }
        guard let excluded = candidates.first(where: \.excluded), excluded.distance != 0 else { return nil }
        if excluded.distance <= rules.distanciaMaxima { return .repeatCommand }
        guard catalog.activacion.reservadas[WakeName.key(word)] == nil, let best = candidates.first, !best.excluded, best.distance <= rules.distanciaMaxima, best.verb.count >= rules.minimoLetras,
              candidates.count < 2 || candidates[1].distance >= rules.distanciaSegundo else { return nil }
        return .text(best.verb + original.dropFirst(token.count))
    }
    static func site(_ text: String, language: String = VoiceCatalog.currentLanguage) -> String? {
        guard let catalog = VoiceCatalog.shared, language.hasPrefix("es") else { return nil }
        let key = WakeName.key(text)
        guard key.count >= catalog.tolerancia.minimoLetras else { return nil }
        let found = catalog.sitios.filter { (catalog.tolerancia.sitios[$0.key] ?? []).contains(key) || $0.value.alias.contains { profileAlias in VoiceActivation.profile(WakeName.key(profileAlias)) == VoiceActivation.profile(key) } }.map(\.key)
        return found.count == 1 ? found[0] : nil
    }
    static func announcement(site id: String, language: String = VoiceCatalog.currentLanguage) -> String? {
        guard let home = VoiceCatalog.shared?.sitios[id]?.inicio, let host = URL(string: home)?.host else { return nil }
        return VoiceCatalog.text("voz.abriendo", ["sitio": host.hasPrefix("www.") ? String(host.dropFirst(4)) : host], language: language)
    }
}

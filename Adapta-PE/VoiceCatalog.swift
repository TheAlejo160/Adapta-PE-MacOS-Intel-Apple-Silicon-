import Foundation
import OSLog
import CryptoKit

struct VoiceCatalog: Decodable {
    struct Pattern: Decodable {
        let patron: String
        let flags: String
        func regex() throws -> NSRegularExpression {
            guard flags.allSatisfy({ "iu".contains($0) }) else { throw CatalogError.invalid }
            return try NSRegularExpression(pattern: patron, options: flags.contains("i") ? .caseInsensitive : [])
        }
    }
    struct Phrase: Decodable {
        let pattern: Pattern
        let replacement: String
        init(from decoder: Decoder) throws {
            var values = try decoder.unkeyedContainer()
            pattern = try values.decode(Pattern.self); replacement = try values.decode(String.self)
            guard values.isAtEnd else { throw CatalogError.invalid }
        }
    }
    struct Language: Decodable {
        let activacion: String, palabra: String, tts: String, ayuda: String
        let envoltorios: Pattern, finales: Pattern
        let verbos: [String: String]?
        let frases: [Phrase]
        let conector: String?
        let pestanaNueva: Pattern?, ventanaNueva: Pattern?
    }
    struct Site: Decodable {
        let alias: [String]
        let inicio: String
        let busqueda: String?
    }
    struct Origin: Decodable { let sha256: [String: String] }
    struct Rule: Decodable {
        let patron: String, flags: String, reemplazo: String
        func apply(_ text: String) -> String { text.replacingOccurrences(of: patron, with: reemplazo, options: .regularExpression) }
    }
    struct Activation: Decodable {
        struct Profile: Decodable { let minimoLetras: Int; let reglas: [Rule] }
        let version: Int, maxAlias: Int, fragmentosPorPalabra: Int
        let reservadas: [String: String], pronunciaciones: [String: [String]], vocativos: [String: [String]], cierres: [String: [String]], interrupciones: [String: [String]]
        let compuestosVocativos: [String], perfilEspanol: Profile
    }
    struct Tolerance: Decodable {
        let prefijoTokens: Int, minimoLetras: Int, distanciaMaxima: Int, distanciaSegundo: Int
        let combinarEdicionFonetica: Bool
        let verbos: [String: [String]], excluidos: [String: [String]], sitios: [String: [String]]
    }
    struct Behavior: Decodable { let version: Int; let confirmacionMs: Int; let destructivas: [String]; let confirmaciones: [String: [String: String]] }
    struct Texts: Decodable { let voz: [String: [String: String]] }
    struct TutorialStep: Decodable, Equatable {
        let id: String
        let orden: String?
        let soloBase: Bool?
        var isSoloBase: Bool { soloBase ?? false }
    }
    struct TutorialCatalog: Decodable, Equatable {
        let version: Int
        let orden: String
        let pasos: [TutorialStep]
    }
    enum CatalogError: Error { case invalid, missing }
    let schemaVersion: Int
    let origen: Origin
    let activacion: Activation
    let comportamiento: Behavior
    let tolerancia: Tolerance
    let codigos: [String]
    let textos: Texts
    let tutorial: TutorialCatalog?
    let idiomas: [String: Language]
    let sitios: [String: Site]
    static let supported = ["es", "en", "pt", "de", "fr", "it"]
    static let shared: VoiceCatalog? = {
        do { return try load() }
        catch { Logger(subsystem: "pe.adapta.desktop", category: "catalog").error("Catálogo de voz inválido: \(error.localizedDescription, privacy: .public)"); return nil }
    }()
    private final class ResourceAnchor: NSObject {}
    static func resource(_ name: String) -> URL? {
        if let url = Bundle(for: ResourceAnchor.self).url(forResource: name, withExtension: "json"), FileManager.default.fileExists(atPath: url.path) { return url }
        for candidate in ["Adapta-PE/\(name).json", "\(name).json", "../Adapta-PE/\(name).json"] {
            let fileURL = URL(fileURLWithPath: candidate)
            if FileManager.default.fileExists(atPath: fileURL.path) { return fileURL }
        }
        return nil
    }
    static func load() throws -> VoiceCatalog {
        guard let url = resource("nativo-v1") else { throw CatalogError.missing }
        let catalog = try decode(Data(contentsOf: url))
        for name in ["voz-paridad", "activacion-paridad"] {
            guard let url = resource(name), let expected = catalog.origen.sha256["tests/fixtures/\(name).json"] else { throw CatalogError.missing }
            let digest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            guard digest == expected else { throw CatalogError.invalid }
        }
        return catalog
    }
    static func decode(_ data: Data) throws -> VoiceCatalog {
        guard data.count <= 3_000_000 else { throw CatalogError.invalid }
        let catalog = try JSONDecoder().decode(Self.self, from: data)
        guard catalog.schemaVersion == 1, catalog.activacion.version == 1, !catalog.activacion.reservadas.isEmpty,
              catalog.activacion.maxAlias == 3, catalog.activacion.fragmentosPorPalabra == 3,
              catalog.tolerancia.prefijoTokens == 1, !catalog.tolerancia.combinarEdicionFonetica,
              catalog.comportamiento.version == 1, catalog.comportamiento.confirmacionMs == 8_000,
              Set(catalog.comportamiento.confirmaciones.keys) == Set(supported), catalog.comportamiento.confirmaciones.values.allSatisfy({ $0["verbo"] != nil && $0["pregunta"] != nil }),
              Set(catalog.idiomas.keys) == Set(supported), !catalog.sitios.isEmpty,
              catalog.codigos.contains("es-PE") else { throw CatalogError.invalid }
        for rule in catalog.activacion.perfilEspanol.reglas {
            guard rule.flags == "g" else { throw CatalogError.invalid }
            _ = try NSRegularExpression(pattern: rule.patron)
        }
        for language in catalog.idiomas.values {
            guard !language.palabra.isEmpty, !language.ayuda.isEmpty, catalog.codigos.contains(language.tts) else { throw CatalogError.invalid }
            _ = try NSRegularExpression(pattern: "^(?:" + language.activacion + ")$")
            for pattern in [language.envoltorios, language.finales] + [language.pestanaNueva, language.ventanaNueva].compactMap({ $0 }) + language.frases.map(\.pattern) { _ = try pattern.regex() }
            if let connector = language.conector { _ = try NSRegularExpression(pattern: connector) }
        }
        for site in catalog.sitios.values {
            guard !site.alias.isEmpty, site.alias.allSatisfy({ !$0.isEmpty }) else { throw CatalogError.invalid }
            for address in [site.inicio, site.busqueda].compactMap({ $0 }) {
                guard let url = URL(string: address), ["http", "https"].contains(url.scheme), url.host != nil else { throw CatalogError.invalid }
            }
        }
        return catalog
    }
    static func locale(preference: String, preferred: [String] = Locale.preferredLanguages) -> String {
        for code in preference == "auto" ? preferred : [preference] {
            let code = code.replacingOccurrences(of: "_", with: "-")
            let base = String(code.prefix(2)).lowercased()
            guard supported.contains(base) else { continue }
            if let exact = shared?.codigos.first(where: { $0.lowercased() == code.lowercased() }) { return exact }
            if code.range(of: #"^[a-zA-Z]{2}-[a-zA-Z0-9]{2,3}$"#, options: .regularExpression) != nil { return code }
            return ["es": "es-PE", "en": "en-US", "pt": "pt-BR", "de": "de-DE", "fr": "fr-FR", "it": "it-IT"][base]!
        }
        return "es-PE"
    }
    static var currentLocale: String { locale(preference: UserDefaults.standard.string(forKey: "VoiceLanguage") ?? "auto") }
    static var currentLanguage: String { String(currentLocale.prefix(2)).lowercased() }
    // Textos de voz del catálogo («voz.corregido»…), con respaldo español y variables {nombre}.
    static func text(_ key: String, _ values: [String: String] = [:], language: String = currentLanguage) -> String {
        Textos.shared.t(key, values, idioma: language)
    }

    // Mapea cada unidad plegada al original; los grupos conservan Unicode y espacios del dictado.
    static func match(_ pattern: String, in text: String) -> (NSRange, [String])? {
        var folded = "", starts: [Int] = [], ends: [Int] = [], offset = 0
        for character in text {
            let original = String(character)
            let piece = original.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es_PE"))
            folded += piece
            starts += repeatElement(offset, count: piece.utf16.count)
            offset += original.utf16.count
            ends += repeatElement(offset, count: piece.utf16.count)
        }
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: folded, range: NSRange(location: 0, length: folded.utf16.count)), match.range.length > 0 else { return nil }
        func range(_ index: Int) -> NSRange? {
            let value = match.range(at: index)
            guard value.location != NSNotFound, value.length > 0, starts.indices.contains(value.location), ends.indices.contains(NSMaxRange(value) - 1) else { return nil }
            return NSRange(location: starts[value.location], length: ends[NSMaxRange(value) - 1] - starts[value.location])
        }
        guard let full = range(0) else { return nil }
        return (full, (0..<match.numberOfRanges).map { range($0).map { (text as NSString).substring(with: $0) } ?? "" })
    }
    func prepare(_ text: String, language code: String) -> String {
        guard let spanish = idiomas["es"] else { return text }
        let language = idiomas[String(code.prefix(2))] ?? spanish
        let foreign = String(code.prefix(2)) != "es"
        let ending = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;:!?"))
        var original = String(text.trimmingCharacters(in: .whitespacesAndNewlines).drop(while: { $0.isWhitespace || "¿¡,.;:".contains($0) }))
        func replace(_ pattern: String, _ replacement: String) -> Bool {
            guard let (range, groups) = Self.match(pattern, in: original) else { return false }
            var value = replacement
            for index in groups.indices.reversed() { value = value.replacingOccurrences(of: "$\(index)", with: groups[index]) }
            original = (original as NSString).replacingCharacters(in: range, with: value)
            return true
        }
        original += ","
        while replace(language.envoltorios.patron, "") || (foreign && replace(spanish.envoltorios.patron, "")) {
            original = String(original.drop(while: { $0.isWhitespace || "¿¡,.;:!?".contains($0) }))
        }
        if original.hasSuffix(",") { original.removeLast() }
        if foreign { for phrase in language.frases where replace(phrase.pattern.patron, phrase.replacement) { break } }
        if let (range, words) = Self.match(#"^[\p{L}\p{M}]+"#, in: original), let verb = spanish.verbos?[CommandParser.normalize(words[0])] {
            original = (original as NSString).replacingCharacters(in: range, with: verb)
        }
        if Self.match(#"^(?:escribe|dicta|introduce|ingresa texto|teclea|tipea|(?:pregunta|consulta)\s+a\s+la\s+ia|(?:selecciona|resalta)\s+(?:el\s+)?texto)\s+"#, in: original) != nil { return original }
        original = original.trimmingCharacters(in: ending)
        // Los nombres propios «Adapta PE» y consultas acabadas en «pues» no son cortesías.
        let spanishEnd = #"(?:[\s,]+(?:por favor|porfa|porfis)|,\s*(?:ya pe|ya pues|pe|pues))$"#
        while replace(foreign ? language.finales.patron : spanishEnd, "") || (foreign && replace(spanishEnd, "")) { original = original.trimmingCharacters(in: ending) }
        var suffix = ""
        if foreign, Self.match(#"^(?:busca|abre) "#, in: original) != nil {
            for (pattern, destination) in [(language.pestanaNueva, " en una nueva pestaña"), (language.ventanaNueva, " en una nueva ventana")] {
                if let pattern, replace(pattern.patron, "") { suffix = destination; break }
            }
            if let connector = language.conector, let (range, groups) = Self.match("^(busca .*\\S) " + connector + " (.+)$", in: original), groups.count == 3,
               sitios.contains(where: { CommandParser.normalize(groups[2]) == $0.key || $0.value.alias.contains(CommandParser.normalize(groups[2])) }) {
                original = (original as NSString).replacingCharacters(in: range, with: groups[1] + " en " + groups[2])
            }
        }
        for phrase in spanish.frases where replace(phrase.pattern.patron, phrase.replacement) { break }
        return original + suffix
    }
}

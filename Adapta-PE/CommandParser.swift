import Foundation
import CoreGraphics

enum VoiceCommand: Equatable {
    case dictate(String), clearText, select(String), focus(String), press(String), pressSelection, readElement(String)
    case open(String, String), search(String, String?, String), closeApp(String), shortcut(String)
    case kinetic(String), readScreen, silence, cancel, unknown(String)
    case appShortcut(String, String), keyChord(String), menu(String), listActions, listFields, writeField(String, String), selectText(String), choose(String)
}

struct CommandParser {
    static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_PE"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // Capturar sobre el original conserva signos, acentos y mayúsculas del dictado.
    static func tail(_ pattern: String, in text: String) -> String? {
        guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive, .diacriticInsensitive]) else { return nil }
        return String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parse(_ text: String) -> VoiceCommand {
        var original = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let clean = tail("^(?:por favor[, ]+|puedes\\s+|podrías\\s+)", in: original) { original = clean }
        let clean = original.replacingOccurrences(of: "[.!?]+$", with: "", options: .regularExpression)
        let normalized = normalize(clean)
        if ["que puedo hacer", "mostrar comandos", "muestra comandos", "listar acciones", "muestra acciones", "acciones disponibles"].contains(normalized) { return .listActions }
        if ["muestra campos", "mostrar campos", "buscar campos", "busca campos de texto", "campos de texto", "donde puedo escribir"].contains(normalized) { return .listFields }
        if let value = tail("^(?:elige|elijo|elegir|opción|opcion|número|numero)\\s+", in: clean) { return .choose(value) }
        if let value = tail("^(?:selecciona|seleccionar)\\s+", in: clean), ChoicePrompt.ordinal(value) != nil { return .choose(value) }
        if ChoicePrompt.ordinal(normalized) != nil { return .choose(normalized) }
        if let match = captures("^(?:(?:abre|abrir|crea|crear|muestra|mostrar)(?: una| la|otra)? )?(?:una |la |otra )?((?:nueva )?(?:ventana|pestaña)(?: nueva)?) (?:de|en) (.+)$", in: clean) {
            return .appShortcut(match[1], normalize(match[0]).contains("ventana") ? "nueva_ventana" : "nueva_pestana")
        }
        if let match = captures("^(?:escribe|dicta|introduce) (.+?) en (?:el )?campo (.+)$", in: original) { return .writeField(match[0], controlName(match[1])) }
        if let match = captures("^(?:escribe|dicta) en (?:el )?campo (.+?) (?:el texto|lo siguiente) (.+)$", in: original) { return .writeField(match[1], controlName(match[0])) }
        if let value = tail("^(?:selecciona|seleccionar|resalta) (?:el )?texto\\s+", in: original) { return .selectText(value) }
        if let value = tail("^(?:atajo|pulsa el atajo|presiona el atajo|ejecuta el atajo)\\s+", in: clean) { return .keyChord(value) }
        if let value = tail("^(?:presiona(?:r)?|pulsa(?:r)?|oprime)\\s+", in: clean), KeyChord.parse(value) != nil { return .keyChord(value) }
        if let value = tail("^(?:ejecuta|activa|elige|pulsa) (?:la )?(?:acción|opción de menú|opcion de menu)|^menú|^menu", in: clean), !value.isEmpty { return .menu(value) }
        if let shortcut = shortcuts[normalized] { return .shortcut(shortcut) }
        if let target = tail("^(?:presiona(?:r)?|pulsa(?:r)?|ejecuta(?:r)?)\\s+", in: clean), let shortcut = shortcuts[normalize(target)] { return .shortcut(shortcut) }
        if let match = captures("^(.+?) en (.+)$", in: clean), let shortcut = shortcuts[normalize(match[0])] { return .appShortcut(match[1], shortcut) }
        if let value = tail("^(?:escribe|escribir|dicta|dictar|introduce|ingresa texto)\\s+", in: original) { return .dictate(value) }
        original = original.replacingOccurrences(of: "[, ]+por favor[.!?]*$|[.!?]+$", with: "", options: [.regularExpression, .caseInsensitive])
        let cmd = normalize(original)
        if ["cancelar", "cancela", "olvidalo", "no hagas nada", "cancelar seleccion", "quita la seleccion"].contains(cmd) { return .cancel }
        if ["callar", "silencio", "deja de leer", "deja de hablar"].contains(cmd) { return .silence }
        if ["lee la pantalla", "leer pantalla", "leer la pantalla", "lee pantalla", "leer ventana", "lee la ventana", "ojo bionico"].contains(cmd) { return .readScreen }
        if let target = tail("^(?:lee|leer|léeme)\\s+", in: original) { return .readElement(controlName(target)) }
        if let target = tail("^(?:selecciona(?:r)?|resalta(?:r)?|marca(?:r)?)\\s+", in: original) { return .select(controlName(target)) }
        if let target = tail("^(?:enfoca(?:r)?|activa el campo)\\s+", in: original) { return .focus(controlName(target)) }
        if ["dale clic", "dale click", "hazle clic", "pulsa lo seleccionado", "activa lo seleccionado"].contains(cmd) { return .pressSelection }
        if let kinetic = kineticCommands[cmd] { return .kinetic(kinetic) }
        if let target = tail("^(?:(?:haz|hacer|da|dar|dale) (?:clic|click)(?: en| a)?|clic en|click en|pulsa(?:r)?|presiona(?:r)?|oprime|activar)\\s+", in: original), !["enter", "intro", "copiar", "pegar"].contains(normalize(target)) { return .press(controlName(target)) }
        if let kinetic = kineticCommands[cmd] { return .kinetic(kinetic) }
        if let shortcut = shortcuts[cmd] { return .shortcut(shortcut) }
        let patterns: [(String, String)] = [
            ("^(?:(?:abre|abrir|crea|crear) )?(?:una )?(?:nueva pestana|pestana(?: nueva)?)$", "nueva_pestana"),
            ("^(?:(?:abre|abrir|crea|crear) )?(?:una )?(?:nueva ventana|ventana(?: nueva)?)$", "nueva_ventana"),
            ("^(?:cierra|cerrar) (?:(?:esta|la|actual) )?pestana(?: actual)?$", "cerrar_pestana"),
            ("^(?:cierra|cerrar) (?:(?:esta|la|actual) )?ventana(?: actual)?$", "cerrar_ventana"),
            ("^(atras|volver|vuelve|regresa|regresar|retrocede|retroceder|pagina anterior|vuelve atras|volver atras)$", "atras"),
            ("^(adelante|avanza|pagina siguiente|ve adelante)$", "adelante"),
            ("^(recarga|recargar|actualiza|actualizar|refresca|refrescar)( la)?( pagina)?$", "recargar"),
            ("^(?:cambia (?:a )?(?:la )?)?(siguiente pestana|pestana siguiente)$", "siguiente_pestana"),
            ("^(?:cambia (?:a )?(?:la )?)?(anterior pestana|pestana anterior)$", "anterior_pestana"),
            ("^(aumenta(r)? zoom|acerca(r)?|amplia|zoom mas)$", "zoom_mas"),
            ("^(reduce zoom|aleja(r)?|zoom menos)$", "zoom_menos"),
            ("^(restablece zoom|zoom normal)$", "zoom_normal"),
            ("^(?:ve |ir )?(?:al )?(inicio|principio)(?: de (?:la )?pagina)?$", "inicio"),
            ("^(?:ve |ir )?(?:al )?(final|fin)(?: de (?:la )?pagina)?$", "final"),
            ("^(reproduce|reproducir|continuar video)(?: (?:el )?(?:video|audio|musica))?$", "reproducir"),
            ("^(pausa|pausar)(?: (?:el )?(?:video|audio|musica))?$", "pausar")
        ]
        if let match = patterns.first(where: { cmd.range(of: $0.0, options: .regularExpression) != nil }) { return .shortcut(match.1) }

        if cmd.range(of: "^(borra|borrar|limpia|limpiar)( el)? (texto|campo)$", options: .regularExpression) != nil { return .clearText }
        if cmd.range(of: "^(baja(r)?|desciende|sube|subir|asciende|((desplazate|desliza|haz scroll|scroll) )?(hacia )?(abajo|arriba))( (un poco|mas|la pagina|una pantalla))?$", options: .regularExpression) != nil {
            return .shortcut(cmd.range(of: "sube|subir|asciende|arriba", options: .regularExpression) != nil ? "subir" : "bajar")
        }
        var destination = "actual"
        if let range = original.range(of: "\\s+(?:(?:en|en una|en la|en otra)\\s+)?(?:nueva (?:pestaña|ventana)|(?:pestaña|ventana) nueva|otra (?:pestaña|ventana))$", options: [.regularExpression, .caseInsensitive, .diacriticInsensitive]) {
            destination = normalize(String(original[range])).contains("ventana") ? "ventana" : "pestana"
            original = String(original[..<range.lowerBound])
        }
        if let query = tail("^(?:busca(?:r)?|búsqueda(?: de)?|(?:haz|realiza|ejecuta)(?: una)? búsqueda(?: de)?|encuentra|consulta|investiga)\\s+", in: original) {
            let normalized = normalize(query)
            for site in VoiceSite.catalog {
                for alias in site.aliases {
                    if normalized.hasSuffix(" en " + alias) { return .search(String(query.dropLast(alias.count + 4)), site.id, destination) }
                    if normalized.hasPrefix("en " + alias + " ") { return .search(String(query.dropFirst(alias.count + 4)), site.id, destination) }
                }
            }
            return .search(query, nil, destination)
        }
        if let target = tail("^(?:abre|abrir|ejecuta|ejecutar|inicia|iniciar|lanza|lanzar|muestra|mostrar|arranca|arrancar|entra a|entra en|ingresa a|ingresa en|ve a|ir a|visita|visitar)\\s+", in: original) {
            let cleaned = tail("^(?:la página(?: de)?|el sitio(?: de)?|la aplicación|la app|el programa|una ventana de|el|la|un|una)\\s+", in: target) ?? target
            return .open(cleaned, destination)
        }
        if let target = tail("^(?:cierra|cerrar|termina)\\s+", in: original) { return .closeApp(target) }
        return .unknown(original)
    }

    static func controlName(_ text: String) -> String {
        tail("^(?:(?:el|la|un|una)\\s+)?(?:botón|campo|elemento|opción|enlace)\\s+", in: text) ?? text
    }
    static func captures(_ pattern: String, in text: String) -> [String]? {
        var pattern = pattern
        for (letter, equivalent) in [("ñ", "[nñ]"), ("ó", "[oó]"), ("á", "[aá]")] { pattern = pattern.replacingOccurrences(of: letter, with: equivalent) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { index in Range(match.range(at: index), in: text).map { String(text[$0]) } ?? "" }
    }
    static func monitorTarget(_ text: String) -> (String, Int?) {
        let normalized = normalize(text)
        let ordinal = ["primer": 0, "primero": 0, "primera": 0, "uno": 0, "principal": 0, "segundo": 1, "segunda": 1, "dos": 1, "tercer": 2, "tercero": 2, "tercera": 2, "tres": 2, "cuarto": 3, "cuarta": 3, "cuatro": 3]
        let words = normalized.split(separator: " ").map(String.init)
        guard let en = words.lastIndex(of: "en") else { return (text, nil) }
        let suffix = words[(en + 1)...].filter { !["el", "la", "monitor", "pantalla", "escritorio"].contains($0) }
        guard words[(en + 1)...].contains(where: { ["monitor", "pantalla", "escritorio"].contains($0) }), suffix.count == 1, let value = suffix.first,
              let index = ordinal[value] ?? Int(value).flatMap({ $0 > 0 ? $0 - 1 : nil }) else { return (text, nil) }
        // Localizar sobre el original para conservar el nombre de la app.
        guard let range = text.range(of: "\\s+en\\s+[^\\n]+$", options: [.regularExpression, .caseInsensitive]) else { return (text, nil) }
        return (String(text[..<range.lowerBound]), index)
    }

    static let shortcuts: [String: String] = [
        "guardar": "guardar", "guarda": "guardar", "guardar como": "guardar_como", "guarda como": "guardar_como", "imprimir": "imprimir", "imprime": "imprimir", "cortar": "cortar", "corta": "cortar", "buscar en la pagina": "buscar_texto", "buscar en el documento": "buscar_texto", "minimiza ventana": "minimizar", "minimizar ventana": "minimizar", "pantalla completa": "pantalla_completa", "salir de pantalla completa": "pantalla_completa", "mission control": "mission_control", "mostrar escritorio": "escritorio", "muestra escritorio": "escritorio", "spotlight": "spotlight", "abre spotlight": "spotlight", "cambiar aplicacion": "cambiar_app", "siguiente aplicacion": "cambiar_app", "ocultar aplicacion": "ocultar_app", "escape": "escape", "escapar": "escape", "tabulador": "tabulador", "campo siguiente": "tabulador", "campo anterior": "tabulador_anterior", "barra de direcciones": "direccion", "selecciona todo": "seleccionar_todo",
        "nueva pestana": "nueva_pestana", "abre una pestana": "nueva_pestana", "abre nueva pestana": "nueva_pestana",
        "nueva ventana": "nueva_ventana", "abre una ventana": "nueva_ventana", "abre nueva ventana": "nueva_ventana",
        "cierra pestana": "cerrar_pestana", "cierra la pestana": "cerrar_pestana", "cerrar pestana": "cerrar_pestana", "cierra esta pestana": "cerrar_pestana",
        "cierra ventana": "cerrar_ventana", "cierra la ventana": "cerrar_ventana", "cerrar ventana": "cerrar_ventana",
        "atras": "atras", "volver": "atras", "vuelve": "atras", "regresa": "atras", "retrocede": "atras", "pagina anterior": "atras",
        "adelante": "adelante", "avanza": "adelante", "pagina siguiente": "adelante",
        "recarga": "recargar", "recargar": "recargar", "recarga la pagina": "recargar", "actualiza la pagina": "recargar", "refresca": "recargar",
        "siguiente pestana": "siguiente_pestana", "pestana siguiente": "siguiente_pestana", "anterior pestana": "anterior_pestana", "pestana anterior": "anterior_pestana",
        "aumenta zoom": "zoom_mas", "acerca": "zoom_mas", "amplia": "zoom_mas", "zoom mas": "zoom_mas",
        "reduce zoom": "zoom_menos", "aleja": "zoom_menos", "zoom menos": "zoom_menos", "restablece zoom": "zoom_normal", "zoom normal": "zoom_normal",
        "inicio": "inicio", "ve al inicio": "inicio", "final": "final", "ve al final": "final",
        "copia": "copiar", "copiar": "copiar", "copia esto": "copiar", "pega": "pegar", "pegar": "pegar", "pega esto": "pegar",
        "enter": "enter", "intro": "enter", "presiona enter": "enter", "pulsa enter": "enter", "enviar formulario": "enter",
        "deshacer": "deshacer", "rehacer": "rehacer", "seleccionar todo": "seleccionar_todo",
        "reproduce": "reproducir", "reproduce video": "reproducir", "continuar video": "reproducir", "pausa": "pausar", "pausa video": "pausar"
    ]
    static let kineticCommands: [String: String] = [
        "activar mouse cinetico": "activar", "activar cursor": "activar", "desactivar mouse cinetico": "desactivar", "desactivar cursor": "desactivar",
        "dar clic": "izquierdo", "da clic": "izquierdo", "dar click": "izquierdo", "haz click": "izquierdo",
        "dar anticlick": "derecho", "da anticlick": "derecho", "haz anticlick": "derecho", "anti click": "derecho", "dar clic derecho": "derecho", "dar click derecho": "derecho", "hacer clic derecho": "derecho", "presionar clic derecho": "derecho",
        "clic": "izquierdo", "click": "izquierdo", "haz clic": "izquierdo", "hacer clic": "izquierdo",
        "clic derecho": "derecho", "click derecho": "derecho", "anticlick": "derecho", "anticlic": "derecho", "menu contextual": "derecho", "haz clic derecho": "derecho", "haz click derecho": "derecho", "clic secundario": "derecho",
        "siguiente clic derecho": "preparar_derecho", "activar clic derecho": "preparar_derecho",
        "calibrar cursor": "calibrar", "recalibrar": "calibrar", "centrar cursor": "calibrar", "postura comoda": "calibrar", "acomodar postura": "calibrar",
        "pausar cursor": "pausar", "descansar": "pausar", "reanudar cursor": "reanudar", "continuar cursor": "reanudar", "cancelar clic": "cancelar",
        "control automatico": "automatico", "control cabeza": "cabeza", "control rostro": "cabeza", "control torso": "torso", "control manos": "manos",
        "control brazo izquierdo": "brazo_izquierdo", "control brazo derecho": "brazo_derecho", "control zona libre": "zona", "control munon": "zona",
        "ajustar temblor": "temblor", "activar temblor": "temblor", "desactivar temblor": "sin_temblor",
        "movimientos pequenos": "movimiento_reducido", "movilidad reducida": "movimiento_reducido", "movimientos normales": "movimiento_normal", "cursor mas lento": "lento", "cursor mas rapido": "rapido"
    ]
}

struct ChoicePrompt {
    let labels: [String]
    let expiresAt: Double
    static func ordinal(_ text: String) -> Int? {
        let value = CommandParser.normalize(text).replacingOccurrences(of: "^(?:(?:la|el|opcion|numero)\\s+)+", with: "", options: .regularExpression)
        let words = ["uno": 1, "una": 1, "primero": 1, "primera": 1, "dos": 2, "segundo": 2, "segunda": 2, "tres": 3, "tercero": 3, "tercera": 3, "cuatro": 4, "cuarto": 4, "cuarta": 4, "cinco": 5, "quinto": 5, "quinta": 5, "seis": 6, "sexto": 6, "sexta": 6]
        return words[value] ?? Int(value)
    }
    func index(_ answer: String, at time: Double) -> Int? {
        guard time < expiresAt else { return nil }
        let text = CommandParser.tail("^(?:elige|elegir|opción|opcion|número|numero)\\s+", in: answer) ?? answer
        if let number = Self.ordinal(text) { return number > 0 && number <= labels.count ? number - 1 : nil }
        return NameMatch.uniqueIndex(text, names: labels.map { [$0] })
    }
}

struct KeyChord: Equatable {
    let code: CGKeyCode
    let flags: CGEventFlags
    static func parse(_ text: String) -> KeyChord? {
        let words = CommandParser.normalize(text).replacingOccurrences(of: "+", with: " ").split(separator: " ").map(String.init).filter { !["mas", "tecla"].contains($0) }
        let modifiers: [String: CGEventFlags] = ["comando": .maskCommand, "command": .maskCommand, "cmd": .maskCommand, "control": .maskControl, "ctrl": .maskControl, "opcion": .maskAlternate, "option": .maskAlternate, "alt": .maskAlternate, "shift": .maskShift, "mayusculas": .maskShift]
        let keys: [String: CGKeyCode] = ["a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,"1":18,"2":19,"3":20,"4":21,"6":22,"5":23,"igual":24,"9":25,"7":26,"menos":27,"8":28,"0":29,"o":31,"u":32,"i":34,"p":35,"enter":36,"intro":36,"l":37,"j":38,"k":40,"n":45,"m":46,"tab":48,"tabulador":48,"espacio":49,"borrar":51,"retroceso":51,"escape":53,"esc":53,"f1":122,"f2":120,"f3":99,"f4":118,"f5":96,"f6":97,"f7":98,"f8":100,"f9":101,"f10":109,"f11":103,"f12":111,"izquierda":123,"derecha":124,"abajo":125,"arriba":126]
        var flags: CGEventFlags = [], code: CGKeyCode?
        guard !words.isEmpty, words.count <= 6 else { return nil }
        for word in words {
            if let modifier = modifiers[word] { flags.formUnion(modifier) }
            else if let key = keys[word], code == nil { code = key }
            else { return nil }
        }
        return code.map { KeyChord(code: $0, flags: flags) }
    }
}

struct VoiceSite {
    let id: String
    let aliases: [String]
    let home: String
    let search: String?
    static func match(_ name: String) -> VoiceSite? { catalog.first { $0.id == CommandParser.normalize(name) || $0.aliases.contains(CommandParser.normalize(name)) } }
    func url(query: String = "") -> URL? {
        guard !query.isEmpty else { return URL(string: home) }
        let value = id == "mercadolibre" ? query.split(whereSeparator: \.isWhitespace).joined(separator: "-") : query
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        if let search { return URL(string: search + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")) }
        let host = URL(string: home)?.host ?? ""
        return VoiceSite.match("google")?.url(query: query + " site:" + host)
    }
    static let catalog: [VoiceSite] = [
        VoiceSite(id: "google", aliases: ["google"], home: "https://www.google.com/", search: "https://www.google.com/search?q="),
        VoiceSite(id: "youtube", aliases: ["youtube", "you tube"], home: "https://www.youtube.com/", search: "https://www.youtube.com/results?search_query="),
        VoiceSite(id: "mercadolibre", aliases: ["mercado libre", "mercadolibre"], home: "https://www.mercadolibre.com.pe/", search: "https://listado.mercadolibre.com.pe/"),
        VoiceSite(id: "amazon", aliases: ["amazon"], home: "https://www.amazon.com/", search: "https://www.amazon.com/s?k="),
        VoiceSite(id: "wikipedia", aliases: ["wikipedia"], home: "https://es.wikipedia.org/", search: "https://es.wikipedia.org/wiki/Especial:Buscar?search="),
        VoiceSite(id: "facebook", aliases: ["facebook", "face book"], home: "https://www.facebook.com/", search: "https://www.facebook.com/search/top/?q="),
        VoiceSite(id: "instagram", aliases: ["instagram"], home: "https://www.instagram.com/", search: nil),
        VoiceSite(id: "x", aliases: ["x", "twitter", "equis"], home: "https://x.com/", search: "https://x.com/search?q="),
        VoiceSite(id: "reddit", aliases: ["reddit"], home: "https://www.reddit.com/", search: "https://www.reddit.com/search/?q="),
        VoiceSite(id: "netflix", aliases: ["netflix"], home: "https://www.netflix.com/", search: "https://www.netflix.com/search?q="),
        VoiceSite(id: "twitch", aliases: ["twitch"], home: "https://www.twitch.tv/", search: "https://www.twitch.tv/search?term="),
        VoiceSite(id: "github", aliases: ["github", "git hub"], home: "https://github.com/", search: "https://github.com/search?q="),
        VoiceSite(id: "chatgpt", aliases: ["chatgpt", "chat gpt"], home: "https://chatgpt.com/", search: nil),
        VoiceSite(id: "claude", aliases: ["claude"], home: "https://claude.ai/", search: nil),
        VoiceSite(id: "gemini", aliases: ["gemini"], home: "https://gemini.google.com/", search: nil),
        VoiceSite(id: "canvas", aliases: ["canvas"], home: "https://canvas.instructure.com/", search: nil),
        VoiceSite(id: "gmail", aliases: ["gmail", "g mail", "correo de google"], home: "https://mail.google.com/", search: nil),
        VoiceSite(id: "outlook", aliases: ["outlook", "hotmail"], home: "https://outlook.live.com/", search: nil),
        VoiceSite(id: "whatsapp", aliases: ["whatsapp", "whats app", "wasap"], home: "https://web.whatsapp.com/", search: nil),
        VoiceSite(id: "telegram", aliases: ["telegram"], home: "https://web.telegram.org/", search: nil),
        VoiceSite(id: "drive", aliases: ["drive", "google drive"], home: "https://drive.google.com/", search: nil),
        VoiceSite(id: "documentos", aliases: ["google docs", "documentos de google"], home: "https://docs.google.com/", search: nil),
        VoiceSite(id: "mapas", aliases: ["mapas", "maps", "google maps"], home: "https://www.google.com/maps/", search: "https://www.google.com/maps/search/?api=1&query="),
        VoiceSite(id: "linkedin", aliases: ["linkedin", "linked in"], home: "https://www.linkedin.com/", search: nil),
        VoiceSite(id: "tiktok", aliases: ["tiktok", "tik tok"], home: "https://www.tiktok.com/", search: nil),
        VoiceSite(id: "spotify", aliases: ["spotify"], home: "https://open.spotify.com/", search: nil),
        VoiceSite(id: "bing", aliases: ["bing"], home: "https://www.bing.com/", search: "https://www.bing.com/search?q="),
        VoiceSite(id: "duckduckgo", aliases: ["duckduckgo", "duck duck go"], home: "https://duckduckgo.com/", search: "https://duckduckgo.com/?q="),
    ]
}

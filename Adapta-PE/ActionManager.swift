import Foundation
import AppKit
import CoreGraphics
import AVFoundation

class ActionManager {
    static let shared = ActionManager()
    let synthesizer = AVSpeechSynthesizer()
    
    func hablar(_ texto: String) {
        DispatchQueue.main.async {
            print("🤖 Asistente: \(texto)")
            let utterance = AVSpeechUtterance(string: texto)
            utterance.voice = AVSpeechSynthesisVoice(language: "es-PE") ?? AVSpeechSynthesisVoice(language: "es-MX")
            utterance.rate = 0.5
            self.synthesizer.speak(utterance)
        }
    }
    
    func procesarIntencion(_ texto: String) {
        let cmd = texto.components(separatedBy: .punctuationCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "  ", with: " ")
        
        print("🧠 Procesando intención final: \(cmd)")
        
        // ----------------------------------------------------
        // 1. WEBS GLOBALES MÁS INTELIGENTES (Apertura Directa)
        // ----------------------------------------------------
        if (cmd.contains("mercadolibre") || cmd.contains("mercado libre")) && (cmd.contains("abre") || cmd.contains("ingresa") || cmd.contains("página")) {
            NSWorkspace.shared.open(URL(string: "https://www.mercadolibre.com.pe")!)
            hablar("Abriendo Mercado Libre")
            return
        }
        else if cmd.contains("youtube") && (cmd.contains("abre") || cmd.contains("ingresa") || cmd.contains("página")) {
            NSWorkspace.shared.open(URL(string: "https://www.youtube.com")!)
            hablar("Abriendo YouTube")
            return
        }
        else if cmd.contains("canvas") && (cmd.contains("abre") || cmd.contains("ingresa") || cmd.contains("página")) {
            NSWorkspace.shared.open(URL(string: "https://canvas.usil.edu.pe")!)
            hablar("Abriendo Canvas")
            return
        }
        else if cmd.contains("google") && (cmd.contains("abre") || cmd.contains("ingresa") || cmd.contains("página")) && !cmd.contains("busca") {
            NSWorkspace.shared.open(URL(string: "https://www.google.com")!)
            hablar("Abriendo Google")
            return
        }
        
        // ----------------------------------------------------
        // 2. NUEVAS PESTAÑAS Y APPS DEL SISTEMA
        // ----------------------------------------------------
        else if cmd.contains("nueva pestaña") || cmd.contains("abre una pestaña") {
            var navegador = "safari"
            if cmd.contains("chrome") { navegador = "google chrome" }
            nuevaPestana(navegador: navegador)
        }
        else if cmd.starts(with: "abre ") || cmd.starts(with: "abrir ") || cmd.starts(with: "ejecuta ") {
            let objetivo = extraerObjetivo(de: cmd, despuesDe: ["abre ", "abrir ", "ejecuta ", "inicia ", "la aplicación ", "una ventana de "])
            
            if cmd.contains("monitor") || cmd.contains("pantalla") || cmd.contains("escritorio") {
                var monitorIndex = 0
                if cmd.contains("2do") || cmd.contains("segundo") || cmd.contains("dos") { monitorIndex = 1 }
                else if cmd.contains("3er") || cmd.contains("tercer") || cmd.contains("tres") { monitorIndex = 2 }
                
                let appPura = extraerAppMultimonitor(objetivo)
                if !appPura.isEmpty {
                    abrirApp(nombre: appPura)
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.5) {
                        self.moverVentanaAMonitor(appName: appPura, monitorIndex: monitorIndex)
                    }
                }
            } else {
                if !objetivo.isEmpty { abrirApp(nombre: objetivo) }
            }
        }
        else if cmd.starts(with: "cierra ") || cmd.starts(with: "cerrar ") {
            let objetivo = extraerObjetivo(de: cmd, despuesDe: ["cierra ", "cerrar ", "termina ", "la aplicación "])
            if !objetivo.isEmpty { cerrarApp(nombre: objetivo) }
        }
        
        // ----------------------------------------------------
        // 3. BÚSQUEDA WEB INTELIGENTE (Filtrado exacto)
        // ----------------------------------------------------
        else if cmd.starts(with: "busca ") || cmd.starts(with: "buscar ") {
            let objetivo = extraerObjetivo(de: cmd, despuesDe: ["busca ", "buscar "])
            var sitio = "google"
            var queryLimpia = objetivo
            
            if objetivo.hasSuffix(" en youtube") {
                sitio = "youtube"
                queryLimpia = objetivo.replacingOccurrences(of: " en youtube", with: "").trimmingCharacters(in: .whitespaces)
            } else if objetivo.hasSuffix(" en mercado libre") || objetivo.hasSuffix(" en mercadolibre") {
                sitio = "mercadolibre"
                queryLimpia = objetivo.replacingOccurrences(of: " en mercado libre", with: "").replacingOccurrences(of: " en mercadolibre", with: "").trimmingCharacters(in: .whitespaces)
            } else if objetivo.hasSuffix(" en google") {
                sitio = "google"
                queryLimpia = objetivo.replacingOccurrences(of: " en google", with: "").trimmingCharacters(in: .whitespaces)
            }
            
            buscarWeb(query: queryLimpia, sitio: sitio)
        }
        
        // ----------------------------------------------------
        // 4. RATÓN Y ATAJOS
        // ----------------------------------------------------
        else if cmd.contains("anticlick") || cmd.contains("click derecho") { ejecutarClick(derecho: true) }
        else if cmd.contains("click") || cmd.contains("clic") || cmd.contains("selecciona") { ejecutarClick(derecho: false) }
        else if cmd.contains("baja") || cmd.contains("bajar") || cmd.contains("hacia abajo") { ejecutarAtajo("bajar") }
        else if cmd.contains("sube") || cmd.contains("subir") || cmd.contains("hacia arriba") { ejecutarAtajo("subir") }
        else if cmd.contains("presiona ") || cmd.contains("toca ") || cmd.contains("dale ") {
            if cmd.contains("enter") || cmd.contains("entrar") { ejecutarAtajo("enter") }
            else if cmd.contains("copiar") || cmd.contains("copia") { ejecutarAtajo("copiar") }
            else if cmd.contains("pegar") || cmd.contains("pega") { ejecutarAtajo("pegar") }
        }
        else if cmd == "copia" || cmd == "copiar" || cmd == "copia esto" { ejecutarAtajo("copiar") }
        else if cmd == "pega" || cmd == "pegar" || cmd == "pega esto" { ejecutarAtajo("pegar") }
        else if cmd.contains("ojo biónico") || cmd.contains("lee la pantalla") {
            leerPantalla()
        }
        
        // ----------------------------------------------------
        // 5. FALLBACK A IA (Charla Normal)
        // ----------------------------------------------------
        else {
            consultarIA(pregunta: cmd)
        }
    }
    
    // --- INTEGRACIÓN LLM (CHARLA NORMAL) ---
    private func consultarIA(pregunta: String) {
        let apiKey = UserDefaults.standard.string(forKey: "NvidiaAPIKey") ?? ""
        if apiKey.isEmpty {
            hablar("Perdón, no entendí tu comando. Por favor coloca tu API Key en la interfaz.")
            return
        }
        
        let url = URL(string: "https://integrate.api.nvidia.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let payload: [String: Any] = [
            // UTILIZAMOS EL MODELO QUE SÍ TIENE ACCESO TU API KEY (El mismo del ojo biónico)
            "model": "meta/llama-3.2-11b-vision-instruct",
            "messages": [
                ["role": "system", "content": "Eres el asistente del escritorio de la computadora Adapta PE. Responde de forma muy breve, natural, y útil. Cero asteriscos ni formatos markdown."],
                ["role": "user", "content": pregunta]
            ],
            "max_tokens": 150,
            "temperature": 0.5
        ]
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data, error == nil else {
                self.hablar("Error de red al conectar con el cerebro de Inteligencia Artificial.")
                return
            }
            
            // DEBUG: Imprime la respuesta real de NVIDIA en consola por si vuelve a fallar
            if let strData = String(data: data, encoding: .utf8) {
                print("📦 RESPUESTA NVIDIA NIM: \(strData)")
            }
            
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let text = message["content"] as? String {
                self.hablar(text)
            } else {
                self.hablar("Hubo un problema al procesar la respuesta. Revisa la consola.")
            }
        }.resume()
    }
    
    // --- LÓGICAS MULTIMONITOR Y NAVEGADORES ---
    private func nuevaPestana(navegador: String) {
        let app = navegador.lowercased().contains("chrome") ? "Google Chrome" : "Safari"
        let script: String
        
        if app == "Google Chrome" {
            script = """
            tell application "Google Chrome"
                if (count every window) = 0 then
                    make new window
                else
                    tell front window to make new tab at end of tabs
                end if
                activate
            end tell
            """
        } else {
            script = """
            tell application "Safari"
                if (count every document) = 0 then
                    make new document
                else
                    tell front window to make new tab at end of tabs
                end if
                activate
            end tell
            """
        }
        ejecutarAppleScript(script)
        hablar("Nueva pestaña abierta en \(app)")
    }
    
    private func moverVentanaAMonitor(appName: String, monitorIndex: Int) {
        let screens = NSScreen.screens
        guard screens.count > monitorIndex else { hablar("No detecto un monitor número \(monitorIndex + 1)"); return }
        
        let targetScreen = screens[monitorIndex]
        let frame = targetScreen.visibleFrame
        let nombreReal = appName.lowercased().contains("chrome") ? "Google Chrome" : appName.capitalized
        
        let script = """
        tell application "System Events"
            tell process "\(nombreReal)"
                set position of window 1 to {\(Int(frame.minX)), \(Int(frame.minY))}
            end tell
        end tell
        """
        ejecutarAppleScript(script)
        hablar("Movido al monitor \(monitorIndex + 1)")
    }
    
    private func ejecutarAppleScript(_ source: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            if let scriptObject = NSAppleScript(source: source) { scriptObject.executeAndReturnError(&error) }
        }
    }
    
    private func extraerAppMultimonitor(_ frase: String) -> String {
        var app = frase
        let basuras = ["en", "mi", "el", "la", "segundo", "tercer", "2do", "3er", "monitor", "pantalla", "escritorio"]
        for b in basuras { app = app.replacingOccurrences(of: b, with: "") }
        return app.trimmingCharacters(in: .whitespaces)
    }
    
    private func extraerObjetivo(de frase: String, despuesDe palabrasClave: [String]) -> String {
        var objetivo = frase
        for palabra in palabrasClave {
            if let range = objetivo.range(of: palabra) {
                objetivo = String(objetivo[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        let articulos = ["el ", "la ", "los ", "las ", "un ", "una "]
        for articulo in articulos {
            if objetivo.hasPrefix(articulo) { objetivo = String(objetivo.dropFirst(articulo.count)) }
        }
        return objetivo.trimmingCharacters(in: .whitespaces)
    }
    
    func ejecutarClick(derecho: Bool) {
        guard let currentEvent = CGEvent(source: nil) else { return }
        let loc = currentEvent.location
        let button: CGMouseButton = derecho ? .right : .left
        let typeDown: CGEventType = derecho ? .rightMouseDown : .leftMouseDown
        let typeUp: CGEventType = derecho ? .rightMouseUp : .leftMouseUp
        
        let md = CGEvent(mouseEventSource: nil, mouseType: typeDown, mouseCursorPosition: loc, mouseButton: button)
        let mu = CGEvent(mouseEventSource: nil, mouseType: typeUp, mouseCursorPosition: loc, mouseButton: button)
        md?.post(tap: .cghidEventTap); mu?.post(tap: .cghidEventTap)
        hablar(derecho ? "Anticlick" : "Click")
    }
    
    func abrirApp(nombre: String) {
        let nombreReal = nombre.lowercased().contains("chrome") ? "Google Chrome" : nombre
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.launchPath = "/usr/bin/mdfind"
            task.arguments = ["kMDItemContentType == 'com.apple.application-bundle' && kMDItemFSName == '*\(nombreReal)*'cd"]
            let pipe = Pipe()
            task.standardOutput = pipe
            try? task.run()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                if let rutaApp = output.split(separator: "\n").first {
                    let url = URL(fileURLWithPath: String(rutaApp))
                    DispatchQueue.main.async {
                        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                            if error == nil { self.hablar("Abriendo \(nombreReal)") }
                        }
                    }
                    return
                }
            }
            self.hablar("No encontré la aplicación \(nombreReal)")
        }
    }
    
    func cerrarApp(nombre: String) {
        let nombreReal = nombre.lowercased().contains("chrome") ? "Google Chrome" : nombre
        DispatchQueue.global(qos: .userInitiated).async {
            let apps = NSWorkspace.shared.runningApplications
            var cerrada = false
            for app in apps {
                if let appName = app.localizedName, appName.lowercased().contains(nombreReal.lowercased()) {
                    app.terminate()
                    cerrada = true
                }
            }
            self.hablar(cerrada ? "Cerrando \(nombreReal)" : "No encontré \(nombreReal) ejecutándose")
        }
    }
    
    func buscarWeb(query: String, sitio: String) {
        let cleanQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        var urlString = "https://www.google.com/search?q=\(cleanQuery)"
        if sitio == "youtube" { urlString = "https://www.youtube.com/results?search_query=\(cleanQuery)" }
        else if sitio == "mercadolibre" { urlString = "https://listado.mercadolibre.com.pe/\(cleanQuery.replacingOccurrences(of: " ", with: "-"))" }
        
        if let url = URL(string: urlString) {
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            hablar("Buscando \(query.isEmpty ? sitio : query)")
        }
    }
    
    func ejecutarAtajo(_ accion: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        switch accion {
        case "copiar": simularTeclado(keyCode: 8, flags: .maskCommand, source: source); hablar("Copiado")
        case "pegar": simularTeclado(keyCode: 9, flags: .maskCommand, source: source); hablar("Pegado")
        case "enter": simularTeclado(keyCode: 36, flags: [], source: source)
        case "bajar": let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -15, wheel2: 0, wheel3: 0); scroll?.post(tap: .cghidEventTap)
        case "subir": let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 15, wheel2: 0, wheel3: 0); scroll?.post(tap: .cghidEventTap)
        default: break
        }
    }
    
    private func simularTeclado(keyCode: CGKeyCode, flags: CGEventFlags, source: CGEventSource?) {
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = flags; down?.post(tap: .cghidEventTap)
        up?.flags = flags; up?.post(tap: .cghidEventTap)
    }

    // --- INTEGRACIÓN LLM (VISIÓN DE PANTALLA) ---
    func leerPantalla() {
        let apiKey = UserDefaults.standard.string(forKey: "NvidiaAPIKey") ?? ""
        if apiKey.isEmpty { hablar("Falta configurar tu clave de API en la interfaz."); return }
        hablar("Analizando pantalla...")
        guard let image = CGDisplayCreateImage(CGMainDisplayID()) else { return }
        let bitmapRep = NSBitmapImageRep(cgImage: image)
        guard let imageData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.5]) else { return }
        
        enviarAlLLM(base64Image: imageData.base64EncodedString(), apiKey: apiKey)
    }
    
    private func enviarAlLLM(base64Image: String, apiKey: String) {
        let url = URL(string: "https://integrate.api.nvidia.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let payload: [String: Any] = [
            "model": "meta/llama-3.2-11b-vision-instruct",
            "messages": [["role": "user", "content": "Describe brevemente qué hay en la pantalla y qué puedo seleccionar. <img src=\"data:image/jpeg;base64,\(base64Image)\" />"]],
            "max_tokens": 250, "temperature": 0.3
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data, error == nil else { self.hablar("Error de conexión."); return }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let text = message["content"] as? String {
                self.hablar(text)
            } else { self.hablar("Error al interpretar la imagen.") }
        }.resume()
    }
}

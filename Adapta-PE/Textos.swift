import Foundation
import Combine

/// Textos neutros y compartibles entre Adapta-PE (macOS Base) y Adapta-PE-Lite.
/// Carga primero las claves del catálogo `nativo-v1.json` (voz, páginas, mascota)
/// y añade las claves propias de la interfaz de escritorio en los 6 idiomas:
/// español (es), inglés (en), portugués (pt), alemán (de), francés (fr) e italiano (it).
/// Una sola preferencia (`VoiceLanguage`) gobierna la voz y la interfaz.
/// Si falta una clave en el idioma activo, cae automáticamente al español.
public final class Textos: ObservableObject {
    public static let shared = Textos()

    public static let supportedLanguages = ["es", "en", "pt", "de", "fr", "it"]

    @Published public private(set) var currentLanguage: String = "es"

    private let lock = NSLock()

    // [idioma: [clave: texto]]
    private var diccionarios: [String: [String: String]] = [
        "es": [:], "en": [:], "pt": [:], "de": [:], "fr": [:], "it": [:]
    ]

    private init() {
        cargarCatalogo()
        definirPropios()
        actualizarIdioma()

        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.actualizarIdioma()
        }
    }

    // MARK: - Carga de catálogo nativo-v1.json
    public func cargarCatalogo() {
        let data: Data? = {
            if let url = VoiceCatalog.resource("nativo-v1"), let d = try? Data(contentsOf: url) { return d }
            for path in ["Adapta-PE/nativo-v1.json", "nativo-v1.json", "../Adapta-PE/nativo-v1.json"] {
                if let d = try? Data(contentsOf: URL(fileURLWithPath: path)) { return d }
            }
            return nil
        }()

        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let textosRoot = root["textos"] as? [String: Any] else {
            return
        }

        lock.lock()
        defer { lock.unlock() }
        for categoria in ["voz", "paginas", "mascota"] {
            guard let catDict = textosRoot[categoria] as? [String: [String: String]] else { continue }
            for (lang, claves) in catDict {
                let base = String(lang.prefix(2)).lowercased()
                if Self.supportedLanguages.contains(base) {
                    diccionarios[base, default: [:]].merge(claves) { (_, new) in new }
                }
            }
        }
    }

    // MARK: - Registro de textos propios
    public func definir(_ textosPorIdioma: [String: [String: String]]) {
        lock.lock()
        defer { lock.unlock() }
        for (lang, claves) in textosPorIdioma {
            let base = String(lang.prefix(2)).lowercased()
            if Self.supportedLanguages.contains(base) {
                diccionarios[base, default: [:]].merge(claves) { (_, new) in new }
            }
        }
    }

    // MARK: - Traducción
    public func t(_ clave: String, _ variables: [String: String] = [:], idioma: String? = nil) -> String {
        let lang: String
        if let idioma {
            let base = String(idioma.prefix(2)).lowercased()
            lang = Self.supportedLanguages.contains(base) ? base : currentLanguage
        } else {
            lang = currentLanguage
        }

        lock.lock()
        let plantilla = diccionarios[lang]?[clave] ?? diccionarios["es"]?[clave] ?? clave
        lock.unlock()

        if variables.isEmpty { return plantilla }
        return variables.reduce(plantilla) { acc, pair in
            acc.replacingOccurrences(of: "{\(pair.key)}", with: pair.value)
        }
    }

    public static func t(_ clave: String, _ variables: [String: String] = [:], idioma: String? = nil) -> String {
        Textos.shared.t(clave, variables, idioma: idioma)
    }

    // MARK: - Idioma y preferencia
    public func fijarIdioma(_ preferencia: String) {
        let base = resolverBase(preferencia: preferencia)
        if currentLanguage != base {
            if Thread.isMainThread {
                currentLanguage = base
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.currentLanguage = base
                }
            }
        }
    }

    public func actualizarIdioma() {
        let pref = UserDefaults.standard.string(forKey: "VoiceLanguage") ?? "auto"
        fijarIdioma(pref)
    }

    private func resolverBase(preferencia: String) -> String {
        if preferencia != "auto" {
            let base = String(preferencia.prefix(2)).lowercased()
            if Self.supportedLanguages.contains(base) { return base }
        }
        for code in Locale.preferredLanguages {
            let base = String(code.prefix(2)).lowercased()
            if Self.supportedLanguages.contains(base) { return base }
        }
        return "es"
    }

    // MARK: - Inspección para pruebas
    public func todasLasClaves() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        var claves = Set<String>()
        for (_, dict) in diccionarios {
            claves.formUnion(dict.keys)
        }
        return claves
    }

    public func claveDirecta(_ clave: String, idioma: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let base = String(idioma.prefix(2)).lowercased()
        return diccionarios[base]?[clave]
    }

    public func totalClaves(idioma: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let base = String(idioma.prefix(2)).lowercased()
        return diccionarios[base]?.count ?? 0
    }

    // MARK: - Claves propias de escritorio (6 idiomas)
    private func definirPropios() {
        definir([
            "es": [
                // Aplicación y cabecera
                "app.titulo": "Adapta PE",
                "app.subtitulo": "Tu escritorio, a tu ritmo",
                "app.usarPanel": "Usar panel",
                "app.ajustes": "Ajustes de AdaptaPE",
                "app.bienvenida": "Bienvenida a Adapta PE",
                "app.bienvenidaDesc": "Aprende a usar el asistente paso a paso con ejercicios prácticos.",

                // Menú de barra y ventanas
                "menu.ajustes": "Ajustes…",
                "menu.tutorial": "Tutorial…",
                "menu.detenerTodo": "Detener todo",
                "menu.salir": "Salir de AdaptaPE",
                "menu.opciones": "Opciones",
                "menu.abrirAjustes": "Abrir ajustes",

                // Secciones
                "seccion.control": "Control",
                "seccion.lectura": "Lectura y filtros",
                "seccion.mascota": "Mascota",
                "seccion.ia": "IA opcional",
                "seccion.ayuda": "Ayuda",

                // Controles principales
                "control.activaLoQueNecesitas": "Activa lo que necesitas",
                "control.calibrar": "Calibrar",
                "control.pausarCursor": "Pausar cursor",
                "control.reanudarCursor": "Reanudar cursor",
                "control.velocidad": "Velocidad",
                "control.reducirTemblores": "Reducir temblores",
                "control.movimientosPequenos": "Adaptar a movimientos pequeños",
                "control.esperaClic": "Espera de clic",
                "control.camara": "Cámara",
                "control.sinCamara": "Sin cámara",
                "control.microfono": "Micrófono",
                "control.sinMicrofono": "Sin micrófono",
                "control.sinAlias": "Sin alias de pronunciación",
                "control.quitarAlias": "Quitar alias",
                "control.escala": "Tamaño de controles",
                "control.ayudaEscala": "Ajusta la escala del panel flotante y los controles (100 %, 125 % o 150 %).",
                "control.reconocimientoRed": "Permitir reconocimiento de Apple por red",
                "control.ayudaReconocimientoRed": "Apagado: reconocimiento local. Encendido: Apple puede procesar audio por red; no activa IA generativa.",
                "control.iniciarAlEncender": "Iniciar al encender el Mac",
                "control.ayudaIniciarAlEncender": "Recuerda tus módulos y ajustes. Detener todo conserva los ajustes y apaga la asistencia hasta que la actives de nuevo.",
                "control.pantallasDisponibles": "Pantallas disponibles",
                "control.actualizarDispositivos": "Actualizar dispositivos y permisos",
                "control.cerrarVentanaAviso": "Cerrar esta ventana mantiene la asistencia activa.",
                "control.moverMascotaYPanel": "Mover mascota y panel juntos",
                "control.elegirMascota": "Elegir mascota",
                "control.mostrarCamara": "Mostrar cámara",
                "control.filtroPantalla": "Filtro de pantalla",
                "control.apagados": "Voz y cursor apagados",
                "control.aquiVeras": "Aquí verás lo que escuché",
                "control.confirmarExacto": "Para confirmar, di exactamente:",
                "control.cancelarConfirmacion": "Cancelar confirmación",
                "control.eligeEn": "Elige en {contexto}",
                "control.siguiente": "Siguiente",
                "control.cancelar": "Cancelar",
                "control.cerrar": "Cerrar",
                "control.anterior": "Anterior",
                "control.finalizar": "Finalizar",
                "control.probar": "Probar",
                "control.guardar": "Guardar",

                // Permisos nativos
                "permisos.controlEscritorio": "Permitir control del escritorio",
                "permisos.ayudaAccesibilidad": "Accesibilidad permite mover, pulsar y leer elementos. Sólo se solicita al activar esas funciones.",
                "permisos.revisarMicro": "Revisar permiso del micrófono",
                "permisos.revisarVoz": "Revisar permiso de reconocimiento de voz",
                "permisos.revisarCamara": "Revisar permiso de la cámara",
                "permisos.revisarPantalla": "Revisar permiso de grabación de pantalla",

                // Cámara y HUD
                "camara.preparando": "Preparando cámara",
                "camara.apagada": "Cámara apagada",
                "camara.guiaColores": "Verde: zona segura · Blanco: movimiento",
                "camara.progresoDwell": "Progreso del clic por permanencia",

                // Lectura y filtros
                "lectura.leerVentana": "Leer ventana activa",
                "lectura.detener": "Detener lectura",
                "filtro.preparando": "Preparando filtro…",
                "filtro.visionNormal": "Normal",
                "filtro.grupoRojoVerde": "Rojo-verde",
                "filtro.grupoAzulAmarillo": "Azul-amarillo",
                "filtro.grupoGrises": "Escala de grises",

                // Mascota
                "mascota.saludar": "Saludar",
                "mascota.dormir": "Dormir",
                "mascota.despertar": "Despertar",
                "mascota.moverTeclas": "Mover con teclas",
                "mascota.otroMonitor": "Otro monitor",
                "mascota.estadoFeliz": "feliz",
                "mascota.estadoConfundida": "confundida",

                // IA Opcional
                "ia.titulo": "Tu API, sólo si la eliges",
                "ia.descripcion": "Todos los comandos, el cursor y TalkBack funcionan sin IA generativa. No se incluye un modelo local ni una suscripción.",
                "ia.activar": "Activar IA con mi API key",
                "ia.guardar": "Guardar en Llavero",
                "ia.eliminar": "Eliminar clave",
                "ia.cancelar": "Cancelar consulta",
                "ia.permitirPantalla": "Permitir envío de pantalla al proveedor",

                // Tutorial nativo
                "tutorial.pasosTitulo": "1. Asistente de permisos y voz",
                "tutorial.requierePermisos": "Para que Adapta PE funcione correctamente, necesita autorizaciones del sistema:",
                "tutorial.microPermiso": "Micrófono: para escuchar tus órdenes de voz.",
                "tutorial.reconocimientoPermiso": "Reconocimiento de voz: procesa tu voz en el Mac.",
                "tutorial.accesibilidadPermiso": "Accesibilidad: para interactuar con botones, ventanas y menús.",
                "tutorial.grabacionPermiso": "Grabación de pantalla: necesaria para los filtros de daltonismo. Requiere reiniciar la app.",
                "tutorial.camaraPermiso": "Cámara: exclusiva de Adapta PE Base para el control cinético.",
                "tutorial.probarNombreExito": "¡Funciona! Nombre reconocido correctamente.",
                "tutorial.probarNombreFallo": "No se reconoció el nombre. Inténtalo otra vez.",

                // Menú y ventanas adicionales
                "menu.detenerModulos": "Detener todos los módulos",
                "menu.mostrarFlotante": "Mostrar panel flotante",
                "menu.ocultarFlotante": "Ocultar panel flotante",
                "menu.activarCursor": "Activar cursor",
                "menu.apagarCursor": "Apagar cursor",
                "menu.activarVoz": "Activar voz",
                "menu.apagarVoz": "Apagar voz",
                "menu.pausarCursor": "Pausar cursor",
                "menu.reanudarCursor": "Reanudar cursor",
                "panel.superiorIzquierda": "Superior izquierda",
                "panel.superiorDerecha": "Superior derecha",
                "panel.inferiorIzquierda": "Inferior izquierda",
                "panel.inferiorDerecha": "Inferior derecha",
                "panel.tituloVentana": "Adapta PE · panel",
                "tutorial.tituloVentana": "Tutorial de Adapta PE",
                "panel.soloUnaPantalla": "Sólo hay una pantalla conectada",

                // Ajustes y controles adicionales
                "control.voz": "Voz",
                "control.cursor": "Cursor",
                "control.cursorCamara": "Cursor con cámara",
                "control.controlCon": "Control con",
                "control.modoCabeza": "Cabeza / torso",
                "control.modoManos": "Brazos, manos o puños",
                "control.modoZona": "Zona con textura",
                "control.modoDesc": "Cabeza aprende tu reposo. Para manos o textura, desplaza un poco la zona visible y mantén el gesto; volver al inicio detiene el cursor.",
                "control.clicMantener": "Clic al mantener la postura",
                "control.ayudaOrdenesVoz": "«Cursor más lento», «calibrar cursor» y «clic derecho» también funcionan por voz.",
                "control.adaptarMovimiento": "Adaptar a mi movimiento",
                "control.dispositivosYPreferencias": "Dispositivos y preferencias",
                "control.nombreAsistente": "Nombre para llamar al asistente",
                "control.guardarNombre": "Guardar nombre",
                "control.restaurarComputadora": "Restaurar Computadora",
                "control.probarNombre": "Probar nombre",
                "control.anadirAlias": "Añadir como alias",
                "control.responderComputadora": "Responder también a «Computadora»",
                "control.modoConversacion": "Modo conversación: 8 s más tras cada orden cumplida",
                "control.cerrarConversacionAyuda": "Di «gracias», «listo» o «silencio» para cerrarla; el micrófono sigue activo.",
                "control.idiomaVoz": "Idioma de voz",
                "control.idiomaAuto": "Automático (sistema)",
                "control.tiempoOrdenAyuda": "Si dices sólo el nombre, tienes 8 segundos para dar la orden.",
                "filtro.soloUno": "Sólo un filtro a la vez",
                "filtro.quitarFiltro": "Quitar filtro",
                "lectura.titulo": "Lectura y color",
                "lectura.leerBajoCursor": "Leer en voz alta el elemento bajo el cursor",
                "lectura.ayudaCursor": "Mantén el cursor sobre un elemento para escucharlo. Funciona con el ratón y con la cámara.",
                "ayuda.tutorialPractico": "Tutorial práctico",
                "ayuda.accionesApp": "Acciones de la app activa",
                "ayuda.buscarCampos": "Buscar campos de texto",
                "tutorial.bienvenida": "Bienvenida a Adapta PE",
                "tutorial.aprendePasoPaso": "Aprende a usar el asistente paso a paso con ejercicios prácticos.",
                "tutorial.actualizarPermisos": "Actualizar permisos",
                "tutorial.vozActiva": "Voz activa ✅",
                "tutorial.activarVoz": "Activar control por voz",
                "tutorial.revisar": "Revisar",
                "tutorial.autorizado": "Autorizado",
                "tutorial.pasoCompletado": "Paso completado",
                "tutorial.comenzar": "Comenzar a usar Adapta PE",
                "tutorial.ejecutarClic": "Ejecutar clic",
                "tutorial.clicExito": "¡Clic ejecutado con éxito!",
                "tutorial.hecho": "Hecho",

                "control.instruccionVoz": "Di «{palabra}, abre Zoom» o «pausar cursor». Puedes cerrar los ajustes y seguir usando la voz.",
                "control.ejemploSafari": "Prueba «{palabra}, por favor abre Safari» o «{palabra}, quiero que abras Safari». Para dictar, di «escribe» y tu texto; las palabras siguientes se conservan.",
                "control.aliasPrefijo": "Alias",
                "ayuda.explicacionComandos": "Di «abre nueva ventana de Chrome», «presiona comando shift N» o «escribe Hola en el campo Nombre». Si hay varias opciones, responde «la segunda», di su nombre o «cancelar». Las opciones caducan a los 45 segundos; «siguiente» muestra más.",
                "ayuda.pasosPostura": "1. Autoriza Accesibilidad.\n2. Elige cámara y control.\n3. Activa el cursor y mantén la postura al calibrar.\n4. Activa voz y prueba un comando.\n5. Usa el panel flotante o cierra ajustes.",
                "ayuda.listaComandos": "«Abre YouTube»\n«Busca movilidad en Wikipedia»\n«Escribe Hola, José»\n«Selecciona Contacto» / «Pulsa lo seleccionado»\n«Enfoca buscar» / «Enter»\n«Nueva pestaña» / «Atrás» / «Recarga»\n«Control cabeza» / «Control manos»\n«Calibrar cursor» / «Pausar cursor»\n«Siguiente clic derecho»\n«Activar TalkBack» / «Lee la pantalla»\n«Filtro deuteranopía» / «Quitar filtro»\n«Abre Safari en el segundo monitor»\n«Mostrar ajustes» / «Detener todo»",
                "ayuda.notaAccesibilidad": "La lectura y selección dependen de los elementos accesibles que expone cada aplicación. Campos protegidos no se leen ni se dictan. Zona libre rastrea textura; una oclusión puede exigir recalibrar.",
                "ayuda.permisoAccesibilidad": "Accesibilidad",
                "ayuda.permisoCamaraMicro": "Cámara y micrófono",
                "ayuda.permisoGrabacion": "Grabación de pantalla",
                "panel.opcionesAcc": "Opciones del panel",
                "ia.endpoint": "Endpoint HTTPS de chat/completions",
                "ia.modelo": "Modelo disponible en tu proveedor",
                "ia.apiKey": "API key personal"
            ],

            "en": [
                // Application and header
                "app.titulo": "Adapta PE",
                "app.subtitulo": "Your desktop, at your pace",
                "app.usarPanel": "Use panel",
                "app.ajustes": "AdaptaPE Settings",
                "app.bienvenida": "Welcome to Adapta PE",
                "app.bienvenidaDesc": "Learn to use the assistant step by step with practical exercises.",

                // Menu bar and windows
                "menu.ajustes": "Settings…",
                "menu.tutorial": "Tutorial…",
                "menu.detenerTodo": "Stop all",
                "menu.salir": "Quit AdaptaPE",
                "menu.opciones": "Options",
                "menu.abrirAjustes": "Open settings",

                // Sections
                "seccion.control": "Control",
                "seccion.lectura": "Reading and filters",
                "seccion.mascota": "Pet",
                "seccion.ia": "Optional AI",
                "seccion.ayuda": "Help",

                // Main controls
                "control.activaLoQueNecesitas": "Turn on what you need",
                "control.calibrar": "Calibrate",
                "control.pausarCursor": "Pause cursor",
                "control.reanudarCursor": "Resume cursor",
                "control.velocidad": "Speed",
                "control.reducirTemblores": "Reduce tremors",
                "control.movimientosPequenos": "Adapt to small movements",
                "control.esperaClic": "Click wait time",
                "control.camara": "Camera",
                "control.sinCamara": "No camera",
                "control.microfono": "Microphone",
                "control.sinMicrofono": "No microphone",
                "control.sinAlias": "No pronunciation aliases",
                "control.quitarAlias": "Remove aliases",
                "control.escala": "Control size",
                "control.ayudaEscala": "Adjusts the scale of the floating panel and controls (100%, 125% or 150%).",
                "control.reconocimientoRed": "Allow Apple network recognition",
                "control.ayudaReconocimientoRed": "Off: local recognition. On: Apple may process audio over the network; does not activate generative AI.",
                "control.iniciarAlEncender": "Launch at Mac startup",
                "control.ayudaIniciarAlEncender": "Remembers your modules and settings. Stop all preserves settings and suspends assistance until turned on again.",
                "control.pantallasDisponibles": "Available displays",
                "control.actualizarDispositivos": "Refresh devices and permissions",
                "control.cerrarVentanaAviso": "Closing this window keeps assistance active.",
                "control.moverMascotaYPanel": "Move pet and panel together",
                "control.elegirMascota": "Choose pet",
                "control.mostrarCamara": "Show camera",
                "control.filtroPantalla": "Screen filter",
                "control.apagados": "Voice and cursor off",
                "control.aquiVeras": "Here you will see what I heard",
                "control.confirmarExacto": "To confirm, say exactly:",
                "control.cancelarConfirmacion": "Cancel confirmation",
                "control.eligeEn": "Choose in {contexto}",
                "control.siguiente": "Next",
                "control.cancelar": "Cancel",
                "control.cerrar": "Close",
                "control.anterior": "Previous",
                "control.finalizar": "Finish",
                "control.probar": "Test",
                "control.guardar": "Save",

                // Native permissions
                "permisos.controlEscritorio": "Allow desktop control",
                "permisos.ayudaAccesibilidad": "Accessibility allows moving, clicking and reading elements. Only requested when turning on those features.",
                "permisos.revisarMicro": "Check microphone permission",
                "permisos.revisarVoz": "Check speech recognition permission",
                "permisos.revisarCamara": "Check camera permission",
                "permisos.revisarPantalla": "Check screen recording permission",

                // Camera and HUD
                "camara.preparando": "Setting up camera",
                "camara.apagada": "Camera off",
                "camara.guiaColores": "Green: safe zone · White: motion",
                "camara.progresoDwell": "Dwell click progress",

                // Reading and filters
                "lectura.leerVentana": "Read active window",
                "lectura.detener": "Stop reading",
                "filtro.preparando": "Preparing filter…",
                "filtro.visionNormal": "Normal",
                "filtro.grupoRojoVerde": "Red-green",
                "filtro.grupoAzulAmarillo": "Blue-yellow",
                "filtro.grupoGrises": "Grayscale",

                // Pet
                "mascota.saludar": "Wave",
                "mascota.dormir": "Sleep",
                "mascota.despertar": "Wake",
                "mascota.moverTeclas": "Move with keys",
                "mascota.otroMonitor": "Next display",
                "mascota.estadoFeliz": "happy",
                "mascota.estadoConfundida": "confused",

                // Optional AI
                "ia.titulo": "Your API, only if you choose",
                "ia.descripcion": "All commands, cursor and TalkBack work without generative AI. No local model or subscription included.",
                "ia.activar": "Enable AI with my API key",
                "ia.guardar": "Save to Keychain",
                "ia.eliminar": "Delete key",
                "ia.cancelar": "Cancel request",
                "ia.permitirPantalla": "Allow sending screen to provider",

                // Native tutorial
                "tutorial.pasosTitulo": "1. Permissions and voice setup",
                "tutorial.requierePermisos": "For Adapta PE to work properly, it needs system authorizations:",
                "tutorial.microPermiso": "Microphone: to hear your voice commands.",
                "tutorial.reconocimientoPermiso": "Speech recognition: processes your voice on the Mac.",
                "tutorial.accesibilidadPermiso": "Accessibility: to interact with buttons, windows and menus.",
                "tutorial.grabacionPermiso": "Screen recording: required for color blindness filters. Requires app restart.",
                "tutorial.camaraPermiso": "Camera: exclusive to Adapta PE Base for kinetic cursor control.",
                "tutorial.probarNombreExito": "It works! Name recognized successfully.",
                "tutorial.probarNombreFallo": "Name not recognized. Please try again.",

                // Additional menu and windows
                "menu.detenerModulos": "Stop all modules",
                "menu.mostrarFlotante": "Show floating panel",
                "menu.ocultarFlotante": "Hide floating panel",
                "menu.activarCursor": "Start cursor",
                "menu.apagarCursor": "Stop cursor",
                "menu.activarVoz": "Start voice",
                "menu.apagarVoz": "Stop voice",
                "menu.pausarCursor": "Pause cursor",
                "menu.reanudarCursor": "Resume cursor",
                "panel.superiorIzquierda": "Top left",
                "panel.superiorDerecha": "Top right",
                "panel.inferiorIzquierda": "Bottom left",
                "panel.inferiorDerecha": "Bottom right",
                "panel.tituloVentana": "Adapta PE · panel",
                "tutorial.tituloVentana": "Adapta PE Tutorial",
                "panel.soloUnaPantalla": "Only one screen is connected",

                // Additional settings and controls
                "control.voz": "Voice",
                "control.cursor": "Cursor",
                "control.cursorCamara": "Camera cursor",
                "control.controlCon": "Control with",
                "control.modoCabeza": "Head / torso",
                "control.modoManos": "Arms, hands or fists",
                "control.modoZona": "Textured area",
                "control.modoDesc": "Head learns your rest posture. For hands or texture, shift the area and hold; returning to rest stops the cursor.",
                "control.clicMantener": "Dwell click on hold",
                "control.ayudaOrdenesVoz": "“Slower cursor”, “calibrate cursor” and “right click” also work by voice.",
                "control.adaptarMovimiento": "Adapt to my movement",
                "control.dispositivosYPreferencias": "Devices and preferences",
                "control.nombreAsistente": "Name to call the assistant",
                "control.guardarNombre": "Save name",
                "control.restaurarComputadora": "Restore Computer",
                "control.probarNombre": "Test name",
                "control.anadirAlias": "Add as alias",
                "control.responderComputadora": "Also respond to “Computer”",
                "control.modoConversacion": "Conversation mode: 8s after each completed order",
                "control.cerrarConversacionAyuda": "Say “thanks”, “done” or “silence” to close; microphone remains active.",
                "control.idiomaVoz": "Voice language",
                "control.idiomaAuto": "Automatic (system)",
                "control.tiempoOrdenAyuda": "If you say only the name, you have 8 seconds to give the command.",
                "filtro.soloUno": "Only one filter at a time",
                "filtro.quitarFiltro": "Remove filter",
                "lectura.titulo": "Reading and color",
                "lectura.leerBajoCursor": "Read aloud element under cursor",
                "lectura.ayudaCursor": "Hold cursor over an element to hear it. Works with mouse and camera.",
                "ayuda.tutorialPractico": "Practical tutorial",
                "ayuda.accionesApp": "Active app actions",
                "ayuda.buscarCampos": "Find text fields",
                "tutorial.bienvenida": "Welcome to Adapta PE",
                "tutorial.aprendePasoPaso": "Learn to use the assistant step by step with practical exercises.",
                "tutorial.actualizarPermisos": "Refresh permissions",
                "tutorial.vozActiva": "Voice active ✅",
                "tutorial.activarVoz": "Activate voice control",
                "tutorial.revisar": "Review",
                "tutorial.autorizado": "Authorized",
                "tutorial.pasoCompletado": "Step completed",
                "tutorial.comenzar": "Start using Adapta PE",
                "tutorial.ejecutarClic": "Execute click",
                "tutorial.clicExito": "Click executed successfully!",
                "tutorial.hecho": "Done",

                "control.instruccionVoz": "Say “{palabra}, open Zoom” or “pause cursor”. You can close settings and continue using voice.",
                "control.ejemploSafari": "Try “{palabra}, please open Safari” or “{palabra}, I want you to open Safari”. To dictate, say “type” and your text; subsequent words are preserved.",
                "control.aliasPrefijo": "Aliases",
                "ayuda.explicacionComandos": "Say “open new Chrome window”, “press command shift N” or “type Hello in field Name”. If multiple options, say “the second”, its name or “cancel”. Options expire after 45 seconds; “next” shows more.",
                "ayuda.pasosPostura": "1. Authorize Accessibility.\n2. Choose camera and control.\n3. Activate cursor and hold posture when calibrating.\n4. Activate voice and test a command.\n5. Use floating panel or close settings.",
                "ayuda.listaComandos": "“Open YouTube”\n“Search mobility on Wikipedia”\n“Type Hello, Jose”\n“Select Contact” / “Click selected”\n“Focus search” / “Enter”\n“New tab” / “Back” / “Reload”\n“Head control” / “Hand control”\n“Calibrate cursor” / “Pause cursor”\n“Next right click”\n“Activate TalkBack” / “Read screen”\n“Deuteranopia filter” / “Remove filter”\n“Open Safari on second monitor”\n“Show settings” / “Stop all”",
                "ayuda.notaAccesibilidad": "Reading and selection depend on accessible elements exposed by each application. Protected fields are not read or dictated. Free zone tracks texture; occlusion may require recalibrating.",
                "ayuda.permisoAccesibilidad": "Accessibility",
                "ayuda.permisoCamaraMicro": "Camera and microphone",
                "ayuda.permisoGrabacion": "Screen recording",
                "panel.opcionesAcc": "Panel options",
                "ia.endpoint": "HTTPS chat/completions endpoint",
                "ia.modelo": "Model available at your provider",
                "ia.apiKey": "Personal API key"
            ],

            "pt": [
                // Aplicativo e cabeçalho
                "app.titulo": "Adapta PE",
                "app.subtitulo": "Sua área de trabalho, no seu ritmo",
                "app.usarPanel": "Usar painel",
                "app.ajustes": "Configurações do AdaptaPE",
                "app.bienvenida": "Boas-vindas ao Adapta PE",
                "app.bienvenidaDesc": "Aprenda a usar o assistente passo a passo com exercícios práticos.",

                // Menu de barra e janelas
                "menu.ajustes": "Configurações…",
                "menu.tutorial": "Tutorial…",
                "menu.detenerTodo": "Parar tudo",
                "menu.salir": "Encerrar AdaptaPE",
                "menu.opciones": "Opções",
                "menu.abrirAjustes": "Abrir configurações",

                // Seções
                "seccion.control": "Controle",
                "seccion.lectura": "Leitura e filtros",
                "seccion.mascota": "Mascote",
                "seccion.ia": "IA opcional",
                "seccion.ayuda": "Ajuda",

                // Controles principais
                "control.activaLoQueNecesitas": "Ative o que você precisa",
                "control.calibrar": "Calibrar",
                "control.pausarCursor": "Pausar cursor",
                "control.reanudarCursor": "Retomar cursor",
                "control.velocidad": "Velocidade",
                "control.reducirTemblores": "Reduzir tremores",
                "control.movimientosPequenos": "Adaptar a movimentos pequenos",
                "control.esperaClic": "Espera de clique",
                "control.camara": "Câmera",
                "control.sinCamara": "Sem câmera",
                "control.microfono": "Microfone",
                "control.sinMicrofono": "Sem microfone",
                "control.sinAlias": "Sem apelidos de pronúncia",
                "control.quitarAlias": "Remover apelidos",
                "control.escala": "Tamanho dos controles",
                "control.ayudaEscala": "Ajusta a escala do painel flutuante e dos controles (100%, 125% ou 150%).",
                "control.reconocimientoRed": "Permitir reconhecimento da Apple por rede",
                "control.ayudaReconocimientoRed": "Desligado: reconhecimento local. Ligado: a Apple pode processar áudio pela rede; não ativa IA generativa.",
                "control.iniciarAlEncender": "Iniciar ao ligar o Mac",
                "control.ayudaIniciarAlEncender": "Lembra seus módulos e configurações. Parar tudo preserva as configurações e desliga a assistência até ser ativada novamente.",
                "control.pantallasDisponibles": "Telas disponíveis",
                "control.actualizarDispositivos": "Atualizar dispositivos e permissões",
                "control.cerrarVentanaAviso": "Fechar esta janela mantém a assistência ativa.",
                "control.moverMascotaYPanel": "Mover mascote e painel juntos",
                "control.elegirMascota": "Escolher mascote",
                "control.mostrarCamara": "Mostrar câmera",
                "control.filtroPantalla": "Filtro de tela",
                "control.apagados": "Voz e cursor desligados",
                "control.aquiVeras": "Aqui você verá o que ouvi",
                "control.confirmarExacto": "Para confirmar, diga exatamente:",
                "control.cancelarConfirmacion": "Cancelar confirmação",
                "control.eligeEn": "Escolha em {contexto}",
                "control.siguiente": "Seguinte",
                "control.cancelar": "Cancelar",
                "control.cerrar": "Fechar",
                "control.anterior": "Anterior",
                "control.finalizar": "Concluir",
                "control.probar": "Testar",
                "control.guardar": "Salvar",

                // Permissões nativas
                "permisos.controlEscritorio": "Permitir controle da área de trabalho",
                "permisos.ayudaAccesibilidad": "A acessibilidade permite mover, clicar e ler elementos. Solicitada apenas ao ativar esses recursos.",
                "permisos.revisarMicro": "Verificar permissão do microfone",
                "permisos.revisarVoz": "Verificar permissão de reconhecimento de voz",
                "permisos.revisarCamara": "Verificar permissão da câmera",
                "permisos.revisarPantalla": "Verificar permissão de gravação de tela",

                // Câmera e HUD
                "camara.preparando": "Preparando câmera",
                "camara.apagada": "Câmera desligada",
                "camara.guiaColores": "Verde: zona segura · Branco: movimento",
                "camara.progresoDwell": "Progresso do clique por permanência",

                // Leitura e filtros
                "lectura.leerVentana": "Ler janela ativa",
                "lectura.detener": "Parar leitura",
                "filtro.preparando": "Preparando filtro…",
                "filtro.visionNormal": "Normal",
                "filtro.grupoRojoVerde": "Vermelho-verde",
                "filtro.grupoAzulAmarillo": "Azul-amarelo",
                "filtro.grupoGrises": "Escala de cinza",

                // Mascote
                "mascota.saludar": "Cumprimentar",
                "mascota.dormir": "Dormir",
                "mascota.despertar": "Acordar",
                "mascota.moverTeclas": "Mover com teclas",
                "mascota.otroMonitor": "Outro monitor",
                "mascota.estadoFeliz": "feliz",
                "mascota.estadoConfundida": "confuso",

                // IA Opcional
                "ia.titulo": "Sua API, só se você escolher",
                "ia.descripcion": "Todos os comandos, o cursor e o TalkBack funcionam sem IA generativa. Não inclui modelo local nem assinatura.",
                "ia.activar": "Ativar IA com minha chave de API",
                "ia.guardar": "Salvar nas Chaves",
                "ia.eliminar": "Excluir chave",
                "ia.cancelar": "Cancelar consulta",
                "ia.permitirPantalla": "Permitir envio de tela ao provedor",

                // Tutorial nativo
                "tutorial.pasosTitulo": "1. Permissões e configuração de voz",
                "tutorial.requierePermisos": "Para o Adapta PE funcionar corretamente, são necessárias autorizações do sistema:",
                "tutorial.microPermiso": "Microfone: para ouvir seus comandos de voz.",
                "tutorial.reconocimientoPermiso": "Reconhecimento de voz: processa sua voz no Mac.",
                "tutorial.accesibilidadPermiso": "Acessibilidade: para interagir com botões, janelas e menus.",
                "tutorial.grabacionPermiso": "Gravação de tela: necessária para filtros de daltonismo. Requer reiniciar o app.",
                "tutorial.camaraPermiso": "Câmera: exclusiva do Adapta PE Base para controle cinético.",
                "tutorial.probarNombreExito": "Funciona! Nome reconhecido com sucesso.",
                "tutorial.probarNombreFallo": "Nome não reconhecido. Tente novamente.",

                // Menus e janelas adicionais
                "menu.detenerModulos": "Parar todos os módulos",
                "menu.mostrarFlotante": "Mostrar painel flutuante",
                "menu.ocultarFlotante": "Ocultar painel flutuante",
                "menu.activarCursor": "Ativar cursor",
                "menu.apagarCursor": "Desativar cursor",
                "menu.activarVoz": "Ativar voz",
                "menu.apagarVoz": "Desativar voz",
                "menu.pausarCursor": "Pausar cursor",
                "menu.reanudarCursor": "Retomar cursor",
                "panel.superiorIzquierda": "Superior esquerda",
                "panel.superiorDerecha": "Superior direita",
                "panel.inferiorIzquierda": "Inferior esquerda",
                "panel.inferiorDerecha": "Inferior direita",
                "panel.tituloVentana": "Adapta PE · painel",
                "tutorial.tituloVentana": "Tutorial do Adapta PE",
                "panel.soloUnaPantalla": "Apenas uma tela conectada",

                // Configurações e controles adicionais
                "control.voz": "Voz",
                "control.cursor": "Cursor",
                "control.cursorCamara": "Cursor com câmera",
                "control.controlCon": "Controle com",
                "control.modoCabeza": "Cabeça / tronco",
                "control.modoManos": "Braços, mãos ou punhos",
                "control.modoZona": "Zona com textura",
                "control.modoDesc": "Cabeça aprende seu repouso. Para mãos ou textura, desloque a área e segure; retornar ao início para o cursor.",
                "control.clicMantener": "Clique ao manter a postura",
                "control.ayudaOrdenesVoz": "«Cursor mais lento», «calibrar cursor» e «clique direito» também funcionam por voz.",
                "control.adaptarMovimiento": "Adaptar ao meu movimento",
                "control.dispositivosYPreferencias": "Dispositivos e preferências",
                "control.nombreAsistente": "Nome para chamar o assistente",
                "control.guardarNombre": "Salvar nome",
                "control.restaurarComputadora": "Restaurar Computador",
                "control.probarNombre": "Testar nome",
                "control.anadirAlias": "Adicionar como alias",
                "control.responderComputadora": "Responder também a «Computador»",
                "control.modoConversacion": "Modo conversação: 8 s após cada ordem concluída",
                "control.cerrarConversacionAyuda": "Diga «obrigado», «pronto» ou «silêncio» para fechar; o microfone continua ativo.",
                "control.idiomaVoz": "Idioma de voz",
                "control.idiomaAuto": "Automático (sistema)",
                "control.tiempoOrdenAyuda": "Se você disser apenas o nome, tem 8 segundos para dar o comando.",
                "filtro.soloUno": "Apenas um filtro por vez",
                "filtro.quitarFiltro": "Remover filtro",
                "lectura.titulo": "Leitura e cor",
                "lectura.leerBajoCursor": "Ler em voz alta o elemento sob o cursor",
                "lectura.ayudaCursor": "Mantenha o cursor sobre um elemento para ouvi-lo. Funciona com mouse e câmera.",
                "ayuda.tutorialPractico": "Tutorial prático",
                "ayuda.accionesApp": "Ações do app ativo",
                "ayuda.buscarCampos": "Buscar campos de texto",
                "tutorial.bienvenida": "Bem-vindo ao Adapta PE",
                "tutorial.aprendePasoPaso": "Aprenda a usar o assistente passo a passo com exercícios práticos.",
                "tutorial.actualizarPermisos": "Atualizar permissões",
                "tutorial.vozActiva": "Voz ativa ✅",
                "tutorial.activarVoz": "Ativar controle por voz",
                "tutorial.revisar": "Revisar",
                "tutorial.autorizado": "Autorizado",
                "tutorial.pasoCompletado": "Etapa concluída",
                "tutorial.comenzar": "Começar a usar o Adapta PE",
                "tutorial.ejecutarClic": "Executar clique",
                "tutorial.clicExito": "Clique executado com sucesso!",
                "tutorial.hecho": "Concluído",

                "control.instruccionVoz": "Diga «{palabra}, abra o Zoom» ou «pausar cursor». Você pode fechar as configurações e continuar usando a voz.",
                "control.ejemploSafari": "Experimente «{palabra}, por favor abra o Safari» ou «{palabra}, quero que abra o Safari». Para ditar, diga «escreva» e seu texto.",
                "control.aliasPrefijo": "Aliases",
                "ayuda.explicacionComandos": "Diga «abra nova janela do Chrome», «pressione comando shift N» ou «escreva Olá no campo Nome». Se houver várias opções, diga «a segunda» ou «cancelar». As opções expiram em 45 segundos; «seguinte» mostra mais.",
                "ayuda.pasosPostura": "1. Autorize Acessibilidade.\n2. Escolha câmera e controle.\n3. Ative o cursor e mantenha a postura ao calibrar.\n4. Ative a voz e teste um comando.\n5. Use o painel flutuante ou feche as configurações.",
                "ayuda.listaComandos": "«Abre YouTube»\n«Busca mobilidade na Wikipedia»\n«Escreva Olá, José»\n«Seleciona Contato» / «Clica no selecionado»\n«Foca buscar» / «Enter»\n«Nova aba» / «Voltar» / «Recarrega»\n«Controle cabeça» / «Controle mãos»\n«Calibrar cursor» / «Pausar cursor»\n«Próximo clique direito»\n«Ativar TalkBack» / «Lê a tela»\n«Filtro deuteranopia» / «Remover filtro»\n«Abre Safari no segundo monitor»\n«Mostrar configurações» / «Parar tudo»",
                "ayuda.notaAccesibilidad": "A leitura e seleção dependem dos elementos acessíveis expostos por cada aplicativo. Campos protegidos não são lidos nem ditados. Zona livre rastreia textura.",
                "ayuda.permisoAccesibilidad": "Acessibilidade",
                "ayuda.permisoCamaraMicro": "Câmera e microfone",
                "ayuda.permisoGrabacion": "Gravação de tela",
                "panel.opcionesAcc": "Opções do painel",
                "ia.endpoint": "Endpoint HTTPS de chat/completions",
                "ia.modelo": "Modelo disponível no seu provedor",
                "ia.apiKey": "Chave de API pessoal"
            ],

            "de": [
                // Anwendung und Kopfzeile
                "app.titulo": "Adapta PE",
                "app.subtitulo": "Dein Schreibtisch, in deinem Tempo",
                "app.usarPanel": "Panel verwenden",
                "app.ajustes": "AdaptaPE-Einstellungen",
                "app.bienvenida": "Willkommen bei Adapta PE",
                "app.bienvenidaDesc": "Lerne die Nutzung des Assistenten Schritt für Schritt mit praktischen Übungen.",

                // Menüleiste und Fenster
                "menu.ajustes": "Einstellungen…",
                "menu.tutorial": "Tutorial…",
                "menu.detenerTodo": "Alles stoppen",
                "menu.salir": "AdaptaPE beenden",
                "menu.opciones": "Optionen",
                "menu.abrirAjustes": "Einstellungen öffnen",

                // Bereiche
                "seccion.control": "Steuerung",
                "seccion.lectura": "Vorlesen und Filter",
                "seccion.mascota": "Maskottchen",
                "seccion.ia": "Optionale KI",
                "seccion.ayuda": "Hilfe",

                // Hauptsteuerelemente
                "control.activaLoQueNecesitas": "Aktiviere, was du brauchst",
                "control.calibrar": "Kalibrieren",
                "control.pausarCursor": "Cursor pausieren",
                "control.reanudarCursor": "Cursor fortsetzen",
                "control.velocidad": "Geschwindigkeit",
                "control.reducirTemblores": "Zittern reduzieren",
                "control.movimientosPequenos": "An kleine Bewegungen anpassen",
                "control.esperaClic": "Klick-Wartezeit",
                "control.camara": "Kamera",
                "control.sinCamara": "Keine Kamera",
                "control.microfono": "Mikrofon",
                "control.sinMicrofono": "Kein Mikrofon",
                "control.sinAlias": "Keine Aussprache-Aliasse",
                "control.quitarAlias": "Aliasse entfernen",
                "control.escala": "Steuerelementgröße",
                "control.ayudaEscala": "Passt die Skalierung des schwebenden Panels und der Steuerelemente an (100 %, 125 % oder 150 %).",
                "control.reconocimientoRed": "Apple-Netzwerkerkennung erlauben",
                "control.ayudaReconocimientoRed": "Aus: lokale Erkennung. Ein: Apple darf Audio über das Netzwerk verarbeiten; aktiviert keine generative KI.",
                "control.iniciarAlEncender": "Beim Starten des Mac öffnen",
                "control.ayudaIniciarAlEncender": "Erinnert sich an Module und Einstellungen. Alles stoppen behält Einstellungen und pausiert Hilfe bis zum erneuten Start.",
                "control.pantallasDisponibles": "Verfügbare Bildschirme",
                "control.actualizarDispositivos": "Geräte und Berechtigungen aktualisieren",
                "control.cerrarVentanaAviso": "Das Schließen dieses Fensters hält die Hilfe aktiv.",
                "control.moverMascotaYPanel": "Maskottchen und Panel zusammen bewegen",
                "control.elegirMascota": "Maskottchen wählen",
                "control.mostrarCamara": "Kamera anzeigen",
                "control.filtroPantalla": "Bildschirmfilter",
                "control.apagados": "Sprache und Cursor aus",
                "control.aquiVeras": "Hier siehst du, was gehört wurde",
                "control.confirmarExacto": "Um zu bestätigen, sage genau:",
                "control.cancelarConfirmacion": "Bestätigung abbrechen",
                "control.eligeEn": "Wähle in {contexto}",
                "control.siguiente": "Weiter",
                "control.cancelar": "Abbrechen",
                "control.cerrar": "Schließen",
                "control.anterior": "Zurück",
                "control.finalizar": "Fertigstellen",
                "control.probar": "Testen",
                "control.guardar": "Speichern",

                // Native Berechtigungen
                "permisos.controlEscritorio": "Schreibtischsteuerung erlauben",
                "permisos.ayudaAccesibilidad": "Bedienungshilfen erlauben Bewegen, Klicken und Vorlesen von Elementen. Nur bei Aktivierung dieser Funktionen angefordert.",
                "permisos.revisarMicro": "Mikrofonberechtigung prüfen",
                "permisos.revisarVoz": "Spracherkennungsberechtigung prüfen",
                "permisos.revisarCamara": "Kameraberechtigung prüfen",
                "permisos.revisarPantalla": "Bildschirmaufnahmeberechtigung prüfen",

                // Kamera und HUD
                "camara.preparando": "Kamera wird vorbereitet",
                "camara.apagada": "Kamera aus",
                "camara.guiaColores": "Grün: sichere Zone · Weiß: Bewegung",
                "camara.progresoDwell": "Fortschritt des Verweil-Klicks",

                // Vorlesen und Filter
                "lectura.leerVentana": "Aktives Fenster vorlesen",
                "lectura.detener": "Vorlesen stoppen",
                "filtro.preparando": "Filter wird vorbereitet…",
                "filtro.visionNormal": "Normal",
                "filtro.grupoRojoVerde": "Rot-Grün",
                "filtro.grupoAzulAmarillo": "Blau-Gelb",
                "filtro.grupoGrises": "Graustufen",

                // Maskottchen
                "mascota.saludar": "Winken",
                "mascota.dormir": "Schlafen",
                "mascota.despertar": "Aufwecken",
                "mascota.moverTeclas": "Mit Tasten bewegen",
                "mascota.otroMonitor": "Anderer Bildschirm",
                "mascota.estadoFeliz": "froh",
                "mascota.estadoConfundida": "verwirrt",

                // Optionale KI
                "ia.titulo": "Deine API, nur wenn du möchtest",
                "ia.descripcion": "Alle Befehle, Cursor und TalkBack funktionieren ohne generative KI. Kein lokales Modell oder Abo enthalten.",
                "ia.activar": "KI mit eigenem API-Schlüssel aktivieren",
                "ia.guardar": "Im Schlüsselbund speichern",
                "ia.eliminar": "Schlüssel löschen",
                "ia.cancelar": "Anfrage abbrechen",
                "ia.permitirPantalla": "Bildschirmübertragung an Anbieter erlauben",

                // Natives Tutorial
                "tutorial.pasosTitulo": "1. Berechtigungen und Spracheinrichtung",
                "tutorial.requierePermisos": "Damit Adapta PE ordnungsgemäß funktioniert, sind Systemberechtigungen erforderlich:",
                "tutorial.microPermiso": "Mikrofon: um deine Sprachbefehle zu hören.",
                "tutorial.reconocimientoPermiso": "Spracherkennung: verarbeitet deine Sprache auf dem Mac.",
                "tutorial.accesibilidadPermiso": "Bedienungshilfen: für Schaltflächen, Fenster und Menüs.",
                "tutorial.grabacionPermiso": "Bildschirmaufnahme: für Farbfilter erforderlich. Erfordert Neustart der App.",
                "tutorial.camaraPermiso": "Kamera: exklusiv in Adapta PE Base für kinetische Cursorsteuerung.",
                "tutorial.probarNombreExito": "Funktioniert! Name erfolgreich erkannt.",
                "tutorial.probarNombreFallo": "Name nicht erkannt. Bitte erneut versuchen.",

                // Zusätzliche Menüs und Fenster
                "menu.detenerModulos": "Alle Module stoppen",
                "menu.mostrarFlotante": "Schwebendes Panel anzeigen",
                "menu.ocultarFlotante": "Schwebendes Panel ausblenden",
                "menu.activarCursor": "Cursor starten",
                "menu.apagarCursor": "Cursor stoppen",
                "menu.activarVoz": "Sprachsteuerung starten",
                "menu.apagarVoz": "Sprachsteuerung stoppen",
                "menu.pausarCursor": "Cursor pausieren",
                "menu.reanudarCursor": "Cursor fortsetzen",
                "panel.superiorIzquierda": "Oben links",
                "panel.superiorDerecha": "Oben rechts",
                "panel.inferiorIzquierda": "Unten links",
                "panel.inferiorDerecha": "Unten rechts",
                "panel.tituloVentana": "Adapta PE · Panel",
                "tutorial.tituloVentana": "Adapta PE Anleitung",
                "panel.soloUnaPantalla": "Nur ein Bildschirm ist angeschlossen",

                // Zusätzliche Einstellungen und Steuerelemente
                "control.voz": "Sprachsteuerung",
                "control.cursor": "Cursor",
                "control.cursorCamara": "Kamera-Cursor",
                "control.controlCon": "Steuerung mit",
                "control.modoCabeza": "Kopf / Oberkörper",
                "control.modoManos": "Arme, Hände oder Fäuste",
                "control.modoZona": "Texturbereich",
                "control.modoDesc": "Kopf lernt deine Ruheposition. Für Hände oder Textur bewege den Bereich und halte die Geste; Rückkehr stoppt den Cursor.",
                "control.clicMantener": "Klick durch Verweilen",
                "control.ayudaOrdenesVoz": "„Langsamerer Cursor“, „Cursor kalibrieren“ und „Rechtsklick“ funktionieren auch per Sprache.",
                "control.adaptarMovimiento": "An meine Bewegung anpassen",
                "control.dispositivosYPreferencias": "Geräte und Einstellungen",
                "control.nombreAsistente": "Name zum Aufrufen des Assistenten",
                "control.guardarNombre": "Name speichern",
                "control.restaurarComputadora": "Computer wiederherstellen",
                "control.probarNombre": "Name testen",
                "control.anadirAlias": "Als Alias hinzufügen",
                "control.responderComputadora": "Auch auf „Computer“ reagieren",
                "control.modoConversacion": "Gesprächsmodus: 8 s nach jedem Befehl",
                "control.cerrarConversacionAyuda": "Sage „danke“, „fertig“ oder „Ruhe“, um ihn zu schließen; Mikrofon bleibt aktiv.",
                "control.idiomaVoz": "Sprache für Sprachsteuerung",
                "control.idiomaAuto": "Automatisch (System)",
                "control.tiempoOrdenAyuda": "Wenn du nur den Namen nennst, hast du 8 Sekunden für den Befehl.",
                "filtro.soloUno": "Nur ein Filter gleichzeitig",
                "filtro.quitarFiltro": "Filter entfernen",
                "lectura.titulo": "Vorlesen und Farbe",
                "lectura.leerBajoCursor": "Element unter dem Cursor vorlesen",
                "lectura.ayudaCursor": "Halte den Cursor über ein Element, um es zu hören. Funktioniert mit Maus und Kamera.",
                "ayuda.tutorialPractico": "Praktische Anleitung",
                "ayuda.accionesApp": "Aktionen der aktiven App",
                "ayuda.buscarCampos": "Textfelder suchen",
                "tutorial.bienvenida": "Willkommen bei Adapta PE",
                "tutorial.aprendePasoPaso": "Lerne die Nutzung des Assistenten Schritt für Schritt mit praktischen Übungen.",
                "tutorial.actualizarPermisos": "Berechtigungen aktualisieren",
                "tutorial.vozActiva": "Sprachsteuerung aktiv ✅",
                "tutorial.activarVoz": "Sprachsteuerung aktivieren",
                "tutorial.revisar": "Prüfen",
                "tutorial.autorizado": "Autorisiert",
                "tutorial.pasoCompletado": "Schritt abgeschlossen",
                "tutorial.comenzar": "Adapta PE starten",
                "tutorial.ejecutarClic": "Klick ausführen",
                "tutorial.clicExito": "Klick erfolgreich ausgeführt!",
                "tutorial.hecho": "Fertig",

                "control.instruccionVoz": "Sage „{palabra}, öffne Zoom“ oder „Cursor pausieren“. Du kannst die Einstellungen schließen und weiter die Sprache nutzen.",
                "control.ejemploSafari": "Probiere „{palabra}, bitte öffne Safari“ oder „{palabra}, öffne Safari“. Zum Diktieren sage „schreibe“ und deinen Text.",
                "control.aliasPrefijo": "Aliasse",
                "ayuda.explicacionComandos": "Sage „Neues Chrome-Fenster öffnen“, „Drücke Befehl Umschalt N“ oder „Schreibe Hallo in Feld Name“. Bei mehreren Optionen sage „das zweite“ oder „abbrechen“.",
                "ayuda.pasosPostura": "1. Bedienungshilfen autorisieren.\n2. Kamera und Steuerung wählen.\n3. Cursor aktivieren und beim Kalibrieren stillhalten.\n4. Sprache aktivieren und Befehl testen.\n5. Schwebendes Panel nutzen oder Einstellungen schließen.",
                "ayuda.listaComandos": "„Öffne YouTube“\n„Suche Mobilität auf Wikipedia“\n„Schreibe Hallo, Jose“\n„Wähle Kontakt“ / „Auswahl anklicken“\n„Suche fokussieren“ / „Enter“\n„Neuer Tab“ / „Zurück“ / „Neu laden“\n„Kopfsteuerung“ / „Handsteuerung“\n„Cursor kalibrieren“ / „Cursor pausieren“\n„Nächster Rechtsklick“\n„TalkBack aktivieren“ / „Bildschirm vorlesen“\n„Deuteranopie-Filter“ / „Filter entfernen“\n„Öffne Safari auf dem zweiten Monitor“\n„Einstellungen anzeigen“ / „Alles stoppen“",
                "ayuda.notaAccesibilidad": "Das Vorlesen und Auswählen hängt von den bereitgestellten Bedienungshilfe-Elementen ab. Geschützte Felder werden nicht gelesen oder diktiert.",
                "ayuda.permisoAccesibilidad": "Bedienungshilfen",
                "ayuda.permisoCamaraMicro": "Kamera und Mikrofon",
                "ayuda.permisoGrabacion": "Bildschirmaufnahme",
                "panel.opcionesAcc": "Panel-Optionen",
                "ia.endpoint": "HTTPS-Chat/Completions-Endpunkt",
                "ia.modelo": "Verfügbares Modell bei deinem Anbieter",
                "ia.apiKey": "Persönlicher API-Schlüssel"
            ],

            "fr": [
                // Application et en-tête
                "app.titulo": "Adapta PE",
                "app.subtitulo": "Votre bureau, à votre rythme",
                "app.usarPanel": "Utiliser le panneau",
                "app.ajustes": "Réglages d’AdaptaPE",
                "app.bienvenida": "Bienvenue dans Adapta PE",
                "app.bienvenidaDesc": "Apprenez à utiliser l’assistant étape par étape avec des exercices pratiques.",

                // Barre de menu et fenêtres
                "menu.ajustes": "Réglages…",
                "menu.tutorial": "Tutoriel…",
                "menu.detenerTodo": "Tout arrêter",
                "menu.salir": "Quitter AdaptaPE",
                "menu.opciones": "Options",
                "menu.abrirAjustes": "Ouvrir les réglages",

                // Sections
                "seccion.control": "Contrôle",
                "seccion.lectura": "Lecture et filtres",
                "seccion.mascota": "Mascotte",
                "seccion.ia": "IA optionnelle",
                "seccion.ayuda": "Aide",

                // Contrôles principaux
                "control.activaLoQueNecesitas": "Activez ce dont vous avez besoin",
                "control.calibrar": "Calibrer",
                "control.pausarCursor": "Mettre le curseur en pause",
                "control.reanudarCursor": "Reprendre le curseur",
                "control.velocidad": "Vitesse",
                "control.reducirTemblores": "Réduire les tremblements",
                "control.movimientosPequenos": "Adapter aux petits mouvements",
                "control.esperaClic": "Attente de clic",
                "control.camara": "Caméra",
                "control.sinCamara": "Aucune caméra",
                "control.microfono": "Microphone",
                "control.sinMicrofono": "Aucun microphone",
                "control.sinAlias": "Aucun alias de prononciation",
                "control.quitarAlias": "Retirer les alias",
                "control.escala": "Taille des contrôles",
                "control.ayudaEscala": "Ajuste l’échelle du panneau flottant et des contrôles (100 %, 125 % ou 150 %).",
                "control.reconocimientoRed": "Autoriser la reconnaissance réseau Apple",
                "control.ayudaReconocimientoRed": "Désactivé : reconnaissance locale. Activé : Apple peut traiter l’audio par réseau ; n’active pas l’IA générative.",
                "control.iniciarAlEncender": "Lancer au démarrage du Mac",
                "control.ayudaIniciarAlEncender": "Mémorise vos modules et réglages. Tout arrêter conserve les réglages et désactive l’aide jusqu’à réactivation.",
                "control.pantallasDisponibles": "Écrans disponibles",
                "control.actualizarDispositivos": "Actualiser les appareils et permissions",
                "control.cerrarVentanaAviso": "Fermer cette fenêtre maintient l’assistance active.",
                "control.moverMascotaYPanel": "Déplacer la mascotte et le panneau ensemble",
                "control.elegirMascota": "Choisir la mascotte",
                "control.mostrarCamara": "Afficher la caméra",
                "control.filtroPantalla": "Filtre d’écran",
                "control.apagados": "Voix et curseur éteints",
                "control.aquiVeras": "Ici vous verrez ce que j’ai entendu",
                "control.confirmarExacto": "Pour confirmer, dites exactement :",
                "control.cancelarConfirmacion": "Annuler la confirmation",
                "control.eligeEn": "Choisissez dans {contexto}",
                "control.siguiente": "Suivant",
                "control.cancelar": "Annuler",
                "control.cerrar": "Fermer",
                "control.anterior": "Précédent",
                "control.finalizar": "Terminer",
                "control.probar": "Tester",
                "control.guardar": "Enregistrer",

                // Permissions natives
                "permisos.controlEscritorio": "Autoriser le contrôle du bureau",
                "permisos.ayudaAccesibilidad": "L’accessibilité permet de déplacer, cliquer et lire des éléments. Demandée uniquement lors de l’activation.",
                "permisos.revisarMicro": "Vérifier la permission du micro",
                "permisos.revisarVoz": "Vérifier la permission de reconnaissance vocale",
                "permisos.revisarCamara": "Vérifier la permission de la caméra",
                "permisos.revisarPantalla": "Vérifier la permission d’enregistrement d’écran",

                // Caméra et HUD
                "camara.preparando": "Préparation de la caméra",
                "camara.apagada": "Caméra éteinte",
                "camara.guiaColores": "Vert : zone sûre · Blanc : mouvement",
                "camara.progresoDwell": "Progression du clic par maintien",

                // Lecture et filtres
                "lectura.leerVentana": "Lire la fenêtre active",
                "lectura.detener": "Arrêter la lecture",
                "filtro.preparando": "Préparation du filtre…",
                "filtro.visionNormal": "Normal",
                "filtro.grupoRojoVerde": "Rouge-vert",
                "filtro.grupoAzulAmarillo": "Bleu-jaune",
                "filtro.grupoGrises": "Niveaux de gris",

                // Mascotte
                "mascota.saludar": "Saluer",
                "mascota.dormir": "Dormir",
                "mascota.despertar": "Réveiller",
                "mascota.moverTeclas": "Déplacer avec les touches",
                "mascota.otroMonitor": "Autre écran",
                "mascota.estadoFeliz": "heureuse",
                "mascota.estadoConfundida": "confuse",

                // IA Optionnelle
                "ia.titulo": "Votre API, seulement si vous le choisissez",
                "ia.descripcion": "Toutes les commandes, le curseur et TalkBack fonctionnent sans IA générative. Aucun modèle local ni abonnement inclus.",
                "ia.activar": "Activer l’IA avec ma clé d’API",
                "ia.guardar": "Enregistrer dans le trousseau",
                "ia.eliminar": "Supprimer la clé",
                "ia.cancelar": "Annuler la requête",
                "ia.permitirPantalla": "Autoriser l’envoi de l’écran au fournisseur",

                // Tutoriel natif
                "tutorial.pasosTitulo": "1. Permissions et configuration vocale",
                "tutorial.requierePermisos": "Pour qu’Adapta PE fonctionne correctement, des autorisations système sont requises :",
                "tutorial.microPermiso": "Microphone : pour écouter vos commandes vocales.",
                "tutorial.reconocimientoPermiso": "Reconnaissance vocale : traite votre voix sur le Mac.",
                "tutorial.accesibilidadPermiso": "Accessibilité : pour interagir avec les boutons, fenêtres et menus.",
                "tutorial.grabacionPermiso": "Enregistrement de l’écran : nécessaire pour les filtres de daltonisme. Nécessite de redémarrer l’application.",
                "tutorial.camaraPermiso": "Caméra : exclusive à Adapta PE Base pour le contrôle cinétique du curseur.",
                "tutorial.probarNombreExito": "Ça marche ! Nom reconnu avec succès.",
                "tutorial.probarNombreFallo": "Nom non reconnu. Veuillez réessayer.",

                // Menus et fenêtres supplémentaires
                "menu.detenerModulos": "Arrêter tous les modules",
                "menu.mostrarFlotante": "Afficher le panneau flottant",
                "menu.ocultarFlotante": "Masquer le panneau flottant",
                "menu.activarCursor": "Activer le curseur",
                "menu.apagarCursor": "Désactiver le curseur",
                "menu.activarVoz": "Activer la voix",
                "menu.apagarVoz": "Désactiver la voix",
                "menu.pausarCursor": "Mettre le curseur en pause",
                "menu.reanudarCursor": "Reprendre le curseur",
                "panel.superiorIzquierda": "En haut à gauche",
                "panel.superiorDerecha": "En haut à droite",
                "panel.inferiorIzquierda": "En bas à gauche",
                "panel.inferiorDerecha": "En bas à droite",
                "panel.tituloVentana": "Adapta PE · panneau",
                "tutorial.tituloVentana": "Tutoriel Adapta PE",
                "panel.soloUnaPantalla": "Un seul écran est connecté",

                // Réglages et contrôles supplémentaires
                "control.voz": "Voix",
                "control.cursor": "Curseur",
                "control.cursorCamara": "Curseur avec caméra",
                "control.controlCon": "Contrôle avec",
                "control.modoCabeza": "Tête / torse",
                "control.modoManos": "Bras, mains ou poings",
                "control.modoZona": "Zone avec texture",
                "control.modoDesc": "La tête apprend votre repos. Pour les mains ou la texture, déplacez la zone et maintenez ; revenir au centre arrête le curseur.",
                "control.clicMantener": "Clic par maintien",
                "control.ayudaOrdenesVoz": "« Curseur plus lent », « calibrer le curseur » et « clic droit » fonctionnent aussi par la voix.",
                "control.adaptarMovimiento": "Adapter à mon mouvement",
                "control.dispositivosYPreferencias": "Appareils et préférences",
                "control.nombreAsistente": "Nom pour appeler l'assistant",
                "control.guardarNombre": "Enregistrer le nom",
                "control.restaurarComputadora": "Restaurer Ordinateur",
                "control.probarNombre": "Tester le nom",
                "control.anadirAlias": "Ajouter comme alias",
                "control.responderComputadora": "Répondre aussi à « Ordinateur »",
                "control.modoConversacion": "Mode conversation : 8 s après chaque commande",
                "control.cerrarConversacionAyuda": "Dites « merci », « prêt » ou « silence » pour fermer ; le micro reste actif.",
                "control.idiomaVoz": "Langue de la voix",
                "control.idiomaAuto": "Automatique (système)",
                "control.tiempoOrdenAyuda": "Si vous ne dites que le nom, vous avez 8 secondes pour donner l'ordre.",
                "filtro.soloUno": "Un seul filtre à la fois",
                "filtro.quitarFiltro": "Désactiver le filtre",
                "lectura.titulo": "Lecture et couleur",
                "lectura.leerBajoCursor": "Lire à voix haute l'élément sous le curseur",
                "lectura.ayudaCursor": "Maintenez le curseur sur un élément pour l'écouter. Fonctionne avec souris et caméra.",
                "ayuda.tutorialPractico": "Tutoriel pratique",
                "ayuda.accionesApp": "Actions de l'application active",
                "ayuda.buscarCampos": "Rechercher des champs de texte",
                "tutorial.bienvenida": "Bienvenue dans Adapta PE",
                "tutorial.aprendePasoPaso": "Apprenez à utiliser l'assistant pas à pas grâce à des exercices pratiques.",
                "tutorial.actualizarPermisos": "Actualiser les autorisations",
                "tutorial.vozActiva": "Voix active ✅",
                "tutorial.activarVoz": "Activer le contrôle vocal",
                "tutorial.revisar": "Vérifier",
                "tutorial.autorizado": "Autorisé",
                "tutorial.pasoCompletado": "Étape terminée",
                "tutorial.comenzar": "Commencer à utiliser Adapta PE",
                "tutorial.ejecutarClic": "Exécuter le clic",
                "tutorial.clicExito": "Clic exécuté avec succès !",
                "tutorial.hecho": "Terminé",

                "control.instruccionVoz": "Dites « {palabra}, ouvre Zoom » ou « pause curseur ». Vous pouvez fermer les réglages et continuer à utiliser la voix.",
                "control.ejemploSafari": "Essayez « {palabra}, s’il te plaît ouvre Safari » ou « {palabra}, je veux que tu ouvres Safari ». Pour dicter, dites « écris » et votre texte.",
                "control.aliasPrefijo": "Alias",
                "ayuda.explicacionComandos": "Dites « ouvrir nouvelle fenêtre Chrome », « appuyer sur commande shift N » ou « écrire Bonjour dans le champ Nom ». En cas d’options multiples, dites « la deuxième » ou « annuler ».",
                "ayuda.pasosPostura": "1. Autorisez l’accessibilité.\n2. Choisissez caméra et contrôle.\n3. Activez le curseur et maintenez la posture lors du calibrage.\n4. Activez la voix et testez une commande.\n5. Utilisez le panneau flottant ou fermez les réglages.",
                "ayuda.listaComandos": "« Ouvre YouTube »\n« Cherche mobilité sur Wikipédia »\n« Écris Bonjour, José »\n« Sélectionne Contact » / « Clique sur la sélection »\n« Focalise recherche » / « Entrée »\n« Nouvel onglet » / « Retour » / « Recharger »\n« Contrôle tête » / « Contrôle mains »\n« Calibrer le curseur » / « Pause curseur »\n« Prochain clic droit »\n« Activer TalkBack » / « Lis l'écran »\n« Filtre deutéranopie » / « Supprimer le filtre »\n« Ouvre Safari sur le deuxième écran »\n« Afficher les réglages » / « Tout arrêter »",
                "ayuda.notaAccesibilidad": "La lecture et la sélection dépendent des éléments accessibles exposés par chaque application. Les champs protégés ne sont ni lus ni dictés.",
                "ayuda.permisoAccesibilidad": "Accessibilité",
                "ayuda.permisoCamaraMicro": "Caméra et microphone",
                "ayuda.permisoGrabacion": "Enregistrement de l'écran",
                "panel.opcionesAcc": "Options du panneau",
                "ia.endpoint": "Point de terminaison HTTPS chat/completions",
                "ia.modelo": "Modèle disponible chez votre fournisseur",
                "ia.apiKey": "Clé API personnelle"
            ],

            "it": [
                // Applicazione e intestazione
                "app.titulo": "Adapta PE",
                "app.subtitulo": "La tua scrivania, al tuo ritmo",
                "app.usarPanel": "Usa pannello",
                "app.ajustes": "Impostazioni di AdaptaPE",
                "app.bienvenida": "Benvenuto in Adapta PE",
                "app.bienvenidaDesc": "Impara a usare l’assistente passo dopo passo con esercizi pratici.",

                // Barra dei menu e finestre
                "menu.ajustes": "Impostazioni…",
                "menu.tutorial": "Tutorial…",
                "menu.detenerTodo": "Interrompi tutto",
                "menu.salir": "Esci da AdaptaPE",
                "menu.opciones": "Opzioni",
                "menu.abrirAjustes": "Apri impostazioni",

                // Sezioni
                "seccion.control": "Controllo",
                "seccion.lectura": "Lettura e filtri",
                "seccion.mascota": "Mascotte",
                "seccion.ia": "IA opzionale",
                "seccion.ayuda": "Aiuto",

                // Controlli principali
                "control.activaLoQueNecesitas": "Attiva ciò di cui hai bisogno",
                "control.calibrar": "Calibra",
                "control.pausarCursor": "Metti in pausa cursore",
                "control.reanudarCursor": "Riprendi cursore",
                "control.velocidad": "Velocità",
                "control.reducirTemblores": "Riduci tremori",
                "control.movimientosPequenos": "Adatta a piccoli movimenti",
                "control.esperaClic": "Attesa clic",
                "control.camara": "Fotocamera",
                "control.sinCamara": "Nessuna fotocamera",
                "control.microfono": "Microfono",
                "control.sinMicrofono": "Nessun microfono",
                "control.sinAlias": "Nessun alias di pronuncia",
                "control.quitarAlias": "Rimuovi alias",
                "control.escala": "Dimensione dei controlli",
                "control.ayudaEscala": "Regola la scala del pannello mobile e dei controlli (100%, 125% o 150%).",
                "control.reconocimientoRed": "Consenti riconoscimento di rete Apple",
                "control.ayudaReconocimientoRed": "Disattivo: riconoscimento locale. Attivo: Apple può elaborare audio via rete; non attiva IA generativa.",
                "control.iniciarAlEncender": "Avvia all’accensione del Mac",
                "control.ayudaIniciarAlEncender": "Ricorda moduli e impostazioni. Interrompi tutto conserva le impostazioni e sospende l’assistenza fino alla riattivazione.",
                "control.pantallasDisponibles": "Schermi disponibili",
                "control.actualizarDispositivos": "Aggiorna dispositivi e permessi",
                "control.cerrarVentanaAviso": "Chiudere questa finestra mantiene l’assistenza attiva.",
                "control.moverMascotaYPanel": "Muovi mascotte e pannello insieme",
                "control.elegirMascota": "Scegli mascotte",
                "control.mostrarCamara": "Mostra fotocamera",
                "control.filtroPantalla": "Filtro schermo",
                "control.apagados": "Voce e cursore disattivi",
                "control.aquiVeras": "Qui vedrai cosa ho sentito",
                "control.confirmarExacto": "Per confermare, di’ esattamente:",
                "control.cancelarConfirmacion": "Annulla conferma",
                "control.eligeEn": "Scegli in {contexto}",
                "control.siguiente": "Avanti",
                "control.cancelar": "Annulla",
                "control.cerrar": "Chiudi",
                "control.anterior": "Precedente",
                "control.finalizar": "Termina",
                "control.probar": "Prova",
                "control.guardar": "Salva",

                // Permessi nativi
                "permisos.controlEscritorio": "Consenti controllo della scrivania",
                "permisos.ayudaAccesibilidad": "L’accessibilità consente di muovere, cliccare e leggere elementi. Richiesta solo quando si attivano queste funzioni.",
                "permisos.revisarMicro": "Controlla permesso microfono",
                "permisos.revisarVoz": "Controlla permesso riconoscimento vocale",
                "permisos.revisarCamara": "Controlla permesso fotocamera",
                "permisos.revisarPantalla": "Controlla permesso registrazione schermo",

                // Fotocamera e HUD
                "camara.preparando": "Preparazione fotocamera",
                "camara.apagada": "Fotocamera spenta",
                "camara.guiaColores": "Verde: zona sicura · Bianco: movimento",
                "camara.progresoDwell": "Avanzamento del clic a permanenza",

                // Lettura e filtri
                "lectura.leerVentana": "Leggi finestra attiva",
                "lectura.detener": "Interrompi lettura",
                "filtro.preparando": "Preparazione filtro…",
                "filtro.visionNormal": "Normal",
                "filtro.grupoRojoVerde": "Rosso-verde",
                "filtro.grupoAzulAmarillo": "Blu-giallo",
                "filtro.grupoGrises": "Scala di grigi",

                // Mascotte
                "mascota.saludar": "Saluta",
                "mascota.dormir": "Addormenta",
                "mascota.despertar": "Sveglia",
                "mascota.moverTeclas": "Sposta con i tasti",
                "mascota.otroMonitor": "Altro monitor",
                "mascota.estadoFeliz": "felice",
                "mascota.estadoConfundida": "confusa",

                // IA Opzionale
                "ia.titulo": "La tua API, solo se la scegli",
                "ia.descripcion": "Tutti i comandi, il cursore e TalkBack funzionano senza IA generativa. Nessun modello locale o abbonamento incluso.",
                "ia.activar": "Attiva IA con la mia chiave API",
                "ia.guardar": "Salva nel Portachiavi",
                "ia.eliminar": "Elimina chiave",
                "ia.cancelar": "Annulla richiesta",
                "ia.permitirPantalla": "Consenti invio dello schermo al provider",

                // Tutorial nativo
                "tutorial.pasosTitulo": "1. Permessi e configurazione vocale",
                "tutorial.requierePermisos": "Affinché Adapta PE funzioni correttamente, sono necessarie le autorizzazioni di sistema:",
                "tutorial.microPermiso": "Microfono: per ascoltare i tuoi comandi vocali.",
                "tutorial.reconocimientoPermiso": "Riconoscimento vocale: elabora la tua voce sul Mac.",
                "tutorial.accesibilidadPermiso": "Accessibilità: per interagire con pulsanti, finestre e menu.",
                "tutorial.grabacionPermiso": "Registrazione schermo: necessaria per i filtri daltonismo. Richiede il riavvio dell’app.",
                "tutorial.camaraPermiso": "Fotocamera: esclusiva di Adapta PE Base per il controllo cinetico.",
                "tutorial.probarNombreExito": "Funziona! Nome riconosciuto correttamente.",
                "tutorial.probarNombreFallo": "Nome non riconosciuto. Riprova.",

                // Menu e finestre aggiuntivi
                "menu.detenerModulos": "Interrompi tutti i moduli",
                "menu.mostrarFlotante": "Mostra pannello fluttuante",
                "menu.ocultarFlotante": "Nascondi pannello fluttuante",
                "menu.activarCursor": "Attiva cursore",
                "menu.apagarCursor": "Disattiva cursore",
                "menu.activarVoz": "Attiva voce",
                "menu.apagarVoz": "Disattiva voce",
                "menu.pausarCursor": "Metti in pausa cursore",
                "menu.reanudarCursor": "Riprendi cursore",
                "panel.superiorIzquierda": "In alto a sinistra",
                "panel.superiorDerecha": "In alto a destra",
                "panel.inferiorIzquierda": "In basso a sinistra",
                "panel.inferiorDerecha": "In basso a destra",
                "panel.tituloVentana": "Adapta PE · pannello",
                "tutorial.tituloVentana": "Tutorial di Adapta PE",
                "panel.soloUnaPantalla": "È collegato un solo schermo",

                // Impostazioni e controlli aggiuntivi
                "control.voz": "Voce",
                "control.cursor": "Cursore",
                "control.cursorCamara": "Cursore con fotocamera",
                "control.controlCon": "Controllo con",
                "control.modoCabeza": "Testa / busto",
                "control.modoManos": "Braccia, mani o pugni",
                "control.modoZona": "Zona con texture",
                "control.modoDesc": "La testa impara la posizione di riposo. Per mani o texture, sposta l'area e mantieni il gesto; tornare al centro ferma il cursore.",
                "control.clicMantener": "Clic mantenendo la postura",
                "control.ayudaOrdenesVoz": "«Cursore più lento», «calibra cursore» e «clic destro» funzionano anche a voce.",
                "control.adaptarMovimiento": "Adatta al mio movimento",
                "control.dispositivosYPreferencias": "Dispositivos y preferenze",
                "control.nombreAsistente": "Nome per chiamare l'assistente",
                "control.guardarNombre": "Salva nome",
                "control.restaurarComputadora": "Ripristina Computer",
                "control.probarNombre": "Prova nome",
                "control.anadirAlias": "Aggiungi come alias",
                "control.responderComputadora": "Rispondi anche a «Computer»",
                "control.modoConversacion": "Modalità conversazione: 8 s dopo ogni ordine completato",
                "control.cerrarConversacionAyuda": "Di' «grazie», «fatto» o «silenzio» per chiuderla; il microfono rimane attivo.",
                "control.idiomaVoz": "Lingua della voce",
                "control.idiomaAuto": "Automatico (sistema)",
                "control.tiempoOrdenAyuda": "Se dici solo il nome, hai 8 secondi per dare l'ordine.",
                "filtro.soloUno": "Solo un filtro alla volta",
                "filtro.quitarFiltro": "Rimuovi filtro",
                "lectura.titulo": "Lettura e colore",
                "lectura.leerBajoCursor": "Leggi ad alta voce l'elemento sotto il cursore",
                "lectura.ayudaCursor": "Mantieni il cursore su un elemento per ascoltarlo. Funziona con mouse e fotocamera.",
                "ayuda.tutorialPractico": "Tutorial pratico",
                "ayuda.accionesApp": "Azioni dell'app attiva",
                "ayuda.buscarCampos": "Cerca campi di testo",
                "tutorial.bienvenida": "Benvenuto in Adapta PE",
                "tutorial.aprendePasoPaso": "Impara a usare l'assistente passo dopo passo con esercizi pratici.",
                "tutorial.actualizarPermisos": "Aggiorna autorizzazioni",
                "tutorial.vozActiva": "Voce attiva ✅",
                "tutorial.activarVoz": "Attiva controllo vocale",
                "tutorial.revisar": "Verifica",
                "tutorial.autorizado": "Autorizzato",
                "tutorial.pasoCompletado": "Passaggio completato",
                "tutorial.comenzar": "Inizia a usare Adapta PE",
                "tutorial.ejecutarClic": "Esegui clic",
                "tutorial.clicExito": "Clic eseguito con successo!",
                "tutorial.hecho": "Fatto",

                "control.instruccionVoz": "Di' «{palabra}, apri Zoom» o «metti in pausa cursore». Puoi chiudere le impostazioni e continuare a usare la voce.",
                "control.ejemploSafari": "Prova «{palabra}, per favore apri Safari» o «{palabra}, voglio che tu apra Safari». Per dettare, di' «scrivi» e il tuo testo.",
                "control.aliasPrefijo": "Alias",
                "ayuda.explicacionComandos": "Di' «apri nuova finestra di Chrome», «premi comando maiuscole N» o «scrivi Ciao nel campo Nome». Se ci sono più opzioni, di' «la seconda» o «annulla».",
                "ayuda.pasosPostura": "1. Autorizza Accessibilità.\n2. Scegli fotocamera e controllo.\n3. Attiva il cursore e mantieni la postura durante la calibrazione.\n4. Attiva la voce e prova un comando.\n5. Usa il pannello fluttuante o chiudi le impostazioni.",
                "ayuda.listaComandos": "«Apri YouTube»\n«Cerca mobilità su Wikipedia»\n«Scrivi Ciao, Jose»\n«Seleziona Contatto» / «Premi la selezione»\n«Metti a fuoco cerca» / «Invio»\n«Nuova scheda» / «Indietro» / «Ricarica»\n«Controllo testa» / «Controllo mani»\n«Calibra cursore» / «Metti in pausa cursore»\n«Prossimo clic destro»\n«Attiva TalkBack» / «Leggi lo schermo»\n«Filtro deuteranopia» / «Rimuovi filtro»\n«Apri Safari sul secondo monitor»\n«Mostra impostazioni» / «Interrompi tutto»",
                "ayuda.notaAccesibilidad": "La lettura e la selezione dipendono dagli elementi accessibili esposti da ciascuna applicazione. I campi protetti non vengono letti né dettati.",
                "ayuda.permisoAccesibilidad": "Accessibilità",
                "ayuda.permisoCamaraMicro": "Fotocamera e microfono",
                "ayuda.permisoGrabacion": "Registrazione schermo",
                "panel.opcionesAcc": "Opzioni del pannello",
                "ia.endpoint": "Endpoint HTTPS di chat/completions",
                "ia.modelo": "Modello disponibile presso il tuo provider",
                "ia.apiKey": "API key personale"
            ]
        ])
    }
}

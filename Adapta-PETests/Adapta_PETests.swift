import XCTest
import AVFoundation
import CoreMedia
import Speech
import AppKit
@testable import Adapta_PE

final class Adapta_PETests: XCTestCase {
    func testPermanenciaSeDesarmaTrasSaltosDeMasDe200Milisegundos() {
        for salto in [0.201, 0.300, 0.500] {
            for fps in [15.0, 30.0, 60.0] {
                var state = KineticState(), tiempo = 0.0, clics = 0
                state.fixedCenter = true; state.calibrate()
                let centro = CGPoint(x: 0.5, y: 0.5)
                func alimentar(_ punto: CGPoint, segundos: Double) {
                    for _ in 0..<Int((segundos * fps).rounded()) {
                        tiempo += 1 / fps
                        if state.update(punto, time: tiempo, target: "boton").click { clics += 1 }
                    }
                }
                alimentar(CGPoint(x: 0.8, y: 0.5), segundos: 1)
                while state.progress == 0 && tiempo < 2 {
                    tiempo += 1 / fps
                    _ = state.update(centro, time: tiempo, target: "boton")
                }
                XCTAssertGreaterThan(state.progress, 0, "La permanencia debe haber comenzado")
                tiempo += salto
                XCTAssertFalse(state.update(centro, time: tiempo, target: "boton").click)
                XCTAssertEqual(state.progress, 0)
                alimentar(centro, segundos: 2)
                XCTAssertEqual(clics, 0, "Salto de \(salto) s a \(fps) FPS exige rearmar")
                alimentar(CGPoint(x: 0.8, y: 0.5), segundos: 1)
                alimentar(centro, segundos: 2)
                XCTAssertEqual(clics, 1, "Debe permitir un clic después de rearmar")
            }
        }
    }

    @MainActor func testInterrupcionesDeLecturaLleganAlEjecutor() {
        let actions = ActionManager.shared
        let accionAnterior = actions.appAction, salidaAnterior = actions.speechOutput
        defer { actions.callar(); actions.appAction = accionAnterior; actions.speechOutput = salidaAnterior }
        var accion: String?, hablando = true
        actions.appAction = { accion = $0 }
        actions.speechOutput = { hablando = $0 }
        for frase in ["para la lectura", "desactiva voz", "apaga el micrófono", "desactiva el micrófono", "por favor desactiva voz, pe"] {
            var entrada = VoiceInputState()
            let orden = entrada.consume("Computadora, " + frase, wakeWord: "computadora", time: 1, speaking: true).command
            XCTAssertNotNil(orden, frase)
            guard let orden else { continue }
            accion = nil; hablando = true
            actions.procesarIntencion(orden)
            XCTAssertFalse(hablando, frase)
            if frase == "para la lectura" {
                XCTAssertEqual(CommandParser.parse(orden), .silence)
                XCTAssertNil(accion, "Parar lectura conserva la escucha")
            } else { XCTAssertEqual(accion, "desactivar voz", frase) }
        }
    }

    @MainActor func testPermisoDeMicrofonoTardioNoSolicitaSpeech() async {
        let voz = VoiceManager()
        var resolverMicrofono: (@Sendable (Bool) -> Void)?
        var solicitudesSpeech = 0
        voz.solicitarMicrofono = { resolverMicrofono = $0 }
        voz.solicitarReconocimiento = { _ in solicitudesSpeech += 1 }
        voz.startListening()
        let resolverAnterior = resolverMicrofono
        XCTAssertTrue(voz.isStarting)
        voz.stopListening(remember: false)
        voz.startListening()
        resolverAnterior?(true)
        await withCheckedContinuation { continuacion in DispatchQueue.main.async { continuacion.resume() } }
        XCTAssertEqual(solicitudesSpeech, 0)
        XCTAssertTrue(voz.isStarting, "El permiso anterior no altera el nuevo inicio")
        voz.stopListening(remember: false)
        resolverMicrofono?(true)
        await withCheckedContinuation { continuacion in DispatchQueue.main.async { continuacion.resume() } }
        XCTAssertEqual(solicitudesSpeech, 0)
        XCTAssertFalse(voz.isStarting); XCTAssertFalse(voz.isListening)
        XCTAssertEqual(voz.status, "Micrófono apagado")
    }

    @MainActor func testPermisoSpeechTardioNoReiniciaLaEscucha() async {
        let voz = VoiceManager()
        var resolverSpeech: (@Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void)?
        voz.solicitarMicrofono = { $0(true) }
        voz.solicitarReconocimiento = { XCTAssertTrue(Thread.isMainThread); resolverSpeech = $0 }
        voz.startListening()
        await withCheckedContinuation { continuacion in DispatchQueue.main.async { continuacion.resume() } }
        XCTAssertNotNil(resolverSpeech)
        voz.stopListening(remember: false)
        resolverSpeech?(.authorized)
        await withCheckedContinuation { continuacion in DispatchQueue.main.async { continuacion.resume() } }
        XCTAssertFalse(voz.isStarting); XCTAssertFalse(voz.isListening)
        XCTAssertEqual(voz.status, "Micrófono apagado")
    }

    func testWakeAliasesAndLiteralSuffix() {
        for word in ["Computadora", "Computadoras", "Computador"] {
            var wake = WakePhraseState()
            XCTAssertTrue(wake.consume(word + ", por favor", wakeWord: "computadora", time: 0).beep)
            XCTAssertEqual(wake.consume("Abre Safari", wakeWord: "computadora", time: 7.99).command, "Abre Safari")
            XCTAssertTrue(wake.consume(word, wakeWord: "computadora", time: 10).beep)
            XCTAssertNil(wake.consume("Abre Safari", wakeWord: "computadora", time: 18).command)
            XCTAssertEqual(wake.consume("oye   " + word + " escribe Hola,  Perú!", wakeWord: "computadora", time: 20).command, "escribe Hola,  Perú!")
        }
        for rejected in ["compu", "ordenador", "supercomputadora", "computadoramente"] {
            var wake = WakePhraseState()
            XCTAssertNil(wake.consume(rejected + " abre Safari", wakeWord: "computadora", time: 0).command)
        }
        var custom = WakePhraseState()
        var invalidTime = WakePhraseState()
        _ = invalidTime.consume("Computadora", wakeWord: "computadora", time: 0)
        XCTAssertNil(invalidTime.consume("Computadora abre Safari", wakeWord: "computadora", time: .nan).command)
        XCTAssertEqual(invalidTime.waitingUntil, 0)
        var input = VoiceInputState()
        _ = input.consume("Computadora", wakeWord: "computadora", time: 0)
        input.beginUtterance()
        XCTAssertNil(input.consume("abre Safari", wakeWord: "computadora", time: .nan, followUp: true).command)
        XCTAssertEqual(input.waitingUntil, 0)
        XCTAssertNil(input.consume("abre Safari", wakeWord: "computadora", time: 1).command)
        XCTAssertEqual(custom.consume("Asistente escribe Hola,  Perú!", wakeWord: "Asistente", time: 0).command, "escribe Hola,  Perú!")
        XCTAssertNil(custom.consume("Computadora abre Safari", wakeWord: "Asistente", time: 1).command)
    }

    func testGestureRejectsInvalidOrientationAndBoundsAngles() {
        let point = CGPoint(x: 0.4, y: 0.4), center = CGPoint(x: 0.5, y: 0.5)
        var gesture = GestureState()
        XCTAssertEqual(gesture.update(point, time: 0, tilt: CGPoint(x: CGFloat.nan, y: CGFloat.infinity)), center)
        XCTAssertEqual(gesture.update(point, time: 0.05, tilt: CGPoint(x: 0.2, y: 0)), center)
        gesture.reset()
        _ = gesture.update(point, time: 0, angle: .infinity)
        XCTAssertEqual(gesture.update(point, time: 0.05, angle: 0), center)
        gesture.reset()
        _ = gesture.update(point, time: 0, angle: -.greatestFiniteMagnitude)
        let bounded = gesture.update(point, time: 0.05, angle: .greatestFiniteMagnitude)
        XCTAssertTrue(bounded.x.isFinite && bounded.y.isFinite)
        gesture.reset()
        _ = gesture.update(point, time: 0, angle: .pi - 0.01)
        XCTAssertEqual(gesture.update(point, time: 0.05, angle: -.pi + 0.01).x, 0.518, accuracy: 0.000001)
    }

    func testSpanishPreparationPreservesContent() {
        for phrase in ["¿puedes abrir Safari?", "escribí Ya pe, abre YouTube.", "oye, búscame Ají de Gallina en YouTube porfa", "no abras Safari", "buscar en la página"] {
            XCTAssertEqual(CommandParser.prepare(CommandParser.prepare(phrase)), CommandParser.prepare(phrase), phrase)
        }
        XCTAssertEqual(CommandParser.parse("escribi\u{301} Hola, José!"), .dictate("Hola, José!"))
        XCTAssertEqual(CommandParser.parse("seleccione el texto Hola, José!"), .selectText("Hola, José!"))
        XCTAssertEqual(CommandParser.parse("buscar en la página"), .shortcut("buscar_texto"))
        for phrase in ["ábrame Safari", "abrí Safari", "¿puedes abrir Safari?", "podrías abrirme Safari por favor", "quiero que abras Safari", "me haces el favor de abrir Safari", "ayúdame a abrir Safari", "oye, porfa abre Safari, pe", "oye, ¿puedes abrir Safari?"] {
            XCTAssertEqual(CommandParser.parse(phrase), .open("Safari", "actual"), phrase)
        }
        XCTAssertEqual(CommandParser.parse("por favor escriba Hola, ¿cómo estás? Gracias pe"), .dictate("Hola, ¿cómo estás? Gracias pe"))
        XCTAssertEqual(CommandParser.parse("escribí Ya pe, abre YouTube."), .dictate("Ya pe, abre YouTube."))
        XCTAssertEqual(CommandParser.parse("escribe Hola,  José!"), .dictate("Hola,  José!"))
        XCTAssertEqual(CommandParser.parse("oye, búscame Ají de Gallina en YouTube porfa"), .search("Ají de Gallina", "youtube", "actual"))
        XCTAssertEqual(CommandParser.parse("quiero que cierres la pestaña"), .shortcut("cerrar_pestana"))
        XCTAssertEqual(CommandParser.parse("por favor no abras Safari"), .unknown("no abras Safari"))
        XCTAssertEqual(CommandParser.parse("busca Adapta PE"), .search("Adapta PE", nil, "actual"))
        XCTAssertEqual(CommandParser.parse("busca qué significa pues"), .search("qué significa pues", nil, "actual"))
        XCTAssertEqual(CommandParser.parse("abre Adapta PE"), .open("Adapta PE", "actual"))
        XCTAssertEqual(CommandParser.parse("buscar campos"), .listFields)
        XCTAssertEqual(CommandParser.prepare("oye, ¿puedes abrir Safari?"), CommandParser.prepare(CommandParser.prepare("oye, ¿puedes abrir Safari?")))
    }

    @MainActor func testCourtesyDispatchesFilterCommands() {
        let actions = ActionManager.shared
        let oldAction = actions.appAction
        defer { actions.appAction = oldAction }
        var action: String?
        actions.appAction = { action = $0 }
        actions.procesarIntencion("por favor quitar filtro")
        XCTAssertEqual(action, "filtro:ninguno")
        actions.procesarIntencion("oye, filtro deuteranopía")
        XCTAssertEqual(action, "filtro:deuteranopia")
    }

    @MainActor
    func testStoppingRejectsLateTrackingCallbacks() {
        let tracker = TrackingManager(), token = tracker.currentGeneration
        var calls = 0
        tracker.whileCurrent(token) { calls += 1 }
        XCTAssertEqual(calls, 1)
        tracker.stopTracking(remember: false)
        tracker.whileCurrent(token) { calls += 1 }
        XCTAssertEqual(calls, 1, "Una inferencia antigua no mueve, pulsa ni reactiva salida después de detener")
        XCTAssertNotEqual(tracker.currentGeneration, token)
    }

    func testGameSurfaceIdentityChecksForegroundAndMonitorCoordinates() {
        let bounds = CGRect(x: -1920, y: -300, width: 1920, height: 1080).dictionaryRepresentation
        let game: [String: Any] = [kCGWindowLayer as String: 0, kCGWindowOwnerPID as String: 77, kCGWindowNumber as String: 5, kCGWindowBounds as String: bounds]
        XCTAssertNotNil(DesktopAccess.surfaceIdentity(at: CGPoint(x: -500, y: -100), windows: [game], pid: 77))
        XCTAssertNil(DesktopAccess.surfaceIdentity(at: CGPoint(x: -500, y: -100), windows: [game], pid: 78))
        XCTAssertNil(DesktopAccess.surfaceIdentity(at: CGPoint(x: 500, y: 100), windows: [game], pid: 77))
        XCTAssertNil(DesktopAccess.surfaceIdentity(at: CGPoint(x: Double.nan, y: 100), windows: [game], pid: 77))
    }


    func testLinkedPanelPlacementAndMascotActivity() {
        let screen = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        for corner in PanelCorner.allCases {
            for point in [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: -5, y: 7), CGPoint(x: CGFloat.nan, y: CGFloat.infinity)] {
                let frame = corner.frame(size: CGSize(width: 320, height: 600), visible: screen, free: point, reservedHeight: 164)
                XCTAssertTrue(screen.contains(frame))
                XCTAssertLessThanOrEqual(frame.maxY + 164, screen.maxY)
                let grown = corner.frame(size: CGSize(width: 320, height: 900), visible: screen, free: point, reservedHeight: 164)
                XCTAssertLessThanOrEqual(grown.maxY + 164, screen.maxY)
            }
        }
        var activity = MascotActivity(); activity.touch(10)
        XCTAssertFalse(activity.shouldSleep(99)); XCTAssertTrue(activity.shouldSleep(100))
        activity.speaking = true; XCTAssertFalse(activity.shouldSleep(200))
        activity.speaking = false; activity.touch(200); XCTAssertFalse(activity.shouldSleep(201))
        activity.manualSleep = true; XCTAssertFalse(activity.shouldSleep(300))
        XCTAssertEqual(CommandParser.parse("une mascota al panel"), .mascot("join"))
        XCTAssertEqual(CommandParser.parse("separa la mascota del panel"), .mascot("separate"))
        XCTAssertEqual(CommandParser.parse("escribe une mascota al panel"), .dictate("une mascota al panel"))
    }

    func testMascotCommandsAndPlayback() throws {
        XCTAssertEqual(CommandParser.parse("mascota Cu Chu"), .mascot("cuchu"))
        XCTAssertEqual(CommandParser.parse("elige mascota tiiinku"), .mascot("tinku"))
        XCTAssertEqual(CommandParser.parse("mascota Yaty"), .mascot("yati"))
        XCTAssertEqual(CommandParser.parse("oculta la mascota"), .mascot("ninguna"))
        XCTAssertEqual(CommandParser.parse("duerme mascota"), .mascot("sleep"))
        XCTAssertEqual(CommandParser.parse("escribe mascota Cuchu"), .dictate("mascota Cuchu"))
        XCTAssertEqual(CommandParser.parse("busca mascota Yati en Google"), .search("mascota Yati", "google", "actual"))
        for name in ["tinku", "cuchu", "yati"] {
            let url = try XCTUnwrap(Bundle.main.url(forResource: "mascota-" + name, withExtension: "json"))
            let atlas = try JSONDecoder().decode(MascotAtlas.self, from: Data(contentsOf: url))
            XCTAssertEqual(atlas.frames.count, 144)
            XCTAssertTrue(atlas.animations.allSatisfy { ($0.entry + $0.loop + $0.exit).allSatisfy(atlas.frames.indices.contains) })
            var animation = MascotPlayback(atlas: atlas)
            animation.set("wave"); for _ in 0..<100 { animation.advance() }; XCTAssertEqual(animation.state, "idle")
            animation.set("laptop"); for _ in 0..<100 { animation.advance() }; XCTAssertEqual(animation.state, "idle")
            animation.set("sleep"); for _ in 0..<100 { animation.advance() }; XCTAssertEqual(animation.state, "sleep"); XCTAssertTrue(animation.resting)
            animation.set("wake"); for _ in 0..<100 { animation.advance() }; XCTAssertEqual(animation.state, "idle")
        }
    }

    func testLocalAttractionDoesNotArmClicksOrCatchFastMovement() {
        let point = CGPoint(x: -100, y: 50)
        let moved = cursorAttraction(point, center: CGPoint(x: -80, y: 50), speed: 0, dt: 0.02)
        XCTAssertGreaterThan(moved.x, -100); XCTAssertLessThan(moved.x, -80)
        XCTAssertEqual(cursorAttraction(point, center: CGPoint(x: -71, y: 50), speed: 0, dt: 0.02), point)
        XCTAssertEqual(cursorAttraction(point, center: CGPoint(x: -80, y: 50), speed: 121, dt: 0.02), point)
    }
    func testGesturesFixedCenterAndLegacyModes() {
        XCTAssertEqual(ControlModes.normalize("automatico"), "manos")
        XCTAssertEqual(ControlModes.normalize("brazo_izquierdo"), "manos")
        XCTAssertEqual(ControlModes.normalize("torso"), "cabeza")
        for fps in [5.0, 15, 30, 60] {
            var gesture = GestureState(), t = 0.0
            let neutral = CGPoint(x: 0.2, y: 0.7)
            XCTAssertEqual(gesture.update(neutral, time: t), CGPoint(x: 0.5, y: 0.5))
            t += 1 / fps; XCTAssertGreaterThan(gesture.update(CGPoint(x: 0.23, y: 0.7), time: t).x, 0.65)
            for _ in 0..<5 { t += 1 / fps; XCTAssertGreaterThan(gesture.update(CGPoint(x: 0.23, y: 0.7), time: t).x, 0.65) }
            t += 1 / fps; XCTAssertEqual(gesture.update(neutral, time: t), CGPoint(x: 0.5, y: 0.5))
            XCTAssertEqual(gesture.update(CGPoint(x: 0.9, y: 0.9), time: t), CGPoint(x: 0.5, y: 0.5))
            t += 0.3; XCTAssertEqual(gesture.update(CGPoint(x: 0.9, y: 0.9), time: t), CGPoint(x: 0.5, y: 0.5)); XCTAssertTrue(gesture.resetNow)
            var state = KineticState(); state.fixedCenter = true; state.calibrate()
            XCTAssertNotNil(state.origin); XCTAssertFalse(state.update(CGPoint(x: 0.5, y: 0.5), time: 0, target: "button").click)
            state.lost(at: 2); XCTAssertEqual(state.progress, 0)
        }
    }
    func testLocalTextureRejectsLightingAndTracksAwayFromCenter() {
        var zone = ZoneTracker()
        let plain = [Float](repeating: 50, count: 19200)
        XCTAssertNil(zone.update(plain, time: 0)); XCTAssertNil(zone.update([Float](repeating: 80, count: 19200), time: 0.1))
        var seed: UInt32 = 160
        let patch = (0..<900).map { _ -> Float in seed = 1664525 &* seed &+ 1013904223; return Float(20 + seed % 210) }
        func picture(_ offset: Int) -> [Float] { var pixels = plain; for y in 0..<30 { for x in 0..<30 { pixels[(40 + y) * 160 + 30 + x + offset] = patch[y * 30 + x] } }; return pixels }
        zone.reset(); XCTAssertNil(zone.update(picture(0), time: 0))
        let tracked = zone.update(picture(2), time: 0.1); XCTAssertNotNil(tracked)
        let next = zone.update(picture(4), time: 0.2); XCTAssertNotNil(next)
        if let tracked, let next { XCTAssertEqual(next.x - tracked.x, 2.0 / 160, accuracy: 0.001) }
        XCTAssertNil(zone.update(plain, time: 0.3)); XCTAssertNil(zone.update(plain, time: 1.6))
    }

    func testPiPRemainsInItsCornerWhenResizedOnAnyDisplay() {
        for display in [CGRect(x: 0, y: 24, width: 1440, height: 850), CGRect(x: -1280, y: -500, width: 1280, height: 700), CGRect(x: 0, y: 0, width: 280, height: 500)] {
            for corner in PanelCorner.allCases {
                for height in [240.0, 428.0, 552.0, 740.0, 900.0] {
                    let frame = corner.frame(size: CGSize(width: 320, height: height), visible: display)
                    XCTAssertTrue(display.contains(frame))
                    if corner == .upperLeft || corner == .lowerLeft { XCTAssertEqual(frame.minX, display.minX + 16) }
                    else { XCTAssertEqual(frame.maxX, display.maxX - 16) }
                    if corner == .upperLeft || corner == .upperRight { XCTAssertEqual(frame.maxY, display.maxY - 16) }
                    else { XCTAssertEqual(frame.minY, display.minY + 16) }
                }
            }
        }
    }
    func testTargetedWindowsFieldsAndNativeActions() {
        for phrase in ["abre nueva ventana de Chrome", "abre una nueva ventana de Chrome", "crear ventana nueva en Chrome", "abre ventana de Chrome", "nueva ventana de Chrome", "abre otra ventana de Chrome"] { XCTAssertEqual(CommandParser.parse(phrase), .appShortcut("Chrome", "nueva_ventana")) }
        XCTAssertEqual(CommandParser.parse("abre una nueva pestaña en Safari"), .appShortcut("Safari", "nueva_pestana"))
        XCTAssertEqual(CommandParser.parse("abre Chrome en nueva ventana"), .open("Chrome", "ventana"))
        XCTAssertEqual(CommandParser.parse("guardar en TextEdit"), .appShortcut("TextEdit", "guardar"))
        XCTAssertEqual(CommandParser.parse("escribe Hola, José. en el campo Nombre"), .writeField("Hola, José.", "Nombre"))
        XCTAssertEqual(CommandParser.parse("escribe en el campo Nombre el texto Perú 😀"), .writeField("Perú 😀", "Nombre"))
        XCTAssertEqual(CommandParser.parse("selecciona el texto Buenos días"), .selectText("Buenos días"))
        XCTAssertEqual(CommandParser.parse("selecciona todo"), .shortcut("seleccionar_todo"))
        XCTAssertEqual(CommandParser.parse("muestra campos"), .listFields)
        XCTAssertEqual(CommandParser.parse("qué puedo hacer"), .listActions)
        XCTAssertEqual(CommandParser.parse("ejecuta la acción Exportar PDF"), .menu("Exportar PDF"))
        XCTAssertEqual(CommandParser.parse("presiona comando shift N"), .keyChord("comando shift N"))
        XCTAssertEqual(CommandParser.parse("presiona copiar"), .shortcut("copiar"))
        XCTAssertEqual(CommandParser.parse("mostrar escritorio"), .shortcut("escritorio"))
    }
    func testChoicesExpireAndRequireUniqueNamesOrValidNumbers() {
        let prompt = ChoicePrompt(labels: ["Nombre", "Correo", "Correo"], expiresAt: 45)
        XCTAssertEqual(prompt.index("la opción dos", at: 1), 1)
        XCTAssertEqual(prompt.index("elige la tercera", at: 1), 2)
        XCTAssertEqual(prompt.index("Nombre", at: 1), 0)
        XCTAssertNil(prompt.index("Correo", at: 1))
        XCTAssertNil(prompt.index("0", at: 1))
        XCTAssertNil(prompt.index(String(Int.min), at: 1))
        XCTAssertNil(prompt.index("4", at: 1))
        XCTAssertNil(prompt.index("1", at: 45))
        XCTAssertEqual(CommandParser.parse("selecciona la segunda"), .choose("la segunda"))
        var input = VoiceInputState()
        XCTAssertEqual(input.consume("la segunda", wakeWord: "computadora", time: 1, followUp: true).command, "la segunda")
        input.beginUtterance()
        XCTAssertNil(input.consume("la segunda", wakeWord: "computadora", time: 2).command)
        XCTAssertNil(input.consume("la segunda", wakeWord: "computadora", time: 3, speaking: true, followUp: true).command)
        XCTAssertEqual(input.consume("cancelar", wakeWord: "computadora", time: 4, followUp: true).command, "cancelar")
    }
    func testKeyboardChordsAreBoundedAndNeverInventUnknownKeys() {
        XCTAssertEqual(KeyChord.parse("comando más shift más n"), KeyChord(code: 45, flags: [.maskCommand, .maskShift]))
        XCTAssertEqual(KeyChord.parse("control + option + arriba"), KeyChord(code: 126, flags: [.maskControl, .maskAlternate]))
        XCTAssertEqual(KeyChord.parse("F11"), KeyChord(code: 103, flags: []))
        XCTAssertEqual(KeyChord.parse("comando y"), KeyChord(code: 16, flags: .maskCommand))
        for invalid in ["", "comando", "comando n t", "comando desconocida", "ejecuta rm"] { XCTAssertNil(KeyChord.parse(invalid)) }
    }
    @MainActor
    func testChoiceCancellationNeverRunsPendingAction() {
        let actions = ActionManager.shared
        var result: Int?
        actions.presentChoices(["Uno", "Dos"]) { result = $0 }
        XCTAssertTrue(actions.hasChoices)
        actions.choose("dos")
        XCTAssertEqual(result, 1)
        XCTAssertFalse(actions.hasChoices)
        result = nil
        actions.presentChoices(["Uno", "Dos"]) { result = $0 }
        actions.procesarIntencion("cancelar")
        XCTAssertNil(result)
        XCTAssertTrue(actions.choices.isEmpty)
        XCTAssertFalse(actions.hasChoices)
        actions.callar()
    }
    func testCommandsPreserveDictationAndSearch() {
        XCTAssertEqual(CommandParser.parse("Computadora"), .unknown("Computadora"))
        XCTAssertEqual(CommandParser.parse("Escribe Hola, José. ¡Buenos días!"), .dictate("Hola, José. ¡Buenos días!"))
        XCTAssertEqual(CommandParser.parse("Busca arriba y abajo en YouTube"), .search("arriba y abajo", "youtube", "actual"))
        XCTAssertEqual(CommandParser.parse("busca en Wikipedia Perú"), .search("Perú", "wikipedia", "actual"))
        XCTAssertEqual(CommandParser.parse("Abre YouTube en nueva pestaña"), .open("YouTube", "pestana"))
        XCTAssertEqual(CommandParser.parse("haz clic en Contacto"), .press("Contacto"))
        XCTAssertEqual(CommandParser.parse("clic derecho"), .kinetic("derecho"))
        XCTAssertEqual(CommandParser.parse("activar temblor"), .kinetic("temblor"))
        XCTAssertEqual(CommandParser.parse("desactivar temblor"), .kinetic("sin_temblor"))
        XCTAssertEqual(CommandParser.parse("nueva pestaña"), .shortcut("nueva_pestana"))
        XCTAssertNil(VoiceSite.match("Netflix x"))
        XCTAssertEqual(VoiceSite.match("equis")?.id, "x")
        XCTAssertEqual(VoiceSite.match("google")?.url(query: "A&B #Perú")?.query, "q=A%26B%20%23Per%C3%BA")
        XCTAssertTrue(VoiceSite.match("instagram")?.url(query: "arte")?.absoluteString.contains("site%3Awww.instagram.com") == true)
    }

    func testWakeWordBoundaryAndEightSecondWindow() {
        var state = WakePhraseState()
        XCTAssertNil(state.consume("microcomputadora abre Safari", wakeWord: "computadora", time: 0).command)
        XCTAssertTrue(state.consume("Computadora", wakeWord: "computadora", time: 1).beep)
        XCTAssertEqual(state.consume("Escribe Hola, José", wakeWord: "computadora", time: 8.9).command, "Escribe Hola, José")
        XCTAssertNil(state.consume("abre Safari", wakeWord: "computadora", time: 9).command)
        XCTAssertTrue(state.consume("Computadora", wakeWord: "computadora", time: 10).beep)
        XCTAssertNil(state.consume("abre Safari", wakeWord: "computadora", time: 18.01).command)
        XCTAssertEqual(state.consume("Computadora, escribe Hola, José. ¡Sí!", wakeWord: "computadora", time: 19).command, "escribe Hola, José. ¡Sí!")
        XCTAssertEqual(state.consume("Jarvis, abre Safari", wakeWord: "Jarvis", time: 20).command, "abre Safari")
    }

    func testCalibrationDwellAndLossAtDifferentFrameRates() {
        for fps in [15.0, 30.0, 60.0] {
            var state = KineticState()
            var time = 0.0
            var clicks = 0
            func feed(_ point: CGPoint, seconds: Double, target: String? = "button") {
                let count = Int((seconds * fps).rounded())
                for _ in 0..<count {
                    time += 1 / fps
                    let result = state.update(point, time: time, target: target)
                    if result.click { clicks += 1 }
                }
            }
            let neutral = CGPoint(x: 0.2, y: 0.7)
            feed(neutral, seconds: 3)
            XCTAssertNotNil(state.origin, "fps \(fps)")
            XCTAssertEqual(clicks, 0, "No debe hacer clic al calibrar")
            feed(CGPoint(x: 0.5, y: 0.7), seconds: 1)
            feed(neutral, seconds: 2)
            XCTAssertEqual(clicks, 1, "fps \(fps)")
            feed(neutral, seconds: 3)
            XCTAssertEqual(clicks, 1, "Un clic por entrada")
            feed(CGPoint(x: 0.5, y: 0.7), seconds: 1)
            state.lost(at: time + 1.3)
            XCTAssertNil(state.origin)
            feed(neutral, seconds: 2)
            XCTAssertEqual(clicks, 1, "Pérdida exige recalibración sin clic")
        }
    }

    func testMovementIsFrameRateIndependentAndInvalidSamplesCannotClick() {
        var distances: [Double] = []
        for fps in [15.0, 30.0, 60.0] {
            var state = KineticState(), time = 0.0, distance = 0.0
            for _ in 0..<Int(fps * 2) { time += 1 / fps; _ = state.update(CGPoint(x: 0.5, y: 0.5), time: time, target: nil) }
            for _ in 0..<Int(fps * 2) {
                time += 1 / fps
                distance += state.update(CGPoint(x: 0.7, y: 0.5), time: time, target: nil).delta.x
            }
            distances.append(distance)
            XCTAssertFalse(state.update(CGPoint(x: Double.nan, y: 0), time: time + 0.1, target: "button").click)
        }
        XCTAssertLessThan((distances.max()! - distances.min()!) / distances.max()!, 0.08)
    }

    func testCalibrationRejectsMovingPostureAndClickNeedsTarget() {
        var state = KineticState()
        for index in 0..<40 { _ = state.update(CGPoint(x: 0.1 + Double(index) * 0.006, y: 0.5), time: Double(index) / 30, target: "button") }
        XCTAssertNil(state.origin)
        state.calibrate()
        for index in 0..<45 { _ = state.update(CGPoint(x: 0.5, y: 0.5), time: Double(index) / 30, target: nil) }
        XCTAssertNotNil(state.origin)
        for index in 45..<100 { XCTAssertFalse(state.update(CGPoint(x: 0.5, y: 0.5), time: Double(index) / 30, target: nil).click) }
    }

    func testUnicodeEventsNeverSplitEmojiOrEmitEmptyChunk() {
        for text in ["", "Hola, José", String(repeating: "a", count: 19) + "😀", String(repeating: "👩🏽‍💻", count: 15)] {
            let chunks = DesktopAccess.unicodeChunks(text)
            XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.count <= 20 })
            XCTAssertEqual(chunks.map { String(decoding: $0, as: UTF16.self) }.joined(), text)
        }
    }

    func testColorMatricesMatchExtension() {
        XCTAssertEqual(ColorFilter.allCases.count, 8)
        for filter in ColorFilter.allCases { XCTAssertEqual(filter.matrix.count, 9); for row in 0..<3 { XCTAssertEqual(filter.matrix[(row * 3)..<(row * 3 + 3)].reduce(0, +), 1, accuracy: 0.0001) } }
        XCTAssertEqual(ColorFilter.protanopia.matrix, [0.567,0.433,0, 0.558,0.442,0, 0,0.242,0.758])
    }
    func testSynonymsMatchingAndMonitorPlacement() {
        for verb in ["Abre", "abrir", "ejecutar", "muestra", "mostrar", "lanza", "iniciar"] {
            XCTAssertEqual(CommandParser.parse(verb + " visual studio code"), .open("visual studio code", "actual"))
        }
        for phrase in ["anticlick", "anti click", "dar anticlick", "hacer clic derecho", "dar click derecho"] { XCTAssertEqual(CommandParser.parse(phrase), .kinetic("derecho")) }
        XCTAssertEqual(CommandParser.parse("presionar Contacto"), .press("Contacto"))
        XCTAssertEqual(CommandParser.parse("dar clic en Contacto"), .press("Contacto"))
        XCTAssertEqual(CommandParser.parse("leer la pantalla"), .readScreen)
        XCTAssertEqual(CommandParser.parse("leer el botón Contacto"), .readElement("Contacto"))
        XCTAssertEqual(CommandParser.parse("seleccionar el botón Contacto"), .select("Contacto"))
        for suffix in ["en el segundo monitor", "en el monitor dos", "en la pantalla 2"] {
            let (name, monitor) = CommandParser.monitorTarget("Visual Studio Code " + suffix)
            XCTAssertEqual(name, "Visual Studio Code"); XCTAssertEqual(monitor, 1)
        }
        XCTAssertNil(CommandParser.monitorTarget("zoom en el monitor cero").1)
        XCTAssertEqual(NameMatch.uniqueIndex("VISUAL estudio code", names: [["Visual Studio Code"], ["Zoom"]]), 0)
        XCTAssertEqual(NameMatch.uniqueIndex("zom", names: [["Zoom"]]), nil, "Nombres muy cortos no se infieren")
        XCTAssertNil(NameMatch.uniqueIndex("casa", names: [["casa"], ["casa"]]), "Nunca decidir un empate")
        XCTAssertEqual(NameMatch.uniqueIndex("calculador", names: [["Calculadora"], ["Calendar"]]), 0)
        XCTAssertEqual(ApplicationCatalog.aliases["zoom"], "us.zoom.xos")
        XCTAssertEqual(ApplicationCatalog.aliases["visual studio code"], "com.microsoft.VSCode")
    }
    func testAudioPacketsRequireValidNonEmptyPCM() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        var description: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: format.streamDescription, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description), noErr)
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 320))
        pcm.frameLength = 320
        for i in 0..<320 { pcm.floatChannelData?[0][i] = 0.25 }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 16_000), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: nil, formatDescription: description, sampleCount: 320, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample), noErr)
        let valid = try XCTUnwrap(sample)
        XCTAssertNil(VoiceManager.pcmBuffer(valid), "Formato válido sin datos no se envía a Speech")
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(valid, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList), noErr)
        let copied = try XCTUnwrap(VoiceManager.pcmBuffer(valid))
        XCTAssertEqual(copied.frameLength, 320)
        XCTAssertEqual(copied.floatChannelData?[0][100], 0.25)
        CMSampleBufferInvalidate(valid)
        XCTAssertNil(VoiceManager.pcmBuffer(valid))
    }
    func testGentleKineticSpeedCap() {
        var state = KineticState()
        for i in 0..<60 { _ = state.update(CGPoint(x: 0.5, y: 0.5), time: Double(i) / 30, target: nil) }
        var step = CGPoint.zero
        for i in 60..<120 { step = state.update(CGPoint(x: 0.62, y: 0.5), time: Double(i) / 30, target: nil).delta }
        XCTAssertGreaterThan(step.x, 0)
        XCTAssertLessThan(step.x * 30, 80, "Desplazamiento pequeño exige precisión")
        for i in 120..<180 { step = state.update(CGPoint(x: 1, y: 0.5), time: Double(i) / 30, target: nil).delta }
        XCTAssertLessThanOrEqual(step.x * 30, 481)
    }

    @MainActor
    func testStopDistinguishesSuspensionFromUserIntent() {
        let defaults = UserDefaults.standard
        let oldVoice = defaults.object(forKey: "VoiceActive"), oldCamera = defaults.object(forKey: "CameraActive")
        defer {
            defaults.set(oldVoice, forKey: "VoiceActive"); defaults.set(oldCamera, forKey: "CameraActive")
        }
        let voice = VoiceManager(), tracker = TrackingManager()
        defaults.set(true, forKey: "VoiceActive"); defaults.set(true, forKey: "CameraActive")
        voice.stopListening(remember: false); tracker.stopTracking(remember: false)
        XCTAssertTrue(defaults.bool(forKey: "VoiceActive")); XCTAssertTrue(defaults.bool(forKey: "CameraActive"))
        voice.stopListening(); tracker.stopTracking()
        XCTAssertFalse(defaults.bool(forKey: "VoiceActive")); XCTAssertFalse(defaults.bool(forKey: "CameraActive"))
    }

    func testWholeTranscriptionsSurviveCorrectionsAndRepeatedWakeCycles() {
        var input = VoiceInputState()
        XCTAssertNil(input.consume("Abre", wakeWord: "computadora", time: 0).command)
        XCTAssertTrue(input.consume("Computadora.", wakeWord: "computadora", time: 1).beep)
        input.beginUtterance()
        XCTAssertNil(input.consume("Abre", wakeWord: "computadora", time: 1.4).command)
        let command = input.consume("Abre Google Chrome", wakeWord: "computadora", time: 2).command
        XCTAssertEqual(command, "Abre Google Chrome")
        XCTAssertEqual(command.map(CommandParser.parse), .open("Google Chrome", "actual"))
        XCTAssertNil(input.consume("Abre Google Chrome.", wakeWord: "computadora", time: 2.1).command, "Una orden por tarea")
        input.beginUtterance()
        XCTAssertTrue(input.consume("Computadora", wakeWord: "computadora", time: 3).beep)
        input.beginUtterance()
        XCTAssertEqual(input.consume("Abre Chrome", wakeWord: "computadora", time: 4).command, "Abre Chrome")
        input.beginUtterance()
        XCTAssertEqual(input.consume("Computadora abre Zoom", wakeWord: "computadora", time: 5).command, "abre Zoom")
        input.beginUtterance()
        XCTAssertNil(input.consume("abre Safari", wakeWord: "computadora", time: 6).command, "No ejecutar ambiente sin activación")
    }
    func testWakeCanInterruptSpeechWithoutExecutingItsEcho() {
        var input = VoiceInputState()
        XCTAssertNil(input.consume("computadora abre Chrome", wakeWord: "computadora", time: 0, speaking: true).command)
        XCTAssertTrue(input.consume("computadora", wakeWord: "computadora", time: 1, speaking: true).beep)
        input.beginUtterance()
        XCTAssertEqual(input.consume("abre Chrome", wakeWord: "computadora", time: 2).command, "abre Chrome")
        input.beginUtterance()
        XCTAssertEqual(input.consume("computadora silencio.", wakeWord: "computadora", time: 3, speaking: true).command, "silencio.")
        input.beginUtterance()
        XCTAssertTrue(input.consume("computadora", wakeWord: "computadora", time: 4).beep)
        input.beginUtterance()
        XCTAssertNil(input.consume("abre Zoom", wakeWord: "computadora", time: 12.1).command)
        input.cancel()
    }
    func testPartialAppNamesAreUniqueAndNeverUsedForControls() {
        let names = [["Visual Studio Code"], ["Google Chrome"], ["Zoom Workplace"]]
        XCTAssertEqual(NameMatch.uniqueIndex("studio", names: names, allowPartial: true), 0)
        XCTAssertEqual(NameMatch.uniqueIndex("workplace", names: names, allowPartial: true), 2)
        XCTAssertEqual(NameMatch.uniqueIndex("chro", names: names, allowPartial: true), nil)
        XCTAssertNil(NameMatch.uniqueIndex("studio", names: names), "Los controles AX no usan coincidencia parcial de apps")
        XCTAssertNil(NameMatch.uniqueIndex("studio", names: [["Visual Studio"], ["Visual Studio Code"]], allowPartial: true))
        XCTAssertEqual(NameMatch.uniqueIndex("studio", names: [["Studio"], ["Visual Studio Code"]], allowPartial: true), 0, "El nombre completo tiene prioridad")
    }

    @MainActor
    func testInstalledChromeAndZoomAliasesResolve() async {
        for (name, identifier) in [("Abre Google Chrome", "com.google.Chrome"), ("Abre Chrome", "com.google.Chrome"), ("Abre Zoom", "us.zoom.xos"), ("Abre Visual Studio Code", "com.microsoft.VSCode")] {
            guard let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else { continue }
            guard case .open(let target, _) = CommandParser.parse(name) else { XCTFail("Comando no reconocido: " + name); continue }
            let resolved: URL? = await withCheckedContinuation { continuation in
                ApplicationCatalog.shared.resolve(target) { continuation.resume(returning: $0) }
            }
            XCTAssertEqual(resolved?.standardizedFileURL, installed.standardizedFileURL)
        }
    }

    @MainActor func testOptionalAIEndpointChangeDownloadLimitAndRedirects() async {
        let suite = "cc.adaptape.optional-ai-test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OptionalAIStubProtocol.self]
        let session = URLSession(configuration: configuration)
        // Proveedor simulado: sin red ni claves reales.
        var key = "", deletionAllowed = true
        let ai = OptionalAI(defaults: defaults, session: session, readKey: { key }, deleteKey: {
            guard deletionAllowed else { return false }
            key = ""; return true
        })
        ai.endpoint = "https://ejemplo.test/v1/chat/completions"
        ai.isEnabled = true; ai.model = "modelo-prueba"; key = "clave-falsa-de-prueba"; ai.allowScreenUpload = true
        OptionalAIStubProtocol.reply = { _ in nil }
        ai.ask("hola")
        XCTAssertTrue(ai.isBusy)
        // Cambiar de destino cancela la consulta, borra la clave y revoca el envío de pantalla.
        ai.endpoint = "https://otro.test/v1/chat/completions"
        XCTAssertTrue(key.isEmpty); XCTAssertFalse(ai.allowScreenUpload); XCTAssertFalse(ai.isBusy)
        XCTAssertEqual(defaults.string(forKey: "AIEndpoint"), "https://otro.test/v1/chat/completions")
        // Si el llavero no borra la clave, se conserva el destino anterior.
        deletionAllowed = false; key = "clave-falsa-de-prueba"
        ai.endpoint = "https://rechazado.test/v1/chat/completions"
        XCTAssertEqual(ai.endpoint, "https://otro.test/v1/chat/completions")
        XCTAssertEqual(defaults.string(forKey: "AIEndpoint"), ai.endpoint)
        XCTAssertEqual(key, "clave-falsa-de-prueba"); XCTAssertTrue(ai.status.contains("conserva"))
        // HTTP sólo en loopback real.
        for valid in ["https://ejemplo.test/v1/chat/completions", "http://localhost:11434/v1/chat/completions",
                      "http://127.12.34.56:8080/v1", "http://[::1]:8080/v1"] {
            XCTAssertNotNil(OptionalAI.compatibleEndpoint(valid), valid)
        }
        for invalid in ["http://ejemplo.test/v1", "http://localhost.evil.com/v1", "http://127.0.0.1.evil.com/v1", "http://127.256.0.1/v1",
                        "http://128.0.0.1/v1", "https://ejemplo.test/v1?key=x", "https://usuario:clave@ejemplo.test/v1", "ftp://localhost/v1"] {
            XCTAssertNil(OptionalAI.compatibleEndpoint(invalid), invalid)
        }
        // El límite se aplica durante la descarga, aunque falte Content-Length.
        let request = URLRequest(url: URL(string: "https://ejemplo.test/v1")!)
        OptionalAIStubProtocol.reply = { _ in (200, Data(repeating: 97, count: OptionalAI.maxResponseBytes + 4_000)) }
        if case .failure(let error) = await OptionalAI.fetch(request, session: session) {
            XCTAssertEqual((error as? URLError)?.code, .dataLengthExceedsMaximum)
        } else { XCTFail("Una respuesta mayor de 64 KiB debe rechazarse") }
        OptionalAIStubProtocol.reply = { _ in (200, Data("{}".utf8)) }
        if case .success(let (data, http)) = await OptionalAI.fetch(request, session: session) {
            XCTAssertEqual(data, Data("{}".utf8)); XCTAssertEqual(http.statusCode, 200)
        } else { XCTFail("Una respuesta pequeña debe llegar completa") }
        // La política nunca sigue redirecciones.
        let redirect = URL(string: "http://otro.test/v1")!
        var followed: URLRequest? = URLRequest(url: redirect)
        OptionalAIRedirectPolicy().urlSession(session, task: session.dataTask(with: redirect),
            willPerformHTTPRedirection: HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: nil, headerFields: nil)!,
            newRequest: URLRequest(url: redirect)) { followed = $0 }
        XCTAssertNil(followed)
        OptionalAIStubProtocol.reply = nil
    }
}

/// Proveedor simulado para OptionalAI: responde sin red; `nil` deja la petición en vuelo.
final class OptionalAIStubProtocol: URLProtocol {
    nonisolated(unsafe) static var reply: ((URLRequest) -> (Int, Data)?)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let (code, data) = Self.reply?(request) else { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

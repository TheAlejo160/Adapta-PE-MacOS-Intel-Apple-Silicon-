import XCTest
import AVFoundation
import CoreMedia
import AppKit
@testable import Adapta_PE

final class Adapta_PETests: XCTestCase {
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

}

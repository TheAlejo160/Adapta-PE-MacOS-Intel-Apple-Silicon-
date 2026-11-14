import XCTest
import CryptoKit
@testable import Adapta_PE

final class CatalogParityTests: XCTestCase {
    struct Fixture: Decodable { let idioma: String, texto: String, canonica: String }
    func testAll36SharedVoiceCasesAndIntents() throws {
        let url = try XCTUnwrap(VoiceCatalog.resource("voz-paridad"))
        let cases = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        XCTAssertEqual(cases.count, 36)
        let catalog = try VoiceCatalog.load()
        let intents: [String: VoiceCommand] = [
            "abre YouTube": .open("YouTube", "actual"), "": .unknown(""),
            "escribe Hola, ¡Perú!": .dictate("Hola, ¡Perú!"), "selecciona Mi Cuenta": .select("Mi Cuenta"),
            "escribe Hello, ¡Perú!": .dictate("Hello, ¡Perú!"), "escribe Olá, ¡Perú!": .dictate("Olá, ¡Perú!"),
            "escribe Hallo, ¡Perú!": .dictate("Hallo, ¡Perú!"), "escribe Bonjour, ¡Perú!": .dictate("Bonjour, ¡Perú!"),
            "escribe Ciao, ¡Perú!": .dictate("Ciao, ¡Perú!"), "busca hide pet en YouTube": .search("hide pet", "youtube", "actual"),
            "mascota Y Atti": .mascot("yati"), "saluda mascota": .mascot("wave"),
            "duerme mascota": .mascot("sleep"), "despierta mascota": .mascot("wake"),
            "cancelar clic": .kinetic("cancelar"), "reanudar cursor": .kinetic("reanudar")
        ]
        for fixture in cases {
            let actual = catalog.prepare(fixture.texto, language: fixture.idioma)
            XCTAssertEqual(actual, fixture.canonica, fixture.texto)
            XCTAssertEqual(catalog.prepare(actual, language: fixture.idioma), actual, fixture.texto)
            XCTAssertEqual(CommandParser.parse(actual), try XCTUnwrap(intents[fixture.canonica]), fixture.texto)
        }
    }
    struct ActivationFixture: Decodable {
        struct Activation: Decodable { let nombre: String, texto: String, activa: Bool; let alias: [String]?, idioma: String?, tambienComputadora: Bool?, canonica: String?, sitio: String?, esperando: Bool? }
        struct Tolerance: Decodable { let idioma: String, texto: String, corregida: String?, repetir: Bool; let query: String?, sitio: String?, intencion: String? }
        struct Site: Decodable { let idioma: String, texto: String, sitio: String?; let anuncio: String? }
        struct Confirmation: Decodable { let texto: String, accion: String, caducidadMs: Int, plazoDesde: String }
        struct Cancel: Decodable { let idioma: String, texto: String }
        struct Conversation: Decodable { let resultado: String, modo: Bool, tts: String, renueva: Bool }
        let activacion: [Activation], tolerancia: [Tolerance], sitios: [Site], confirmacion: [Confirmation], cancelacion: [Cancel], conversacion: [Conversation]
        let cierres: [String], contenido: [String]
    }
    // Todos los casos del contrato 1A, igual que tests/voz.test.cjs en la extensión.
    func testActivationParityFixture() throws {
        let fixture = try JSONDecoder().decode(ActivationFixture.self, from: Data(contentsOf: XCTUnwrap(VoiceCatalog.resource("activacion-paridad"))))
        XCTAssertEqual(fixture.activacion.count, 29)
        for item in fixture.activacion {
            var wake = WakePhraseState()
            let language = item.idioma ?? "es-PE"
            if item.esperando == true { XCTAssertTrue(wake.consume(item.nombre.isEmpty ? "Computadora" : item.nombre, wakeWord: item.nombre, time: 0, language: language, aliases: item.alias ?? []).beep, item.texto) }
            let command = wake.consume(item.texto, wakeWord: item.nombre, time: 1, language: language, aliases: item.alias ?? [], alsoComputer: item.tambienComputadora ?? false).command
            if item.esperando == true { XCTAssertEqual(command, item.canonica, item.texto); continue }
            XCTAssertEqual(VoiceActivation.end(in: item.texto, name: item.nombre, language: language, aliases: item.alias ?? [], alsoComputer: item.tambienComputadora ?? false) != nil, item.activa, "\(item.nombre): \(item.texto)")
            if let canonica = item.canonica { XCTAssertEqual(command, canonica, item.texto) }
            if let site = item.sitio, let command { XCTAssertEqual(CommandParser.parse(command), .open("YouTube", "actual")); XCTAssertEqual(VoiceSite.match("YouTube")?.id, site) }
        }
        for item in fixture.tolerancia {
            let correction = VoiceTolerance.correct(item.texto, language: item.idioma)
            let expected: VoiceTolerance.Correction? = item.repetir ? .repeatCommand : item.corregida.map { .text($0) }
            XCTAssertEqual(correction, expected, item.texto)
            guard let fixed = item.corregida else { continue }
            let prepared = CommandParser.prepare(fixed, language: item.idioma)
            if let query = item.query { XCTAssertEqual(CommandParser.parse(prepared), .search(query, item.sitio, "actual"), item.texto) }
            else { XCTAssertEqual(CommandParser.parse(prepared), .shortcut("recargar"), item.texto) }
        }
        for item in fixture.sitios {
            guard case .open(let name, _) = CommandParser.parse(item.texto) else { return XCTFail(item.texto) }
            let site = VoiceTolerance.site(name, language: item.idioma)
            XCTAssertEqual(site, item.sitio, item.texto)
            if let site, let anuncio = item.anuncio { XCTAssertEqual(VoiceTolerance.announcement(site: site, language: item.idioma), anuncio) }
        }
        for item in fixture.confirmacion {
            XCTAssertEqual(CommandParser.parse(item.texto), .shortcut(item.accion), item.texto)
            XCTAssertEqual(VoiceConfirmation.known(item.accion), item.accion)
            XCTAssertEqual(Double(item.caducidadMs) / 1000, VoiceConfirmation.timeout)
            XCTAssertEqual(item.plazoDesde, "fin_tts")
        }
        let tab = VoiceConfirmation(action: "cerrar_pestana", destination: "Safari ventana 7", pid: 3, expiresAt: 8, language: "es")
        XCTAssertEqual(tab.phrase, "confirmo cerrar esta pestaña")
        XCTAssertTrue(tab.accepts("Confirmo cerrar esta pestaña.", pid: 3, time: 1))
        XCTAssertFalse(tab.accepts("confirmo cerrar ventana", pid: 3, time: 1))
        XCTAssertTrue(VoiceConfirmation(action: "cerrar_ventana", destination: "", pid: 3, expiresAt: 8, language: "de").accepts("bestätige Fenster schliessen", pid: 3, time: 1))
        for item in fixture.cancelacion {
            XCTAssertEqual(CommandParser.parse(CommandParser.prepare(item.texto, language: item.idioma)), .cancel, item.texto)
            var input = VoiceInputState()
            XCTAssertEqual(input.consume(item.texto, wakeWord: "Jarvis", time: 0, confirming: true, language: item.idioma).command, item.texto)
        }
        var input = VoiceInputState()
        XCTAssertNil(input.consume("abre YouTube", wakeWord: "Jarvis", time: 0, confirming: true).command, "sin nombre, sólo confirmar o cancelar")
        let results: [String: VoiceExecutionResult] = ["ok": .ok, "fallo": .failure, "desconocida": .unknown, "confirmando": .confirming]
        for item in fixture.conversacion {
            for lateStart in [false, true] {
                var conversation = VoiceConversation(); conversation.enabled = item.modo
                conversation.begin()
                let result = try XCTUnwrap(results[item.resultado])
                if lateStart { conversation.receive(result, at: 1); conversation.speech(starting: true, at: 2) }
                else { conversation.speech(starting: true, at: 1); conversation.receive(result, at: 2) }
                conversation.speech(starting: false, at: 3, failed: item.tts != "end")
                XCTAssertEqual(conversation.state == .waiting, item.renueva, "\(item) tardío: \(lateStart)")
                if item.renueva {
                    XCTAssertEqual(conversation.waitingUntil, 11)
                    conversation.speech(starting: true, at: 4); conversation.speech(starting: false, at: 5)
                    XCTAssertNotEqual(conversation.state, .waiting, "una lectura ajena no renueva")
                }
            }
        }
        var released = VoiceConversation(); released.enabled = true
        released.speech(starting: true, at: 0); released.tick(at: 60)
        XCTAssertEqual(released.state, .inactive)
        for text in fixture.cierres { XCTAssertTrue(VoiceConversation.closes(text, language: "es"), text) }
        for text in fixture.contenido { XCTAssertFalse(VoiceConversation.closes(text, language: "es"), text) }
        var closing = VoiceInputState()
        XCTAssertEqual(closing.consume("Jarvis, gracias", wakeWord: "Jarvis", time: 0).command, "gracias")
    }
    func testNameTrialCapturesOnceAndExpires() {
        var trial = VoiceNameTrial()
        trial.start(at: 0)
        XCTAssertEqual(trial.capture("yarbis", at: 1), "yarbis")
        XCTAssertNil(trial.capture("abre YouTube", at: 2))
        trial.start(at: 10)
        XCTAssertFalse(trial.expired(at: 24.9))
        XCTAssertTrue(trial.expired(at: 25))
        XCTAssertNil(trial.capture("Jarvis cierra esta pestaña", at: 25.1))
        XCTAssertNotNil(VoiceActivation.aliases(["yarbis"], name: "Jarvis"))
        XCTAssertNil(VoiceActivation.aliases(["a", "b", "c", "d"], name: "Jarvis"))
        XCTAssertNil(VoiceActivation.aliases(["Jarvis"], name: "Jarvis"))
        let strings = VoiceActivation.contextualStrings(name: "Computadora", aliases: ["Jarvis"], alsoComputer: false, language: "en-US")
        XCTAssertTrue(["Computadora", "Computer", "Jarvis", "yarbis"].allSatisfy(strings.contains), strings.description)
    }
    func testPackagedResourcesMatchExtensionSHA256WhenPresent() throws {
        // En AdaptaPE-Suite la extensión Base está en extensiones-web/base, junto a macos/.
        let extensionRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("extensiones-web/base")
        guard FileManager.default.fileExists(atPath: extensionRoot.path) else { throw XCTSkip("Extensión no disponible en este equipo") }
        for (name, relative) in [("nativo-v1", "catalogos/nativo-v1.json"), ("voz-paridad", "tests/fixtures/voz-paridad.json"), ("activacion-paridad", "tests/fixtures/activacion-paridad.json")] {
            let original = try Data(contentsOf: extensionRoot.appendingPathComponent(relative))
            let packaged = try Data(contentsOf: XCTUnwrap(VoiceCatalog.resource(name)))
            XCTAssertEqual(SHA256.hash(data: original), SHA256.hash(data: packaged), name)
        }
    }
    func testPackagedFixturesMatchCatalogManifest() throws {
        let catalog = try VoiceCatalog.load()
        for name in ["voz-paridad", "activacion-paridad"] {
            let data = try Data(contentsOf: XCTUnwrap(VoiceCatalog.resource(name)))
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(digest, catalog.origen.sha256["tests/fixtures/\(name).json"])
        }
    }
    func testRejectsInvalidCatalogAndResolvesSystemLanguages() throws {
        let url = try XCTUnwrap(VoiceCatalog.resource("nativo-v1"))
        let source = try Data(contentsOf: url)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: source) as? [String: Any])
        json["schemaVersion"] = 90
        XCTAssertThrowsError(try VoiceCatalog.decode(JSONSerialization.data(withJSONObject: json)))
        json = try XCTUnwrap(JSONSerialization.jsonObject(with: source) as? [String: Any])
        var sites = try XCTUnwrap(json["sitios"] as? [String: Any])
        sites["google"] = ["alias": ["google"], "inicio": "file:///private/test"]
        json["sitios"] = sites
        XCTAssertThrowsError(try VoiceCatalog.decode(JSONSerialization.data(withJSONObject: json)))
        XCTAssertThrowsError(try VoiceCatalog.decode(Data("{}".utf8)))
        json = try XCTUnwrap(JSONSerialization.jsonObject(with: source) as? [String: Any])
        json["comportamiento"] = ["version": 90, "confirmacionMs": 8000]
        XCTAssertThrowsError(try VoiceCatalog.decode(JSONSerialization.data(withJSONObject: json)))
        XCTAssertEqual(VoiceCatalog.locale(preference: "auto", preferred: ["ja-JP", "fr-CA"]), "fr-CA")
        XCTAssertEqual(VoiceCatalog.locale(preference: "auto", preferred: ["ja-JP"]), "es-PE")
        XCTAssertEqual(VoiceCatalog.locale(preference: "de"), "de-DE")
        XCTAssertEqual(VoiceCatalog.locale(preference: "en-US"), "en-US")
    }
    func testMissingFamiliesAndPayloads() {
        let cases: [(String, VoiceCommand)] = [
            ("busca en YouTube", .search("", "youtube", "actual")),
            ("googlea Ají de gallina", .search("Ají de gallina", nil, "actual")),
            ("averigua sobre Perú", .search("sobre Perú", nil, "actual")),
            ("llévame a YouTube", .open("YouTube", "actual")), ("accede a Google", .open("Google", "actual")),
            ("muéstrame YouTube", .open("YouTube", "actual")), ("dirígete a Google", .open("Google", "actual")), ("pon YouTube", .open("YouTube", "actual")),
            ("pestaña 3", .shortcut("pestana:3")), ("última pestaña", .shortcut("pestana:9")),
            ("duplica la pestaña", .shortcut("duplicar_pestana")), ("cierra las otras pestañas", .shortcut("cerrar_otras")),
            ("silencia la pestaña", .shortcut("silenciar")), ("ayuda", .help),
            ("baja un poco", .shortcut("bajar:4")), ("sube bastante", .shortcut("subir:36")), ("baja del todo", .shortcut("final")),
            ("activa el cursor", .kinetic("activar")), ("apaga el cursor", .kinetic("desactivar")),
            ("calibra el cursor", .kinetic("calibrar")), ("pausa el cursor", .kinetic("pausar")), ("reanuda el cursor", .kinetic("reanudar")),
            ("da clic derecho", .kinetic("derecho")), ("hazle clic derecho", .kinetic("derecho")),
            ("envía el formulario", .shortcut("enter"))
        ]
        for (phrase, expected) in cases { XCTAssertEqual(CommandParser.parse(phrase), expected, phrase) }
        for phrase in ["calla", "cállate", "basta", "detente"] { XCTAssertEqual(CommandParser.parse(phrase), .silence, phrase) }
        for phrase in ["cancela eso", "olvida eso", "no importa", "déjalo", "deselecciona"] { XCTAssertEqual(CommandParser.parse(phrase), .cancel, phrase) }
        XCTAssertEqual(CommandParser.prepare("search hide pet on YouTube", language: "en"), "busca hide pet en YouTube")
        XCTAssertEqual(CommandParser.prepare("write Héllo,  José! thanks", language: "en"), "escribe Héllo,  José! thanks")
        XCTAssertEqual(CommandParser.prepare("open YouTube in a new tab", language: "en"), "abre YouTube en una nueva pestaña")
        XCTAssertEqual(CommandParser.parse("pestaña 10"), .unknown("pestaña 10"))
    }
    func testDestructiveApproximationNeverProducesAnAction() {
        for name in ["Eliminar", "Vaciar papelera", "Cerrar ventana", "Salir", "Enviar", "Delete", "Quit", "Fermer", "Excluir", "Chiudi", "Schließen"] {
            XCTAssertTrue(VoiceSafety.destructive(name), name)
            XCTAssertEqual(VoiceSafety.menuIndices(name, labels: [name]), [0])
            XCTAssertTrue(VoiceSafety.menuIndices(String(name.dropLast()), labels: [name]).isEmpty, name)
        }
        XCTAssertTrue(VoiceSafety.menuIndices("elminar", labels: ["Eliminar"]).isEmpty)
        XCTAssertEqual(VoiceSafety.menuIndices("Preferencia", labels: ["Preferencias", "Eliminar"]), [0])
        XCTAssertEqual(VoiceConfirmation.timeout, 8)
        let confirmation = VoiceConfirmation(action: "Eliminar", destination: "Finder · Pruebas", pid: 41, expiresAt: VoiceConfirmation.timeout)
        XCTAssertTrue(confirmation.accepts(confirmation.phrase, pid: 41, time: 7.9))
        for text in ["sí", "confirmar", "confirmar Eliminar", "confirmar Eliminar en Safari"] { XCTAssertFalse(confirmation.accepts(text, pid: 41, time: 1)) }
        XCTAssertFalse(confirmation.accepts(confirmation.phrase, pid: 42, time: 1))
        XCTAssertFalse(confirmation.accepts(confirmation.phrase, pid: 41, time: 8))
        XCTAssertFalse(confirmation.accepts(confirmation.phrase, pid: 41, time: .nan))
    }
    func testWakeNameValidationAndPosition() {
        for name in ["Jarvis", "Máquina Azul", "Computadora", "Hey Google"] { XCTAssertNil(WakeName.error(name), name) }
        for name in ["ab", "123", "ab3", "una dos tres cuatro", "abrir", "close", "borrar", "por favor", "Tinku", "hey", "Jarvis busca", "<Jarvis>"] { XCTAssertNotNil(WakeName.error(name), name) }
        for name in VoiceCatalog.shared?.activacion.reservadas.keys ?? Dictionary<String, String>().keys where name.count >= 3 {
            XCTAssertNotNil(WakeName.error(name), name)
        }
        var wake = WakePhraseState()
        XCTAssertNil(wake.consume("busca Jarvis en Wikipedia", wakeWord: "Jarvis", time: 0).command)
        XCTAssertEqual(wake.consume("oye Jarvis abre Safari", wakeWord: "Jarvis", time: 1).command, "abre Safari")
        XCTAssertNil(wake.consume("Pena abre Safari", wakeWord: "Peña", time: 2).command)
        XCTAssertEqual(wake.consume("Pen\u{303}a abre Safari", wakeWord: "Peña", time: 3).command, "abre Safari")
    }
    func testContinuousTranscriptConsumesOnlyNewAudio() {
        var stream = VoiceTranscriptState()
        let first = [VoiceTranscriptState.Segment(range: NSRange(location: 0, length: 11), start: 0, duration: 0.4)]
        XCTAssertEqual(stream.suffix("Computadora", segments: first), "Computadora")
        stream.commit(first)
        XCTAssertEqual(stream.suffix("Computadoras", segments: first), "")
        let next = first + [.init(range: NSRange(location: 12, length: 11), start: 0.8, duration: 0.5)]
        XCTAssertEqual(stream.suffix("Computadora Abre Safari", segments: next), "Abre Safari")
        stream.commit(next)
        XCTAssertEqual(stream.suffix("Computadora Abre Safari", segments: next), "")
        stream.reset()
        XCTAssertEqual(stream.suffix("Computadora", segments: first), "Computadora")
    }
    func testZeroDurationTranscriptCorrectionNeverReplaysACommand() {
        var stream = VoiceTranscriptState()
        let first = [VoiceTranscriptState.Segment(range: NSRange(location: 0, length: 11), start: 0, duration: 0)]
        stream.commit(first)
        XCTAssertEqual(stream.suffix("Computadoras", segments: first), "")
        let next = first + [.init(range: NSRange(location: 12, length: 11), start: 0.1, duration: 0)]
        XCTAssertEqual(stream.suffix("Computadora Abre Safari", segments: next), "Abre Safari")
        stream.commit(next)
        XCTAssertEqual(stream.suffix("Computadora Abre Safari", segments: next), "")
    }
}

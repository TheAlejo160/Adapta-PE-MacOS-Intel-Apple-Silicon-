import XCTest
#if canImport(Adapta_PE)
@testable import Adapta_PE
#endif

final class TutorialAndUXTests: XCTestCase {

    // 1. Secuencia = catálogo (Base 8 pasos / Lite 7 pasos)
    func testTutorialSequenceMatchesCatalog() throws {
        let catalog = try VoiceCatalog.load()
        let tutorial = try XCTUnwrap(catalog.tutorial)
        XCTAssertEqual(tutorial.version, 1)
        XCTAssertEqual(tutorial.orden, "tutorial")

        let expectedBase = ["voz", "nombre", "baja", "selecciona", "clic", "filtro", "cursor", "reabrir"]
        let expectedLite = ["voz", "nombre", "baja", "selecciona", "clic", "filtro", "reabrir"]

        XCTAssertEqual(tutorial.pasos.map(\.id), expectedBase)

        let litePasos = tutorial.pasos.filter { !$0.isSoloBase }
        XCTAssertEqual(litePasos.map(\.id), expectedLite)

        // Verificar propiedades de órdenes
        let baja = try XCTUnwrap(tutorial.pasos.first(where: { $0.id == "baja" }))
        XCTAssertEqual(baja.orden, "baja")
        XCTAssertFalse(baja.isSoloBase)

        let selecciona = try XCTUnwrap(tutorial.pasos.first(where: { $0.id == "selecciona" }))
        XCTAssertEqual(selecciona.orden, "selecciona Siguiente")
        XCTAssertFalse(selecciona.isSoloBase)

        let clic = try XCTUnwrap(tutorial.pasos.first(where: { $0.id == "clic" }))
        XCTAssertEqual(clic.orden, "dale clic")
        XCTAssertFalse(clic.isSoloBase)

        let cursor = try XCTUnwrap(tutorial.pasos.first(where: { $0.id == "cursor" }))
        XCTAssertTrue(cursor.isSoloBase)

        let reabrir = try XCTUnwrap(tutorial.pasos.first(where: { $0.id == "reabrir" }))
        XCTAssertEqual(reabrir.orden, "tutorial")
        XCTAssertFalse(reabrir.isSoloBase)

        // Comprobar secuencia en OnboardingSequence
        let baseSteps = OnboardingSequence.steps(isBase: true)
        XCTAssertEqual(baseSteps.map(\.id), expectedBase)

        let liteSteps = OnboardingSequence.steps(isBase: false)
        XCTAssertEqual(liteSteps.map(\.id), expectedLite)
    }

    // 2. Orden «tutorial» en 6 idiomas
    func testTutorialVoiceCommandInSixLanguages() {
        let testPhrases: [String: [String]] = [
            "es": ["tutorial", "abre el tutorial", "abrir tutorial", "inicia el tutorial", "muestra tutorial", "empieza tutorial"],
            "en": ["tutorial", "open tutorial", "show the tutorial", "start tutorial"],
            "pt": ["tutorial", "abre o tutorial", "abrir tutorial", "mostra o tutorial", "inicia tutorial"],
            "de": ["tutorial", "anleitung", "starte tutorial", "zeige das tutorial"],
            "fr": ["tutoriel", "ouvre le tutoriel", "montre le tutoriel", "lance le tutoriel"],
            "it": ["tutorial", "apri il tutorial", "mostra tutorial", "avvia il tutorial"]
        ]

        for (lang, phrases) in testPhrases {
            for phrase in phrases {
                let prepared = CommandParser.prepare(phrase, language: lang)
                XCTAssertEqual(prepared, "tutorial", "Idioma \(lang): '\(phrase)' falló al preparar")
                let command = CommandParser.parse(prepared)
                XCTAssertEqual(command, .tutorial, "Idioma \(lang): '\(phrase)' no produjo .tutorial")
            }
        }

        // Palabra reservada en activación
        XCTAssertNotNil(VoiceCatalog.shared?.activacion.reservadas["tutorial"], "'tutorial' debe ser palabra reservada en activación")
    }

    // 3. Persistencia (TutorialVisto, ControlScale, ActiveColorFilter)
    func testTutorialAndUXPersistence() {
        let defaults = UserDefaults.standard
        let originalTutorial = defaults.object(forKey: "TutorialVisto")
        let originalScale = defaults.object(forKey: "ControlScale")
        let originalFilter = defaults.object(forKey: "ActiveColorFilter")

        defer {
            defaults.setValue(originalTutorial, forKey: "TutorialVisto")
            defaults.setValue(originalScale, forKey: "ControlScale")
            defaults.setValue(originalFilter, forKey: "ActiveColorFilter")
        }

        // A. TutorialVisto
        defaults.set(false, forKey: "TutorialVisto")
        XCTAssertFalse(defaults.bool(forKey: "TutorialVisto"))
        defaults.set(true, forKey: "TutorialVisto")
        XCTAssertTrue(defaults.bool(forKey: "TutorialVisto"))

        // B. ControlScale (100 %, 125 %, 150 %)
        XCTAssertEqual(ControlScale.normal.rawValue, 1.0)
        XCTAssertEqual(ControlScale.medium.rawValue, 1.25)
        XCTAssertEqual(ControlScale.large.rawValue, 1.5)

        XCTAssertEqual(ControlScale.normal.title, "100 %")
        XCTAssertEqual(ControlScale.medium.title, "125 %")
        XCTAssertEqual(ControlScale.large.title, "150 %")

        // Anchos correspondientes no fijos a 320 pt
        XCTAssertEqual(round(320 * ControlScale.normal.rawValue), 320)
        XCTAssertEqual(round(320 * ControlScale.medium.rawValue), 400)
        XCTAssertEqual(round(320 * ControlScale.large.rawValue), 480)

        defaults.set(1.25, forKey: "ControlScale")
        let restoredMedium = defaults.double(forKey: "ControlScale")
        XCTAssertEqual(restoredMedium, 1.25)

        defaults.set(1.5, forKey: "ControlScale")
        let restoredLarge = defaults.double(forKey: "ControlScale")
        XCTAssertEqual(restoredLarge, 1.5)

        // C. ColorFilter atributos de grupo y swatch
        XCTAssertEqual(ColorFilter.ninguno.groupTitle, "Normal")
        XCTAssertEqual(ColorFilter.deuteranopia.groupTitle, "Rojo-verde")
        XCTAssertEqual(ColorFilter.protanopia.groupTitle, "Rojo-verde")
        XCTAssertEqual(ColorFilter.tritanopia.groupTitle, "Azul-amarillo")
        XCTAssertEqual(ColorFilter.acromatopsia.groupTitle, "Escala de grises")

        XCTAssertEqual(ColorFilter.ninguno.swatchType, "todos")
        XCTAssertEqual(ColorFilter.deuteranopia.swatchType, "rojo-verde")
        XCTAssertEqual(ColorFilter.tritanopia.swatchType, "azul-amarillo")
        XCTAssertEqual(ColorFilter.acromatopsia.swatchType, "grises")

        defaults.set(ColorFilter.deuteranopia.rawValue, forKey: "ActiveColorFilter")
        XCTAssertEqual(ColorFilter(rawValue: defaults.string(forKey: "ActiveColorFilter") ?? "") , .deuteranopia)
    }

    // 4. «Probar nombre» del tutorial: sólo una frase oída que activa el nombre completa el paso (antes, éxito simulado a los 2,5 s).
    func testTutorialNameStepNeedsRealActivation() {
        XCTAssertTrue(OnboardingSequence.activates("Computadora", name: "Computadora", aliases: [], alsoComputer: false))
        XCTAssertTrue(OnboardingSequence.activates("Jarvis", name: "Jarvis", aliases: [], alsoComputer: false))
        XCTAssertTrue(OnboardingSequence.activates("Lumi", name: "Jarvis", aliases: ["Lumi"], alsoComputer: false))
        XCTAssertTrue(OnboardingSequence.activates("Computadora", name: "Jarvis", aliases: [], alsoComputer: true))
        XCTAssertFalse(OnboardingSequence.activates("Computadora", name: "Jarvis", aliases: [], alsoComputer: false))
        XCTAssertFalse(OnboardingSequence.activates("hola qué tal", name: "Jarvis", aliases: [], alsoComputer: false))
    }

    // 5. Un filtro desconocido avisa del fallo en lugar de terminar sin efecto y con resultado «ok».
    @MainActor func testUnknownFilterReportsFailure() {
        let actions = ActionManager.shared
        let oldAction = actions.appAction, oldResult = actions.onResult
        defer { actions.appAction = oldAction; actions.onResult = oldResult; actions.callar() }
        var action: String?, result: VoiceExecutionResult?
        actions.appAction = { action = $0 }; actions.onResult = { result = $0 }
        actions.procesarIntencion("filtro arcoíris")
        XCTAssertNil(action)
        XCTAssertEqual(result, .failure)
        actions.procesarIntencion("filtro tritanopía")
        XCTAssertEqual(action, "filtro:tritanopia")
    }

    // 6. «pulsa tutorial» caía en un atajo sin acción; ahora pulsa el control con ese nombre.
    func testTutorialIsNeverADeadShortcut() {
        XCTAssertEqual(CommandParser.parse("pulsa tutorial"), .press("tutorial"))
        XCTAssertEqual(CommandParser.parse("abre el tutorial"), .tutorial)
    }
}

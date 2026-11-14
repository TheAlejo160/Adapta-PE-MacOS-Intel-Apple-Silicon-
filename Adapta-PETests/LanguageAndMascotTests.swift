import XCTest
#if canImport(Adapta_PE)
@testable import Adapta_PE
#endif

final class LanguageAndMascotTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Textos.shared.actualizarIdioma()
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "VoiceLanguage")
        Textos.shared.actualizarIdioma()
        super.tearDown()
    }

    // MARK: - 1. Cobertura de claves en los 6 idiomas
    func testAllKeysExistInAllSixLanguages() {
        let todas = Textos.shared.todasLasClaves()
        XCTAssertGreaterThanOrEqual(todas.count, 300, "Debe haber más de 300 claves registradas en el diccionario")

        let idiomas = ["es", "en", "pt", "de", "fr", "it"]
        var reportesFaltantes: [String: [String]] = [:]

        for lang in idiomas {
            var faltantes: [String] = []
            for clave in todas {
                if let valor = Textos.shared.claveDirecta(clave, idioma: lang), !valor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Clave presente
                } else {
                    faltantes.append(clave)
                }
            }
            if !faltantes.isEmpty {
                reportesFaltantes[lang] = faltantes
            }
            let total = Textos.shared.totalClaves(idioma: lang)
            XCTAssertEqual(total, todas.count, "El idioma \(lang) debe contener exactamente \(todas.count) claves pero tiene \(total)")
        }

        XCTAssertTrue(reportesFaltantes.isEmpty, "No debe faltar ninguna clave en los 6 idiomas: \(reportesFaltantes)")
    }

    // MARK: - 2. Caída a español y reemplazo de plantillas
    func testFallbackToSpanishAndInterpolation() {
        // Clave inexistente devuelve la propia clave
        let inexistente = Textos.shared.t("clave.que.no.existe.12345")
        XCTAssertEqual(inexistente, "clave.que.no.existe.12345")

        // Interpolar {palabra}
        let textoInterpolar = Textos.t("control.instruccionVoz", ["palabra": "Computadora"], idioma: "es")
        XCTAssertTrue(textoInterpolar.contains("Computadora"))
        XCTAssertFalse(textoInterpolar.contains("{palabra}"))

        // Interpolar en inglés
        let enInterpolar = Textos.t("control.instruccionVoz", ["palabra": "Computer"], idioma: "en")
        XCTAssertTrue(enInterpolar.contains("Computer"))
        XCTAssertTrue(enInterpolar.contains("Say"))

        // Clave contextual {contexto}
        let eligeEn = Textos.t("control.eligeEn", ["contexto": "Safari"], idioma: "pt")
        XCTAssertTrue(eligeEn.contains("Safari"))
    }

    // MARK: - 3. Cambio de idioma en vivo reflejado
    func testLiveLanguagePreferenceSwitch() {
        // Fijar español
        Textos.shared.fijarIdioma("es")
        XCTAssertEqual(Textos.shared.currentLanguage, "es")
        XCTAssertEqual(Textos.t("seccion.mascota"), "Mascota")
        XCTAssertEqual(Textos.t("menu.detenerTodo"), "Detener todo")

        // Fijar inglés
        Textos.shared.fijarIdioma("en")
        XCTAssertEqual(Textos.shared.currentLanguage, "en")
        XCTAssertEqual(Textos.t("seccion.mascota"), "Pet")
        XCTAssertEqual(Textos.t("menu.detenerTodo"), "Stop all")

        // Fijar portugués
        Textos.shared.fijarIdioma("pt")
        XCTAssertEqual(Textos.shared.currentLanguage, "pt")
        XCTAssertEqual(Textos.t("seccion.mascota"), "Mascote")
        XCTAssertEqual(Textos.t("menu.detenerTodo"), "Parar tudo")

        // Fijar alemán
        Textos.shared.fijarIdioma("de")
        XCTAssertEqual(Textos.shared.currentLanguage, "de")
        XCTAssertEqual(Textos.t("seccion.mascota"), "Maskottchen")
        XCTAssertEqual(Textos.t("menu.detenerTodo"), "Alles stoppen")

        // Fijar francés
        Textos.shared.fijarIdioma("fr")
        XCTAssertEqual(Textos.shared.currentLanguage, "fr")
        XCTAssertEqual(Textos.t("seccion.mascota"), "Mascotte")
        XCTAssertEqual(Textos.t("menu.detenerTodo"), "Tout arrêter")

        // Fijar italiano
        Textos.shared.fijarIdioma("it")
        XCTAssertEqual(Textos.shared.currentLanguage, "it")
        XCTAssertEqual(Textos.t("seccion.mascota"), "Mascotte")
        XCTAssertEqual(Textos.t("menu.detenerTodo"), "Interrompi tutto")

        // Cambio a través de UserDefaults con "auto"
        UserDefaults.standard.set("auto", forKey: "VoiceLanguage")
        Textos.shared.actualizarIdioma()
        XCTAssertTrue(Textos.supportedLanguages.contains(Textos.shared.currentLanguage))
    }

    // MARK: - 4. Respuestas de Mascota a happy y confused (T-21)
    func testMascotRespondsToHappyAndConfused() {
        let atlas = MascotAtlas(
            frames: [
                MascotAtlas.Frame(x: 0, y: 0, w: 96, h: 112, duration: 100),
                MascotAtlas.Frame(x: 96, y: 0, w: 96, h: 112, duration: 100)
            ],
            animations: [
                MascotAtlas.Animation(name: "idle", entry: [], loop: [0], exit: []),
                MascotAtlas.Animation(name: "happy", entry: [], loop: [0, 1], exit: []),
                MascotAtlas.Animation(name: "confused", entry: [], loop: [1, 0], exit: [])
            ]
        )

        var playback = MascotPlayback(atlas: atlas)
        XCTAssertEqual(playback.state, "idle")

        // Disparar happy
        playback.set("happy")
        XCTAssertEqual(playback.state, "happy")
        // Avanzar la animación de loop para que agote el ciclo y retorne a idle
        playback.advance()
        playback.advance()
        playback.advance()
        XCTAssertEqual(playback.state, "idle", "MascotPlayback debe retornar a idle tras completar happy")

        // Disparar confused
        playback.set("confused")
        XCTAssertEqual(playback.state, "confused")
        playback.advance()
        playback.advance()
        playback.advance()
        XCTAssertEqual(playback.state, "idle", "MascotPlayback debe retornar a idle tras completar confused")
    }

    // MARK: - 5. Disparo de happy y confused desde ActionManager
    func testActionManagerDispatchesResultToCallback() {
        let actions = ActionManager.shared
        var receivedResult: VoiceExecutionResult?

        actions.onResult = { result in
            receivedResult = result
        }

        actions.report(.ok)
        XCTAssertEqual(receivedResult, .ok)

        actions.report(.unknown)
        XCTAssertEqual(receivedResult, .unknown)

        actions.report(.failure)
        XCTAssertEqual(receivedResult, .failure)
    }
}

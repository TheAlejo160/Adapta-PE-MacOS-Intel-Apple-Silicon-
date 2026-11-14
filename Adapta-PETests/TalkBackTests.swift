import XCTest
import ApplicationServices
@testable import Adapta_PE

/// TalkBack de escritorio (T-13): debounce real de 300 ms, una lectura por objetivo y privacidad de campos de texto.
final class TalkBackTests: XCTestCase {
    func testDebounceRealDe300msYUnaLecturaPorObjetivo() {
        var lectura = LecturaDiferida()
        XCTAssertTrue(lectura.observar(1, en: 0))
        XCTAssertNil(lectura.pendiente(en: 0.29), "Antes de 300 ms no lee")
        XCTAssertEqual(lectura.pendiente(en: 0.3), 1)
        XCTAssertNil(lectura.pendiente(en: 0.6), "Una sola lectura por objetivo")
        XCTAssertFalse(lectura.observar(1, en: 0.7), "El mismo objetivo no reprograma")
        // Pasar rápido por varios controles: sólo se lee el último en el que se detiene.
        XCTAssertTrue(lectura.observar(2, en: 1.0)); XCTAssertTrue(lectura.observar(3, en: 1.1))
        XCTAssertNil(lectura.pendiente(en: 1.3), "El objetivo 2 nunca se lee")
        XCTAssertEqual(lectura.pendiente(en: 1.4), 3)
        // Salir del control lo olvida: volver a él lo lee otra vez (en Windows `lastReadId` no se limpiaba).
        XCTAssertTrue(lectura.observar(nil, en: 2)); XCTAssertNil(lectura.pendiente(en: 3))
        XCTAssertTrue(lectura.observar(3, en: 3)); XCTAssertEqual(lectura.pendiente(en: 3.3), 3)
    }

    func testRevisionH3SalirYVolverAntesDe300msLeeUnaVez() {
        var lectura = LecturaDiferida(), lecturas = 0
        XCTAssertTrue(lectura.observar(1, en: 0)); XCTAssertTrue(lectura.observar(nil, en: 0.1)); XCTAssertTrue(lectura.observar(1, en: 0.2))
        for t in [0.3, 0.5, 0.6, 0.9] where lectura.pendiente(en: t) != nil { lecturas += 1 } // Temporizadores de ambas entradas.
        XCTAssertEqual(lecturas, 1)
    }

    func testCamposDeTextoNoSeLeenSalvoPeticion() {
        for role in [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"] {
            XCTAssertFalse(DesktopAccess.labelAttributes(role: role, includeTextValue: false).contains(kAXValueAttribute), "\(role): TalkBack no lee lo escrito")
            XCTAssertTrue(DesktopAccess.labelAttributes(role: role, includeTextValue: false).contains("AXPlaceholderValue"), "Lee la etiqueta del campo")
            XCTAssertTrue(DesktopAccess.labelAttributes(role: role, includeTextValue: true).contains(kAXValueAttribute), "«lee el elemento» sí lo pide")
        }
        XCTAssertTrue(DesktopAccess.labelAttributes(role: kAXStaticTextRole, includeTextValue: false).contains(kAXValueAttribute), "El texto estático se lee")
        XCTAssertEqual(LecturaDiferida.espera, 0.3)
    }

    // Sin Accesibilidad, activar TalkBack se apaga solo y debe contar como fallo, no como orden cumplida.
    @MainActor func testSinAccesibilidadTalkBackAvisaFallo() throws {
        try XCTSkipIf(AXIsProcessTrusted(), "Con Accesibilidad concedida no hay fallo que avisar")
        let actions = ActionManager.shared, old = actions.onResult
        defer { actions.onResult = old; actions.callar() }
        var result: VoiceExecutionResult?
        actions.onResult = { result = $0 }
        let talkBack = TalkBackManager()
        talkBack.isEnabled = true
        XCTAssertFalse(talkBack.isEnabled)
        XCTAssertEqual(result, .failure)
    }
}

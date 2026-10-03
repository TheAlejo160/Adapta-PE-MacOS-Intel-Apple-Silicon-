import XCTest

final class Adapta_PEUITests: XCTestCase {
    func testSettingsFloatingPanelAndBackgroundLifecycle() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Panel flotante"].waitForExistence(timeout: 5))
        app.buttons["Panel flotante"].click()
        XCTAssertTrue(app.buttons["Abrir ajustes"].waitForExistence(timeout: 5))
        app.buttons["Abrir ajustes"].click()
        XCTAssertTrue(app.buttons["Panel flotante"].waitForExistence(timeout: 5))
        app.radioButtons["IA opcional"].click()
        XCTAssertTrue(app.switches["Activar IA con mi API key"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.switches["Activar IA con mi API key"].value as? String, "0")
        app.windows["Adapta PE"].buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertNotEqual(app.state, .notRunning, "Cerrar ajustes debe conservar la app en segundo plano")
    }
}

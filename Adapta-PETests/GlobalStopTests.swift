import XCTest
@testable import Adapta_PE

final class GlobalStopTests: XCTestCase {
    @MainActor func testImperativeStopAliasesUseGlobalExecutor() {
        let actions = ActionManager.shared
        let previous = actions.appAction
        defer { actions.appAction = previous }
        for phrase in ["detener todo", "detén todo", "por favor detén todo", "apaga todo", "para todo", "para", "porfa detén todo pe"] {
            var received: String?
            actions.appAction = { received = $0 }
            actions.procesarIntencion(phrase)
            XCTAssertEqual(received, "detener todo", phrase)
        }
    }
}

import XCTest
@testable import Adapta_PE

final class PersonalWakeTests: XCTestCase {
    func testCameraDefaultAndDisconnectedSelection() {
        XCTAssertEqual(TrackingManager.validatedCameraID("", available: ["usb", "integrada"]), "")
        XCTAssertEqual(TrackingManager.validatedCameraID("usb", available: ["integrada", "usb"]), "usb")
        XCTAssertEqual(TrackingManager.validatedCameraID("retirada", available: ["integrada"]), "")
        XCTAssertEqual(TrackingManager.validatedCameraID("usb", available: []), "")
    }
    func testMicrophoneDefaultAndDisconnectedSelection() {
        XCTAssertEqual(VoiceManager.validatedMicID("", available: ["usb", "integrado"]), "")
        XCTAssertEqual(VoiceManager.validatedMicID("usb", available: ["integrado", "usb"]), "usb")
        XCTAssertEqual(VoiceManager.validatedMicID("retirado", available: ["integrado"]), "")
        XCTAssertEqual(VoiceManager.validatedMicID("usb", available: []), "")
    }
    func testAccentWhitespaceAndOriginalSuffix() {
        var input = VoiceInputState()
        XCTAssertEqual(input.consume("Computadora, por favor detén todo", wakeWord: "computadora", time: 0, speaking: true).command, "por favor detén todo")
        var wake = WakePhraseState()
        XCTAssertEqual(wake.consume("oye MA\u{301}QUINA   AZUL, escribe Hola,  Perú!", wakeWord: "Máquina Azul", time: 0).command, "escribe Hola,  Perú!")
        XCTAssertEqual(wake.consume("Maquina Azul abre Safari", wakeWord: "Máquina Azul", time: 1).command, "abre Safari")
        XCTAssertNil(wake.consume("Computadora abre Safari", wakeWord: "Máquina Azul", time: 2).command)
    }
}

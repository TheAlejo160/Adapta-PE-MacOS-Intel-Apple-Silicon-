import XCTest
#if canImport(Adapta_PE)
@testable import Adapta_PE
#endif

final class PersonalWakeTests: XCTestCase {
    @MainActor func testWakeNameSaveRejectsInvalidInputAndRestoresDefault() {
        let defaults = UserDefaults.standard, previous = UserDefaults.standard.object(forKey: "WakeWord")
        defer { defaults.set(previous, forKey: "WakeWord") }
        let voice = VoiceManager()
        XCTAssertNil(voice.saveWakeName("  Jarvis  "))
        XCTAssertEqual(voice.wakeName, "Jarvis")
        XCTAssertNotNil(voice.saveWakeName("close"))
        XCTAssertEqual(defaults.string(forKey: "WakeWord"), "Jarvis")
        XCTAssertNil(voice.saveWakeName(WakeName.defaultName))
        XCTAssertEqual(voice.wakeName, "Computadora")
        XCTAssertEqual(WakeName.saved, "Computadora")
    }
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

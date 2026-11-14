import Foundation

enum ControlScale: Double, CaseIterable, Identifiable {
    case normal = 1.0
    case medium = 1.25
    case large = 1.5
    var id: Double { rawValue }
    var percentage: Int { Int(rawValue * 100) }
    var title: String { "\(percentage) %" }
}

struct OnboardingStepInfo: Identifiable, Equatable {
    let id: String
    let orden: String?
    let soloBase: Bool
    var isSoloBase: Bool { soloBase }
}

struct OnboardingSequence {
    static let baseSteps = ["voz", "nombre", "baja", "selecciona", "clic", "filtro", "cursor", "reabrir"]
    static let liteSteps = ["voz", "nombre", "baja", "selecciona", "clic", "filtro", "reabrir"]

    static func steps(isBase: Bool = true) -> [OnboardingStepInfo] {
        if let catalogPasos = VoiceCatalog.shared?.tutorial?.pasos {
            return catalogPasos.compactMap { paso in
                let soloBase = paso.isSoloBase
                if soloBase && !isBase { return nil }
                return OnboardingStepInfo(id: paso.id, orden: paso.orden, soloBase: soloBase)
            }
        }
        let fallback: [OnboardingStepInfo] = [
            OnboardingStepInfo(id: "voz", orden: nil, soloBase: false),
            OnboardingStepInfo(id: "nombre", orden: nil, soloBase: false),
            OnboardingStepInfo(id: "baja", orden: "baja", soloBase: false),
            OnboardingStepInfo(id: "selecciona", orden: "selecciona Siguiente", soloBase: false),
            OnboardingStepInfo(id: "clic", orden: "dale clic", soloBase: false),
            OnboardingStepInfo(id: "filtro", orden: nil, soloBase: false),
            OnboardingStepInfo(id: "cursor", orden: nil, soloBase: true),
            OnboardingStepInfo(id: "reabrir", orden: "tutorial", soloBase: false)
        ]
        return fallback.filter { !$0.soloBase || isBase }
    }

    /// Paso «nombre»: la frase capturada por «Probar nombre» debe activar el nombre igual que el motor de voz.
    static func activates(_ sample: String, name: String, aliases: [String], alsoComputer: Bool) -> Bool {
        VoiceActivation.end(in: sample, name: WakeName.effective(name), aliases: aliases, alsoComputer: alsoComputer) != nil
    }
}

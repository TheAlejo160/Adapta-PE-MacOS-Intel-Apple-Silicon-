import SwiftUI
import AVFoundation
import Speech
import AppKit

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var voice: VoiceManager
    @ObservedObject private var filter: ColorFilterManager
    @ObservedObject private var actions: ActionManager
    @ObservedObject private var textos = Textos.shared
    let isBase: Bool
    let onClose: (() -> Void)?
    init(model: AppModel, isBase: Bool = true, onClose: (() -> Void)? = nil) {
        self.model = model; voice = model.voice; filter = model.colorFilter; actions = model.actions; self.isBase = isBase; self.onClose = onClose
    }

    @State private var completedSteps: Set<String> = []
    @State private var scrollOffsetY: CGFloat = 0
    @State private var targetSelected = false
    @State private var targetClicked = false
    @State private var dwellButtonsDone: Set<Int> = []
    @State private var trialFeedback = ""

    private var steps: [OnboardingStepInfo] {
        OnboardingSequence.steps(isBase: isBase)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerView
                Divider()

                // Paso 1: voz y permisos
                if steps.contains(where: { $0.id == "voz" }) {
                    permissionsStepView
                }

                // Paso 2: probar nombre
                if steps.contains(where: { $0.id == "nombre" }) {
                    nameStepView
                }

                // Paso 3: orden «baja»
                if steps.contains(where: { $0.id == "baja" }) {
                    scrollStepView
                }

                // Paso 4: orden «selecciona Siguiente»
                if steps.contains(where: { $0.id == "selecciona" }) {
                    selectionStepView
                }

                // Paso 5: orden «dale clic»
                if steps.contains(where: { $0.id == "clic" }) {
                    clickStepView
                }

                // Paso 6: filtro con muestras
                if steps.contains(where: { $0.id == "filtro" }) {
                    filterStepView
                }

                // Paso 7: sólo Base - cursor, dwell y gestos
                if isBase && steps.contains(where: { $0.id == "cursor" }) {
                    cursorStepView
                }

                // Paso 8: cómo reabrir y finalizar
                if steps.contains(where: { $0.id == "reabrir" }) {
                    reopenStepView
                }
            }
            .padding(28)
            .frame(maxWidth: 800)
        }
        .coordinateSpace(name: "tutorial")
        // Ejercicio «baja»: cuenta el desplazamiento real de la página o de la lista de práctica.
        .onPreferenceChange(ScrollOffsetKey.self) { value in
            if value < -60 { completedSteps.insert("baja") }
        }
        .frame(minWidth: 600, minHeight: 650)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header
    private var headerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(textos.t("tutorial.bienvenida"))
                    .font(.system(size: 28, weight: .bold))
                Spacer()
                if let onClose {
                    Button(textos.t("control.cerrar")) {
                        UserDefaults.standard.set(true, forKey: "TutorialVisto")
                        onClose()
                    }
                    .frame(minWidth: 44, minHeight: 44)
                }
            }
            Text(textos.t("tutorial.aprendePasoPaso"))
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .background(GeometryReader { geo in
            Color.clear.preference(key: ScrollOffsetKey.self, value: geo.frame(in: .named("tutorial")).minY)
        })
    }

    // MARK: - Paso 1: Permisos
    private var permissionsStepView: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepHeader(id: "voz", title: textos.t("tutorial.pasosTitulo"))
            Text(textos.t("tutorial.requierePermisos"))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                permissionRow(
                    name: textos.t("tutorial.microPermiso"),
                    granted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                    action: { model.openPrivacy("Microphone") }
                )
                permissionRow(
                    name: textos.t("tutorial.reconocimientoPermiso"),
                    granted: SFSpeechRecognizer.authorizationStatus() == .authorized,
                    action: { model.openPrivacy("SpeechRecognition") }
                )
                permissionRow(
                    name: textos.t("tutorial.accesibilidadPermiso"),
                    granted: model.accessibilityGranted,
                    action: { model.requestAccessibility() }
                )
                permissionRow(
                    name: textos.t("tutorial.grabacionPermiso"),
                    granted: model.screenGranted,
                    action: { CGRequestScreenCaptureAccess(); model.openPrivacy("ScreenCapture") }
                )
                if isBase {
                    permissionRow(
                        name: textos.t("tutorial.camaraPermiso"),
                        granted: AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
                        action: { model.openPrivacy("Camera") }
                    )
                }
            }

            HStack(spacing: 12) {
                Button(textos.t("tutorial.actualizarPermisos")) {
                    model.refreshPermissions()
                    if model.accessibilityGranted {
                        completedSteps.insert("voz")
                    }
                }
                .frame(minWidth: 44, minHeight: 44)

                Button(voice.isListening ? textos.t("tutorial.vozActiva") : textos.t("tutorial.activarVoz")) {
                    model.toggleVoice()
                    completedSteps.insert("voz")
                }
                .frame(minWidth: 44, minHeight: 44)
            }
            stepStatus(id: "voz")
        }
        .padding(16)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    private func permissionRow(name: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? Color.green : Color.orange)
                .imageScale(.large)
            Text(name).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if !granted {
                Button(textos.t("tutorial.revisar")) { action() }
                    .frame(minWidth: 44, minHeight: 44)
            } else {
                Text(textos.t("tutorial.autorizado")).font(.caption.bold()).foregroundStyle(.green)
            }
        }
        .frame(minHeight: 44)
    }

    // MARK: - Paso 2: Nombre de activación
    private var nameStepView: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepHeader(id: "nombre", title: textos.t("tutorial.nombre.titulo"))
            Text(textos.t("tutorial.nombre.texto", ["palabra": voice.wakeName]))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button(textos.t("control.probarNombre"), systemImage: "waveform") {
                    trialFeedback = ""
                    voice.testWakeName()
                }
                .frame(minWidth: 44, minHeight: 44)
                .disabled(voice.testingName)

                if !trialFeedback.isEmpty {
                    Text(trialFeedback).font(.callout).accessibilityAddTraits(.updatesFrequently)
                } else if !voice.nameTrialStatus.isEmpty {
                    Text(voice.nameTrialStatus).font(.callout).accessibilityAddTraits(.updatesFrequently)
                }
            }
            // Sólo una frase realmente oída completa el paso, comprobada como el motor de activación.
            .onChange(of: voice.nameTrialSample) { _, sample in
                guard !sample.isEmpty else { return }
                if OnboardingSequence.activates(sample, name: voice.wakeName, aliases: voice.activationAliases, alsoComputer: voice.alsoComputer) {
                    trialFeedback = textos.t("tutorial.nombre.oido", ["texto": sample])
                    completedSteps.insert("nombre")
                    actions.hablar(textos.t("tutorial.nombre.respuesta"))
                } else {
                    trialFeedback = textos.t("tutorial.nombre.noOido", ["texto": sample])
                }
            }
            stepStatus(id: "nombre")
        }
        .padding(16)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Paso 3: Ejercicio «baja»
    private var scrollStepView: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepHeader(id: "baja", title: textos.t("tutorial.baja.titulo"))
            Text(textos.t("tutorial.baja.texto", ["palabra": voice.wakeName]))
                .foregroundStyle(.secondary)

            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: 14) {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(1...8, id: \.self) { i in
                                Text("\(i)")
                                    .frame(maxWidth: .infinity, minHeight: 36)
                                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                                    .id(i)
                            }
                        }
                        .padding(8)
                        .background(GeometryReader { geo in
                            Color.clear.preference(key: ScrollOffsetKey.self, value: geo.frame(in: .named("bajaLista")).minY)
                        })
                    }
                    .coordinateSpace(name: "bajaLista")
                    .frame(height: 120)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3), lineWidth: 1))

                    // Muestra el efecto de «baja» desplazando de verdad la lista.
                    Button(textos.t("tutorial.baja.titulo")) {
                        withAnimation { proxy.scrollTo(8, anchor: .bottom) }
                    }
                    .frame(minWidth: 44, minHeight: 44)
                }
            }

            stepStatus(id: "baja")
        }
        .padding(16)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Paso 4: Ejercicio «selecciona Siguiente»
    private var selectionStepView: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepHeader(id: "selecciona", title: textos.t("tutorial.selecciona.titulo"))
            Text(textos.t("tutorial.selecciona.texto", ["palabra": voice.wakeName]))
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                // «dale clic» pulsa por Accesibilidad el botón ya seleccionado.
                Button(action: {
                    if targetSelected {
                        targetClicked = true
                        completedSteps.insert("clic")
                    } else {
                        targetSelected = true
                        completedSteps.insert("selecciona")
                    }
                }) {
                    Text(textos.t("tutorial.objetivo"))
                        .font(.headline)
                        .padding(.horizontal, 20)
                        .frame(minWidth: 44, minHeight: 44)
                        .background(targetSelected ? Color.accentColor : Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(targetSelected ? Color.white : Color.primary)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(targetSelected ? Color.white : Color.clear, lineWidth: 2))
                }
                .accessibilityLabel(textos.t("tutorial.objetivo"))

                if targetSelected {
                    Text(textos.t("tutorial.hecho")).font(.callout).foregroundStyle(.green)
                }
            }
            // «selecciona Siguiente» por voz resalta el botón y responde «Seleccionado: …».
            .onChange(of: actions.lastResponse) { _, response in
                if response == "Seleccionado: " + textos.t("tutorial.objetivo") {
                    targetSelected = true
                    completedSteps.insert("selecciona")
                }
            }

            stepStatus(id: "selecciona")
        }
        .padding(16)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Paso 5: Ejercicio «dale clic»
    private var clickStepView: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepHeader(id: "clic", title: textos.t("tutorial.clic.titulo"))
            Text(textos.t("tutorial.clic.texto", ["palabra": voice.wakeName]))
                .foregroundStyle(.secondary)

            Button(action: {
                if targetSelected || !completedSteps.contains("selecciona") {
                    targetClicked = true
                    completedSteps.insert("clic")
                }
            }) {
                HStack {
                    Image(systemName: targetClicked ? "checkmark.circle.fill" : "cursorarrow.click")
                    Text(targetClicked ? textos.t("tutorial.clicExito") : textos.t("tutorial.ejecutarClic"))
                }
                .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(OnboardingButtonStyle())

            stepStatus(id: "clic")
        }
        .padding(16)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Paso 6: Filtro con muestras
    private var filterStepView: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepHeader(id: "filtro", title: textos.t("tutorial.filtro.titulo"))
            Text(textos.t("filtro.soloUno")).font(.callout.bold()).foregroundStyle(.secondary)
            Text(textos.t("tutorial.filtro.texto"))
                .foregroundStyle(.secondary)

            ColorFilterSelectionView(selected: filter.selected) { chosen in
                model.mascot.react("laptop")
                filter.apply(chosen)
                completedSteps.insert("filtro")
            }

            stepStatus(id: "filtro")
        }
        .padding(16)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Paso 7: Sólo Base (Dwell y gestos)
    private var cursorStepView: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader(id: "cursor", title: textos.t("tutorial.cursor.titulo"))
            Text(textos.t("tutorial.cursor.texto"))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    ForEach(1...3, id: \.self) { index in
                        Button(action: {
                            dwellButtonsDone.insert(index)
                            if dwellButtonsDone.count >= 3 {
                                completedSteps.insert("cursor")
                            }
                        }) {
                            VStack(spacing: 4) {
                                Image(systemName: dwellButtonsDone.contains(index) ? "checkmark.circle.fill" : "target")
                                Text(dwellButtonsDone.contains(index) ? textos.t("tutorial.hecho") : textos.t("tutorial.cursor.boton", ["n": "\(index)"]))
                            }
                            .frame(maxWidth: .infinity, minHeight: 60)
                            .background(dwellButtonsDone.contains(index) ? Color.green.opacity(0.2) : Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(dwellButtonsDone.contains(index) ? Color.green : Color.accentColor, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(textos.t("tutorial.cursor.boton", ["n": "\(index)"]))
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle.fill").foregroundStyle(.blue)
                    Text(textos.t("tutorial.cursor.clic"))
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            stepStatus(id: "cursor")
        }
        .padding(16)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Paso 8: Cómo reabrir y finalizar
    private var reopenStepView: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepHeader(id: "reabrir", title: textos.t("tutorial.reabrir.titulo"))
            Text(textos.t("tutorial.reabrir.texto", ["palabra": voice.wakeName]))
                .foregroundStyle(.secondary)

            Button(action: {
                UserDefaults.standard.set(true, forKey: "TutorialVisto")
                completedSteps.insert("reabrir")
                onClose?()
            }) {
                Text(textos.t("tutorial.comenzar"))
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(OnboardingButtonStyle())
        }
        .padding(16)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Auxiliares
    private func stepHeader(id: String, title: String) -> some View {
        HStack {
            Text(title).font(.title3.bold())
            Spacer()
            if completedSteps.contains(id) {
                Label(textos.t("tutorial.hecho"), systemImage: "checkmark.seal.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.green)
            }
        }
    }

    private func stepStatus(id: String) -> some View {
        Group {
            if completedSteps.contains(id) {
                Text("✅ " + textos.t("tutorial.pasoCompletado")).font(.caption).foregroundStyle(.green)
            }
        }
    }
}

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    // Página y lista informan su desplazamiento: basta con que una baje.
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

struct OnboardingButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .padding(.horizontal, 16)
            .frame(minWidth: 44, minHeight: 44)
            .foregroundStyle(Color.white)
            .background(Color(red: 0.04, green: 0.26, blue: 0.60), in: RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

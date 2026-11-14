import AppKit
import Security
import SwiftUI
import AVFoundation
import Speech

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var tracker: TrackingManager
    @ObservedObject private var voice: VoiceManager
    @ObservedObject private var actions: ActionManager
    @ObservedObject private var textos = Textos.shared
    @State private var section = "Control"
    @State private var wakeWord = WakeName.saved
    @State private var wakeError = ""
    init(model: AppModel) { self.model = model; tracker = model.tracker; voice = model.voice; actions = model.actions }
    var body: some View {
        ZStack {
            GeometryReader { geo in
                Image("FondoApp").resizable().scaledToFill().frame(width: max(0, geo.size.width), height: max(0, geo.size.height)).clipped().overlay(Color.black.opacity(0.6))
            }.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(textos.t("app.titulo")).font(.system(size: 30, weight: .bold))
                        Text(textos.t("app.subtitulo")).font(.body)
                    }.foregroundStyle(.white)
                    Spacer()
                    Button(textos.t("menu.tutorial"), systemImage: "graduationcap") { model.showTutorial() }
                    Button(textos.t("app.usarPanel"), systemImage: "pip") { model.showFloating() }
                }
                VStack(alignment: .leading, spacing: 16) {
                    Picker(textos.t("seccion.control"), selection: $section) {
                        Text(textos.t("seccion.control")).tag("Control"); Text(textos.t("seccion.lectura")).tag("Lectura")
                        Text(textos.t("seccion.mascota")).tag("Mascota"); Text(textos.t("seccion.ia")).tag("IA"); Text(textos.t("seccion.ayuda")).tag("Ayuda")
                    }.pickerStyle(.segmented).labelsHidden()
                    if section == "Control", tracker.isTracking || tracker.isStarting {
                        CameraSurface(tracker: tracker).frame(height: 180)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            switch section {
                            case "Control": controlSettings
                            case "Mascota": MascotSettings(mascot: model.mascot)
                            case "Lectura": ReadingSettings(model: model)
                            case "IA": AISettings(ai: model.ai)
                            default: helpSettings
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(2)
                    }
                    Divider()
                    HStack {
                        Text(textos.t("control.cerrarVentanaAviso")).font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button(role: .destructive, action: { model.stopAll() }) { Label(textos.t("menu.detenerTodo"), systemImage: "stop.circle") }
                    }
                }.padding(20).background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
            }.padding(22)
        }.frame(minWidth: 580, minHeight: 580).font(.system(size: 16))
        .buttonStyle(AccessibleButtonStyle()).tint(Color(red: 0.04, green: 0.26, blue: 0.60))
        .controlSize(model.controlScale == .large ? .extraLarge : model.controlScale == .medium ? .large : .regular)
    }
    private var controlSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(textos.t("control.activaLoQueNecesitas")).font(.title2.bold())
            Toggle(isOn: Binding(get: { voice.isListening || voice.isStarting }, set: { _ in model.toggleVoice() })) {
                Label(textos.t("control.voz"), systemImage: "mic")
                Text(voice.status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.toggleStyle(.switch).frame(minHeight: 44).accessibilityLabel(textos.t("control.voz")).accessibilityValue(voice.status)
            Toggle(isOn: Binding(get: { tracker.isTracking || tracker.isStarting }, set: { _ in model.toggleTracking() })) {
                Label(textos.t("control.cursorCamara"), systemImage: "viewfinder")
                Text(tracker.statusMessage).font(.callout).foregroundStyle(.secondary)
            }.toggleStyle(.switch).frame(minHeight: 44).accessibilityLabel(textos.t("control.cursorCamara")).accessibilityValue(tracker.statusMessage)
            if tracker.isTracking {
                HStack {
                    Button(textos.t("control.calibrar"), systemImage: "scope") { tracker.calibrate() }
                    Button(tracker.isPaused ? textos.t("control.reanudarCursor") : textos.t("control.pausarCursor"), systemImage: tracker.isPaused ? "play" : "pause") { tracker.isPaused.toggle() }
                }
            }
            Text(textos.t("control.instruccionVoz", ["palabra": wakeWord.isEmpty ? "computadora" : wakeWord])).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !voice.transcript.isEmpty { Text(textos.t("control.aquiVeras") + ": " + voice.transcript).font(.callout).lineLimit(2).accessibilityLabel("Último comando escuchado: " + voice.transcript) }
            Text(actions.lastResponse).font(.callout).foregroundStyle(.secondary).lineLimit(3).accessibilityLabel("Última respuesta: " + actions.lastResponse)
            if !model.accessibilityGranted {
                Button(textos.t("permisos.controlEscritorio"), systemImage: "hand.raised") { model.requestAccessibility() }
                Text(textos.t("permisos.ayudaAccesibilidad")).font(.callout).foregroundStyle(.secondary)
            }
            if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
                Button(textos.t("permisos.revisarMicro")) { model.openPrivacy("Microphone") }
            }
            if SFSpeechRecognizer.authorizationStatus() == .denied {
                Button(textos.t("permisos.revisarVoz")) { model.openPrivacy("SpeechRecognition") }
            }
            if AVCaptureDevice.authorizationStatus(for: .video) == .denied {
                Button(textos.t("permisos.revisarCamara")) { model.openPrivacy("Camera") }
            }
            Divider()
            DisclosureGroup(textos.t("control.adaptarMovimiento")) {
                VStack(alignment: .leading, spacing: 14) {
                    Picker(textos.t("control.controlCon"), selection: $tracker.controlMode) {
                        Text(textos.t("control.modoCabeza")).tag("cabeza"); Text(textos.t("control.modoManos")).tag("manos"); Text(textos.t("control.modoZona")).tag("zona")
                    }
                    Text(textos.t("control.modoDesc")).font(.callout).foregroundStyle(.secondary)
                    HStack { Text(textos.t("control.velocidad")); Slider(value: $tracker.sensitivity, in: 0.3...2, step: 0.1).accessibilityLabel(textos.t("control.velocidad")); Text(String(format: "%.1f×", tracker.sensitivity)).monospacedDigit() }
                    Toggle(textos.t("control.reducirTemblores"), isOn: $tracker.isParkinsonMode)
                    Toggle(textos.t("control.movimientosPequenos"), isOn: $tracker.reducedMovement)
                    Toggle(textos.t("control.clicMantener"), isOn: $tracker.dwellEnabled)
                    HStack { Text(textos.t("control.esperaClic")); Slider(value: $tracker.dwellDuration, in: KineticDefaults.dwellMinimo...KineticDefaults.dwellMaximo, step: 0.1).accessibilityLabel(textos.t("control.esperaClic")); Text(String(format: "%.1f s", tracker.dwellDuration)).monospacedDigit() }.disabled(!tracker.dwellEnabled)
                    Toggle(TrackingManager.hudText("atraccion", language: textos.currentLanguage), isOn: $tracker.attractionEnabled)
                    Text(textos.t("control.ayudaOrdenesVoz")).font(.callout).foregroundStyle(.secondary)
                }.padding(.top, 12)
            }
            Text(textos.t("control.ejemploSafari", ["palabra": voice.wakeName]))
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup(textos.t("control.dispositivosYPreferencias")) {
                VStack(alignment: .leading, spacing: 14) {
                    Picker(textos.t("control.camara"), selection: $tracker.selectedCameraID) {
                        if tracker.availableCameras.isEmpty { Text(textos.t("control.sinCamara")).tag("") }
                        ForEach(tracker.availableCameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                    }
                    Picker(textos.t("control.microfono"), selection: $voice.selectedMicID) {
                        if voice.availableMics.isEmpty { Text(textos.t("control.sinMicrofono")).tag("") }
                        ForEach(voice.availableMics, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                    }
                    TextField(textos.t("control.nombreAsistente"), text: $wakeWord).textFieldStyle(.roundedBorder).accessibilityLabel(textos.t("control.nombreAsistente"))
                        .onSubmit { wakeError = voice.saveWakeName(wakeWord) ?? "" }
                    HStack {
                        Button(textos.t("control.guardarNombre")) { wakeError = voice.saveWakeName(wakeWord) ?? "" }
                        Button(textos.t("control.restaurarComputadora")) { wakeWord = WakeName.defaultName; wakeError = voice.saveWakeName(wakeWord) ?? "" }
                    }
                    if !wakeError.isEmpty { Text(wakeError).foregroundStyle(.red).accessibilityAddTraits(.updatesFrequently) }
                    Text(voice.activationAliases.isEmpty ? textos.t("control.sinAlias") : textos.t("control.aliasPrefijo") + ": " + voice.activationAliases.joined(separator: ", ")).font(.callout)
                    HStack {
                        Button(textos.t("control.probarNombre")) { voice.testWakeName() }.disabled(voice.testingName)
                        if !voice.nameTrialSample.isEmpty { Button(textos.t("control.anadirAlias")) { wakeError = voice.addTrialAlias() ?? "" } }
                        if !voice.activationAliases.isEmpty { Button(textos.t("control.quitarAlias")) { wakeError = voice.saveAliases([]) ?? "" } }
                    }
                    if !voice.nameTrialStatus.isEmpty { Text(voice.nameTrialStatus).font(.callout).accessibilityAddTraits(.updatesFrequently) }
                    Toggle(textos.t("control.responderComputadora"), isOn: $voice.alsoComputer)
                    Toggle(textos.t("control.modoConversacion"), isOn: $voice.conversationMode)
                    Text(textos.t("control.cerrarConversacionAyuda")).font(.callout).foregroundStyle(.secondary)
                    Picker(textos.t("control.idiomaVoz"), selection: $voice.languagePreference) {
                        Text(textos.t("control.idiomaAuto")).tag("auto")
                        ForEach(VoiceCatalog.shared?.codigos ?? ["es-PE"], id: \.self) { Text(Locale.current.localizedString(forIdentifier: $0) ?? $0).tag($0) }
                    }
                    Text(textos.t("control.tiempoOrdenAyuda")).font(.callout).foregroundStyle(.secondary)
                    Picker(textos.t("control.escala"), selection: $model.controlScale) {
                        ForEach(ControlScale.allCases) { scale in
                            Text(scale.title).tag(scale)
                        }
                    }.pickerStyle(.segmented)
                    Text(textos.t("control.ayudaEscala")).font(.callout).foregroundStyle(.secondary)
                    Toggle(textos.t("control.reconocimientoRed"), isOn: $voice.allowAppleNetwork)
                    Text(textos.t("control.ayudaReconocimientoRed")).font(.callout).foregroundStyle(.secondary)
                    Toggle(textos.t("control.iniciarAlEncender"), isOn: Binding(get: { model.loginEnabled }, set: model.setLogin))
                    Text(textos.t("control.ayudaIniciarAlEncender")).font(.callout).foregroundStyle(.secondary)
                    Text(textos.t("control.pantallasDisponibles")).font(.headline)
                    ForEach(Array(model.screens.enumerated()), id: \.offset) { index, screen in
                        Text("\(index + 1). \(screen.localizedName) — \(Int(screen.frame.width)) × \(Int(screen.frame.height))")
                    }
                    Text("«Abre Visual Studio Code en el monitor dos»").font(.callout).foregroundStyle(.secondary)
                    Button(textos.t("control.actualizarDispositivos")) { model.refreshPermissions() }
                    if !model.notice.isEmpty { Text(model.notice).foregroundStyle(.secondary) }
                }.padding(.top, 12)
            }
        }
    }
    private var helpSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button(textos.t("ayuda.tutorialPractico"), systemImage: "graduationcap") { model.showTutorial() }
                Button(textos.t("ayuda.accionesApp")) { actions.procesarIntencion("muestra comandos") }
                Button(textos.t("ayuda.buscarCampos")) { actions.procesarIntencion("muestra campos") }
            }
            Text(textos.t("ayuda.explicacionComandos")).fixedSize(horizontal: false, vertical: true)
            Text(textos.t("ayuda.posturaComoda")).font(.title2.bold())
            Text(textos.t("ayuda.pasosPostura"))
            Divider()
            Text(textos.t("ayuda.comandosEjemplo")).font(.headline)
            Text(textos.t("ayuda.listaComandos"))
            Text(textos.t("ayuda.notaAccesibilidad")).font(.system(size: 15)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                Button(textos.t("ayuda.permisoAccesibilidad")) { model.openPrivacy("Accessibility") }
                Button(textos.t("ayuda.permisoCamaraMicro")) { model.openPrivacy("Camera") }
                Button(textos.t("ayuda.permisoGrabacion")) { model.openPrivacy("ScreenCapture") }
            }
            Button(textos.t("control.actualizarDispositivos")) { model.refreshPermissions() }
        }
    }
}

struct ReadingSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var talkBack: TalkBackManager
    @ObservedObject private var filter: ColorFilterManager
    @ObservedObject private var textos = Textos.shared
    init(model: AppModel) { self.model = model; talkBack = model.talkBack; filter = model.colorFilter }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(textos.t("lectura.titulo")).font(.title2.bold())
            Toggle(textos.t("lectura.leerBajoCursor"), isOn: $talkBack.isEnabled).toggleStyle(.switch).frame(minHeight: 44)
            Text(textos.t("lectura.ayudaCursor")).foregroundStyle(.secondary)
            Button(textos.t("lectura.leerVentana"), systemImage: "speaker.wave.2") { model.actions.procesarIntencion("lee la pantalla") }.controlSize(.large)
            Button(textos.t("lectura.detener")) { model.actions.callar() }
            Divider()
            Text(textos.t("control.filtroPantalla")).font(.headline)
            Text(textos.t("filtro.soloUno")).font(.callout.bold()).foregroundStyle(.secondary)
            ColorFilterSelectionView(selected: filter.selected) { chosen in
                model.mascot.react("laptop")
                filter.apply(chosen)
            }
            if filter.isStarting { ProgressView(textos.t("filtro.preparando")) }
            Text(filter.isStarting ? "Preparando: " + filter.selected.title : filter.selected == .ninguno ? filter.status : "Activo: " + filter.selected.title + " · " + filter.status).font(.system(size: 16)).foregroundStyle(.secondary)
            Text("Reproduce las matrices de color de Adapta PE sobre tus pantallas. Requiere Grabación de pantalla. Las imágenes se procesan localmente y no se guardan ni se envían.").foregroundStyle(.secondary)
            Text("Las matrices simulan alteraciones de color. No corrigen por sí mismas el daltonismo. Adapta PE queda fuera del filtro para que puedas desactivarlo.").font(.system(size: 15)).foregroundStyle(.secondary)
            Button(textos.t("filtro.quitarFiltro")) { filter.stop() }.disabled(filter.selected == .ninguno)
        }
    }
}

struct AISettings: View {
    @ObservedObject var ai: OptionalAI
    @ObservedObject private var textos = Textos.shared
    @State private var key = ""
    @State private var keyStatus = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(textos.t("ia.titulo")).font(.title2.bold())
            Text(textos.t("ia.descripcion")).foregroundStyle(.secondary)
            Toggle(textos.t("ia.activar"), isOn: $ai.isEnabled).toggleStyle(.switch).frame(minHeight: 44)
            VStack(alignment: .leading, spacing: 12) {
                TextField(textos.t("ia.endpoint"), text: $ai.endpoint).textFieldStyle(.roundedBorder)
                TextField(textos.t("ia.modelo"), text: $ai.model).textFieldStyle(.roundedBorder)
                SecureField(textos.t("ia.apiKey"), text: $key).textFieldStyle(.roundedBorder)
                HStack {
                    Button(textos.t("ia.guardar")) {
                        let result = APIKeyStore.save(key.trimmingCharacters(in: .whitespacesAndNewlines))
                        keyStatus = result == errSecSuccess ? "Clave guardada en Llavero" : "No se pudo guardar la clave (\(result))"
                        if result == errSecSuccess { key = "" }
                    }.disabled(key.isEmpty)
                    Button(textos.t("ia.eliminar")) { ai.cancel(); keyStatus = APIKeyStore.save("") == errSecSuccess ? "Clave eliminada" : "No se pudo eliminar la clave"; key = "" }
                }
                Text(keyStatus).font(.system(size: 15))
                Toggle(textos.t("ia.permitirPantalla"), isOn: $ai.allowScreenUpload)
                Text("Sólo durante esta sesión y al pedir «analiza pantalla con IA». Puede incluir datos privados. «Lee la pantalla» siempre usa lectura local.").font(.system(size: 15)).foregroundStyle(.secondary)
            }.disabled(!ai.isEnabled)
            Text("Usa «pregunta a la IA …» para enviar una consulta. Los comandos desconocidos nunca se envían automáticamente.").font(.system(size: 16)).foregroundStyle(.secondary)
            Text(ai.status).foregroundStyle(.secondary)
            if ai.isBusy { Button(textos.t("ia.cancelar")) { ai.cancel() } }
        }
    }
}

struct FloatingView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var tracker: TrackingManager
    @ObservedObject private var filter: ColorFilterManager
    @ObservedObject private var mascot: MascotManager
    @ObservedObject private var voice: VoiceManager
    @ObservedObject private var actions: ActionManager
    @ObservedObject private var textos = Textos.shared
    init(model: AppModel) { self.model = model; mascot = model.mascot; filter = model.colorFilter; tracker = model.tracker; voice = model.voice; actions = model.actions }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                PanelDragHandle(title: "Adapta PE", move: { mascot.touch(); model.moveFloating($0) }, save: model.saveFloatingPosition).frame(height: 44)
                Spacer()
                Menu {
                    Button(textos.t("ayuda.tutorialPractico"), systemImage: "graduationcap") { model.showTutorial() }
                    Divider()
                    Toggle(textos.t("control.moverMascotaYPanel"), isOn: Binding(get: { mascot.linked }, set: { mascot.linked = $0 })).disabled(mascot.name == "ninguna")
                    Menu(textos.t("control.elegirMascota")) {
                        ForEach(MascotManager.names, id: \.self) { name in
                            Button(MascotManager.titles[MascotManager.names.firstIndex(of: name)!]) { mascot.choose(name) }
                        }
                    }
                    Toggle(textos.t("control.mostrarCamara"), isOn: $model.previewVisible)
                    Menu(textos.t("control.filtroPantalla")) {
                        ForEach(ColorFilter.allCases) { filter in Button { mascot.react("laptop"); model.colorFilter.apply(filter) } label: { Label(filter.title, systemImage: self.filter.selected == filter ? "checkmark" : "circle") } }
                    }
                    Divider()
                    ForEach(PanelCorner.allCases, id: \.self) { corner in
                        Button { model.floatingCorner = corner } label: {
                            Label(corner.title, systemImage: model.floatingCorner == corner ? "checkmark" : "square")
                        }
                    }
                    if model.screens.count > 1 {
                        Divider()
                        ForEach(Array(model.screens.enumerated()), id: \.offset) { index, screen in
                            Button("Monitor \(index + 1) · \(screen.localizedName)") { model.floatingScreenID = AppModel.screenID(screen) }
                        }
                    }
                } label: { Text(textos.t("menu.opciones")).frame(minWidth: 44, minHeight: 44) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel(textos.t("panel.opcionesAcc")).help("Mascota, filtros, posición y monitor")
                Button(action: model.showSettings) { Image(systemName: "gearshape").frame(width: 44, height: 44) }
                    .modifier(FloatingSettingsStyle()).accessibilityLabel(textos.t("menu.abrirAjustes")).help(textos.t("menu.abrirAjustes"))
            }
            if model.previewVisible, tracker.isTracking || tracker.isStarting {
                CameraSurface(tracker: tracker).frame(height: 180)
            }
            HStack {
                Toggle(textos.t("control.voz"), isOn: Binding(get: { voice.isListening || voice.isStarting }, set: { _ in model.toggleVoice() })).toggleStyle(.switch)
                Toggle(textos.t("control.cursor"), isOn: Binding(get: { tracker.isTracking || tracker.isStarting }, set: { _ in model.toggleTracking() })).toggleStyle(.switch)
            }.frame(minHeight: 44)
            Text((voice.isListening || voice.isStarting ? voice.status : tracker.isTracking || tracker.isStarting ? tracker.statusMessage : textos.t("control.apagados")) + "\n" + (filter.selected == .ninguno ? filter.status : filter.selected.title + " · " + filter.status))
                .font(.callout).foregroundStyle(.primary).lineLimit(2).frame(height: 40, alignment: .leading).help(filter.status)
            Text(voice.transcript.isEmpty ? textos.t("control.aquiVeras") : "Escuché: " + voice.transcript)
                .font(.callout).lineLimit(2).frame(maxWidth: .infinity, minHeight: 32, alignment: .leading).accessibilityLabel("Último comando escuchado: " + voice.transcript)
            if !actions.confirmationPhrase.isEmpty {
                Text(textos.t("control.confirmarExacto")).font(.headline)
                ScrollView { Text(actions.confirmationPhrase).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 120)
                Button(textos.t("control.cancelarConfirmacion")) { actions.procesarIntencion("cancelar") }.frame(minHeight: 44)
            } else if actions.choices.isEmpty {
                Text(actions.lastResponse).font(.callout).foregroundStyle(.primary).lineLimit(2).frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(textos.t("control.eligeEn", ["contexto": actions.choiceContext])).font(.headline).lineLimit(1)
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(actions.choices.enumerated()), id: \.offset) { index, label in
                                Button { actions.choose(String(index + 1)) } label: {
                                    Text("\(index + 1). \(label)").lineLimit(1).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                    }.frame(minHeight: 44, maxHeight: CGFloat(actions.choices.count * 44))
                    HStack {
                        Button(textos.t("control.siguiente")) { actions.choose("siguiente") }
                        Button(textos.t("control.cancelar")) { actions.procesarIntencion("cancelar") }
                    }.frame(minHeight: 44)
                }
            }
            Button(role: .destructive, action: { model.stopAll() }) { Label(textos.t("menu.detenerTodo"), systemImage: "stop.circle").frame(maxWidth: .infinity) }.buttonStyle(AccessibleButtonStyle())
        }.padding(.horizontal, 16).padding(.vertical, 10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .font(.system(size: 16))
            .controlSize(model.controlScale == .large ? .extraLarge : model.controlScale == .medium ? .large : .regular)
    }
}

struct CameraSurface: View {
    @ObservedObject var tracker: TrackingManager
    var body: some View {
        ZStack {
            Color.black
            if tracker.isTracking {
                CameraPreview(session: tracker.captureSession)
                GeometryReader { geo in
                    let width = min(geo.size.width, geo.size.height / 0.75)
                    Circle().stroke(.orange.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [5])).frame(width: width * tracker.zonaAtraccionUI * 2).position(x: geo.size.width / 2, y: geo.size.height / 2)
                    Circle().fill(.green.opacity(0.15)).overlay(Circle().stroke(.green, lineWidth: 1.5)).frame(width: width * tracker.zonaMuertaRadioUI * 2).position(x: geo.size.width / 2, y: geo.size.height / 2)
                    if let point = tracker.detectedPointUI {
                        Circle().fill(.white).frame(width: 10, height: 10).position(x: geo.size.width / 2 + (point.x - 0.5) * width, y: geo.size.height / 2 + (point.y - 0.5) * width)
                    }
                }.allowsHitTesting(false).accessibilityHidden(true)
            } else {
                VStack(spacing: 10) {
                    if tracker.isStarting { ProgressView().tint(.white) }
                    else { Image(systemName: "video.slash").font(.title).foregroundStyle(.white) }
                    Text(tracker.isStarting ? Textos.t("camara.preparando") : Textos.t("camara.apagada")).font(.system(size: 16)).foregroundStyle(.white)
                }
            }
        }.overlay(alignment: .bottom) {
            if tracker.isTracking {
                VStack(spacing: 4) {
                    Text(tracker.statusMessage).font(.caption).lineLimit(2)
                    Text(Textos.t("camara.guiaColores")).font(.caption2)
                    ProgressView(value: tracker.clickProgress)
                        .accessibilityLabel(Textos.t("camara.progresoDwell"))
                }.padding(8).frame(maxWidth: .infinity)
                    .foregroundStyle(.white).tint(.white).background(.black.opacity(0.75))
            }
        }.clipShape(RoundedRectangle(cornerRadius: 14)).accessibilityLabel("Vista de cámara, " + tracker.trackingTypeUI)
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> PreviewView { PreviewView(session: session) }
    func updateNSView(_ view: PreviewView, context: Context) { view.preview.session = session }
}
final class PreviewView: NSView {
    let preview: AVCaptureVideoPreviewLayer
    init(session: AVCaptureSession) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero); wantsLayer = true; layer = CALayer(); layer?.addSublayer(preview)
        preview.videoGravity = .resizeAspect
        if let connection = preview.connection, connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = true }
    }
    required init?(coder: NSCoder) { nil }
    override func layout() { super.layout(); preview.frame = bounds }
}


// Superficie sólida y objetivo mínimo de 44 pt para ratón, cámara y navegación por teclado.
struct AccessibleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    func makeBody(configuration: Configuration) -> some View {
        let fill = configuration.role == .destructive ? Color(red: 0.65, green: 0.10, blue: 0.13) : Color(red: 0.04, green: 0.26, blue: 0.60)
        configuration.label.font(.system(size: 16, weight: .semibold))
            .padding(.horizontal, 12).frame(minWidth: 44, minHeight: 44)
            .foregroundStyle(isEnabled ? Color.white : Color(red: 0.32, green: 0.34, blue: 0.37))
            .background(isEnabled ? fill : Color(red: 0.86, green: 0.88, blue: 0.90), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).inset(by: 3).strokeBorder(Color.white, lineWidth: isFocused ? 2 : 0))
            .contentShape(RoundedRectangle(cornerRadius: 8)).opacity(configuration.isPressed ? 0.85 : 1)
    }
}


private struct FloatingSettingsStyle: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26, *), !reduceTransparency { content.buttonStyle(.glass) }
        else { content.buttonStyle(.plain) }
    }
}

private struct PanelDragHandle: NSViewRepresentable {
    let title: String
    let move: (CGPoint) -> Void
    let save: () -> Void
    func makeNSView(context: Context) -> PanelDragButton {
        let button = PanelDragButton(title: title, target: nil, action: nil)
        button.isBordered = false; button.font = .systemFont(ofSize: 16, weight: .semibold)
        button.setAccessibilityLabel(title + ": arrastra para mover el panel; enfoca y usa las flechas")
        button.toolTip = "Arrastra para mover. Con teclado: flechas."
        button.move = move; button.save = save; return button
    }
    func updateNSView(_ button: PanelDragButton, context: Context) { button.move = move; button.save = save }
}

private final class PanelDragButton: NSButton {
    override var needsPanelToBecomeKey: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    var move: ((CGPoint) -> Void)?
    var save: (() -> Void)?
    override func mouseDown(with event: NSEvent) { window?.makeKey(); window?.makeFirstResponder(self) }
    override func mouseDragged(with event: NSEvent) { move?(CGPoint(x: event.deltaX, y: -event.deltaY)) }
    override func mouseUp(with event: NSEvent) { save?() }
    override func keyDown(with event: NSEvent) {
        let moves: [UInt16: CGPoint] = [123: CGPoint(x: -24, y: 0), 124: CGPoint(x: 24, y: 0), 125: CGPoint(x: 0, y: -24), 126: CGPoint(x: 0, y: 24)]
        if let delta = moves[event.keyCode] { move?(delta); save?() } else { super.keyDown(with: event) }
    }
}

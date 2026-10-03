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
    @State private var section = "Control"
    @AppStorage("WakeWord") private var wakeWord = "computadora"
    init(model: AppModel) { self.model = model; tracker = model.tracker; voice = model.voice; actions = model.actions }
    var body: some View {
        ZStack {
            GeometryReader { geo in
                Image("FondoApp").resizable().scaledToFill().frame(width: max(0, geo.size.width), height: max(0, geo.size.height)).clipped().overlay(Color.black.opacity(0.5))
            }.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Adapta PE").font(.largeTitle.bold())
                        Text("Tu escritorio, a tu ritmo").font(.body)
                    }.foregroundStyle(.white)
                    Spacer()
                    Button("Panel flotante", systemImage: "pip") { model.showFloating() }
                }
                VStack(alignment: .leading, spacing: 18) {
                    Picker("Sección", selection: $section) {
                        Text("Control").tag("Control"); Text("Lectura y color").tag("Lectura")
                        Text("IA opcional").tag("IA"); Text("Ayuda").tag("Ayuda")
                    }.pickerStyle(.segmented).labelsHidden()
                    if tracker.isTracking || tracker.isStarting {
                        CameraSurface(tracker: tracker).frame(height: 180)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            switch section {
                            case "Control": controlSettings
                            case "Lectura": ReadingSettings(model: model)
                            case "IA": AISettings(ai: model.ai)
                            default: helpSettings
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(2)
                    }
                    Divider()
                    HStack {
                        Text("Cerrar esta ventana mantiene la asistencia activa.").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button(role: .destructive, action: { model.stopAll() }) { Label("Detener todo", systemImage: "stop.circle") }
                    }
                }.padding(20).background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
            }.padding(22)
        }.frame(minWidth: 580, minHeight: 580).font(.system(size: 16))
        .buttonStyle(AccessibleButtonStyle()).tint(Color(red: 0.04, green: 0.26, blue: 0.60))
    }
    private var controlSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Activa lo que necesitas").font(.title2.bold())
            Toggle(isOn: Binding(get: { voice.isListening || voice.isStarting }, set: { $0 ? voice.startListening() : voice.stopListening() })) {
                Label("Voz", systemImage: "mic")
                Text(voice.status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.toggleStyle(.switch).frame(minHeight: 44).accessibilityLabel("Control por voz").accessibilityValue(voice.status)
            Toggle(isOn: Binding(get: { tracker.isTracking || tracker.isStarting }, set: { $0 ? tracker.startTracking() : tracker.stopTracking() })) {
                Label("Cursor con cámara", systemImage: "viewfinder")
                Text(tracker.statusMessage).font(.callout).foregroundStyle(.secondary)
            }.toggleStyle(.switch).frame(minHeight: 44).accessibilityLabel("Cursor con cámara").accessibilityValue(tracker.statusMessage)
            if tracker.isTracking {
                HStack {
                    Button("Calibrar", systemImage: "scope") { tracker.calibrate() }
                    Button(tracker.isPaused ? "Reanudar cursor" : "Pausar cursor", systemImage: tracker.isPaused ? "play" : "pause") { tracker.isPaused.toggle() }
                }
            }
            Text("Di «\(wakeWord.isEmpty ? "computadora" : wakeWord), abre Zoom» o «anticlick» después del nombre. Puedes cerrar los ajustes y seguir usando la voz.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !voice.transcript.isEmpty { Text("Escuché: " + voice.transcript).font(.callout).lineLimit(2).accessibilityLabel("Último comando escuchado: " + voice.transcript) }
            Text(actions.lastResponse).font(.callout).foregroundStyle(.secondary).lineLimit(3).accessibilityLabel("Última respuesta: " + actions.lastResponse)
            if !model.accessibilityGranted {
                Button("Permitir control del escritorio", systemImage: "hand.raised") { model.requestAccessibility() }
                Text("Accesibilidad permite mover, pulsar y leer elementos. Sólo se solicita al activar esas funciones.").font(.callout).foregroundStyle(.secondary)
            }
            if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
                Button("Revisar permiso del micrófono") { model.openPrivacy("Microphone") }
            }
            if SFSpeechRecognizer.authorizationStatus() == .denied {
                Button("Revisar permiso de reconocimiento de voz") { model.openPrivacy("SpeechRecognition") }
            }
            if AVCaptureDevice.authorizationStatus(for: .video) == .denied {
                Button("Revisar permiso de la cámara") { model.openPrivacy("Camera") }
            }
            Divider()
            DisclosureGroup("Adaptar a mi movimiento") {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Control con", selection: $tracker.controlMode) {
                        Text("Automático").tag("automatico"); Text("Cabeza").tag("cabeza"); Text("Manos").tag("manos"); Text("Torso").tag("torso")
                        Text("Brazo izquierdo").tag("brazo_izquierdo"); Text("Brazo derecho").tag("brazo_derecho"); Text("Zona libre").tag("zona")
                    }
                    HStack { Text("Velocidad"); Slider(value: $tracker.sensitivity, in: 0.3...2, step: 0.1).accessibilityLabel("Velocidad del cursor"); Text(String(format: "%.1f×", tracker.sensitivity)).monospacedDigit() }
                    Toggle("Reducir temblores", isOn: $tracker.isParkinsonMode)
                    Toggle("Adaptar a movimientos pequeños", isOn: $tracker.reducedMovement)
                    Toggle("Clic al mantener la postura", isOn: $tracker.dwellEnabled)
                    HStack { Text("Espera de clic"); Slider(value: $tracker.dwellDuration, in: 0.4...3, step: 0.1).accessibilityLabel("Espera de clic"); Text(String(format: "%.1f s", tracker.dwellDuration)).monospacedDigit() }.disabled(!tracker.dwellEnabled)
                    Text("«Cursor más lento», «calibrar cursor» y «clic derecho» también funcionan por voz.").font(.callout).foregroundStyle(.secondary)
                }.padding(.top, 12)
            }
            DisclosureGroup("Dispositivos y preferencias") {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Cámara", selection: $tracker.selectedCameraID) {
                        if tracker.availableCameras.isEmpty { Text("Sin cámara").tag("") }
                        ForEach(tracker.availableCameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                    }
                    Picker("Micrófono", selection: $voice.selectedMicID) {
                        if voice.availableMics.isEmpty { Text("Sin micrófono").tag("") }
                        ForEach(voice.availableMics, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                    }
                    TextField("Nombre para llamar al asistente", text: $wakeWord).textFieldStyle(.roundedBorder).accessibilityLabel("Palabra de activación")
                    Text("Si dices sólo el nombre, tienes 8 segundos para dar la orden.").font(.callout).foregroundStyle(.secondary)
                    Toggle("Permitir reconocimiento de Apple por red", isOn: $voice.allowAppleNetwork)
                    Text("Apagado: reconocimiento local. Encendido: Apple puede procesar audio por red; no activa IA generativa.").font(.callout).foregroundStyle(.secondary)
                    Toggle("Iniciar al encender el Mac", isOn: Binding(get: { model.loginEnabled }, set: model.setLogin))
                    Text("Recuerda tus módulos y ajustes. Detener todo conserva los ajustes y apaga la asistencia hasta que la actives de nuevo.").font(.callout).foregroundStyle(.secondary)
                    Text("Pantallas disponibles").font(.headline)
                    ForEach(Array(model.screens.enumerated()), id: \.offset) { index, screen in
                        Text("\(index + 1). \(screen.localizedName) — \(Int(screen.frame.width)) × \(Int(screen.frame.height))")
                    }
                    Text("«Abre Visual Studio Code en el monitor dos»").font(.callout).foregroundStyle(.secondary)
                    Button("Actualizar dispositivos y permisos") { model.refreshPermissions() }
                    if !model.notice.isEmpty { Text(model.notice).foregroundStyle(.secondary) }
                }.padding(.top, 12)
            }
        }
    }
    private var helpSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button("Acciones de la app activa") { actions.procesarIntencion("muestra comandos") }
                Button("Buscar campos de texto") { actions.procesarIntencion("muestra campos") }
            }
            Text("Di «abre nueva ventana de Chrome», «presiona comando shift N» o «escribe Hola en el campo Nombre». Si hay varias opciones, responde «la segunda», di su nombre o «cancelar». Las opciones caducan a los 45 segundos; «siguiente» muestra más.").fixedSize(horizontal: false, vertical: true)
            Text("Empieza con una postura cómoda").font(.title2.bold())
            Text("1. Autoriza Accesibilidad.\n2. Elige cámara y control.\n3. Activa el cursor y mantén la postura al calibrar.\n4. Activa voz y prueba un comando.\n5. Usa el panel flotante o cierra ajustes.")
            Divider()
            Text("Comandos de ejemplo").font(.headline)
            Text("«Abre YouTube»\n«Busca movilidad en Wikipedia»\n«Escribe Hola, José»\n«Selecciona Contacto» / «Pulsa lo seleccionado»\n«Enfoca buscar» / «Enter»\n«Nueva pestaña» / «Atrás» / «Recarga»\n«Control cabeza» / «Control brazo izquierdo»\n«Calibrar cursor» / «Pausar cursor»\n«Siguiente clic derecho»\n«Activar TalkBack» / «Lee la pantalla»\n«Filtro deuteranopía» / «Quitar filtro»\n«Abre Safari en el segundo monitor»\n«Mostrar ajustes» / «Detener todo»")
            Text("La lectura y selección dependen de los elementos accesibles que expone cada aplicación. Campos protegidos no se leen ni se dictan. Zona libre rastrea textura; una oclusión puede exigir recalibrar.").font(.system(size: 15)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                Button("Accesibilidad") { model.openPrivacy("Accessibility") }
                Button("Cámara y micrófono") { model.openPrivacy("Camera") }
                Button("Grabación de pantalla") { model.openPrivacy("ScreenCapture") }
            }
            Button("Actualizar dispositivos y permisos") { model.refreshPermissions() }
        }
    }
}

struct ReadingSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var talkBack: TalkBackManager
    @ObservedObject private var filter: ColorFilterManager
    init(model: AppModel) { self.model = model; talkBack = model.talkBack; filter = model.colorFilter }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Lectura y color").font(.title2.bold())
            Toggle("Leer en voz alta el elemento bajo el cursor", isOn: $talkBack.isEnabled).toggleStyle(.switch).frame(minHeight: 44)
            Text("Mantén el cursor sobre un elemento para escucharlo. Funciona con el ratón y con la cámara.").foregroundStyle(.secondary)
            Button("Leer ventana activa", systemImage: "speaker.wave.2") { model.actions.procesarIntencion("lee la pantalla") }.controlSize(.large)
            Button("Detener lectura") { model.actions.callar() }
            Divider()
            Picker("Filtro de pantalla", selection: Binding(get: { filter.selected }, set: { filter.apply($0) })) {
                ForEach(ColorFilter.allCases) { Text($0.title).tag($0) }
            }
            if filter.isStarting { ProgressView() }
            Text(filter.status).font(.system(size: 16)).foregroundStyle(.secondary)
            Text("Reproduce las matrices de color de Adapta PE sobre tus pantallas. Requiere Grabación de pantalla. Las imágenes se procesan localmente y no se guardan ni se envían.").foregroundStyle(.secondary)
            Text("Las matrices simulan alteraciones de color. No corrigen por sí mismas el daltonismo. Adapta PE queda fuera del filtro para que puedas desactivarlo.").font(.system(size: 15)).foregroundStyle(.secondary)
            Button("Quitar filtro") { filter.stop() }.disabled(filter.selected == .ninguno)
        }
    }
}

struct AISettings: View {
    @ObservedObject var ai: OptionalAI
    @State private var key = ""
    @State private var keyStatus = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Tu API, sólo si la eliges").font(.title2.bold())
            Text("Todos los comandos, el cursor y TalkBack funcionan sin IA generativa. No se incluye un modelo local ni una suscripción.").foregroundStyle(.secondary)
            Toggle("Activar IA con mi API key", isOn: $ai.isEnabled).toggleStyle(.switch).frame(minHeight: 44)
            VStack(alignment: .leading, spacing: 12) {
                TextField("Endpoint HTTPS de chat/completions", text: $ai.endpoint).textFieldStyle(.roundedBorder)
                TextField("Modelo disponible en tu proveedor", text: $ai.model).textFieldStyle(.roundedBorder)
                SecureField("API key personal", text: $key).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Guardar en Llavero") {
                        let result = APIKeyStore.save(key.trimmingCharacters(in: .whitespacesAndNewlines))
                        keyStatus = result == errSecSuccess ? "Clave guardada en Llavero" : "No se pudo guardar la clave (\(result))"
                        if result == errSecSuccess { key = "" }
                    }.disabled(key.isEmpty)
                    Button("Eliminar clave") { ai.cancel(); keyStatus = APIKeyStore.save("") == errSecSuccess ? "Clave eliminada" : "No se pudo eliminar la clave"; key = "" }
                }
                Text(keyStatus).font(.system(size: 15))
                Toggle("Permitir envío de pantalla al proveedor", isOn: $ai.allowScreenUpload)
                Text("Sólo durante esta sesión y al pedir «analiza pantalla con IA». Puede incluir datos privados. «Lee la pantalla» siempre usa lectura local.").font(.system(size: 15)).foregroundStyle(.secondary)
            }.disabled(!ai.isEnabled)
            Text("Usa «pregunta a la IA …» para enviar una consulta. Los comandos desconocidos nunca se envían automáticamente.").font(.system(size: 16)).foregroundStyle(.secondary)
            Text(ai.status).foregroundStyle(.secondary)
            if ai.isBusy { Button("Cancelar consulta") { ai.cancel() } }
        }
    }
}

struct FloatingView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var tracker: TrackingManager
    @ObservedObject private var voice: VoiceManager
    @ObservedObject private var actions: ActionManager
    init(model: AppModel) { self.model = model; tracker = model.tracker; voice = model.voice; actions = model.actions }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("Adapta PE").font(.headline)
                Spacer()
                Menu {
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
                } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 44, height: 44) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Cambiar esquina del panel").help("Elegir esquina y monitor")
                Button(action: model.showSettings) { Image(systemName: "gearshape").frame(width: 44, height: 44) }
                    .buttonStyle(.plain).accessibilityLabel("Abrir ajustes").help("Abrir ajustes")
            }
            if tracker.isTracking || tracker.isStarting {
                CameraSurface(tracker: tracker).frame(height: 180)
            }
            Text(voice.isListening || voice.isStarting ? voice.status : tracker.isTracking ? tracker.statusMessage : "Asistencia apagada")
                .font(.callout).foregroundStyle(.secondary).lineLimit(1).frame(height: 24, alignment: .leading)
            Text(voice.transcript.isEmpty ? "Aquí verás lo que escuché" : "Escuché: " + voice.transcript)
                .font(.callout).lineLimit(2).frame(maxWidth: .infinity, minHeight: 32, alignment: .leading).accessibilityLabel("Último comando escuchado: " + voice.transcript)
            if actions.choices.isEmpty {
                Text(actions.lastResponse).font(.callout).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Elige en " + actions.choiceContext).font(.headline).lineLimit(1)
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
                        Button("Siguiente") { actions.choose("siguiente") }
                        Button("Cancelar") { actions.procesarIntencion("cancelar") }
                    }.frame(minHeight: 44)
                }
            }
            Button(role: .destructive, action: { model.stopAll() }) { Label("Detener todo", systemImage: "stop.circle").frame(maxWidth: .infinity) }.buttonStyle(AccessibleButtonStyle())
        }.padding(.horizontal, 16).padding(.vertical, 10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .font(.system(size: 16))
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
                    Text(tracker.isStarting ? "Preparando cámara" : "Cámara apagada").font(.system(size: 16)).foregroundStyle(.white)
                }
            }
        }.overlay(alignment: .bottom) {
            if tracker.isTracking {
                VStack(spacing: 4) {
                    Text(tracker.statusMessage).font(.caption).lineLimit(2)
                    Text("Verde: zona segura · Blanco: movimiento").font(.caption2)
                    ProgressView(value: tracker.clickProgress)
                        .accessibilityLabel("Progreso del clic por permanencia")
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
    func makeBody(configuration: Configuration) -> some View {
        let fill = configuration.role == .destructive ? Color(red: 0.65, green: 0.10, blue: 0.13) : Color(red: 0.04, green: 0.26, blue: 0.60)
        configuration.label.font(.system(size: 16, weight: .semibold))
            .padding(.horizontal, 12).frame(minWidth: 44, minHeight: 44)
            .foregroundStyle(isEnabled ? Color.white : Color(red: 0.32, green: 0.34, blue: 0.37))
            .background(isEnabled ? fill : Color(red: 0.86, green: 0.88, blue: 0.90), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8)).opacity(configuration.isPressed ? 0.85 : 1)
    }
}

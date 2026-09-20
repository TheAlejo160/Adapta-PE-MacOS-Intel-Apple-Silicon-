import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var tracker = TrackingManager()
    @StateObject private var voice = VoiceManager()
    
    // MEMORIA DE USUARIO (Persistencia de estados)
    @AppStorage("NvidiaAPIKey") private var apiKey: String = ""
    @AppStorage("WakeWord") private var wakeWord: String = "computadora"
    @AppStorage("isFloatingMode") private var isFloatingMode = true
    @AppStorage("isTrackingEnabled") private var isTrackingEnabled = false
    @AppStorage("isParkinsonMode") private var isParkinsonMode = false
    @AppStorage("isVoiceEnabled") private var isVoiceEnabled = false
    
    @State private var hoverHUD = false
    
    var body: some View {
        ZStack {
            if !isFloatingMode {
                Image("FondoApp")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 1672, height: 941)
                    .edgesIgnoringSafeArea(.all)
                    .opacity(0.3)
                    .background(Color.black)
            }
            
            VStack(spacing: isFloatingMode ? 0 : 20) {
                
                if isFloatingMode && !voice.transcript.isEmpty {
                    Text("💬 \(voice.transcript)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(Color.blue.opacity(0.8))
                        .cornerRadius(8)
                        .padding(.bottom, 4)
                }
                
                if !isFloatingMode {
                    HStack {
                        Image(nsImage: NSImage(named: "AppIcon") ?? NSImage())
                            .resizable().frame(width: 50, height: 50).cornerRadius(12).shadow(radius: 5)
                        Text("Adapta PE OS")
                            .font(.system(size: 28, weight: .bold, design: .rounded)).foregroundColor(.white)
                    }.padding(.top, 15)
                }
                
                ZStack(alignment: .topTrailing) {
                    Color.black.cornerRadius(isFloatingMode ? 16 : 12)
                    
                    if tracker.isTracking {
                        CameraPreview(session: tracker.captureSession)
                            .cornerRadius(isFloatingMode ? 16 : 12)
                            .scaleEffect(x: -1, y: 1)
                        
                        GeometryReader { geo in
                            let w = geo.size.width
                            let h = geo.size.height
                            let posX = w / 2
                            let posY = h / 2
                            
                            Path { path in
                                path.move(to: CGPoint(x: w/2, y: 0))
                                path.addLine(to: CGPoint(x: w/2, y: h))
                                path.move(to: CGPoint(x: 0, y: h/2))
                                path.addLine(to: CGPoint(x: w, y: h/2))
                            }.stroke(Color.white.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4]))
                            
                            let radioAtraccion = w * tracker.zonaAtraccionUI * 2
                            Circle()
                                .stroke(Color.orange, style: StrokeStyle(lineWidth: 2, dash: [5]))
                                .frame(width: radioAtraccion, height: radioAtraccion)
                                .position(x: posX, y: posY)
                            
                            let radioSeguro = w * tracker.zonaMuertaRadioUI * 2
                            Circle()
                                .stroke(Color.green.opacity(0.8), lineWidth: 2)
                                .background(Circle().fill(Color.green.opacity(0.1)))
                                .frame(width: radioSeguro, height: radioSeguro)
                                .position(x: posX, y: posY)
                            
                            if let tp = tracker.detectedPointUI {
                                Circle()
                                    .fill(tracker.trackingTypeUI.contains("✋") ? Color.red : Color.blue)
                                    .frame(width: 14, height: 14)
                                    .shadow(color: .white, radius: 2)
                                    .position(x: (1.0 - tp.x) * w, y: tp.y * h)
                            }
                        }
                    } else {
                        VStack {
                            Image(systemName: "video.slash.fill").font(.system(size: 24)).foregroundColor(.gray)
                            if isFloatingMode { Text("Pausado").font(.caption).foregroundColor(.gray) }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    
                    if isFloatingMode && hoverHUD {
                        Button(action: {
                            isFloatingMode.toggle()
                            applyWindowState()
                        }) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .foregroundColor(.white).padding(6).background(Color.black.opacity(0.6)).clipShape(Circle())
                        }.buttonStyle(PlainButtonStyle()).padding(8)
                    }
                }
                .frame(width: isFloatingMode ? 220 : 360, height: isFloatingMode ? 165 : 240)
                .shadow(radius: isFloatingMode ? 10 : 5)
                .onHover { hover in withAnimation { hoverHUD = hover } }
                
                if !isFloatingMode {
                    VStack(spacing: 15) {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Mouse Cinético", isOn: Binding(
                                get: { tracker.isTracking },
                                set: {
                                    isTrackingEnabled = $0
                                    if $0 { tracker.startTracking() } else { tracker.stopTracking() }
                                }
                            )).toggleStyle(SwitchToggleStyle(tint: .blue))
                            
                            Toggle("Modo Parkinson (Filtro Anti-Temblor)", isOn: Binding(
                                get: { tracker.isParkinsonMode },
                                set: {
                                    isParkinsonMode = $0
                                    tracker.isParkinsonMode = $0
                                }
                            )).toggleStyle(SwitchToggleStyle(tint: .purple))
                            
                            Picker("", selection: $tracker.selectedCameraID) {
                                ForEach(tracker.availableCameras, id: \.uniqueID) { cam in Text("🎥 " + cam.localizedName).tag(cam.uniqueID) }
                            }.labelsHidden()
                            Text(tracker.statusMessage).font(.caption).foregroundColor(.green).bold()
                        }.padding(12).background(Color.black.opacity(0.6)).cornerRadius(12)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Asistente Local", isOn: Binding(
                                get: { voice.isListening },
                                set: {
                                    isVoiceEnabled = $0
                                    if $0 { voice.startListening() } else { voice.stopListening() }
                                }
                            )).toggleStyle(SwitchToggleStyle(tint: .red))
                            
                            Picker("", selection: $voice.selectedMicID) {
                                ForEach(voice.availableMics, id: \.uniqueID) { mic in Text("🎙️ " + mic.localizedName).tag(mic.uniqueID) }
                            }.labelsHidden()
                            
                            HStack {
                                Text("🗣️").foregroundColor(.white)
                                TextField("Nombre (Ej. Jarvis)", text: $wakeWord).textFieldStyle(RoundedBorderTextFieldStyle())
                            }
                            
                            SecureField("🔑 NVIDIA API Key", text: $apiKey).textFieldStyle(RoundedBorderTextFieldStyle())
                            
                            Text(voice.status).font(.caption).foregroundColor(.yellow)
                            if !voice.transcript.isEmpty { Text("💬 \"\(voice.transcript)\"").font(.caption2).foregroundColor(.white).italic() }
                        }.padding(12).background(Color.black.opacity(0.6)).cornerRadius(12)
                        
                        Button(action: {
                            isFloatingMode.toggle()
                            applyWindowState()
                        }) {
                            Text("🔽 Activar PiP en Segundo Plano")
                                .fontWeight(.bold).frame(maxWidth: .infinity).padding(10)
                                .background(Color.blue.opacity(0.8)).foregroundColor(.white).cornerRadius(10)
                        }.buttonStyle(PlainButtonStyle())
                    }.frame(width: 420).padding(.horizontal, 20)
                }
            }
        }
        .frame(width: isFloatingMode ? 240 : 1672, height: isFloatingMode ? 220 : 941)
        .onAppear {
            tracker.fetchCameras()
            voice.fetchMics()
            
            tracker.isParkinsonMode = isParkinsonMode
            if isTrackingEnabled { tracker.startTracking() }
            if isVoiceEnabled { voice.startListening() }
            
            applyWindowState()
        }
    }
    
    private func applyWindowState() {
        guard let window = NSApplication.shared.windows.first else { return }
        
        if isFloatingMode {
            window.styleMask = [.borderless]
            window.backgroundColor = .clear
            
            // LA MAGIA DE macOS: Esto asegura que el PiP NUNCA sea tapado,
            // incluso si abres Chrome o YouTube en Pantalla Completa.
            window.level = .statusBar
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            
            if let screen = NSScreen.main {
                let x = screen.visibleFrame.maxX - 260
                let y = screen.visibleFrame.minY + 20
                window.setFrame(NSRect(x: x, y: y, width: 240, height: 220), display: true, animate: true)
            }
        } else {
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.backgroundColor = .windowBackgroundColor
            
            // Regresa la ventana a ser una aplicación de escritorio normal
            window.level = .normal
            window.collectionBehavior = []
            
            let currentFrame = window.frame
            window.setFrame(NSRect(x: currentFrame.minX, y: currentFrame.minY, width: 1672, height: 941), display: true, animate: true)
            window.center()
        }
    }
}

struct CameraPreview: NSViewRepresentable {
    var session: AVCaptureSession
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        view.layer = previewLayer
        view.wantsLayer = true
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        if let layer = nsView.layer?.sublayers?.first as? AVCaptureVideoPreviewLayer {
            layer.frame = nsView.bounds
        }
    }
}

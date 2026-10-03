import AppKit
import ScreenCaptureKit
import CoreImage
import Combine

// Matrices de las extensiones. Son simulaciones de color, no un tratamiento médico.
enum ColorFilter: String, CaseIterable, Identifiable {
    case ninguno, protanomalia, protanopia, deuteranomalia, deuteranopia, tritanomalia, tritanopia, acromatopsia
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ninguno: return "Sin filtro"
        case .protanomalia: return "Protanomalía"
        case .protanopia: return "Protanopía"
        case .deuteranomalia: return "Deuteranomalía"
        case .deuteranopia: return "Deuteranopía"
        case .tritanomalia: return "Tritanomalía"
        case .tritanopia: return "Tritanopía"
        case .acromatopsia: return "Acromatopsia"
        }
    }
    var matrix: [CGFloat] {
        switch self {
        case .ninguno: return [1,0,0, 0,1,0, 0,0,1]
        case .protanomalia: return [0.817,0.183,0, 0.333,0.667,0, 0,0.125,0.875]
        case .protanopia: return [0.567,0.433,0, 0.558,0.442,0, 0,0.242,0.758]
        case .deuteranomalia: return [0.8,0.2,0, 0.258,0.742,0, 0,0.142,0.858]
        case .deuteranopia: return [0.625,0.375,0, 0.7,0.3,0, 0,0.3,0.7]
        case .tritanomalia: return [0.967,0.033,0, 0,0.733,0.267, 0,0.183,0.817]
        case .tritanopia: return [0.95,0.05,0, 0,0.433,0.567, 0,0.475,0.525]
        case .acromatopsia: return [0.299,0.587,0.114, 0.299,0.587,0.114, 0.299,0.587,0.114]
        }
    }
}

@MainActor
final class ColorFilterManager: ObservableObject {
    @Published private(set) var selected: ColorFilter = .ninguno
    @Published private(set) var status = "Sin captura de pantalla"
    @Published private(set) var isStarting = false
    private var generation = 0
    private var outputs: [FilterOutput] = []
    private var streams: [SCStream] = []
    private var screenObserver: NSObjectProtocol?
    init() {
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in guard let self, self.selected != .ninguno else { return }; self.apply(self.selected) }
        }
    }
    func apply(_ filter: ColorFilter) {
        stop(); selected = filter
        guard filter != .ninguno else { return }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess(); selected = .ninguno; status = "Autoriza Grabación de pantalla y vuelve a activar el filtro"; return
        }
        isStarting = true; status = "Preparando filtro local…"; let token = generation
        let onError: () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.stop(); self.status = "Captura interrumpida. Reactiva el filtro."
            }
        }
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard self.generation == token else { return }
                let ownApp = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                for display in content.displays {
                    guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID }) else { continue }
                    let output = FilterOutput(frame: screen.frame, matrix: filter.matrix, onError: onError)
                    let config = SCStreamConfiguration()
                    config.width = display.width; config.height = display.height
                    config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                    config.queueDepth = 2; config.showsCursor = false; config.capturesAudio = false
                    let stream = SCStream(filter: SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: []), configuration: config, delegate: output)
                    try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
                    self.outputs.append(output); self.streams.append(stream)
                    try await stream.startCapture()
                    guard self.generation == token else { try? await stream.stopCapture(); return }
                    output.window.orderFrontRegardless()
                }
                self.isStarting = false; self.status = "\(filter.title) · filtro local en las pantallas"
            } catch {
                guard self.generation == token else { return }
                self.stop(); self.status = "No se pudo aplicar el filtro: \(error.localizedDescription)"
            }
        }
    }
    func stop() {
        generation += 1; isStarting = false; selected = .ninguno; status = "Sin captura de pantalla"
        for output in outputs { output.invalidate(); output.window.orderOut(nil) }
        let old = streams; streams.removeAll(); outputs.removeAll()
        Task { for stream in old { try? await stream.stopCapture() } }
    }
}

private final class FilterOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "pe.adapta.color", qos: .userInitiated)
    let window: NSPanel
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let filter: CIFilter
    private var pending = false
    private var valid = true
    private let onError: () -> Void
    init(frame: CGRect, matrix: [CGFloat], onError: @escaping () -> Void) {
        self.onError = onError
        filter = CIFilter(name: "CIColorMatrix")!
        filter.setValue(CIVector(x: matrix[0], y: matrix[1], z: matrix[2], w: 0), forKey: "inputRVector")
        filter.setValue(CIVector(x: matrix[3], y: matrix[4], z: matrix[5], w: 0), forKey: "inputGVector")
        filter.setValue(CIVector(x: matrix[6], y: matrix[7], z: matrix[8], w: 0), forKey: "inputBVector")
        window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        window.isOpaque = true; window.backgroundColor = .black; window.ignoresMouseEvents = true; window.hasShadow = false
        window.level = .floating; window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; window.isReleasedWhenClosed = false
        window.contentView?.wantsLayer = true; window.contentView?.layer?.contentsGravity = .resize
    }
    func invalidate() { queue.async { self.valid = false } }
    func stream(_ stream: SCStream, didStopWithError error: Error) { onError() }
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard valid, !pending, type == .screen, buffer.isValid, let pixel = CMSampleBufferGetImageBuffer(buffer),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        autoreleasepool {
            let image = CIImage(cvPixelBuffer: pixel); filter.setValue(image, forKey: kCIInputImageKey)
            guard let result = filter.outputImage, let rendered = context.createCGImage(result, from: result.extent) else { return }
            pending = true
            DispatchQueue.main.async {
                self.window.contentView?.layer?.contents = rendered
                self.queue.async { self.pending = false }
            }
        }
    }
}

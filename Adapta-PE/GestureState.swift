import Foundation
import CoreGraphics

/// Joystick de extremidades (paridad con `KineticEngine.controlarGesto()` de la extensión 13.0).
/// Coordenadas normalizadas a la imagen; la salida se centra en 0,5. Umbrales sin validar con cámaras reales.
struct GestureState {
    enum Event { case none, rest, restExit, inputChanged }
    var deadRadius = KineticDefaults.zonaMuerta
    var amplitude = 1.0
    private(set) var resetNow = false
    private(set) var event = Event.none
    private(set) var signalActive = false
    private(set) var joystick = false
    private(set) var fistActive = false
    private(set) var fistDetected = false
    private(set) var openRecently = false
    private var reference: CGPoint?
    private var referenceTilt: CGPoint?
    private var candidate: (tilt: CGPoint, time: Double)?
    private var lastTime: Double?
    private var lastAngle: Double?
    private var rotation = 0.0
    private var openSeen: Double?
    private var fistSince: Double?
    private var fistCount = 0
    private var fistDoubt: Double?
    private var fistExit: Double?
    private var output = CGPoint(x: 0.5, y: 0.5)

    mutating func reset() { let radius = deadRadius, scale = amplitude; self = GestureState(); deadRadius = radius; amplitude = scale }
    /// Pérdida o clic por pinza: olvida el cierre en curso; abrir la mano vuelve a ser obligatorio.
    mutating func forgetFist() { fistActive = false; fistSince = nil; fistCount = 0; fistDoubt = nil; fistExit = nil; openSeen = nil; openRecently = false }
    /// Cambio mano↔Pose: los modelos difieren unos píxeles; desplazar el reposo evita leerlo como movimiento.
    mutating func shift(by delta: CGPoint) { reference?.x += delta.x; reference?.y += delta.y }

    mutating func update(_ point: CGPoint, time: Double, tilt: CGPoint? = nil, pointing: Bool = false, angle: Double? = nil, open: Bool = false, fist: Bool = false) -> CGPoint {
        resetNow = false; event = .none
        let tilt = tilt.flatMap { $0.x.isFinite && $0.y.isFinite ? $0 : nil }
        let pointing = pointing && tilt != nil
        // Acotar el ángulo impide bucles de normalización con entradas extremas.
        let angle = angle.flatMap { $0.isFinite ? $0.truncatingRemainder(dividingBy: 2 * .pi) : nil }
        guard point.x.isFinite, point.y.isFinite, time.isFinite else { reset(); resetNow = true; return output }
        if let lastTime, time <= lastTime { return output }
        if let lastTime, time - lastTime > KineticDefaults.reinicioJoystick + 0.0001 { reset(); resetNow = true }
        let open = open || pointing
        guard reference != nil else {
            resetNow = true; reference = point; referenceTilt = pointing ? nil : tilt
            candidate = pointing ? tilt.map { ($0, time) } : nil
            openSeen = open ? time : nil; openRecently = open; fistDetected = fist
            lastAngle = angle; lastTime = time; return output
        }
        lastTime = time

        // Puño-reposo: apertura previa, cierre >=120 ms con >=3 inferencias; un clic por cierre.
        fistDetected = fist
        let wasRest = fistActive
        if open { openSeen = time }
        openRecently = openSeen.map { time - $0 <= KineticDefaults.punoAperturaRecordada } ?? false
        if fist && (wasRest || openRecently || fistSince != nil) {
            let since = fistSince ?? time
            fistSince = since; fistCount += 1; fistDoubt = nil; fistExit = nil
            fistActive = wasRest || time - since >= KineticDefaults.punoConfirmar && fistCount >= KineticDefaults.punoInferencias
            if fistActive { openSeen = nil } // Cada clic exige volver a abrir la mano.
        } else if wasRest && (open || fistExit != nil) {
            let exit = fistExit ?? time
            fistExit = exit; event = .restExit
            if time - exit >= KineticDefaults.punoSalida { fistActive = false; fistSince = nil; fistCount = 0 }
        } else if !open && (wasRest || fistSince != nil) && time - (fistDoubt ?? time) < KineticDefaults.punoAmbiguo {
            if fistDoubt == nil { fistDoubt = time } // Imagen ambigua: conservar el puño hasta 400 ms.
        } else { fistSince = nil; fistCount = 0; fistActive = false; fistDoubt = nil }
        if wasRest != fistActive {
            event = fistActive ? .rest : .restExit
            signalActive = false; candidate = nil
            if !fistActive { reference = point; joystick = false; referenceTilt = pointing ? nil : tilt }
        }
        if fistActive { output = CGPoint(x: 0.5, y: 0.5); return output }
        let rest = reference ?? point

        if let angle, let lastAngle {
            var step = angle - lastAngle
            while step > .pi { step -= 2 * .pi }; while step < -.pi { step += 2 * .pi }
            rotation = atan2(sin(rotation + step), cos(rotation + step))
        }
        lastAngle = angle
        if referenceTilt == nil, !pointing { referenceTilt = tilt }

        // Señal confirmada (>=50 ms, direcciones compatibles) prevalece sobre el desplazamiento.
        let signalBefore = signalActive
        if pointing, let tilt {
            if let previous = candidate?.tilt {
                let dot = tilt.x * previous.x + tilt.y * previous.y
                if !signalBefore && dot < KineticDefaults.senalCoseno * hypot(tilt.x, tilt.y) * hypot(previous.x, previous.y) { candidate = (tilt, time) }
            } else { candidate = (tilt, time) }
            signalActive = signalBefore || time - (candidate?.time ?? time) >= KineticDefaults.senalConfirmar
        } else { candidate = nil; signalActive = false }
        if signalBefore != signalActive { event = .inputChanged }

        // Joystick relativo con histéresis: entra en zonaMuerta+0,004 y sale por debajo de zonaMuerta×0,85.
        var dx = (point.x - rest.x) * KineticDefaults.ganancia, dy = (point.y - rest.y) * KineticDefaults.ganancia
        let displacement = hypot(dx, dy) / amplitude
        joystick = displacement > (joystick ? deadRadius * KineticDefaults.salidaJoystick : deadRadius + KineticDefaults.entradaJoystick)
        if signalActive, let tilt { dx = tilt.x; dy = tilt.y }
        else if !joystick && !pointing {
            dx = 0; dy = 0
            if let tilt, let start = referenceTilt { dx = tilt.x - start.x; dy = tilt.y - start.y }
            else if rotation != 0 { dx = rotation * 0.9 }
        } else {
            if abs(dx) < abs(dy) * KineticDefaults.perpendicularJoystick { dx = 0 }
            if abs(dy) < abs(dx) * KineticDefaults.perpendicularJoystick { dy = 0 }
        }
        if !signalActive && !joystick && hypot(dx, dy) / amplitude <= deadRadius + KineticDefaults.entradaJoystick { dx = 0; dy = 0 }
        let limit = KineticDefaults.limiteGesto
        output = CGPoint(x: 0.5 + max(-limit, min(limit, dx)), y: 0.5 + max(-limit, min(limit, dy)))
        return output
    }
}

enum ClickSignal: Equatable { case active, intermediate, released }

struct HandPose: Equatable {
    var tilt: CGPoint?
    var pointing = false
    var open = false
    var fist = false
    var angle: Double?
}

/// Geometría de la mano en orden MediaPipe 0…20 (Vision se traduce a ese orden). Puntos normalizados y
/// espejados; nil = punto poco fiable. `aspect` = alto/ancho de la imagen. Vision no da profundidad: 2D.
enum HandGeometry {
    private static let fingers = [(5, 8), (9, 12), (13, 16), (17, 20)]
    static func valid(_ points: [CGPoint?], _ index: Int) -> Bool {
        guard points.indices.contains(index), let p = points[index] else { return false }
        return p.x.isFinite && p.y.isFinite && p.x >= 0 && p.x <= 1 && p.y >= 0 && p.y <= 1
    }
    private static func vector(_ points: [CGPoint?], _ a: Int, _ b: Int, _ aspect: Double) -> CGPoint {
        CGPoint(x: points[b]!.x - points[a]!.x, y: (points[b]!.y - points[a]!.y) * aspect)
    }
    private static func distance(_ points: [CGPoint?], _ a: Int, _ b: Int, _ aspect: Double) -> Double {
        let v = vector(points, a, b, aspect); return hypot(v.x, v.y)
    }

    /// Mano falsa: índice de la mano que puede controlar, o nil. En continuidad (a <0,2 de la anterior) una mano fiable
    /// (>=0,8) gana a una dudosa aunque ésta quede más cerca; seguir sin pérdida admite >=0,6, adquirir exige >=0,8.
    static func choose(_ hands: [(anchor: CGPoint, confidence: Double, skeleton: Bool)], previous: CGPoint?, tracking: Bool) -> Int? {
        func distance(_ point: CGPoint) -> Double { previous.map { hypot(point.x - $0.x, point.y - $0.y) } ?? .infinity }
        let reliable = { (hand: (anchor: CGPoint, confidence: Double, skeleton: Bool)) in hand.confidence >= KineticDefaults.manoAdquirir }
        let near = hands.indices.filter { distance(hands[$0].anchor) < 0.2 && hands[$0].confidence >= KineticDefaults.manoConservar }
            .min { reliable(hands[$0]) != reliable(hands[$1]) ? reliable(hands[$0]) : distance(hands[$0].anchor) < distance(hands[$1].anchor) }
        guard let index = near ?? hands.indices.max(by: { hands[$0].confidence < hands[$1].confidence }) else { return nil }
        let minimum = tracking && near != nil ? KineticDefaults.manoConservar : KineticDefaults.manoAdquirir
        return hands[index].confidence >= minimum && hands[index].skeleton ? index : nil
    }

    /// Esqueleto invisible: rechaza proporciones imposibles (falsos positivos en rostro, ropa o fondo).
    static func skeletonValid(_ points: [CGPoint?], aspect: Double = 0.75) -> Bool {
        guard points.count >= 21, points.allSatisfy({ $0.map { $0.x.isFinite && $0.y.isFinite } ?? false }) else { return true }
        let palm = [5, 9, 13, 17].reduce(0.0) { $0 + distance(points, 0, $1, aspect) } / 4
        guard palm >= 0.025 else { return false }
        let width = distance(points, 5, 17, aspect) / palm
        return width >= 0.3 && width <= 1.6 && [5, 9, 13, 17].allSatisfy { base in
            (distance(points, base, base + 1, aspect) + distance(points, base + 1, base + 2, aspect) + distance(points, base + 2, base + 3, aspect)) / palm <= 2.5
        }
    }

    /// Pinza pulgar (4) - índice (8) normalizada por muñeca - nudillo medio (0-9).
    static func pinch(_ points: [CGPoint?], aspect: Double = 0.75) -> ClickSignal? {
        guard [0, 4, 5, 6, 8, 9].allSatisfy({ valid(points, $0) }) else { return nil }
        let size = distance(points, 0, 9, aspect)
        guard size >= 0.03 else { return nil }
        let pinch = distance(points, 4, 8, aspect) / size
        if pinch >= KineticDefaults.pinzaSuelta { return .released }
        if pinch > KineticDefaults.pinzaActiva { return .intermediate }
        // En un puño el pulgar cubre la falange media y la punta del índice se recoge hacia la palma.
        return distance(points, 4, 8, aspect) < distance(points, 4, 6, aspect) && distance(points, 0, 8, aspect) > distance(points, 0, 5, aspect) ? .active : nil
    }

    static func pose(_ points: [CGPoint?], aspect: Double = 0.75) -> HandPose {
        let ok = { valid(points, $0) }
        let complete = fingers.allSatisfy { [0, $0.0, $0.0 + 1, $0.0 + 2, $0.1].allSatisfy(ok) }
        func segments(_ base: Int) -> [Double] { [base, base + 1, base + 2].map { distance(points, $0, $0 + 1, aspect) } }
        let straightness: [Double] = complete ? fingers.map { base, tip in
            let parts = segments(base)
            return parts.allSatisfy { $0 > 0.0001 } ? distance(points, base, tip, aspect) / parts.reduce(0, +) : .nan
        } : []
        // El modelo suele estirar un dedo de un puño real: bastan tres doblados si ninguno queda extendido.
        let fist = complete && straightness.allSatisfy(\.isFinite) && straightness.filter { $0 < 0.75 }.count >= 3 && straightness.allSatisfy { $0 < 0.9 }
        let extended = fingers.filter { base, tip in
            guard ok(base), ok(tip) else { return false }
            let length = distance(points, base, tip, aspect)
            guard length >= 0.015 else { return false }
            if ok(base + 1), ok(base + 2) { let parts = segments(base); return parts.allSatisfy { $0 > 0.0001 } && length >= parts.reduce(0, +) * 0.9 }
            return ok(0) && distance(points, 0, base, aspect) > 0.0001 && distance(points, 0, tip, aspect) > distance(points, 0, base, aspect) * 1.25
        }.map { vector(points, $0.0, $0.1, aspect) }
        let pointing = !extended.isEmpty && extended.allSatisfy { finger in
            finger.x * extended[0].x + finger.y * extended[0].y >= 0.85 * hypot(finger.x, finger.y) * hypot(extended[0].x, extended[0].y)
        }
        let angle = ok(0) && ok(9) ? { let v = vector(points, 0, 9, aspect); return Double(atan2(v.y, v.x)) }() : nil
        var pose = HandPose(open: !extended.isEmpty, fist: fist, angle: angle)
        guard pointing else { return pose }
        var direction = extended.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        if abs(direction.x) < abs(direction.y) * KineticDefaults.perpendicularSenal { direction.x = 0 }
        if abs(direction.y) < abs(direction.x) * KineticDefaults.perpendicularSenal { direction.y = 0 }
        let length = hypot(direction.x, direction.y)
        guard length >= 0.0001, length.isFinite else { return pose }
        pose.pointing = true
        pose.tilt = CGPoint(x: direction.x / length * KineticDefaults.limiteGesto, y: direction.y / length * KineticDefaults.limiteGesto)
        return pose
    }

    /// Apertura de boca 0…1 equivalente a jawOpen: alto/ancho de innerLips (en píxeles) dividido por 0,9.
    static func mouth(_ innerLips: [CGPoint]) -> Double? {
        guard innerLips.count >= 4, innerLips.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let xs = innerLips.map(\.x), ys = innerLips.map(\.y)
        let width = xs.max()! - xs.min()!, height = ys.max()! - ys.min()!
        guard width > 0.0001 else { return nil }
        return min(1, max(0, height / width / KineticDefaults.bocaEscala))
    }
    /// Histéresis amplia para no confundir el habla con un clic.
    static func mouthSignal(_ value: Double?) -> ClickSignal? {
        guard let value, value.isFinite else { return nil }
        return value >= KineticDefaults.bocaActiva ? .active : value <= KineticDefaults.bocaSuelta ? .released : .intermediate
    }
}

/// Clic por pinza (manos) o boca (cabeza): un clic por gesto, al soltar; exige verlo suelto antes.
struct ClickGesture {
    enum Kind { case pinch, mouth }
    enum Output { case none, click, rightClick }
    private var released = false
    private var last: Double?
    private var start: Double?
    private var count = 0
    private var confirmed = false
    private(set) var rightDone = false

    mutating func reset() { self = ClickGesture() }

    /// `holding` mantiene el cursor quieto mientras el gesto está en curso.
    mutating func update(_ signal: ClickSignal?, kind: Kind, inference: Double) -> (holding: Bool, output: Output) {
        let pinch = kind == .pinch
        let (inferences, confirm, right, maximum) = pinch ?
            (KineticDefaults.pinzaInferencias, KineticDefaults.pinzaConfirmar, KineticDefaults.pinzaDerecho, Double.infinity) :
            (KineticDefaults.bocaInferencias, KineticDefaults.bocaConfirmar, Double.infinity, KineticDefaults.bocaMaximo)
        if inference == last { return (start != nil, .none) } // Una imagen repetida no confirma ni suelta.
        // Salto >200 ms (pérdida, Vision atascada): desarmar sin clic y exigir ver el gesto suelto otra vez.
        if let last, inference - last > KineticDefaults.desarmeClic { self = ClickGesture() }
        last = inference
        guard let signal, signal != .released else {
            // Suelto: clic si estaba confirmado. Pulgar oculto, puño o puntos poco fiables: cancelar y exigir soltar.
            let click = signal == .released && confirmed && !rightDone
            self = ClickGesture(); released = signal == .released; last = inference
            return (false, click ? .click : .none)
        }
        if signal == .active, released, start == nil { start = inference }
        guard let start else { return (false, .none) }
        // Antes de confirmar, la banda intermedia (habla, mano relajada) reinicia la cuenta y no congela el cursor.
        if signal == .intermediate && !confirmed { self.start = nil; count = 0; return (false, .none) }
        count += 1
        let duration = inference - start
        if duration >= maximum { self = ClickGesture(); last = inference; return (false, .none) } // Bostezo: sin clic.
        if !confirmed, count >= inferences, duration >= confirm { confirmed = true }
        if confirmed, !rightDone, duration >= right { rightDone = true; return (true, .rightClick) }
        return (true, .none)
    }
}

/// Carga adaptativa (`medirCarga()` de voz/camara.js): media 80/20 del tiempo de inferencia.
struct AdaptiveLoad {
    private(set) var level = 0
    private(set) var rest = 0.0 // segundos de descanso antes de aceptar otra imagen
    private var mean: Double?
    private var samples = 0
    private var discard = true

    mutating func reset() { self = AdaptiveLoad() }
    /// `milliseconds`: duración de una inferencia. `maxLevel`: 2 en manos (640→480→320), 1 en cabeza/zona.
    mutating func measure(_ milliseconds: Double, maxLevel: Int) {
        // La primera inferencia tras cambiar modelo o detalle incluye calentamiento.
        guard !discard, milliseconds >= 0, milliseconds < 1000 else { discard = false; return }
        let average = mean.map { $0 * 0.8 + milliseconds * 0.2 } ?? milliseconds
        mean = average; samples += 1
        if samples >= KineticDefaults.cargaMuestras {
            let next = average > KineticDefaults.cargaAlta ? min(maxLevel, level + 1) : average < KineticDefaults.cargaBaja ? max(0, level - 1) : level
            if next != level { self = AdaptiveLoad(); level = next; return }
        }
        rest = average > KineticDefaults.cargaAlta ? max(0, min(average * 0.5, 130 - average)) / 1000 : 0
    }
    /// Escala de la imagen enviada a Vision; nunca amplía.
    var scale: Double { [1, 0.75, 0.5][min(2, max(0, level))] }
}

enum ControlModes {
    static func normalize(_ mode: String) -> String { if ["cabeza", "torso"].contains(mode) { return "cabeza" }; return mode.hasPrefix("zona") ? "zona" : "manos" }
}

func cursorAttraction(_ point: CGPoint, center: CGPoint, speed: Double, dt: Double) -> CGPoint {
    guard point.x.isFinite, point.y.isFinite, center.x.isFinite, center.y.isFinite, hypot(point.x - center.x, point.y - center.y) <= KineticDefaults.atraccionRadio, speed <= KineticDefaults.atraccionVelocidad, dt > 0 else { return point }
    let alpha = 1 - exp(-min(0.05, dt) / 0.12)
    return CGPoint(x: point.x + (center.x - point.x) * alpha, y: point.y + (center.y - point.y) * alpha)
}

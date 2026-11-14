import CoreGraphics
import Foundation

// Física independiente de la cámara: tiempo monotónico, sin temporizadores por fotograma.
struct KineticState {
    var fixedCenter = false
    var tremor = false
    var sensitivity: Double = 1
    var amplitude: Double = 1
    var dwellDuration: Double = 1
    var dwellEnabled = true
    private(set) var velocity = CGPoint.zero
    private(set) var origin: CGPoint?
    private(set) var smooth = CGPoint(x: 0.5, y: 0.5)
    private(set) var progress: Double = 0
    private(set) var calibratedNow = false
    private var samples: [(Double, CGPoint)] = []
    private var history: [CGPoint] = []
    private var lastTime: Double?
    private var armSince: Double?
    private var dwellSince: Double?
    private var armed = false
    private var safe = false
    private var targetID: String?
    private var pendingTarget: (id: String, since: Double)?
    var deadRadius: Double { tremor ? KineticDefaults.zonaMuertaTemblor : KineticDefaults.zonaMuerta }
    var attractionRadius: Double { deadRadius + KineticDefaults.margenAtraccion }

    mutating func cancelClick() { cancelFixation(); armSince = nil; armed = false; safe = false }
    /// Reinicia el dwell sin desarmar (señal o puño en curso).
    mutating func cancelFixation() { dwellSince = nil; progress = 0; targetID = nil; pendingTarget = nil }
    /// Centra el suavizado: un cambio de entrada (señal, puño) no se lee como movimiento.
    mutating func recenter() { smooth = CGPoint(x: 0.5, y: 0.5); velocity = .zero; if let origin { history = [origin, origin] } }
    /// Puño deliberado: arma el dwell sin exigir salir de la zona segura.
    mutating func armRest() { guard origin != nil else { return }; cancelFixation(); armed = true }
    mutating func calibrate() {
        velocity = .zero
        origin = fixedCenter ? CGPoint(x: 0.5, y: 0.5) : nil; samples.removeAll(keepingCapacity: true); history.removeAll(keepingCapacity: true)
        if fixedCenter { history = [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.5, y: 0.5)] }
        lastTime = nil; smooth = CGPoint(x: 0.5, y: 0.5); cancelClick()
    }
    mutating func lost(at time: Double) {
        velocity = .zero
        cancelClick()
        samples.removeAll(keepingCapacity: true)
        if let lastTime, time - lastTime >= 1.2 { calibrate() }
    }
    private func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    mutating func update(_ point: CGPoint, time: Double, aspect: Double = 0.75, target: String?) -> (delta: CGPoint, click: Bool) {
        velocity = .zero; calibratedNow = false
        guard point.x.isFinite, point.y.isFinite, time.isFinite else { lost(at: time); return (.zero, false) }
        let interval = lastTime.map { time - $0 } ?? 0
        if interval > 1.2 { calibrate() }
        if interval < 0 || interval > 0.2 { cancelClick(); history.removeAll(keepingCapacity: true) }
        lastTime = time
        if origin == nil {
            samples.append((time, point)); samples.removeAll { time - $0.0 > 1.2 }
            guard samples.count >= 4, time - samples[0].0 >= 0.9 else { return (.zero, false) }
            let center = CGPoint(x: median(samples.map { $0.1.x }), y: median(samples.map { $0.1.y }))
            let distances = samples.map { hypot($0.1.x - center.x, ($0.1.y - center.y) * aspect) }.sorted()
            let third = max(1, samples.count / 3)
            let drift = hypot(median(samples.prefix(third).map { $0.1.x }) - median(samples.suffix(third).map { $0.1.x }),
                              (median(samples.prefix(third).map { $0.1.y }) - median(samples.suffix(third).map { $0.1.y })) * aspect)
            guard drift <= 0.012, distances[Int(Double(distances.count) * 0.8)] <= (tremor ? 0.045 : 0.025) else { return (.zero, false) }
            origin = center; history = [center, center]; samples.removeAll(keepingCapacity: true); calibratedNow = true
            cancelClick(); return (.zero, false)
        }
        guard let origin else { return (.zero, false) }
        history.append(point); if history.count > 3 { history.removeFirst() }
        guard history.count == 3 else { return (.zero, false) }
        let filtered = tremor ? CGPoint(x: median(history.map { Double($0.x) }), y: median(history.map { Double($0.y) })) : point
        let rawX = (filtered.x - origin.x) / amplitude
        let rawY = (filtered.y - origin.y) * aspect / amplitude
        let rawDistance = hypot(rawX, rawY)
        let dt = min(max(interval, 0), 0.25)
        let alpha = 1 - exp(-dt / (tremor ? KineticDefaults.emaTemblor : rawDistance > attractionRadius + 0.025 ? KineticDefaults.emaLejos : KineticDefaults.emaCerca))
        // Extremidades: volver dentro de la zona muerta centra la EMA sin avance residual.
        if fixedCenter, rawDistance <= deadRadius { smooth = CGPoint(x: 0.5, y: 0.5) }
        else { smooth.x += (0.5 + rawX - smooth.x) * alpha; smooth.y += (0.5 + rawY - smooth.y) * alpha }
        let dx = smooth.x - 0.5, dy = smooth.y - 0.5
        let distance = hypot(dx, dy)
        let radius = deadRadius + (safe ? 0.008 : 0)
        safe = distance <= radius && rawDistance <= radius + 0.025
        if safe {
            armSince = nil
            guard armed, dwellEnabled, let target else { cancelFixation(); return (.zero, false) }
            // Histéresis de identidad: otra celda u otro hash AX sólo reinicia el dwell si se mantiene.
            if targetID == nil { targetID = target; dwellSince = time; pendingTarget = nil }
            else if targetID != target {
                if pendingTarget?.id != target { pendingTarget = (target, time) }
                if let pending = pendingTarget, time - pending.since >= KineticDefaults.cambioObjetivo { targetID = target; dwellSince = pending.since; pendingTarget = nil }
            } else { pendingTarget = nil }
            progress = min(1, (time - (dwellSince ?? time)) / min(KineticDefaults.dwellMaximo, max(KineticDefaults.dwellMinimo, dwellDuration)))
            if progress >= 1 { cancelClick(); return (.zero, true) }
            return (.zero, false)
        }
        cancelFixation()
        if rawDistance > attractionRadius && distance > attractionRadius {
            if armSince == nil { armSince = time }
            if time - (armSince ?? time) >= KineticDefaults.armado { armed = true }
        } else { armSince = nil }
        guard distance > 0, hypot((point.x - origin.x) / amplitude, (point.y - origin.y) * aspect / amplitude) > deadRadius else { return (.zero, false) }
        let advance = max(0, distance - deadRadius)
        let maximum = tremor ? KineticDefaults.velocidadMaximaTemblor : KineticDefaults.velocidadMaxima
        let speed = distance <= attractionRadius ? 24 * pow(advance / (attractionRadius - deadRadius), 2) : min(maximum, 24 + pow((distance - attractionRadius) * 6, 1.6) * 160)
        let rate = min(maximum, speed * sensitivity)
        velocity = CGPoint(x: dx / distance * rate, y: dy / distance * rate)
        let step = rate * dt
        return (CGPoint(x: dx / distance * step, y: dy / distance * step), false)
    }
}


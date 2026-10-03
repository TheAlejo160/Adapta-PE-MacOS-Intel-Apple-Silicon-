import CoreGraphics
import Foundation

// Física independiente de la cámara: tiempo monotónico, sin temporizadores por fotograma.
struct KineticState {
    var tremor = false
    var sensitivity: Double = 1
    var amplitude: Double = 1
    var dwellDuration: Double = 1
    var dwellEnabled = true
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
    var deadRadius: Double { tremor ? 0.07 : 0.045 }
    var attractionRadius: Double { deadRadius + 0.02 }

    mutating func cancelClick() { armSince = nil; dwellSince = nil; armed = false; progress = 0; targetID = nil; safe = false }
    mutating func calibrate() {
        origin = nil; samples.removeAll(keepingCapacity: true); history.removeAll(keepingCapacity: true)
        lastTime = nil; smooth = CGPoint(x: 0.5, y: 0.5); cancelClick()
    }
    mutating func lost(at time: Double) {
        cancelClick()
        samples.removeAll(keepingCapacity: true)
        if let lastTime, time - lastTime >= 1.2 { calibrate() }
    }
    private func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    mutating func update(_ point: CGPoint, time: Double, aspect: Double = 0.75, target: String?) -> (delta: CGPoint, click: Bool) {
        calibratedNow = false
        guard point.x.isFinite, point.y.isFinite, time.isFinite else { lost(at: time); return (.zero, false) }
        let interval = lastTime.map { time - $0 } ?? 0
        if interval > 1.2 { calibrate() }
        if interval < 0 || interval > 0.5 { cancelClick(); history.removeAll(keepingCapacity: true) }
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
        let filtered = CGPoint(x: median(history.map { Double($0.x) }), y: median(history.map { Double($0.y) }))
        let rawX = (filtered.x - origin.x) / amplitude
        let rawY = (filtered.y - origin.y) * aspect / amplitude
        let rawDistance = hypot(rawX, rawY)
        let dt = min(max(interval, 0), 0.1)
        let alpha = 1 - exp(-dt / (tremor ? 0.24 : rawDistance > attractionRadius + 0.025 ? 0.085 : 0.18))
        smooth.x += (0.5 + rawX - smooth.x) * alpha
        smooth.y += (0.5 + rawY - smooth.y) * alpha
        let dx = smooth.x - 0.5, dy = smooth.y - 0.5
        let distance = hypot(dx, dy)
        let radius = deadRadius + (safe ? 0.008 : 0)
        safe = distance <= radius && rawDistance <= radius + 0.025
        if safe {
            armSince = nil
            guard armed, dwellEnabled, let target else { dwellSince = nil; progress = 0; return (.zero, false) }
            if targetID != target { targetID = target; dwellSince = time }
            progress = min(1, (time - (dwellSince ?? time)) / max(0.4, dwellDuration))
            if progress >= 1 { cancelClick(); return (.zero, true) }
            return (.zero, false)
        }
        dwellSince = nil; progress = 0; targetID = nil
        if rawDistance > attractionRadius && distance > attractionRadius {
            if armSince == nil { armSince = time }
            if time - (armSince ?? time) >= 0.18 { armed = true }
        } else { armSince = nil }
        guard distance > 0 else { return (.zero, false) }
        let advance = max(0, distance - deadRadius)
        let speed = distance <= attractionRadius ? 24 * pow(advance / (attractionRadius - deadRadius), 2) : min(480, 24 + pow((distance - attractionRadius) * 6, 1.6) * 160)
        let step = min(tremor ? 240 : 600, speed * sensitivity) * dt
        return (CGPoint(x: dx / distance * step, y: dy / distance * step), false)
    }
}


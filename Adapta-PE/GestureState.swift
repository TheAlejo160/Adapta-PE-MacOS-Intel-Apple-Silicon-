import Foundation
import CoreGraphics

struct GestureState {
    private(set) var resetNow = false
    private var reference: CGPoint?
    private var referenceTilt: CGPoint?
    private var lastTime: Double?
    private var lastAngle: Double?
    private var rotation = 0.0
    private var output = CGPoint(x: 0.5, y: 0.5)
    mutating func reset() { self = GestureState() }
    mutating func update(_ point: CGPoint, time: Double, tilt: CGPoint? = nil, pointing: Bool = false, angle: Double? = nil) -> CGPoint {
        resetNow = false
        let tilt = tilt.flatMap { $0.x.isFinite && $0.y.isFinite ? $0 : nil }
        // Acotar el ángulo impide bucles de normalización con entradas extremas.
        let angle = angle.flatMap { $0.isFinite ? $0.truncatingRemainder(dividingBy: 2 * .pi) : nil }
        guard point.x.isFinite, point.y.isFinite, time.isFinite else { reset(); resetNow = true; return output }
        if let lastTime, time <= lastTime { return output }
        if let lastTime, time - lastTime > 0.2001 { reset(); resetNow = true }
        guard let reference else { resetNow = true; self.reference = point; referenceTilt = tilt; lastAngle = angle; lastTime = time; return output }
        var dx = (point.x - reference.x) * 6, dy = (point.y - reference.y) * 6
        if let angle, let lastAngle { var step = angle - lastAngle; while step > .pi { step -= 2 * .pi }; while step < -.pi { step += 2 * .pi }; rotation += step }
        lastAngle = angle
        if hypot(point.x - reference.x, point.y - reference.y) < 1.8 / 160 {
            if let tilt { let start = pointing ? CGPoint.zero : referenceTilt ?? tilt; dx = tilt.x - start.x; dy = tilt.y - start.y }
            else if angle != nil { dx = rotation * 0.9; dy = 0 }
        }
        lastTime = time
        output = CGPoint(x: 0.5 + max(-0.2, min(0.2, dx)), y: 0.5 + max(-0.2, min(0.2, dy)))
        return output
    }
}

enum ControlModes {
    static func normalize(_ mode: String) -> String { if ["cabeza", "torso"].contains(mode) { return "cabeza" }; return mode.hasPrefix("zona") ? "zona" : "manos" }
}

func cursorAttraction(_ point: CGPoint, center: CGPoint, speed: Double, dt: Double) -> CGPoint {
    guard point.x.isFinite, point.y.isFinite, center.x.isFinite, center.y.isFinite, hypot(point.x - center.x, point.y - center.y) <= 28, speed <= 120, dt > 0 else { return point }
    let alpha = 1 - exp(-min(0.05, dt) / 0.12)
    return CGPoint(x: point.x + (center.x - point.x) * alpha, y: point.y + (center.y - point.y) * alpha)
}

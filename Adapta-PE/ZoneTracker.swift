import Foundation
import CoreGraphics

// shortcut: textura local; una oclusión de 1,2 s exige nueva adquisición.
struct ZoneTracker {
    private var previous: [Float]?
    private var template: [Float]?
    private var x = 0, y = 0
    private var lostSince: Double?
    private(set) var angle = 0.0
    private(set) var revision = 0
    private struct Match { var x: Int; var y: Int; var error: Double; var angle: Double }
    mutating func reset() { previous = nil; template = nil; lostSince = nil; angle = 0; revision += 1 }
    private func patch(_ image: [Float], _ x: Int, _ y: Int) -> (values: [Float], contrast: Double, detail: Double) {
        var values: [Float] = []; values.reserveCapacity(169)
        var sum = 0.0, energy = 0.0, horizontal = 0.0, vertical = 0.0, cross = 0.0
        for row in stride(from: -12, through: 12, by: 2) { for col in stride(from: -12, through: 12, by: 2) {
            let p = (y + row) * 160 + x + col, v = Double(image[p])
            values.append(Float(v)); sum += v; energy += v * v
            let dx = Double(image[p + 1] - image[p - 1]) / 2, dy = Double(image[p + 160] - image[p - 160]) / 2
            horizontal += dx * dx; vertical += dy * dy; cross += dx * dy
        } }
        let mean = sum / 169, contrast = sqrt(max(0, energy / 169 - mean * mean))
        let detail = sqrt(max(0, (horizontal + vertical - hypot(horizontal - vertical, 2 * cross)) / 338))
        for i in values.indices { values[i] = Float((Double(values[i]) - mean) / max(1, contrast)) }
        return (values, contrast, detail)
    }
    private func measure(_ image: [Float], _ px: Int, _ py: Int, _ angle: Double) -> Match {
        var result = Match(x: px, y: py, error: .infinity, angle: angle)
        guard px >= 13, py >= 13, px < 147, py < 107, let template else { return result }
        var sum = 0.0, squares = 0.0, dot = 0.0, energy = 0.0, index = 0
        let cosine = cos(angle), sine = sin(angle)
        for row in stride(from: -12, through: 12, by: 2) { for col in stride(from: -12, through: 12, by: 2) {
            let sx = Int((Double(px) + Double(col) * cosine - Double(row) * sine).rounded()), sy = Int((Double(py) + Double(col) * sine + Double(row) * cosine).rounded())
            guard sx >= 0, sx < 160, sy >= 0, sy < 120 else { return result }
            let v = Double(image[sy * 160 + sx]), t = Double(template[index]); index += 1
            sum += v; squares += v * v; dot += v * t; energy += t * t
        } }
        guard squares / 169 - sum * sum / (169 * 169) >= 36 else { return result }
        result.error = 1 - dot / sqrt(energy * (squares - sum * sum / 169)); return result
    }
    mutating func update(_ image: [Float], time: Double) -> CGPoint? {
        guard image.count == 19200 else { return nil }
        if template == nil {
            guard let previous else { self.previous = image; return nil }
            let light = zip(image, previous).reduce(0.0) { $0 + Double($1.0 - $1.1) } / 19200
            var count = 0, sx = 0, sy = 0
            for py in stride(from: 0, to: 120, by: 2) { for px in stride(from: 0, to: 160, by: 2) {
                if abs(Double(image[py * 160 + px] - previous[py * 160 + px]) - light) > 12 { count += 1; sx += px; sy += py }
            } }
            var best = 0.0, selected: [Float]?
            if count >= 12, Double(count) < 19200 * 0.35 / 4 {
                let cx = sx / count, cy = sy / count
                for py in stride(from: max(13, cy - 24), to: min(107, cy + 25), by: 4) { for px in stride(from: max(13, cx - 24), to: min(147, cx + 25), by: 4) {
                    let motion = abs(Double(image[py * 160 + px] - previous[py * 160 + px]) - light)
                    guard motion > 12 else { continue }
                    let p = patch(image, px, py)
                    if p.contrast >= 6, p.detail >= 1, p.detail * motion > best { best = p.detail * motion; selected = p.values; x = px; y = py }
                } }
            }
            self.previous = image
            guard let selected else { return nil }; template = selected; angle = 0; revision += 1
        }
        var matches: [Match] = []; matches.reserveCapacity(725)
        var best = Match(x: x, y: y, error: .infinity, angle: 0)
        for py in (y - 12)...(y + 12) { for px in (x - 12)...(x + 12) { let m = measure(image, px, py, 0); matches.append(m); if m.error < best.error { best = m } } }
        let translation = best
        if translation.error <= 0.4 {
            for a in [-0.24, -0.12, 0.12, 0.24] { for py in (translation.y - 2)...(translation.y + 2) { for px in (translation.x - 2)...(translation.x + 2) { let m = measure(image, px, py, a); matches.append(m); if m.error < best.error { best = m } } } }
            if translation.error - best.error < 0.02 { best = translation }
        }
        let ambiguous = matches.contains { hypot(Double($0.x - best.x), Double($0.y - best.y)) > 3 && $0.error <= best.error * 1.15 + 0.005 }
        guard best.error <= 0.15, !ambiguous else { if lostSince == nil { lostSince = time }; if time - (lostSince ?? time) >= 1.2 { reset() }; return nil }
        lostSince = nil; x = best.x; y = best.y; angle += best.angle
        let next = patch(image, x, y)
        for i in next.values.indices { template![i] = best.angle != 0 ? next.values[i] : template![i] * 0.95 + next.values[i] * 0.05 }
        return CGPoint(x: Double(x) / 160, y: Double(y) / 120)
    }
}

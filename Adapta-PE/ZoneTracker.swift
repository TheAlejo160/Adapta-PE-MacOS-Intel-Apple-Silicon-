import Foundation
import CoreGraphics

// Zona libre (paridad con `controlarZona()`/`seguirPunto()` de la extensión 13.0): textura local en grises 160×120,
// sin clasificar anatomía. Una oclusión de 1,2 s exige nueva adquisición. Umbrales sin validar con cámaras reales.
struct ZoneTracker {
    private var previous: [Float]?
    private(set) var template: [Float]?
    private var x = 0, y = 0
    private var velocity: (x: Double, y: Double)?
    private var lastTime: Double?
    private var lostSince: Double?
    private(set) var angle = 0.0
    private(set) var revision = 0
    struct Match { var x: Int; var y: Int; var error: Double; var angle: Double }
    mutating func reset() { previous = nil; template = nil; velocity = nil; lastTime = nil; lostSince = nil; angle = 0; revision += 1 }
    func patch(_ image: [Float], _ x: Int, _ y: Int) -> (values: [Float], contrast: Double, detail: Double) {
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
    private func measure(_ image: [Float], _ template: [Float], _ px: Int, _ py: Int, _ angle: Double) -> Match {
        var result = Match(x: px, y: py, error: .infinity, angle: angle)
        guard px >= 13, py >= 13, px < 147, py < 107 else { return result }
        var sum = 0.0, squares = 0.0, dot = 0.0, energy = 0.0, index = 0
        let cosine = cos(angle), sine = sin(angle)
        for row in stride(from: -12, through: 12, by: 2) { for col in stride(from: -12, through: 12, by: 2) {
            let sx = px + Int((Double(col) * cosine - Double(row) * sine).rounded()), sy = py + Int((Double(col) * sine + Double(row) * cosine).rounded())
            guard sx >= 0, sx < 160, sy >= 0, sy < 120 else { return result }
            let v = Double(image[sy * 160 + sx]), t = Double(template[index]); index += 1
            sum += v; squares += v * v; dot += v * t; energy += t * t
        } }
        guard squares / 169 - sum * sum / (169 * 169) >= 36 else { return result }
        result.error = 1 - dot / sqrt(energy * (squares - sum * sum / 169)); return result
    }
    /// Busca la plantilla ±12 px alrededor de `center`; nil si el error supera 0,25 o hay otro mínimo local a >3 px.
    func track(_ image: [Float], template: [Float], center: (x: Int, y: Int)) -> Match? {
        let radius = 12, side = 25
        var grid = [Double](repeating: .infinity, count: side * side)
        var best = Match(x: center.x, y: center.y, error: .infinity, angle: 0)
        for py in (center.y - radius)...(center.y + radius) { for px in (center.x - radius)...(center.x + radius) {
            let m = measure(image, template, px, py, 0)
            grid[(py - center.y + radius) * side + px - center.x + radius] = m.error
            if m.error < best.error { best = m }
        } }
        let translation = best
        if translation.error <= 0.4 {
            for a in [-0.24, -0.12, 0.12, 0.24] { for py in (translation.y - 2)...(translation.y + 2) { for px in (translation.x - 2)...(translation.x + 2) {
                let m = measure(image, template, px, py, a); if m.error < best.error { best = m }
            } } }
            if translation.error - best.error < 0.02 { best = translation }
        }
        // Ambiguo sólo si otro mínimo local separado >3 px iguala al mejor: la cuenca ancha de piel lisa no lo es.
        let limit = best.error * 1.15 + 0.005
        for row in 0..<side { for col in 0..<side {
            let error = grid[row * side + col]
            guard error <= limit, hypot(Double(center.x - radius + col - best.x), Double(center.y - radius + row - best.y)) > 3 else { continue }
            var minimum = true
            for dy in -1...1 { for dx in -1...1 where row + dy >= 0 && row + dy < side && col + dx >= 0 && col + dx < side {
                if grid[(row + dy) * side + col + dx] < error { minimum = false }
            } }
            if minimum { return nil }
        } }
        return best.error <= 0.25 ? best : nil
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
            var candidates: [(x: Int, y: Int, values: [Float], score: Double)] = []
            // Movimiento local propone textura; un cambio de luz o de imagen completa no adquiere control.
            if count >= 12, Double(count) < 19200 * 0.35 / 4 {
                let cx = Int((Double(sx) / Double(count)).rounded()), cy = Int((Double(sy) / Double(count)).rounded())
                for py in stride(from: max(13, cy - 24), to: min(107, cy + 25), by: 4) { for px in stride(from: max(13, cx - 24), to: min(147, cx + 25), by: 4) {
                    let motion = abs(Double(image[py * 160 + px] - previous[py * 160 + px]) - light)
                    guard motion > 12 else { continue }
                    let p = patch(image, px, py)
                    if p.contrast >= 6, p.detail >= 1 { candidates.append((px, py, p.values, p.detail * motion)) }
                } }
            }
            // Adquirir sólo un parche que reaparece desplazado en la imagen anterior: el fondo inmóvil o destapado no ancla.
            let chosen = candidates.sorted { $0.score > $1.score }.prefix(4).first { candidate in
                guard let origin = track(previous, template: candidate.values, center: (candidate.x, candidate.y)) else { return false }
                return origin.error <= 0.15 && hypot(Double(origin.x - candidate.x), Double(origin.y - candidate.y)) >= 1
            }
            self.previous = image
            guard let chosen else { return nil }
            template = chosen.values; x = chosen.x; y = chosen.y; angle = 0; velocity = nil; lastTime = nil; revision += 1
        }
        // Predicción por velocidad (≤12 px, sólo en memoria) para no salir de la búsqueda en un movimiento rápido.
        let dt = lastTime.map { time - $0 } ?? 0
        func advance(_ speed: Double?) -> Int { Int((max(-12, min(12, (speed ?? 0) * dt))).rounded()) }
        guard let current = template, let best = track(image, template: current, center: (x + advance(velocity?.x), y + advance(velocity?.y))) else {
            velocity = nil; lastTime = nil // Sin extrapolar puntos perdidos.
            if lostSince == nil { lostSince = time }
            if time - (lostSince ?? time) >= 1.2 { reset() }
            return nil
        }
        lostSince = nil
        if let lastTime, time > lastTime { velocity = (Double(best.x - x) / (time - lastTime), Double(best.y - y) / (time - lastTime)) }
        lastTime = time; x = best.x; y = best.y; angle += best.angle
        // Un giro reemplaza la plantilla; una coincidencia dudosa (error >0,15) no la contamina ni la hace derivar.
        let next = patch(image, x, y)
        if best.angle != 0 { template = next.values }
        else if best.error <= 0.15 { template = zip(current, next.values).map { $0 * 0.95 + $1 * 0.05 } }
        return CGPoint(x: Double(x) / 160, y: Double(y) / 120)
    }
}

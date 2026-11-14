import XCTest
import CoreGraphics
@testable import Adapta_PE

/// Casos clave portados de tests/cinetico.test.cjs (extensión Base 13.0). Umbrales sin validar con cámaras reales.
final class KineticTests: XCTestCase {
    // 21 puntos de MediaPipe: muñeca abajo, dedos hacia arriba, pulgar separado (mismo fixture que la extensión).
    static func mano(_ forma: String = "abierta") -> [CGPoint?] {
        var p: [CGPoint?] = [[0.5, 0.7], [0.45, 0.66], [0.41, 0.62], [0.38, 0.58], [0.36, 0.55],
            [0.47, 0.55], [0.47, 0.49], [0.47, 0.45], [0.47, 0.41], [0.5, 0.54], [0.5, 0.47], [0.5, 0.43], [0.5, 0.39],
            [0.53, 0.55], [0.53, 0.49], [0.53, 0.45], [0.53, 0.42], [0.56, 0.57], [0.56, 0.52], [0.56, 0.49], [0.56, 0.46]].map { CGPoint(x: $0[0], y: $0[1]) }
        if forma == "pinza" || forma == "sin_pulgar" {
            p[6] = CGPoint(x: 0.46, y: 0.5); p[7] = CGPoint(x: 0.44, y: 0.5); p[8] = CGPoint(x: 0.42, y: 0.52); p[3] = CGPoint(x: 0.41, y: 0.56); p[4] = CGPoint(x: 0.42, y: 0.53)
        }
        if forma == "puno" { p[6] = CGPoint(x: 0.47, y: 0.52); p[7] = CGPoint(x: 0.48, y: 0.58); p[8] = CGPoint(x: 0.48, y: 0.62); p[4] = CGPoint(x: 0.48, y: 0.6) }
        if forma == "puno_completo" || forma == "medio" { for base in [5, 9, 13, 17] { let b = p[base]!; p[base + 1] = CGPoint(x: b.x, y: b.y - 0.04); p[base + 2] = CGPoint(x: b.x, y: b.y + 0.03); p[base + 3] = CGPoint(x: b.x, y: b.y + 0.065) } }
        if forma == "puno_frontal" { for base in [5, 9, 13, 17] { let b = p[base]!; p[base + 1] = CGPoint(x: b.x, y: b.y - 0.04); p[base + 2] = CGPoint(x: b.x, y: b.y - 0.03); p[base + 3] = CGPoint(x: b.x, y: b.y - 0.02) } }
        if forma == "medio" { for base in [13, 17] { let b = p[base]!; p[base + 1] = CGPoint(x: b.x, y: b.y - 0.04); p[base + 2] = CGPoint(x: b.x + 0.015, y: b.y - 0.065); p[base + 3] = CGPoint(x: b.x + 0.035, y: b.y - 0.065) } }
        if forma == "sin_pulgar" { p[3] = nil; p[4] = nil }
        return p
    }

    func testPinzaMideSueltaActivaYRechazaPunoPulgarOcultoYManoLejana() {
        XCTAssertEqual(HandGeometry.pinch(Self.mano("abierta")), .released)
        XCTAssertEqual(HandGeometry.pinch(Self.mano("pinza")), .active)
        XCTAssertNil(HandGeometry.pinch(Self.mano("puno")))
        XCTAssertNil(HandGeometry.pinch(Self.mano("sin_pulgar")))
        let lejana = Self.mano("pinza").map { $0.map { CGPoint(x: 0.5 + ($0.x - 0.5) * 0.1, y: 0.5 + ($0.y - 0.5) * 0.1) } }
        XCTAssertNil(HandGeometry.pinch(lejana), "Una mano diminuta no permite medir la pinza")
    }

    func testPunoCompletoFrontalYParcial() {
        XCTAssertTrue(HandGeometry.pose(Self.mano("puno_completo")).fist)
        XCTAssertTrue(HandGeometry.pose(Self.mano("puno_frontal")).fist)
        for forma in ["abierta", "pinza", "puno"] { XCTAssertFalse(HandGeometry.pose(Self.mano(forma)).fist, forma) }
        var menique = Self.mano("puno_completo")
        menique[18] = CGPoint(x: 0.56, y: 0.53); menique[19] = CGPoint(x: 0.575, y: 0.505); menique[20] = CGPoint(x: 0.595, y: 0.505)
        XCTAssertTrue(HandGeometry.pose(menique).fist, "Tres dedos doblados y uno a medias siguen siendo puño")
        menique[19] = CGPoint(x: 0.56, y: 0.49); menique[20] = CGPoint(x: 0.56, y: 0.45)
        XCTAssertFalse(HandGeometry.pose(menique).fist, "Un dedo extendido no es puño")
        var parcial = Self.mano("puno_completo"); parcial[20] = nil
        XCTAssertFalse(HandGeometry.pose(parcial).fist, "No inventa dedos ausentes")
        let medio = HandGeometry.pose(Self.mano("medio"))
        XCTAssertFalse(medio.fist); XCTAssertFalse(medio.open)
        XCTAssertTrue(HandGeometry.pose(Self.mano("abierta")).open)
    }

    func testManoFalsaConfianzaEsqueletoYContinuidad() {
        let real = CGPoint(x: 0.5, y: 0.7)
        XCTAssertNil(HandGeometry.choose([(real, 0.7, true)], previous: nil, tracking: false), "Adquirir exige >=0,8")
        XCTAssertEqual(HandGeometry.choose([(real, 0.95, true)], previous: nil, tracking: false), 0)
        XCTAssertEqual(HandGeometry.choose([(real, 0.7, true)], previous: real, tracking: true), 0, "Seguir admite >=0,6")
        XCTAssertNil(HandGeometry.choose([(real, 0.7, true)], previous: real, tracking: false), "Tras una pérdida vuelve a exigir 0,8")
        XCTAssertNil(HandGeometry.choose([(real, 0.95, false)], previous: nil, tracking: false), "Esqueleto imposible")
        let dudosa = (CGPoint(x: 0.51, y: 0.7), 0.65, true), fiable = (CGPoint(x: 0.6, y: 0.7), 0.9, true)
        XCTAssertEqual(HandGeometry.choose([dudosa, fiable], previous: real, tracking: true), 1, "Fiable próxima gana a dudosa más cercana")
        var estirada = Self.mano(); estirada[8] = CGPoint(x: 0.47, y: 0.05)
        XCTAssertFalse(HandGeometry.skeletonValid(estirada), "Dedo de varias palmas es imposible")
        XCTAssertTrue(HandGeometry.skeletonValid(Self.mano("puno_frontal"))); XCTAssertTrue(HandGeometry.skeletonValid(Self.mano("pinza")))
        XCTAssertTrue(HandGeometry.skeletonValid(Self.mano("sin_pulgar")), "Un esqueleto incompleto no se juzga")
    }

    func testPinzaUnClicAlSoltarDerechoA700msYSinClicDudoso() {
        var gesture = ClickGesture()
        func run(_ frames: [(ClickSignal?, Double)]) -> [ClickGesture.Output] { frames.map { gesture.update($0.0, kind: .pinch, inference: $0.1).output }.filter { $0 != .none } }
        XCTAssertEqual(run([(.released, 0), (.active, 0.05), (.active, 0.1), (.active, 0.15)]), [])
        XCTAssertTrue(gesture.update(.active, kind: .pinch, inference: 0.15).holding, "Imagen repetida conserva el gesto sin contar")
        XCTAssertEqual(run([(.released, 0.2)]), [.click], "Un clic al soltar")
        XCTAssertEqual(run([(.released, 0.25)]), [])
        gesture.reset()
        XCTAssertEqual(run([(.active, 0), (.active, 0.1), (.active, 0.2), (.released, 0.3)]), [], "Sin soltar antes no hay clic")
        gesture.reset()
        XCTAssertEqual(run([(.released, 0), (.active, 0.05), (.active, 0.05), (.released, 0.1)]), [], "Una imagen repetida no confirma")
        gesture.reset()
        XCTAssertEqual(run([(.released, 0), (.active, 0.05), (.intermediate, 0.1), (.intermediate, 0.2), (.released, 0.3)]), [], "Banda intermedia antes de confirmar no hace clic")
        XCTAssertFalse(gesture.update(.intermediate, kind: .pinch, inference: 0.35).holding, "Ni congela el cursor")
        gesture.reset()
        XCTAssertEqual(run([(.released, 0), (.active, 0.05), (.active, 0.15), (.active, 0.3), (.active, 0.45), (.active, 0.6), (.active, 0.76), (.active, 0.9), (.active, 1.05), (.active, 1.2), (.released, 1.3)]), [.rightClick], "700 ms: un clic derecho y soltar no añade nada")
        gesture.reset()
        XCTAssertEqual(run([(.released, 0), (.active, 0.05), (.active, 0.15), (nil, 0.2), (.released, 0.25)]), [], "Pulgar oculto o puño cancelan sin clic")
    }

    func testBocaClicAlCerrarHablaYBostezoNo() {
        XCTAssertEqual(HandGeometry.mouth([CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 0), CGPoint(x: 20, y: 0.5), CGPoint(x: 20, y: -0.5)])!, 1.0 / 40 / 0.9, accuracy: 0.0001)
        XCTAssertEqual(HandGeometry.mouth([CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 0), CGPoint(x: 20, y: 30), CGPoint(x: 20, y: -30)]), 1)
        XCTAssertNil(HandGeometry.mouth([]))
        var gesture = ClickGesture(), clicks = 0, last: (holding: Bool, output: ClickGesture.Output) = (false, .none)
        func serie(_ from: Double, _ to: Double, _ value: Double?) {
            for t in stride(from: from, through: to + 0.0001, by: 0.05) {
                last = gesture.update(HandGeometry.mouthSignal(value), kind: .mouth, inference: t)
                if last.output != .none { clicks += 1 }
            }
        }
        serie(0, 1.5, 0.02)
        serie(1.55, 1.65, 0.6); serie(1.7, 1.7, 0.1)
        XCTAssertEqual(clicks, 0, "Abrir la boca 150 ms al hablar no hace clic")
        serie(1.75, 2.15, 0.7); XCTAssertTrue(last.holding)
        serie(2.2, 2.25, 0.35); XCTAssertEqual(clicks, 0, "Banda intermedia mantiene el gesto")
        serie(2.3, 2.3, 0.05); XCTAssertEqual(clicks, 1)
        serie(2.35, 4.1, 0.8); serie(4.15, 4.15, 0.05)
        XCTAssertEqual(clicks, 1, "Un bostezo de más de 1,5 s se cancela")
        serie(4.2, 4.6, 0.7); serie(4.65, 4.65, nil); serie(4.7, 4.7, 0.05)
        XCTAssertEqual(clicks, 1, "Sin boca medible se cancela sin clic")
    }

    /// Simula el bucle de TrackingManager para extremidades: GestureState → eventos → KineticState.
    private struct Loop {
        var gesture = GestureState(), state = KineticState(), clicks = 0, time = 0.0
        init() { state.fixedCenter = true; state.calibrate() }
        mutating func frame(_ forma: String?, at t: Double, target: String? = "boton", point: CGPoint = CGPoint(x: 0.3, y: 0.6)) {
            time = t
            guard let forma else { state.lost(at: t); gesture.forgetFist(); return }
            let pose = HandGeometry.pose(KineticTests.mano(forma))
            let control = gesture.update(point, time: t, tilt: pose.pointing ? pose.tilt : nil, pointing: pose.pointing, angle: nil, open: pose.open, fist: pose.fist)
            switch gesture.event {
            case .rest: state.recenter(); state.armRest()
            case .restExit: state.recenter(); state.cancelClick()
            case .inputChanged: state.recenter(); state.cancelFixation()
            case .none: break
            }
            if state.update(control, time: t, aspect: 1, target: target).click { clicks += 1 }
        }
        /// Tiempos en milisegundos enteros, como la extensión, para que los límites sean exactos.
        mutating func serie(_ from: Int, _ to: Int, _ forma: String?, target: String? = "boton") { for ms in stride(from: from, through: to, by: 50) { frame(forma, at: Double(ms) / 1000, target: target) } }
    }

    func testPunoCentraArmaDwellDe1sYUnClicPorCierre() {
        var loop = Loop()
        loop.serie(0, 400, "abierta")
        loop.serie(450, 600, "puno_completo")
        XCTAssertTrue(loop.gesture.fistActive)
        loop.serie(650, 1500, "puno_completo"); XCTAssertEqual(loop.clicks, 0, "No adelanta los 1.000 ms")
        loop.serie(1550, 1700, "puno_completo"); XCTAssertEqual(loop.clicks, 1)
        loop.serie(1750, 3000, "puno_completo"); XCTAssertEqual(loop.clicks, 1, "Un clic por cierre")
        loop.serie(3050, 3150, "abierta")
        XCTAssertFalse(loop.gesture.fistActive, "Abrir sale del reposo en 80 ms")
        loop.serie(3200, 3600, "puno_completo"); loop.serie(3650, 4800, "puno_completo")
        XCTAssertEqual(loop.clicks, 2, "Volver a abrir y cerrar permite otro clic")
    }

    func testPunoInicialFugazOAmbiguoLargoNoActivanReposo() {
        var inicial = Loop()
        inicial.serie(0, 2000, "puno_completo")
        XCTAssertFalse(inicial.gesture.fistActive); XCTAssertTrue(inicial.gesture.fistDetected); XCTAssertFalse(inicial.gesture.openRecently)
        XCTAssertEqual(inicial.clicks, 0, "Llegar con el puño cerrado no arma clic")
        var fugaz = Loop()
        fugaz.serie(0, 400, "abierta"); fugaz.serie(450, 500, "puno_completo"); fugaz.serie(550, 2000, "abierta")
        XCTAssertEqual(fugaz.clicks, 0, "Un puño fugaz (<120 ms) no activa reposo")
        var breve = Loop()
        breve.serie(0, 400, "abierta"); breve.serie(450, 900, "puno_completo"); breve.serie(950, 1000, "medio"); breve.serie(1050, 1600, "puno_completo")
        XCTAssertEqual(breve.clicks, 1, "Una imagen ambigua breve no rompe el puño ni su permanencia")
        var larga = Loop()
        larga.serie(0, 400, "abierta"); larga.serie(450, 900, "puno_completo"); larga.serie(950, 1400, "medio"); larga.serie(1450, 3000, "puno_completo")
        XCTAssertEqual(larga.clicks, 0, "Ambigüedad larga suelta el puño y volver sin abrir no rearma")
        var perdida = Loop()
        perdida.serie(0, 400, "abierta"); perdida.serie(450, 900, "puno_completo"); perdida.frame(nil, at: 0.95); perdida.serie(1000, 2700, "puno_completo")
        XCTAssertEqual(perdida.clicks, 0, "Una pérdida desarma el puño")
    }

    func testJoystickHisteresisPerpendicularYSenal() {
        var g = GestureState()
        let rest = CGPoint(x: 0.3, y: 0.6), center = CGPoint(x: 0.5, y: 0.5)
        _ = g.update(rest, time: 0)
        let entrada = (KineticDefaults.zonaMuerta + KineticDefaults.entradaJoystick) / KineticDefaults.ganancia
        XCTAssertEqual(g.update(CGPoint(x: rest.x + entrada * 0.98, y: rest.y), time: 0.05), center, "Por debajo de la entrada no mueve")
        XCTAssertGreaterThan(g.update(CGPoint(x: rest.x + entrada * 1.05, y: rest.y), time: 0.1).x, 0.5); XCTAssertTrue(g.joystick)
        let mantener = KineticDefaults.zonaMuerta * 0.9 / KineticDefaults.ganancia
        XCTAssertGreaterThan(g.update(CGPoint(x: rest.x + mantener, y: rest.y), time: 0.15).x, 0.5, "Histéresis: sigue moviendo por encima de zonaMuerta×0,85")
        let salir = KineticDefaults.zonaMuerta * 0.8 / KineticDefaults.ganancia
        XCTAssertEqual(g.update(CGPoint(x: rest.x + salir, y: rest.y), time: 0.2), center); XCTAssertFalse(g.joystick)
        let diagonal = g.update(CGPoint(x: rest.x + 0.02, y: rest.y + 0.004), time: 0.25)
        XCTAssertGreaterThan(diagonal.x, 0.5); XCTAssertEqual(diagonal.y, 0.5, "Componente perpendicular <0,3 suprimida")
        let real = g.update(CGPoint(x: rest.x + 0.02, y: rest.y + 0.015), time: 0.3)
        XCTAssertGreaterThan(real.y, 0.5, "Las diagonales se conservan")
        // Señal: apunta a la izquierda mientras el desplazamiento va a la derecha; confirma a los 50 ms y prevalece.
        let left = CGPoint(x: -0.2, y: 0)
        _ = g.update(CGPoint(x: rest.x + 0.02, y: rest.y), time: 0.35, tilt: left, pointing: true)
        XCTAssertFalse(g.signalActive)
        let senal = g.update(CGPoint(x: rest.x + 0.02, y: rest.y), time: 0.41, tilt: left, pointing: true)
        XCTAssertTrue(g.signalActive); XCTAssertEqual(g.event, .inputChanged); XCTAssertEqual(senal.x, 0.3, accuracy: 0.0001)
        _ = g.update(CGPoint(x: rest.x + 0.02, y: rest.y), time: 0.46)
        XCTAssertFalse(g.signalActive); XCTAssertEqual(g.event, .inputChanged, "Dejar de señalar devuelve el joystick")
    }

    func testRegresoAlReposoSinAvanceResidualYTopeDeVelocidad() {
        var state = KineticState(); state.fixedCenter = true; state.sensitivity = 2; state.calibrate()
        var t = 0.0, maxRate = 0.0
        for _ in 0..<60 { t += 1 / 30; let d = state.update(CGPoint(x: 0.7, y: 0.5), time: t, aspect: 1, target: nil).delta; maxRate = max(maxRate, d.x * 30) }
        XCTAssertGreaterThan(maxRate, 0)
        XCTAssertLessThanOrEqual(maxRate, KineticDefaults.velocidadMaxima + 0.5, "Tope común aun con sensibilidad 2")
        t += 1 / 30
        XCTAssertEqual(state.update(CGPoint(x: 0.51, y: 0.5), time: t, aspect: 1, target: nil).delta, .zero, "Sin avance residual de EMA")
        XCTAssertLessThanOrEqual(KineticDefaults.emaCerca, 0.15); XCTAssertLessThanOrEqual(KineticDefaults.emaTemblor, 0.15)
        XCTAssertLessThan(KineticDefaults.velocidadMaxima, 480, "Más lento que el macOS anterior")
    }

    func testDwellNoSeReiniciaPorCeldaOHashYRespetaLimites() {
        func dwell(_ duration: Double, targets: (Int) -> String) -> Double? {
            var state = KineticState(); state.fixedCenter = true; state.dwellDuration = duration; state.calibrate()
            var t = 0.0
            for _ in 0..<30 { t += 1 / 30; _ = state.update(CGPoint(x: 0.8, y: 0.5), time: t, aspect: 1, target: nil) }
            let start = t
            for i in 0..<150 { t += 1 / 30; if state.update(CGPoint(x: 0.5, y: 0.5), time: t, aspect: 1, target: targets(i)).click { return t - start } }
            return nil
        }
        let fijo = try! XCTUnwrap(dwell(1, targets: { _ in "a" }))
        let parpadeo = try! XCTUnwrap(dwell(1, targets: { $0 % 3 == 0 ? "b" : "a" }), "Cambiar de celda/hash un instante no reinicia")
        XCTAssertEqual(parpadeo, fijo, accuracy: 0.05)
        let cambio = try! XCTUnwrap(dwell(1, targets: { $0 < 20 ? "a" : "b" }))
        XCTAssertGreaterThan(cambio, fijo + 0.3, "Un objetivo distinto mantenido reinicia el dwell")
        XCTAssertLessThan(try! XCTUnwrap(dwell(3, targets: { _ in "a" })), 1.75, "Máximo 1,5 s")
        XCTAssertGreaterThan(try! XCTUnwrap(dwell(0.2, targets: { _ in "a" })), 0.5, "Mínimo 0,5 s")
    }

    func testRevisionH1ObjetivoSeConservaAlVolverRapidoAlAnillo() {
        XCTAssertTrue(TrackingManager.retainsTarget(leftAt: nil, now: 5), "Dentro del anillo se conserva")
        XCTAssertTrue(TrackingManager.retainsTarget(leftAt: 1, now: 1.2), "Salida breve: la identidad sigue para el regreso")
        XCTAssertFalse(TrackingManager.retainsTarget(leftAt: 1, now: 1.25), "Tras 0,25 s fuera se olvida")
    }

    func testRevisionH2PinzaSeDesarmaTrasSaltoDeMasDe200ms() {
        var gesture = ClickGesture()
        func run(_ frames: [(ClickSignal?, Double)]) -> [ClickGesture.Output] { frames.map { gesture.update($0.0, kind: .pinch, inference: $0.1).output }.filter { $0 != .none } }
        XCTAssertEqual(run([(.released, 0), (.active, 0.05), (.active, 0.1), (.active, 0.15), (.released, 0.4)]), [], "Salto de 250 ms: sin clic tardío")
        gesture.reset()
        XCTAssertEqual(run([(.released, 0), (.active, 0.05), (.active, 0.1), (.active, 0.15), (.released, 0.3)]), [.click], "Salto de 150 ms conserva el gesto")
    }

    func testRevisionH4AtraccionIndependienteDeLaCadencia() {
        // El EMA de la atracción es exponencial en el tiempo: misma atracción a 30 o 60 imágenes/s (process() limita a ≈30/s).
        func pull(_ fps: Double) -> Double {
            var point = CGPoint(x: 0, y: 0)
            for _ in 0..<Int(0.2 * fps) { point = cursorAttraction(point, center: CGPoint(x: 20, y: 0), speed: 0, dt: 1 / fps) }
            return point.x
        }
        XCTAssertEqual(pull(30), pull(60), accuracy: 0.01)
        XCTAssertGreaterThan(pull(30), 5)
    }

    func testCargaAdaptativaBajaSubeYRespetaLimites() {
        var load = AdaptiveLoad(), levels: [Int] = []
        for _ in 0..<30 { load.measure(150, maxLevel: 2); levels.append(load.level) }
        XCTAssertEqual(levels.first, 0, "La primera muestra se descarta"); XCTAssertTrue(levels.contains(1)); XCTAssertEqual(levels.last, 2)
        XCTAssertEqual(load.scale, 0.5, "Baja a la mitad y no más")
        for _ in 0..<30 { load.measure(20, maxLevel: 2) }
        XCTAssertEqual(load.level, 0); XCTAssertEqual(load.scale, 1, "Recupera el máximo sin ampliar")
        load.reset(); for _ in 0..<30 { load.measure(150, maxLevel: 1) }
        XCTAssertEqual(load.level, 1, "Cabeza baja un solo nivel")
        load.reset(); for _ in 0..<4 { load.measure(100, maxLevel: 2) }
        XCTAssertEqual(load.rest, 0.03, accuracy: 0.0001, "Descanso min(0,5×media, 130−media)")
        load.reset(); load.measure(10, maxLevel: 2); load.measure(5000, maxLevel: 2)
        XCTAssertEqual(load.rest, 0, "Muestras ≥1 s se ignoran")
    }

    // MARK: Zona libre (ZoneTracker 13.0)
    static func ruido(_ x: Int, _ y: Int, _ semilla: Int = 0) -> Float {
        let a = Int32(truncatingIfNeeded: x + 19 + semilla) &* 73856093, b = Int32(truncatingIfNeeded: y + 31) &* 19349663
        return 80 + Float(UInt32(bitPattern: a ^ b) % 90)
    }
    static func textura(_ dx: Int = 0, _ dy: Int = 0, _ semilla: Int = 0) -> [Float] { (0..<19200).map { ruido($0 % 160 - dx, $0 / 160 - dy, semilla) } }
    static func objeto(_ x0: Int, _ y0: Int = 45) -> [Float] {
        var g = [Float](repeating: 150, count: 19200)
        for y in y0..<(y0 + 30) { for x in max(0, x0)..<min(160, x0 + 30) { g[y * 160 + x] = ruido(x - x0, y - y0, 3) } }
        return g
    }
    static func suave(_ semilla: UInt32, _ escala: Double, _ dx: Double, _ dy: Double, _ ruidoSensor: Double) -> [Float] {
        var estado = semilla
        func azar() -> Double { estado = estado &* 1664525 &+ 1013904223; return Double(estado) / 4294967296 }
        let rejilla = (0..<900).map { _ in azar() }
        func curva(_ t: Double) -> Double { t * t * (3 - 2 * t) }
        func valor(_ x: Double, _ y: Double) -> Double {
            let fx = x / escala + 1, fy = y / escala + 1, ix = Int(fx.rounded(.down)), iy = Int(fy.rounded(.down)), tx = curva(fx - Double(ix)), ty = curva(fy - Double(iy))
            let a = rejilla[iy * 30 + ix], b = rejilla[iy * 30 + ix + 1], c = rejilla[(iy + 1) * 30 + ix], d = rejilla[(iy + 1) * 30 + ix + 1]
            return 80 + 90 * (a + (b - a) * tx + (c - a) * ty + (a - b - c + d) * tx * ty)
        }
        var g = [Float](repeating: 0, count: 19200)
        for y in 0..<120 { for x in 0..<160 { g[y * 160 + x] = Float(valor(Double(x) - dx, Double(y) - dy) + (azar() - 0.5) * 2 * ruidoSensor) } }
        return g
    }

    func testZonaCuencaAnchaNoEsAmbiguaYOtroMinimoSi() {
        let zone = ZoneTracker()
        let plantilla = zone.patch(Self.suave(27, 16, 0, 0, 0), 80, 60).values
        let punto = try! XCTUnwrap(zone.track(Self.suave(27, 16, 4, 2, 6), template: plantilla, center: (80, 60)), "Una vecina a >3 px con error parecido no corta")
        XCTAssertLessThanOrEqual(abs(punto.x - 84), 1); XCTAssertLessThanOrEqual(abs(punto.y - 62), 1)
        var doble = Self.textura(); let patron = Self.textura(0, 0, 9)
        for y in 40..<81 { for x in 60..<108 { doble[y * 160 + x] = patron[y * 160 + 60 + (x - 60) % 8] } }
        XCTAssertNil(zone.track(doble, template: zone.patch(doble, 80, 60).values, center: (80, 60)), "Patrón repetido: dos mínimos separados")
    }

    func testZonaCoincidenciaDudosaSigueSinContaminarPlantilla() {
        let base = Self.textura(), otra = Self.textura(0, 0, 5)
        func mezcla(_ k: Float) -> [Float] { zip(base, otra).map { $0 + k * ($1 - 125) } }
        let zone = ZoneTracker(), plantilla = zone.patch(base, 80, 60).values
        let dudosa = try! XCTUnwrap(zone.track(mezcla(0.75), template: plantilla, center: (80, 60)))
        XCTAssertGreaterThan(dudosa.error, 0.15); XCTAssertLessThanOrEqual(dudosa.error, 0.25)
        XCTAssertEqual(dudosa.x, 80); XCTAssertEqual(dudosa.y, 60)
        XCTAssertNil(zone.track(mezcla(0.9), template: plantilla, center: (80, 60)), "Una textura irreconocible se pierde")
    }

    func testZonaAdquiereSoloTexturaDesplazada() {
        let pared = Self.textura()
        let iluminada = pared.enumerated().map { i, v in (60..<100).contains(i % 160) && (40..<80).contains(i / 160) ? v * 1.5 : v }
        let cambiada = pared.enumerated().map { i, v in (60..<100).contains(i % 160) && (40..<80).contains(i / 160) ? Self.ruido(i % 160, i / 160, 11) : v }
        for alterna in [iluminada, cambiada] {
            var zone = ZoneTracker()
            for i in 0..<8 { _ = zone.update(i % 2 == 1 ? alterna : pared, time: Double(i) * 0.05) }
            XCTAssertNil(zone.template, "Luz o cambio en su sitio no anclan el control")
        }
        var movil = ZoneTracker()
        XCTAssertNil(movil.update(Self.objeto(60), time: 0))
        let punto = try! XCTUnwrap(movil.update(Self.objeto(63), time: 0.05), "Una textura que se desplaza se adquiere")
        XCTAssertTrue((51.0 / 160...105.0 / 160).contains(punto.x))
    }

    func testZonaPrediccionPorVelocidadYSinExtrapolarTrasPerdida() {
        var zone = ZoneTracker()
        func px(_ p: CGPoint?) -> Int? { p.map { Int(($0.x * 160).rounded()) } }
        _ = zone.update(Self.objeto(10), time: 0)
        let inicio = try! XCTUnwrap(px(zone.update(Self.objeto(12), time: 0.05)))
        XCTAssertEqual(px(zone.update(Self.objeto(20), time: 0.1)), inicio + 8)
        for (t, x0) in [(0.15, 36), (0.2, 52), (0.25, 68)] {
            XCTAssertEqual(px(zone.update(Self.objeto(x0), time: t)), inicio + x0 - 12, "16 px por inferencia sigue gracias a la predicción")
        }
        XCTAssertNil(zone.update([Float](repeating: 150, count: 19200), time: 0.3))
        XCTAssertEqual(px(zone.update(Self.objeto(68), time: 0.35)), inicio + 56, "Recupera sin desplazar la búsqueda")
    }
}

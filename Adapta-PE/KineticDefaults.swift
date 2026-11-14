import Foundation

/// Valores por defecto comunes del cursor cinético (T-08/T-09), iguales en macOS Base y Windows Base.
/// Distancias normalizadas a la imagen (ancho = 1); velocidades en puntos de pantalla por segundo
/// (1 pt de macOS ≈ 1 px CSS de la extensión); tiempos en segundos.
/// Todos los umbrales están SIN VALIDAR CON CÁMARAS REALES: ajustar tras probar con personas.
enum KineticDefaults {
    // Física (T-08). La extensión usa 650 px/s; el feedback pedía un cursor más lento y preciso.
    static let velocidadMaxima = 400.0          // tope tras aplicar sensibilidad
    static let velocidadMaximaTemblor = 240.0
    static let zonaMuerta = 0.045, zonaMuertaTemblor = 0.07
    static let margenAtraccion = 0.02           // zonaAtraccion = zonaMuerta + 0.02
    static let histeresisZonaSegura = 0.008
    // Constante de tiempo de la EMA: ninguna añade más de 150 ms de retraso cerca del reposo.
    static let emaLejos = 0.05, emaCerca = 0.10, emaTemblor = 0.15
    // Dwell y atracción (configurables en el panel).
    static let dwell = 1.0, dwellMinimo = 0.5, dwellMaximo = 1.5
    static let armado = 0.18
    static let atraccionActiva = true, atraccionRadio = 28.0, atraccionVelocidad = 120.0
    /// Un objetivo distinto debe mantenerse este tiempo antes de reiniciar el dwell (celda o hash AX del mismo control).
    static let cambioObjetivo = 0.25
    // Joystick de extremidades.
    static let ganancia = 6.0, limiteGesto = 0.2
    static let entradaJoystick = 0.004          // zonaMuerta + 0.004
    static let salidaJoystick = 0.85            // zonaMuerta × 0.85
    static let perpendicularJoystick = 0.3, perpendicularSenal = 0.35
    static let senalConfirmar = 0.05, senalCoseno = 0.7
    static let reinicioJoystick = 0.5, desarmeClic = 0.2
    // Clic por gesto.
    static let pinzaActiva = 0.25, pinzaSuelta = 0.40, pinzaInferencias = 2, pinzaConfirmar = 0.08, pinzaDerecho = 0.7
    static let bocaActiva = 0.5, bocaSuelta = 0.2, bocaInferencias = 3, bocaConfirmar = 0.3, bocaMaximo = 1.5
    /// Vision no ofrece jawOpen: apertura = alto/ancho de innerLips; 0,9 equivale a jawOpen 1.
    static let bocaEscala = 0.9
    static let estabilizarClic = 0.25
    // Puño-reposo.
    static let punoConfirmar = 0.12, punoInferencias = 3, punoAperturaRecordada = 1.5, punoAmbiguo = 0.4, punoSalida = 0.08
    // Mano falsa.
    static let manoAdquirir = 0.8, manoConservar = 0.6, manoNuevaInferencias = 3, manoNuevaTiempo = 0.15, manoOlvido = 0.5
    // Carga adaptativa (milisegundos, como `medirCarga()` de la extensión).
    static let cargaAlta = 90.0, cargaBaja = 40.0, cargaMuestras = 5
}

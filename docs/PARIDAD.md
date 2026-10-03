# Adapta PE para macOS: análisis y portabilidad

## Extensiones analizadas

Fuentes: `extensión` y `extensiónLite` del workspace. Se verificaron el grafo de llamadas, la cobertura del índice y los métodos relevantes de voz, visión, seguimiento, lectura, filtros, controlador y service worker. La exploración del grafo es una ayuda de navegación; no prueba por sí sola paridad funcional.

Los archivos `VoiceAssistant.js` y `FiltrosDaltonismo.js` son idénticos entre ambas variantes en esta revisión. Lite conserva voz, dictado, navegación, selección y filtros. Base agrega `KineticEngine`, `TalkBack`, cámara central y detecciones. La infraestructura de pestañas/documento offscreen pertenece al navegador y no tiene que portarse literalmente a macOS.

La aplicación Swift funciona de forma independiente. No modifica las extensiones, no depende de ellas, no abre un servidor Flask y no importa MediaPipe. Usa Vision, Speech, AVFoundation, AppKit, CoreGraphics, Accesibilidad y ScreenCaptureKit.

## Correspondencias

| Comportamiento de la extensión Base | Implementación de escritorio | Límite práctico |
| --- | --- | --- |
| Reconocedor único, activación «Computadora», espera de 8 s, reinicios y resultados provisionales | `VoiceManager`, una sesión de audio y una tarea Speech, generaciones y reinicio con espera creciente | Español local depende de recursos/soporte del Mac. Red de Apple sólo con autorización del usuario en ajustes. |
| Dictado conserva acentos y signos | `CommandParser` conserva texto original; eventos Unicode, sin alterar el portapapeles | Requiere un campo editable accesible. Se excluyen campos de contraseña. |
| Sitios, alias exactos y búsquedas | Catálogo Swift de los 28 sitios originales; codificación segura de consultas; búsqueda contextual en navegador compatible | Safari, Chrome, Brave y Edge permiten consultar URL/abrir destino por Automatización. Otros navegadores abren URLs con el manejador predeterminado. |
| Pestañas, ventanas, historial, zoom y scroll | Atajos nativos y automatización del navegador activo | Atajos dependen del navegador y la distribución de teclado; no se inyecta JS en páginas. |
| Seleccionar, resaltar, enfocar y pulsar controles por nombre | Árbol AX de la ventana activa, foco, `AXPress`, contorno transparente | Una app que no expone semántica AX requiere cursor o VoiceOver. El recorrido está limitado a 1.800 nodos/0,8 s. |
| Reproducción y pausa | Activación del control accesible por nombre | No se garantiza para reproductores que no expongan controles; no se manda espacio indiscriminadamente a formularios. |
| Mano, rostro, torso, brazos y modo automático | Vision: palma, rostro con nariz/giro, hombros y articulaciones visibles; fuente mantenida | Los modelos de Apple y MediaPipe no producen coordenadas idénticas. No se afirma detección universal con amputaciones. |
| Zona libre sin anatomía | Saliencia local y seguimiento de objeto de Vision | Selección automática de textura/objeto; una oclusión o poco contraste puede exigir recalibrar. No equivale píxel por píxel al correlador JS. |
| Calibración, mediana, suavizado por tiempo, temblor y movimientos pequeños | `KineticState`, ventana de 1,2 s, estabilidad >=900 ms y >=4 muestras, mediana de tres, EMA por tiempo | Se conservan mecánicas y tiempos; las velocidades requieren ajuste personal con cámara y monitores reales. |
| Clic por permanencia y clic derecho siguiente | Armado tras >=180 ms fuera del anillo; clic al volver y mantener el mismo objetivo durante el tiempo elegido | Un clic por entrada. Calibración, pérdida, pausas y saltos de tiempo desarman. El objetivo usa identidad AX; no es un nodo DOM. |
| Menú contextual del sitio / menú propio | Clic derecho nativo del sistema | El menú lo proporciona la aplicación activa; no se copia el menú HTML de la extensión. |
| Cursor limitado a página | Eventos de ratón sobre monitores físicos, incluidos orígenes negativos | El ratón físico pausa 2 s y exige postura nuevamente estable. |
| TalkBack con debounce 300 ms y contorno | `TalkBackManager`, eventos de ratón y elementos AX, síntesis de Apple | Depende del texto accesible. Durante la salida se ignoran órdenes ordinarias y se aceptan interrupciones explícitas con palabra de activación. No se cancela Speech en cada respuesta. |
| Siete matrices SVG de color | Las mismas matrices mediante Core Image y una capa ScreenCaptureKit por pantalla | Captura local hasta 30 FPS, sin audio; se omiten frames sin cambios. Adapta PE se excluye. Contenido protegido y algunas ventanas de nivel superior pueden no filtrarse. Las matrices simulan colores, no constituyen corrección médica. |
| Continuidad al cambiar pestaña | Servicios con vida ligada a la app, barra de menú y panel flotante | Cerrar ajustes no termina la app. Dormir libera sensores/captura; despertar restaura módulos que estaban activos. |
| Backend opcional biónico simulado | Lectura AX local por defecto; API compatible con chat/completions opcional | La IA se invoca explícitamente. Captura para IA requiere permiso adicional durante esa sesión. No hay IA generativa local. |

## Correcciones de la base Swift anterior

- Se elimina el conteo de frames que producía clics repetidos y velocidades diferentes según cámara.
- Se calibra la postura real; el centro visual y la referencia de control ya no se confunden.
- Sesiones y peticiones se serializan; stop/restart no agrega salidas de cámara duplicadas.
- Un token evita reactivar módulos después de una respuesta tardía de permisos.
- Se conservan comandos finales antes del reinicio y el texto original antes de normalizar intenciones.
- La síntesis de voz no se escucha a sí misma como nuevos comandos.
- Se sustituyen captura de pantalla obsoleta y AppleScript con nombres sin escapar.
- Abrir/cerrar aplicaciones compara nombre de bundle, nombre visible, alias y errores breves con coincidencia única; no se fuerza el cierre.
- Se guarda la clave en Llavero. Una clave heredada de preferencias se migra antes de quitar su copia en texto plano.
- Los comandos desconocidos no se envían a una API ni piden una clave para usar funciones básicas.
- Deployment target 14.0; configuración de cámara, micrófono y Apple Events para firma con hardened runtime.

## Recursos y privacidad

Un capturador por sensor. Cámara VGA, inferencia serial, descarte de frames atrasados, solicitudes Vision restringidas a la fuente activa y publicaciones de HUD hasta 10 Hz. Consulta del objetivo AX hasta 10 Hz cerca del centro; TalkBack mantiene una consulta en vuelo. Cámara apagada, voz apagada y filtros apagados no dejan procesos de captura activos.

Los filtros necesitan captura de pantallas para reproducir matrices arbitrarias sin APIs privadas. No tienen el mismo coste que un filtro CSS del navegador. Se procesan con Core Image y cola de dos buffers; no se afirma un consumo medido sin perfilado con esos módulos activos.

No se guardan imágenes, grabaciones ni transcripciones. Los controles cinéticos, lectura y filtros son locales. El reconocimiento puede usar el servicio de Apple únicamente si se enciende esa opción. IA generativa: HTTPS, API key y modelo propios, peticiones explícitas, errores HTTP visibles y cancelación. No se usa una API real durante las pruebas.

## Validación y alcance de compatibilidad

Las pruebas automatizadas cubren parser, catálogo, activación, Unicode, estabilidad de postura, pérdida, movimiento por tiempo, ausencia de clic al calibrar, un clic por entrada y matrices. La prueba UI comprueba panel flotante, retorno a ajustes y continuidad después de cerrar la ventana.

Compilar con el SDK instalado y mínimo 14.0 comprueba disponibilidad declarada de APIs. No prueba ejecución en cada macOS. Se debe ejecutar la lista siguiente en Sonoma 14 y en las versiones posteriores que se quieran distribuir, incluyendo macOS 27, con cámara/micrófono reales y firma definitiva:

1. Denegar permisos, reactivar y detener mientras el diálogo de autorización está abierto.
2. Probar cabeza, mano, torso, brazos y zona libre; calibrar sentado en postura cómoda y verificar pérdida/recuperación.
3. Mover ratón físico durante seguimiento: no debe luchar con el cursor ni provocar clics.
4. Probar dwell, clic derecho, salida del anillo y ausencia de clic repetido al descansar.
5. Reconocer comandos repetidos tras varios reinicios, dictado con acentos y interrupción de TTS y retorno a escucha.
6. Desconectar dispositivos, dormir/despertar y reabrir ajustes desde barra de menú y Dock.
7. Usar pantallas con distintas posiciones/resoluciones; mover ventanas, cursor y resaltar controles.
8. Probar permisos AX/Automatización por navegador, formularios y aplicaciones con árboles AX incompletos.
9. Activar/quitar filtros, cambiar monitores y verificar que detener todo elimina capas de captura.
10. Verificar IA apagada, clave inválida, errores de red/cuota y consentimiento antes de enviar una pantalla.

No se garantiza aún equivalencia visual, rendimiento o cobertura de todos los sitios y aplicaciones de las extensiones. Estas dependencias externas requieren esa validación física; no pueden probarse con resultados sintéticos solamente.

## Resultado de esta revisión

- Compilación Release universal: `arm64` y `x86_64`; ambas cabeceras Mach-O declaran mínimo 14.0 y SDK 27.0.
- Veintiuna pruebas de lógica aprobadas en macOS del entorno, incluyendo casos a 15/30/60 FPS.
- Ajustes, IA apagada, panel flotante y retorno a ajustes inspeccionados con automatización nativa y capturas. Cerrar ajustes mantiene el proceso activo; reabrir la app vuelve a mostrar la misma ventana.
- El runner XCTest UI termina con `signal kill before establishing connection`, antes de ejecutar el caso, tanto sin firma como con firma ad hoc. La prueba queda disponible para ejecutarla con un entorno de Xcode autorizado; no se presenta como aprobada.
- En la revisión posterior se activó el micrófono con permisos existentes y se comprobó inicio local, lectura/cancelación y retorno al estado de escucha, además del panel compacto. No se probaron comandos pronunciados por una persona, desconexiones físicas, múltiples pantallas ni se midió CPU/GPU. Cámara, filtros e IA no se activaron en esa comprobación.

### Regresión de segundo plano y transcripción

Se elimina el desplazamiento por cantidad de palabras: Speech puede corregir la frase completa y el desplazamiento entregaba sólo el sufijo al parser. `VoiceInputState` conserva la frase, procesa una orden por tarea y mantiene la activación de ocho segundos entre tareas. Las regresiones cubren «Computadora» → «Abre Google Chrome», varias activaciones, interrupción de lectura y rechazo de eco. La integración verifica alias instalados de Chrome, Zoom y VS Code sin abrir aplicaciones durante XCTest. Los tests no restauran sensores automáticamente.

La escucha usa una actividad de ProcessInfo mientras está encendida y permite el reposo del sistema. La verificación de captura distingue una tarea Speech acabada de la llegada de audio válido. La búsqueda parcial de nombres se limita al catálogo de apps; no se amplía a controles AX ni ejecuta coincidencias ambiguas.

### Comandos de escritorio y elecciones

El parser distingue ventanas y pestañas dirigidas a una app, dictado en campos nombrados, selección de texto, combinaciones de teclas y acciones del sistema. Nueva ventana/pestaña, guardar e imprimir se ejecutan por los menús AX habilitados, incluyendo sus nombres españoles e ingleses; los comandos de otras apps se descubren en esos menús. El recorrido sigue limitado a 1.800 nodos/0,8 segundos y sólo se realiza al pedir una acción. No se presupone acceso a comandos internos que una app no expone.

Los resultados ambiguos y los campos disponibles ofrecen páginas de seis opciones. Número, ordinal, nombre único, siguiente y cancelación se prueban junto con caducidad; la acción retenida comprueba el PID activo y su generación antes de ejecutarse. Una orden nueva invalida trabajo anterior, sin borrar el elemento seleccionado para «pulsa lo seleccionado». El dictado verifica que app y campo sigan activos por cada fragmento Unicode y evita campos protegidos. La interfaz flotante muestra transcripción, respuesta y opciones sin activar la aplicación.

### Anclaje de PiP

El panel ya no usa arrastre ni autosave de coordenadas libres. Guarda una de cuatro esquinas y el identificador del monitor; calcula su marco sobre visibleFrame con 16 puntos de margen. Los cambios de tamaño conservan la misma esquina y los cambios de pantallas recalculan el marco. Si el monitor recordado se desconecta, usa la pantalla principal disponible y conserva la preferencia. Una regresión prueba las cuatro esquinas, tres alturas y pantallas con origen negativo o tamaño menor que el panel. Se retiran los interruptores redundantes del PiP y se mantienen en Ajustes/barra de menú.

La comprobación nativa mostró elecciones de menús y campos, cancelación explícita y caducidad. No sustituye una sesión controlada de dictado por voz y ejecución de acciones en todas las aplicaciones; los árboles AX y el soporte de cada aplicación siguen delimitando lo disponible.

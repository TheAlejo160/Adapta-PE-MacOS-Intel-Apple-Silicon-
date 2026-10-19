<p align="center">
  <img src="AdaptaPE.png" alt="Logo de Adapta PE" width="250">
</p>

# Adapta PE para macOS

## Comandos naturales: bloque del 17 de octubre de 2026

La palabra predeterminada admite «Computadora», «Computadoras» y «Computador». Una llamada seguida sólo de cortesía mantiene la espera de ocho segundos. Las palabras personales siguen siendo independientes: elegir «Asistente» no activa esos alias. Se conserva el texto original tras la llamada, incluidos espacios interiores y Unicode; las pruebas de texto no acreditan reconocimiento con micrófono.

El parser acepta cortesía y variantes españolas como «por favor abre Safari», «quiero que abras Safari», «ábrame Safari» y «abrí Safari». Conserva mayúsculas, acentos y espacios interiores del dictado. La selección literal y las consultas a la API conservan su puntuación. Se mantienen los atajos nativos existentes.

Las partículas finales ambiguas «pe», «pues», «ya pe» y «ya pues» sólo se retiran si llevan una coma antes. Así «busca Adapta PE» y «busca qué significa pues» conservan su contenido. «Abre Safari, pe» se prepara como «abre Safari». Es una diferencia conservadora respecto a la extensión de referencia; no se adivina si una palabra final pertenece a un nombre o consulta.

Este bloque porta reglas de texto españolas. No añade reconocimiento acústico en seis idiomas ni acredita precisión con micrófonos reales.

También se descartan orientaciones no finitas y se acotan ángulos extremos antes de integrar el gesto. Esto evita bloqueos del cálculo; no cambia umbrales, modelos ni calibración. Las pruebas usan puntos sintéticos, sin cámara.

Aplicación de escritorio independiente en Swift/SwiftUI, basada en las funciones de la extensión Adapta PE completa. Mínimo configurado: macOS Sonoma 14.0. Sin dependencias externas ni IA generativa por defecto. La edición Lite se desarrolla en un proyecto y repositorio independientes: asistente de voz completo, siete filtros y segundo plano.

## Mascotas y mejoras compartidas · 11 de octubre de 2026

Se contrastaron las extensiones completas 13.0 y Lite 3.0, sus README y los motores actuales. Las mejoras se adaptan a las APIs del escritorio; cada edición conserva sus funciones.

En **Mascota**, elige **Tinku** (gallito), **Cuchu** (cuy), **Yati** (llama) o **Sin mascota**, que es el valor inicial. Sólo se decodifica el atlas elegido. Los cuadros nativos de 96×112 conservan transparencia, secuencias de entrada/salida y duración de los sprites originales. Un temporizador sigue la duración de los cuadros; otro se programa una sola vez para el descanso. No se repinta toda la interfaz. La animación se detiene al dormir, con movimiento reducido y durante suspensión. Ocultar/cambiar libera el atlas anterior.

La mascota mira hacia el cursor cercano, acompaña la llamada al asistente y cambia entre hablar y leer durante la salida de voz real. **Saludar**, **Dormir** y **Despertar** permiten controlar su estado; dormir se mantiene hasta despertar. El dibujo deja pasar los clics. Arrastra su nombre entre pantallas o pulsa **Mover con teclas**, usa las flechas y vuelve con **Escape**. **Otro monitor** cambia la pantalla sin arrastrar; se recuerdan mascota, monitor y posición relativa.

### Interfaz, panel y compañía

Las funciones principales quedan en secciones con nombres directos. **Usar panel** abre PiP; **Opciones** permite elegir mascota, filtros, esquina y monitor. Los dispositivos y preferencias de reconocimiento permanecen bajo sus opciones avanzadas. Base conserva calibración, control corporal, selección de cámara y API externa voluntaria. La cámara de ajustes aparece sólo en Control; en PiP puedes ocultar su vista sin apagar el cursor. **Detener todo** permanece accesible.

Activa **Mover mascota y panel juntos** para situar la mascota arriba de PiP. Arrastra el título del panel o el nombre de la mascota para mover ambos. Al separarlos, la mascota recupera su posición propia. Se recuerdan unión, monitor y posición relativa del panel; cambiar de esquina vuelve al anclaje. El tamaño se limita al área útil reservando lugar para la mascota. En macOS también puedes enfocar el título y usar las flechas. PiP conserva fondo sólido para leer incluso cuando está inactivo. El control Ajustes usa Liquid Glass desde macOS 26; versiones anteriores y transparencia reducida usan el estilo nativo sencillo.

La llamada por voz usa el teléfono una vez; ejecutar una orden usa la laptop una vez. Leer y hablar acompañan únicamente la salida de voz real. Después vuelve a reposo, sin dejar teléfono/laptop trabajando indefinidamente. Tras **90 segundos sin interacción**, descansa y detiene su animación. La próxima acción despierta el descanso automático; **Dormir** manual exige **Despertar**. No duerme automáticamente durante una lectura o respuesta hablada.

Di **«computadora, une mascota al panel»**, **«separa mascota del panel»** o **«panel esquina superior izquierda»**. También se admite **«mueve el panel a la esquina inferior derecha»**. Cambiar posición usa los mismos límites que el arrastre y conserva el control disponible.

Después de llamar al asistente, admite **«mascota Cu Chu»**, **«mascota Tinku»**, **«mascota Yaty»**, **«elige mascota tiiinku»**, **«oculta mascota»**, **«saluda mascota»**, **«duerme mascota»** y **«despierta mascota»**. Las órdenes se reconocen completas; mencionar una mascota dentro de dictado o búsqueda conserva ese texto.

El cursor ofrece tres modos: **Cabeza / torso**, **Brazos, manos o puños** y **Zona con textura**. Los nombres antiguos se convierten al modo equivalente: torso → cabeza, automático/brazos/lados → manos, zonas laterales → zona libre. Se conservan velocidad, amplitud, temblor y permanencia.

Cabeza aprende reposo mediante al menos cuatro muestras distintas durante 900 ms. Manos y textura tienen centro fijo: la primera posición es el reposo de un joystick; desplaza ligeramente la zona visible y mantenla para continuar, vuelve al inicio para detenerte. La muñeca permite manos cerradas; el respaldo corporal usa muñecas/codos visibles, nunca hombros para ese modo. Se conserva la mano por proximidad; al perderla, sólo una muñeca cercana puede respaldarla. Cabeza admite nariz/giro y respaldo corporal.

Cerca del reposo, uno o dos dedos alineados aportan dirección. Vision ofrece puntos 2D: se usa dirección de dedos o giro relativo de muñeca/nudillo; no se atribuye profundidad 3D a esos datos. Zona libre adquiere un detalle por movimiento local en cualquier parte útil de la imagen, compensa cambios uniformes de luz y compara parches normalizados con pequeños giros. No identifica anatomía; una textura uniforme/repetida u oclusión puede impedir seguimiento. Después de 1.200 ms de pérdida se necesita otra adquisición.

Pérdidas, pausas, cambios de fuente y huecos de más de 200 ms reinician el gesto y desarman clic. Volver al reposo frena sin esperar al suavizado. El clic sigue exigiendo salida, regreso y permanencia sobre el mismo destino. La atracción suave hacia el centro de controles accesibles cercanos (máximo 28 píxeles) reutiliza la consulta local de accesibilidad; no recorre toda la app ni arma clic. Un movimiento decidido permite salir.

La cámara solicita **640×480 a 30 FPS**. `AVCaptureVideoPreviewLayer` muestra el flujo independientemente de Vision; la inferencia es serial y descarta imágenes atrasadas. La textura usa **160×120**. El HUD publica hasta 10 Hz; esa frecuencia no limita el vídeo de preview.

### Pantalla completa y varios monitores

Los filtros usan una captura/composición local por pantalla. Se reconstruyen al conectar o retirar monitores y al cambiar su disposición. Las capas y mascotas se unen a Spaces y a otras apps en pantalla completa mediante [canJoinAllApplications](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallapplications); el filtro queda debajo de los controles propios de Adapta PE, evita capturarse a sí mismo y deja pasar los clics. **Preparando**, **Activo** y los errores explican el estado real.

La captura requiere el permiso de Grabación de pantalla. Contenido protegido, escritorio seguro o juegos que usen presentación exclusiva pueden impedir captura/capas; usa pantalla completa de escritorio cuando la app lo permita. La lectura requiere controles AX publicados y la entrada puede ser rechazada por cada juego. No se promete acceso a superficies que el sistema protege. La composición por monitor tiene coste de GPU/memoria; 30 FPS es el límite solicitado, no una medición garantizada.

### Código y comprobación

- [`Mascot.swift`](Adapta-PE/Mascot.swift): atlas/secuencias, comandos, ventanas, voz y controles SwiftUI.
- [`Mascotas/`](Adapta-PE/Mascotas/): sprites y manifiestos locales.
- [`GestureState.swift`](Adapta-PE/GestureState.swift) y [`ZoneTracker.swift`](Adapta-PE/ZoneTracker.swift): gesto, modos, atracción y textura.

Compilación Debug y 28 pruebas de lógica aprobadas con Xcode 27, sin activar sensores. Se comprobaron selección y controles de mascotas en la interfaz real. Cámara/micrófono, filtros activos, juegos exclusivos, monitor externo y consumo/FPS en equipo real requieren validación física. No se regeneró una distribución firmada/notarizada.

## Funciones

- Cursor cinético con cámara: cabeza/torso, brazos/manos/puños y zona con textura.
- Calibración de postura, filtro de temblor, movimientos pequeños, velocidad y espera ajustables.
- Clic por permanencia con armado y un clic por entrada; clic derecho por voz y pausa con ratón físico.
- Voz con palabra personalizable, dictado Unicode, búsquedas, pestañas, ventanas y atajos.
- Selección, foco y activación de elementos a través de Accesibilidad de macOS.
- TalkBack local y lectura de la ventana activa, sin enviar pantallas a una API.
- Siete matrices de color equivalentes a la extensión, aplicadas localmente a las pantallas.
- Mascota peruana opcional: Tinku, Cuchu o Yati, con voz, estados y posición entre monitores.
- Barra de menú, panel flotante, continuidad al cerrar ajustes e inicio de sesión opcional.
- IA externa opcional con API key personal en Llavero, endpoint HTTPS y modelo configurables.

La equivalencia y límites por módulo se explican en [docs/PARIDAD.md](docs/PARIDAD.md). Vision y Accesibilidad de macOS sustituyen modelos MediaPipe y DOM; no garantizan la misma detección ni semántica en todas las apps.

## Descargar e instalar desde terminal

Código: [TheAlejo160/Adapta-PE-MacOS-Intel-Apple-Silicon-](https://github.com/TheAlejo160/Adapta-PE-MacOS-Intel-Apple-Silicon-). Este repositorio contiene **Adapta PE completo**. No requiere instalar Python, npm ni paquetes Swift externos.

Necesitas Xcode completo, con sus herramientas de línea de comandos seleccionadas, un SDK macOS compatible y macOS 14 o posterior para estas aplicaciones. `xcodebuild -version` permite comprobarlo. Configura el equipo de firma en **Signing & Capabilities**; el equipo incluido pertenece al autor y puede no estar disponible para tu cuenta. La revisión local usa Xcode 27; no se acredita compatibilidad con todo Xcode anterior.

```sh
git clone https://github.com/TheAlejo160/Adapta-PE-MacOS-Intel-Apple-Silicon-.git Adapta-PE-macOS
cd Adapta-PE-macOS
xcodebuild -version
open Adapta-PE.xcodeproj
# Tras revisar/configurar la firma en Xcode, compila y abre Base:
./script/build_and_run.sh --verify
```

El script detiene la instancia anterior de Base y usa una carpeta temporal de compilación. Para conservar una instalación local, cierra la aplicación desde su barra de menú, compila Release con tu firma configurada y copia el bundle a `~/Applications`:

```sh
xcodebuild -project Adapta-PE.xcodeproj -scheme Adapta-PE \
  -configuration Release -derivedDataPath build/base build
mkdir -p "$HOME/Applications"
ditto build/base/Build/Products/Release/Adapta-PE.app "$HOME/Applications/Adapta-PE.app"
open "$HOME/Applications/Adapta-PE.app"
```


Para actualizar: cierra la edición instalada, guarda cambios propios, ejecuta `git pull --ff-only`, vuelve a compilar y copia el nuevo bundle. Los permisos del sistema pueden necesitar revisión si cambia la firma o ubicación. Para desinstalar, desactiva el inicio de sesión desde la app, sal y elimina su bundle; las preferencias y la clave personal del Llavero no se borran mediante este procedimiento.

## Compilar y verificar

Abre `Adapta-PE.xcodeproj` en Xcode. Selecciona el esquema **Adapta-PE** y tu equipo de firma para ejecutar/distribuir. El proyecto usa grupos sincronizados de Xcode 16 o posterior; esta revisión se verifica con Xcode 27.

```sh
xcodebuild -project Adapta-PE.xcodeproj -scheme Adapta-PE \
  -configuration Debug -derivedDataPath /tmp/adapta-pe-build \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -project Adapta-PE.xcodeproj -scheme Adapta-PE \
  -destination 'platform=macOS' -derivedDataPath /tmp/adapta-pe-build \
  -only-testing:Adapta-PETests CODE_SIGNING_ALLOWED=NO test
```

La prueba de UI usa el target `Adapta-PEUITests` y requiere autorización de Xcode para automatizar la interfaz. No activa sensores ni IA. Para distribución se requiere firma y notarización normales; no se necesita desactivar Gatekeeper.

También puedes usar `./script/build_and_run.sh`: detiene la instancia anterior, compila y abre el bundle. `--debug` abre el proyecto para ejecutar desde Xcode; `--logs` y `--telemetry` muestran logs. Conserva la firma configurada en el proyecto.

## Primer uso

1. Autoriza **Accesibilidad** desde el botón en ajustes para cursor, teclado y lectura AX.
2. Elige cámara y modo de control. Activa Mouse cinético y mantén postura cómoda si elegiste cabeza/torso; en manos o zona basta un gesto breve.
3. Sal del anillo y vuelve al centro; mantener el mismo objetivo realiza un clic. Para otro clic, vuelve a salir.
4. Activa comandos por voz. macOS pedirá micrófono y reconocimiento de voz. Por defecto se exige soporte local de español; la opción de red de Apple es independiente y explícita.
5. Usa **Panel flotante** o cierra ajustes. La app sigue disponible en la barra de menú. **Detener todo** apaga sensores, lectura, filtros y peticiones pendientes. **Salir** termina la app.

Grabación de pantalla sólo se solicita al activar filtros o captura opcional para IA. Automatización se solicita cuando un navegador compatible necesita Apple Events. El primer lanzamiento comienza apagado. Después se recuerdan los módulos activos, dispositivos, palabra de activación, velocidad, pausa y filtros; se restauran sólo permisos ya concedidos. Cerrar o salir conserva esa memoria. «Detener todo» deja los módulos apagados para el próximo inicio. No se guardan grabaciones ni transcripciones. Dormir/despertar restaura los módulos que estaban activos; no conserva grabaciones.

## Comandos

Precede cada orden con «Computadora» o la palabra elegida. Después de decir sólo el nombre, tienes 8 segundos para dar el comando.

- «Abre YouTube», «busca movilidad en Wikipedia», «abre Google en nueva pestaña».
- «Nueva pestaña», «abre una nueva ventana de Chrome», «abre Chrome en nueva ventana», «cierra esta pestaña», «atrás», «recarga».
- «Guardar», «guardar como», «imprimir», «Spotlight», «Mission Control», «mostrar escritorio», «pantalla completa».
- «Presiona comando shift N», «atajo control option arriba», «campo siguiente», «campo anterior».
- «Muestra comandos», «ejecuta la acción Exportar PDF»: consulta o activa los menús accesibles de la app.
- «Muestra campos», «enfoca Nombre», «escribe Hola, José en el campo Nombre», «selecciona el texto Buenos días».
- «Escribe Hola, José», «enfoca buscar», «borra el campo», «enter», «copia», «pega».
- «Selecciona Contacto», «pulsa lo seleccionado», «clic en Contacto», «clic derecho».
- «Control cabeza», «control brazo izquierdo», «control zona libre», «calibrar cursor».
- «Activar temblor», «movimientos pequeños», «cursor más lento», «pausar cursor», «reanudar cursor».
- «Siguiente clic derecho», «cancelar clic», «activar TalkBack», «lee la pantalla».
- «Filtro deuteranopía», «quitar filtro», «mostrar ajustes», «modo flotante», «detener todo».
- «Abre Zoom», «ejecutar visual studio code», «mostrar VS Code en el monitor dos».
- «Dar anticlick», «presionar el botón Contacto», «leer el botón Contacto».

Los nombres se comparan sin distinguir mayúsculas/acentos. Alias de apps y errores de hasta dos letras se resuelven localmente cuando hay una única coincidencia; un empate exige un nombre más preciso. El catálogo se consulta fuera del hilo principal y se conserva un minuto. Los monitores se numeran como se muestran en Dispositivos y preferencias. Durante la lectura puedes interrumpir con «Computadora, silencio» o «Computadora, detener todo».

Safari, Chrome, Brave y Edge admiten control de destinos y búsqueda contextual con Automatización. En otras aplicaciones la lectura y selección dependen de los elementos accesibles publicados. Campos protegidos no se leen ni se dictan. Los filtros reproducen matrices de simulación de color; no son una corrección médica del daltonismo.

## IA opcional

En **IA opcional**, activa la integración, configura un endpoint HTTPS compatible con `chat/completions`, indica un modelo disponible en tu proveedor y guarda tu API key en Llavero. HTTP sólo se acepta en este equipo (localhost, 127.x.x.x o ::1). Cambiar el endpoint cancela la consulta, borra la clave guardada y retira el permiso de pantalla; si el Llavero no la borra, se conserva el endpoint anterior. Las respuestas se cortan a 64 KiB y no se siguen redirecciones. El proveedor puede cobrar según sus condiciones. La app no incluye créditos ni una clave.

«Pregunta a la IA …» envía sólo esa consulta. Los comandos desconocidos no se envían automáticamente. «Lee la pantalla» sigue siendo lectura AX local. «Analiza pantalla con IA» requiere activar **Permitir envío de pantalla al proveedor** durante esa sesión, además del permiso del sistema y un modelo que acepte imágenes. Esa captura puede incluir información privada.

## Compatibilidad comprobada

Deployment target 14.0 y frameworks públicos. Las regresiones automáticas no reemplazan pruebas físicas de cámara, micrófono, permisos, múltiples monitores y cada versión de macOS. Consulta la lista de validación y diferencias en `docs/PARIDAD.md`; no se afirma compatibilidad completa 14–27 sólo por compilar.

## Diagnóstico de voz

La captura descarta muestras inválidas o sin PCM antes de entregarlas a Speech. Los cambios de tarea se ordenan en la cola de audio sin bloquear la interfaz. Si no llegan tramas válidas durante 4 segundos, se intenta recuperar la captura con espera progresiva. Una lectura sin progreso durante 8 segundos se detiene para liberar la escucha. Las devoluciones de una locución antigua no cancelan otra nueva.

En Xcode, ejecuta el esquema Adapta-PE y abre la consola (`⇧⌘Y`). Los logs propios usan `pe.adapta.desktop`, categoría `voice`, sin texto dictado ni grabaciones. `AddInstanceForFactory`, UUID de cámaras y ViewBridge también pueden venir de servicios/controladores del sistema: esta revisión no promete eliminarlos. Las desconexiones físicas, el español local y la ruta de audio de cada dispositivo requieren prueba en el equipo del usuario.

### Escucha al cambiar de aplicación

Con Voz activa, abrir otra app o tapar/cerrar ajustes mantiene la captura y el reconocimiento. Una actividad nativa evita App Nap durante la escucha y se libera al detener voz o dormir el Mac; no impide el reposo del sistema. Los cambios de app y el chequeo de salud recuperan tareas de reconocimiento ya terminadas.

La transcripción de Speech se trata como una frase completa corregible, sin descartar palabras por conteos anteriores. Tras una activación u orden se prepara otra tarea. El sonido de «Computadora» se reproduce al instalar la siguiente petición, para que puedas decir el comando después de la señal. Decir sólo «Computadora» también interrumpe la lectura y abre la espera de ocho segundos. Durante una lectura, órdenes ordinarias del propio audio no se ejecutan.

También se aceptan partes del nombre de una app con coincidencia única: «abre Visual Studio» o «abre Workplace». Si varias apps coinciden, di un nombre más completo. Las coincidencias exactas tienen prioridad y un nombre como `zoom.us` se comprueba como app antes de abrirlo como dominio.

### Elecciones y seguimiento en segundo plano

Los controles ambiguos y la búsqueda de campos ofrecen hasta seis opciones por página. Responde con el número, «la segunda», un nombre único, «siguiente» o «cancelar». Mientras haya una elección pendiente puedes responder sin repetir la palabra de activación, después de escuchar las opciones. Decir la palabra de activación interrumpe la lectura. Una orden distinta sustituye la elección; cambiar de app o esperar 45 segundos la cancela. Dictar sin campo activo permite elegir dónde escribir antes de insertar texto. Los campos protegidos quedan excluidos.

Con voz activa, el panel flotante aparece al pasar a otra aplicación o cerrar ajustes. Muestra la última transcripción y respuesta, sin tomar el foco. Las opciones se pueden elegir por voz o pulsándolas. En Ayuda también puedes consultar acciones y campos de la aplicación externa activa.

Las acciones específicas se descubren en los menús que cada aplicación expone por Accesibilidad; no existe un catálogo universal de todos sus comandos internos. Si la app no expone un menú o campo, Adapta PE lo indica; puedes usar un atajo conocido. Los atajos nombrados usan códigos virtuales de teclado macOS (disposición estándar); los menús respetan las acciones de cada aplicación. No se ejecutan scripts de shell dictados.

### PiP anclado

El panel compacto admite arrastre libre y anclaje a las cuatro esquinas. **Opciones** reúne mascota, unión/separación, filtros, vista de cámara y monitor. Guarda la posición relativa; elegir esquina vuelve al anclaje. La mascota unida queda encima y se reserva su espacio al cambiar el tamaño. Las elecciones conservan desplazamiento y acceso a Detener todo.

Voz y cursor se activan desde Ajustes o la barra de menú. El PiP conserva estado, transcripción, respuesta y Detener todo, y sólo muestra botones de elección cuando hay una pregunta pendiente.

## Documentación del código

| Archivo | Función actual |
| --- | --- |
| [Adapta_PEApp.swift](Adapta-PE/Adapta_PEApp.swift) | Entrada Base, AppModel, barra de menú, PiP, permisos, memoria de sesión y reposo. |
| [ContentView.swift](Adapta-PE/ContentView.swift) | Ajustes y panel flotante nativos SwiftUI/AppKit. |
| [VoiceManager.swift](Adapta-PE/VoiceManager.swift) | Captura AVFoundation, reconocimiento Speech español, recuperación y coordinación con TTS. |
| [VoiceInputState.swift](Adapta-PE/VoiceInputState.swift) | Activación de ocho segundos, deduplicación e interrupciones durante lectura. |
| [CommandParser.swift](Adapta-PE/CommandParser.swift) | Parser de intenciones, catálogo de sitios, atajos y elecciones. |
| [ActionManager.swift](Adapta-PE/ActionManager.swift) | Ejecuta órdenes, coordina destino externo, TTS, navegador y opciones numeradas. |
| [ApplicationCatalog.swift](Adapta-PE/ApplicationCatalog.swift) | Alias/catálogo de aplicaciones y resolución local de nombres. |
| [DesktopAccess.swift](Adapta-PE/DesktopAccess.swift) | Árbol AX, campos, menús, selección, entrada CGEvent y TalkBack de Base. |
| [TrackingManager.swift](Adapta-PE/TrackingManager.swift) | Captura de cámara, Vision/seguimiento por modo, preview y movimiento. |
| [KineticState.swift](Adapta-PE/KineticState.swift) | Postura de referencia, suavizado temporal, zona segura y dwell. |
| [ColorFilterManager.swift](Adapta-PE/ColorFilterManager.swift) | Siete matrices, captura/composición local de pantallas y retirada del filtro. |
| [OptionalAI.swift](Adapta-PE/OptionalAI.swift) | Consulta HTTPS explícita, cancelación, consentimiento de pantalla y clave en Llavero. |
| [script/](script/) y targets `*Tests` / `*UITests` | Compilación/lanzamiento y comprobaciones de lógica/interfaz. |

La voz recorre **AVFoundation → Speech → VoiceInputState → CommandParser → ActionManager → AX/CGEvent/Apple Events → respuesta**. La UI no se convierte en destino al mostrar elecciones. El dictado conserva Unicode; la normalización se limita a intenciones/nombres. Los recorridos AX tienen límites y las acciones revalidan la aplicación. Una app que no exponga controles accesibles limita lo que se puede leer o activar.

Base recorre **cámara → detección Vision o textura → KineticState → cursor y dwell**, con calibración y sin grabar imágenes. Los filtros tienen un coste distinto de CSS web porque componen pantallas localmente. [docs/PARIDAD.md](docs/PARIDAD.md) documenta las equivalencias y la validación física pendiente.

Lite reside en la carpeta y proyecto independientes `Adapta-PE-Lite`, con fuentes locales de voz y filtros. No requiere archivos de este repositorio. Su README documenta compilación, permisos y pruebas.

## Archivos públicos y privacidad del desarrollo

`.gitignore` conserva fuentes, proyectos Xcode, assets, documentación, pruebas y esquemas compartidos. Excluye DerivedData, builds, DMG/APP generados, `xcuserdata`, ajustes de IDE, memoria local de agentes, logs y credenciales. El DMG histórico del equipo no forma parte del flujo reproducible actual ni se publica como instalador validado de esta revisión.

La clave de IA se guarda en Llavero, nunca en el repositorio. Las pruebas automáticas no usan proveedores reales por defecto. © 2026 Rodrigo Alejandro Apcho Aliaga — TheAlejo160. Se conserva [LICENSE](LICENSE), Creative Commons Atribución-NoComercial-CompartirIgual 4.0, y las atribuciones existentes. La publicación de fuentes no cambia sus condiciones de reutilización.

## Verificación de la documentación

El 3 de octubre de 2026 se comprobaron los comandos de Xcode con Xcode 27: pasaron 21 pruebas de Base; Lite se verifica desde su proyecto independiente, sin activar sensores ni IA. No se repitieron pruebas UI ni se acreditó firma/notarización de distribución. El índice se regeneró para contrastar el mapa; el hueco de parseo en Adapta_PEApp.swift:98 se leyó directamente y la configuración Xcode se verificó por fuente.

## Proyectos de la familia Adapta PE

| Programa | Código y alcance |
| --- | --- |
| Extensión Base | [Adapta-PE](https://github.com/TheAlejo160/Adapta-PE): voz, filtros, cursor de página y TalkBack. |
| Extensión Lite | [Adapta-PE-Lite](https://github.com/TheAlejo160/Adapta-PE-Lite): voz y filtros. |
| Windows Base | [Adapta-PE-Win](https://github.com/TheAlejo160/Adapta-PE-Win): aplicación WPF independiente. |
| Windows Lite | [Adapta-PE-Lite-Win](https://github.com/TheAlejo160/Adapta-PE-Lite-Win): voz, lectura manual y filtros. |
| macOS completo | [Adapta-PE-MacOS-Intel-Apple-Silicon-](https://github.com/TheAlejo160/Adapta-PE-MacOS-Intel-Apple-Silicon-): aplicación completa en su proyecto Xcode. |
| macOS Lite independiente | [Adapta-PE-Lite-MacOS](https://github.com/TheAlejo160/Adapta-PE-Lite-MacOS): voz y filtros en un proyecto autónomo. |

Los números de versión y permisos pertenecen a cada plataforma. Un ZIP de la extensión no instala la aplicación de escritorio. Los repositorios publican fuentes y recursos necesarios; los instaladores generados y la configuración personal quedan fuera de Git.

## Filtros: presentación segura (17 de octubre de 2026)

El filtro espera una imagen procesada antes de mostrar su ventana, evitando una cubierta negra al arrancar. Detener invalida inmediatamente la presentación: un cuadro que ya estaba en camino no vuelve a mostrarla. El estado informa de filtro activo al recibir el primer cuadro. Se mantienen las matrices, el permiso de Grabación de pantalla y el procesamiento local en memoria.

FilterPresentationTests.testFirstImageAndCancellation usa una imagen sintética para probar la primera presentación, un solo aviso inicial y el rechazo después de invalidar. Esta prueba no acredita captura real, contenido protegido, monitores ni rendimiento físico.

### Llamada personal y parada durante lectura: 17 de octubre de 2026

La activación de voz ahora compara acentos y espacios equivalentes sin perder los índices del texto original. Una llamada personalizada como «Máquina Azul» admite transcripción sin tilde y espacios variables; el contenido que sigue conserva acentos, mayúsculas y espacios. Durante TTS, «por favor detén todo» atraviesa la protección de eco y llega a la parada global; dictado y búsquedas conservan su contenido. PersonalWakeTests y GlobalStopTests pasaron con Xcode en macOS Apple Silicon. Son pruebas textuales, no validación del micrófono ni del reconocimiento acústico.

### Contraste, foco y micrófono: 17 de octubre de 2026

El fondo de cabecera usa una capa negra del 60 % para que el subtítulo blanco mantenga contraste incluso sobre zonas claras (peor caso calculado 5,74:1). Los botones propios añaden un indicador interior de foco por teclado. El selector conserva Predeterminado y la selección válida; actualizar un ID retirado vuelve a Predeterminado. Una captura solicitada con un micrófono explícito ausente falla en lugar de usar silenciosamente otro dispositivo. Las pruebas de selección con IDs sintéticos y la compilación pasaron; no se validaron desconexión física, dibujo del foco ni VoiceOver.

La misma política se aplica a cámara Predeterminada y selección explícita. Las tres pruebas seleccionadas de llamada y dispositivos pasaron; los casos usan IDs sintéticos y no comprueban desconexión física.

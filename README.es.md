<p align="center"><img src="docs/icon.png" width="128" alt="Icono de OpenMixer"></p>

<h1 align="center">OpenMixer</h1>

<p align="center">
  <b>Un mezclador de audio de código abierto para la barra de menús de macOS.</b><br>
  Volumen, ecualizador y efectos Audio Unit por aplicación, enrutado de salida por app, control de dispositivos, atajos y medidores.
</p>

<p align="center"><a href="README.md">Read in English</a></p>

---

macOS solo da un control de volumen para todo. OpenMixer vive en la barra de menús y te deja bajar Spotify mientras una videollamada
sigue alta, mandar un juego a los auriculares y la música a los altavoces, ecualizar una sola app o pasar un plugin de masterización
por todo el audio del sistema. Está escrito en Swift/SwiftUI sobre los *process taps* de Core Audio, sin extensiones de kernel ni drivers de audio virtuales.

> **Sin afiliación.** OpenMixer es un proyecto independiente con código, nombre, icono y diseño originales. No está hecho, respaldado ni
> relacionado con Rogue Amoeba ni con ningún otro fabricante comercial; todos los nombres de producto pertenecen a sus dueños.

## Funciones

**Icono de la barra de menús**
- Refleja el volumen de salida del sistema: se encienden cuatro píldoras al subirlo y se apagan todas al silenciar.
- Scroll encima para cambiar el volumen, ⌥-clic para silenciar, clic derecho para el menú.
- Se coloca en el hueco más a la derecha, junto a los iconos del sistema.

**Dispositivos**
- Elige salida, entrada y sonidos del sistema; volumen, silencio y medidor de nivel por dispositivo.
- Selector AirPlay; conecta o desconecta dispositivos de audio **Bluetooth** emparejados.
- Frecuencia de muestreo, volumen máximo, ocultar dispositivos que no uses.
- **Volumen por software** para dispositivos sin volumen por hardware o poco fiable (HDMI, algunos DAC).
- Silencio breve al cambiar de salida, para que cambiar a los altavoces no te dé un susto.

**Control por app**
- Volumen 0–200 %, silencio, medidores, favoritas y lista de exclusiones.
- Manda cualquier app a otro dispositivo de salida.
- Solo se intercepta una app cuando cambias algo; el resto suena de forma nativa.

**Efectos** (por app *y* por dispositivo)
- Ecualizador de 10 bandas con presets y los tuyos propios.
- Corrección de auriculares: importa un `ParametricEQ.txt` de [AutoEQ](https://github.com/jaakkopasanen/AutoEq).
- Aloja cualquier efecto **Audio Unit** instalado, con su propia ventana de edición; el estado se guarda.
- Balance, limitador y bypass.

**Control**
- Atajo global para abrir el mezclador y atajos de volumen/silencio por dispositivo.
- Teclas de volumen del teclado para dispositivos que macOS no controla.
- **Quick Configs**: guarda y restaura todo el estado del mezclador.
- Ajustes: *General* (incluye **abrir al iniciar sesión**), *Devices*, *Hotkeys*, *Applications*, *Advanced*.
- Aspecto nativo: Liquid Glass en macOS 26+, sigue el modo claro/oscuro, animaciones suaves y háptica.

## Requisitos
- macOS **14.2** o posterior en **Apple silicon**. El estilo Liquid Glass necesita macOS 26; en versiones anteriores usa un material estándar.
- Un toolchain de Swift para compilar. Basta con las **Command Line Tools** de Xcode.

## Instalación

### Descarga (recomendado)
Descarga **`OpenMixer-<versión>.dmg`** de la [última release](https://github.com/PabloJuGo/OpenMixer/releases/latest), ábrelo y arrastra *OpenMixer* a *Aplicaciones*.
Es un binario nativo para **Apple silicon** (macOS 28 deja de ejecutar código Intel, por eso no se incluye segmento Intel; en Mac Intel compila con `UNIVERSAL=1 scripts/bundle.sh`). Puedes verificar la descarga con `shasum -a 256 -c SHA256SUMS.txt`.

La app está **firmada ad hoc y no notarizada** (no hay una cuenta de pago de Apple Developer detrás), así que Gatekeeper bloquea el primer arranque:
- **Clic derecho** en *OpenMixer* → **Abrir** → **Abrir**, o
- ejecuta una vez `xattr -dr com.apple.quarantine /Applications/OpenMixer.app`.

Si prefieres no fiarte de un binario, compílalo tú:

```sh
git clone https://github.com/PabloJuGo/OpenMixer.git
cd OpenMixer
scripts/bundle.sh --install     # compila, firma ad hoc y copia a /Applications
open /Applications/OpenMixer.app
```

`scripts/bundle.sh` solo genera `build/OpenMixer.app`; `scripts/release.sh` crea el `.dmg` y el `.zip`. Conviene instalar en `/Applications` porque *abrir al iniciar sesión* funciona mejor ahí.

### Permisos
| Permiso | Para qué | Cuándo se pide |
|---|---|---|
| **Captura de audio** | Los *process taps* hacen posible el volumen/EQ por app | La primera vez que se crea un tap (al cambiar una app o abrir la ventana por los medidores) |
| **Bluetooth** | Listar y conectar dispositivos de audio emparejados | La primera vez que se abre la ventana |
| **Accesibilidad** *(opcional)* | Interceptar las teclas de volumen | Solo si activas las teclas de volumen en Hotkeys |

La app está firmada ad hoc, así que macOS puede volver a preguntar tras recompilar. Nada sale de tu equipo: OpenMixer no tiene código de red.

## Uso
- **Clic** en el icono para abrir el mezclador; clic fuera (o Esc) para cerrarlo, o **fíjalo** para mantenerlo sobre otras ventanas.
- Arrastra el slider de una app; el pomo se ajusta al 100 %. A la derecha de cada fila están el silencio y el icono de efectos.
- En **Effects** elige *EQ*, *Headphones*, *Plugins* u *Output* (balance, limitador, dispositivo de salida; frecuencia y volumen por software en dispositivos).
- Clic derecho en una app: favorita, restablecer o excluir.
- Los ajustes se guardan en `~/Library/Application Support/OpenMixer/state.json`.

## Cómo funciona
- Por cada app que cambias, OpenMixer crea un **process tap** (`CATapDescription`, silenciado al capturar) y un dispositivo agregado privado
  sobre la salida elegida. Un IO proc en tiempo real reproduce el audio capturado a través de
  `ganancia/balance → EQ → perfil de auriculares → Audio Units → limitador` (`Sources/MixerCore`).
- Los efectos de dispositivo y el volumen por software usan un **tap de todo el sistema** que excluye a OpenMixer y a las apps con tap propio, así el audio nunca se procesa dos veces y no hay realimentación.
- Los Audio Units se ejecutan con la API clásica `AudioUnitRender`, con una cadena por tap; la ventana de edición usa otra instancia y devuelve su `fullState` a los ajustes.
- La ruta en tiempo real no reserva memoria y solo usa try-locks, así que editar la interfaz nunca bloquea el hilo de audio.
- Los taps se crean fuera del hilo principal y se destruyen cuando los ajustes vuelven a los valores por defecto.

## Estructura
```
Sources/MixerCore    motor de audio sin UI: Core Audio, taps, procesador, filtros, host de plugins, modelo de ajustes
Sources/OpenMixer    la app: icono/popover, vistas SwiftUI, ventana de ajustes, modelo
Sources/SelfCheck    ejecutable de pruebas (DSP, modelos, buffers, Audio Units, audio real)
scripts/             bundle.sh (compilar + firmar + instalar), release.sh (.dmg/.zip), live-check.sh, make_icon.swift
Resources/           icono de la app
```

## Pruebas
XCTest y Swift Testing no vienen con las Command Line Tools, así que las pruebas son un ejecutable:

```sh
swift run SelfCheck       # DSP, ajustes, buffers de Core Audio, Audio Units, enumeración de dispositivos
scripts/live-check.sh     # de extremo a extremo con audio real: reproduce un tono suave y verifica los taps
```
`live-check.sh` pide una vez el permiso de captura de audio. Para trabajar la UI: `OpenMixer --snapshot DIR` genera PNG de las páginas y `OpenMixer --popover-test` comprueba el tamaño del popover y que nada se desborde.

## Solución de problemas
- **Una app se queda en silencio tras cambiarla:** se denegó la captura de audio. Permite *OpenMixer* en *Ajustes del Sistema › Privacidad y seguridad › Grabación de pantalla y audio del sistema* y vuelve a mover el slider.
- **El permiso vuelve a pedirse tras recompilar:** la firma ad hoc cambia en cada build; instala una vez con `scripts/bundle.sh --install`.
- **Las teclas de volumen no hacen nada:** actívalas en *Settings › Hotkeys* y permite OpenMixer en *Privacidad y seguridad › Accesibilidad*.
- **Falta una app en la lista:** solo aparecen las apps con un cliente de Core Audio activo; empieza a reproducir y aparecerá. Revisa también *Settings › Applications* por si está excluida.

## Limitaciones conocidas
- Los editores de Audio Unit **v3** (fuera de proceso) funcionan, pero la sincronización de estado depende de que el plugin publique `fullState`.
- Los procesos auxiliares se agrupan con una llamada privada de libsystem cuando existe; si no, por prefijo de bundle id.
- Los medidores de apps sin modificar usan un tap extra que no silencia.
- No implementado: captura de entrada por app, limitador con look-ahead, perfiles de auriculares incluidos (importa los tuyos), traducciones (la interfaz está en inglés).

## Contribuir
Se aceptan issues y pull requests. Ejecuta `swift run SelfCheck` antes de enviar cambios, y `scripts/live-check.sh` si tocas la ruta de audio.
Mantén el código de tiempo real (`Processor`, `FilterBank`, `PluginChain`, `Render`) sin reservas de memoria ni bloqueos.

## Licencia
[MIT](LICENSE)

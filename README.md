# AlbumExport

App nativa de macOS (SwiftUI, macOS 14+) que extrae las fotos de uno o varios álbumes
de un catálogo o sesión de **Capture One** a una carpeta, y graba en XMP dentro de cada
fichero (RAW de Sony incluidos) los metadatos del índice del catálogo: rating, etiqueta
de color, keywords, título, descripción, contacto, copyright, ciudad, país, localización…

Es la versión de escritorio del script Python `co_album_export.py`; comparte con él el
conocimiento del esquema del catálogo y la estrategia de escritura de metadatos.

## Requisitos

- macOS 14 Sonoma o posterior.
- [exiftool](https://exiftool.org) instalado con Homebrew (`brew install exiftool`) o copiado
  en `AlbumExport.app/Contents/Resources/exiftool/exiftool`. La app lo busca en ese orden.

## Uso

1. **Open Catalog…**: elige el bundle `.cocatalog`, o un `.cosessiondb` de una sesión.
2. Escribe **patrones** de álbum con `*` y `?` separados por `;` (por ejemplo
   `Andorra 20??; Isla*`), o marca álbumes en la lista. Un patrón con `/` compara la ruta
   completa `Grupo/Álbum`.
3. **Destination…**: carpeta de salida (no puede estar dentro del catálogo).
4. Revisa el plan (recuento, tamaño, rating, color, keywords) y pulsa **Export**.

Salida:

```
<destino>/<patrón sin comodines>/<nombre del álbum>/<fichero>
<destino>/AlbumExport_<fecha>.csv          informe de la ejecución
```

- Colisiones de nombre dentro del mismo álbum: sufijo `_1`, `_2`…
- Cada carpeta de álbum guarda `.albumexport.json` (UUID de imagen → fichero) para que las
  ejecuciones repetidas no dupliquen fotos. Con *Refresh already exported* se reescriben los
  metadatos de las ya exportadas.
- *Move* mueve en vez de copiar y pide confirmación: las fotos que viven dentro del bundle
  del catálogo quedan offline en Capture One.

## Seguridad

- El catálogo original **nunca se abre ni se modifica**: la base de datos SQLite se copia
  (con su WAL) a un temporal y se consulta la copia.
- Los metadatos se escriben únicamente en los ficheros ya copiados al destino.
- exiftool reescribe solo el contenedor TIFF del ARW; los datos RAW y el preview quedan
  byte a byte idénticos (verificado por SHA-256 en el script Python con el mismo comando).
- Tras escribir, la app relee rating, etiqueta y keywords de cada fichero y marca en rojo
  cualquier discrepancia con el catálogo.

## Versiones de catálogo

Capture One migra los catálogos al formato de la versión que los abre, y la app sondea el
esquema al abrir:

- Lee `ZVERSIONINFO` y muestra la versión de Capture One y el número de formato.
- Resuelve los tipos de colección por nombre (`ZENTITIES`), no por identificador fijo.
- Comprueba tablas y columnas: las imprescindibles abortan con mensaje; las opcionales
  (`ZCOMBINEDSETTINGS`, `ZKEYWORD`, `ZISTRASHED`, `ZIMAGEUUID`…) degradan con un aviso
  en la cabecera.
- Formatos validados: 1650 (16.5) a 160800 (16.8). Fuera de ese rango avisa y sigue.

## Qué se escribe en cada fichero

| Catálogo | Tag |
|---|---|
| Rating | `XMP-xmp:Rating` |
| Etiqueta de color | `XMP-xmp:Label` (Red, Orange, Yellow, Green, Blue, Pink, Purple) |
| Keywords | `MWG:Keywords` (XMP `dc:subject` + IPTC Keywords) y `XMP-lr:HierarchicalSubject` |
| Título, titular, descripción, redactor | `dc:title`, `photoshop:Headline`, `MWG:Description`, `photoshop:CaptionWriter` |
| Ciudad, provincia, país, código ISO, localización | `MWG:City`, `MWG:State`, `MWG:Country`, `iptcCore:CountryCode`, `MWG:Location` |
| Creador y contacto | `MWG:Creator`, `photoshop:AuthorsPosition`, `iptcCore:Creator*` |
| Copyright, términos, crédito, fuente, instrucciones, job id | `MWG:Copyright`, `xmpRights:UsageTerms`, `photoshop:Credit`, `Source`, `Instructions`, `TransmissionReference` |
| Categorías, código de tema, género, escena | `photoshop:Category`, `SupplementalCategories`, `iptcCore:SubjectCode`, `IntellectualGenre`, `Scene` |

Los ajustes de revelado no tienen representación estándar; con *Adjustments JSON* se vuelcan
a `<foto>.captureone.json`. Los vídeos se copian sin metadatos.

## Desarrollo

```bash
xcodegen generate                 # regenerar el .xcodeproj tras añadir o mover ficheros
open AlbumExport.xcodeproj        # ⌘R para ejecutar
swift scripts/render_icon.swift AlbumExport/Assets.xcassets/AppIcon.appiconset   # icono
scripts/build_release.sh          # Release firmada en dist/AlbumExport-<versión>.zip
```

Estructura:

```
AlbumExport/            fuentes SwiftUI, Assets.xcassets, Localizable.xcstrings (en, es, ca)
project.yml             especificación XcodeGen
scripts/                icono y compilación de release
```

Módulos principales: `CatalogReader` (copia y consulta del SQLite, sondeo del esquema),
`PatternMatcher` (comodines vía `fnmatch`), `ExportPlanner` (plan, carpetas, manifiesto),
`ExifToolWriter` (argumentos, escritura por lotes y relectura), `ExportEngine` (copia,
metadatos, informe) y `ExportViewModel` (estado de la ventana).

## Distribución entre Macs

La app no va al App Store. `scripts/build_release.sh` la firma con *Developer ID
Application* si el certificado está en el llavero; si no, mantiene la firma de desarrollo
y en el otro Mac hay que abrirla con clic derecho > Abrir la primera vez.

# Estudio de viabilidad: mover álbumes entre catálogos de Capture One

Objetivo pedido: que la opción **Move** signifique pasar uno o varios álbumes de un
catálogo a otro (existente o creado en ese momento), de forma que el álbum quede
**idéntico** en el destino: originales, variantes, ajustes, capas, máscaras, metadatos y
pertenencia al álbum. Mover no borra nada del catálogo de origen.

Fecha: 4 de septiembre de 2026. Capture One 16.8.5, formato de catálogo 160800.

## 1. Qué compone "todo el contenido" de un álbum

Verificado sobre el catálogo `SonyA1.cocatalog` (copia de solo lectura):

| Capa | Dónde vive | Notas |
|---|---|---|
| Originales | `Originals/AAAA/MM/DD/HHMM/` dentro del bundle, o ruta externa | 456 GB, 87 % dentro del bundle |
| Imagen | `ZIMAGE` + `ZPATHLOCATION` | EXIF cacheado, hashes del fichero, UUID |
| Variantes | `ZVARIANT` | 1 por imagen salvo 16 imágenes con 2 |
| Ajustes | `ZVARIANTLAYER` | 4 capas por variante (defecto, ajuste, combinada, estilo) con ~200 columnas, más 2 464 capas de ajustes locales |
| Máscaras | `Adjustments/LAM/AAAA/MM/DD/HHMM/<fichero>.comask` | 1 850 ficheros, 2,7 GB; referenciadas por `ZMASKUUID` |
| Retoque de retratos | `ZRETOUCHINGLAYER` | 47 filas, 42 con máscaras propias |
| Metadatos | `ZVARIANTMETADATA` | rating, color, keywords, IPTC completo |
| Keywords | `ZKEYWORD` | árbol global del catálogo (nested set `ZLEFT`/`ZRIGHT`) |
| Pertenencia | `ZIMAGEINCOLLECTION`, `ZVARIANTINCOLLECTION`, `ZIMAGEINCOLLECTIONPROPERTIES` | orden manual incluido |
| Álbumes y grupos | `ZCOLLECTION` con `ZPARENT` | |
| Historial de proceso | `ZPROCESSHISTORY` | 4 161 filas; solo informativo |
| Caché | `Cache/Previews`, `Cache/Thumbnails` | 15 GB; Capture One la regenera |

No hay claves foráneas declaradas ni tablas auxiliares de Core Data (`Z_PRIMARYKEY`,
`Z_METADATA`): la asignación de `Z_PK` y las invariantes las gestiona la propia app.

## 2. Caminos posibles

### A. Escribir directamente en la base de datos del catálogo destino

Copiar las filas de las tablas anteriores remapeando claves, copiar originales y máscaras
al bundle destino, e insertar la colección.

- **Crear un catálogo nuevo**: factible clonando el esquema (`sqlite_master`: 22 tablas,
  27 índices) y las filas singleton del catálogo de origen (`ZDOCUMENTCONTENT`,
  `ZENTITIES`, colecciones raíz, `ZVERSIONINFO`, `ZCAPTUREPILOT`, `ZENABLEDOUTPUTRECIPE`)
  con UUID nuevos, más las carpetas `Originals`, `Adjustments`, `Cache`.
- **Riesgos**: formato no documentado y cambiante entre releases (cinco cambios entre
  16.5 y 16.8); invariantes desconocidas (`ZINDEX`, capa combinada, nested set de
  keywords, `ZSELECTEDVARIANTS`, hashes); un error corrompe un catálogo de producción.
  Capture One no valida al abrir: los daños aparecen tarde y de forma silenciosa.
- **Veredicto**: viable técnicamente, **no recomendable** para datos reales. Solo
  aceptable si el destino es siempre un catálogo nuevo creado por la app y se acepta
  validar cada release de Capture One.

### B. Capture One como motor, vía AppleScript (recomendado)

Capture One expone un diccionario AppleScript amplio (138 KB). Lo relevante, verificado
en el `sdef` de la 16.8.5:

- `make new document` con `kind: catalog` y `template` → **crear un catálogo nuevo**.
- `document > export originals` con `export original options {packed: true, include
  adjustments: true}` → exporta cada original como **EIP** (Enhanced Image Package), el
  contenedor oficial que empaqueta original + ajustes de todas las capas + máscaras +
  metadatos + LCC/ICC. No modifica el catálogo de origen (a diferencia de `pack`, que
  convierte el original en EIP dentro del catálogo).
- `document > import` con `import options {destination type: inside catalog, include
  existing adjustments: true}` → importa los EIP en el destino con **todos los ajustes**.
- `make new collection with properties {kind: album, name: …}` (y `kind: group` para
  anidar) + `add inside` → recrea el álbum y su jerarquía.
- Clase `variant`: rating, color tag y todos los campos IPTC legibles y escribibles;
  `apply keyword`, `keyword library` para keywords.

Ventajas: Capture One escribe su propia base de datos, así que el resultado es válido en
cualquier versión y sobrevive a cambios de formato. El origen no se toca. Es el mismo
mecanismo que "Exportar originales" + "Importar" hechos a mano.

Limitaciones y puntos a validar en la práctica:

1. **Vídeos y formatos no empaquetables**: los `.mp4` no se empaquetan en EIP; sus
   metadatos irían aparte (`include adjustments` genera `.cos` junto al fichero).
2. **Múltiples variantes por imagen**: el EIP guarda las variantes, pero hay que comprobar
   que la importación las restaura todas (16 imágenes afectadas en tu catálogo).
3. **Keywords**: viajan dentro del EIP; verificar que la importación las añade al árbol
   del catálogo destino y no solo a la variante.
4. **Historial de proceso y caché**: no se transfieren (informativo / regenerable).
5. **Espacio y tiempo**: el álbum se copia dos veces (EIP temporal y luego dentro del
   bundle destino). Para "Andorra 2024" (308 fotos, 18 GB) implica 36 GB de escritura;
   el EIP temporal se borra al terminar.
6. **Capture One debe estar abierto** y con automatización permitida; la app pedirá el
   permiso de Automation la primera vez (`NSAppleEventsUsageDescription`). La versión
   Pro es necesaria para `current document` y `make new document`.
7. **Catálogo destino existente**: Capture One lo abre en su ventana; la app debe
   asegurarse de que el documento destino es el que recibe la importación
   (`tell document "X"`), no el que tenga el foco.
8. **Identidad**: el destino tendrá UUID de imagen y variante nuevos. Para el usuario es
   idéntico; para la app, el manifiesto debe basarse en el hash del original
   (`ZRAWFILEFULLHASH`), no en el UUID.

### C. Importar catálogo (File > Import Catalog…)

Es la función oficial para fusionar catálogos con todo su contenido, pero **no está en
el diccionario AppleScript**. Solo sería accesible por GUI scripting (System Events),
frágil ante cambios de interfaz. Descartado como mecanismo principal; útil como
alternativa manual: la app podría crear un catálogo intermedio (camino A o B) y el
usuario importarlo desde Capture One.

## 3. Recomendación

Implementar **B** en fases, manteniendo el catálogo de origen siempre intacto:

1. **Prueba de concepto** (media sesión): script AppleScript que, con un catálogo de
   pruebas pequeño creado a mano, exporte 3 fotos con capas y máscaras como EIP, cree un
   catálogo nuevo, las importe y las meta en un álbum. Comparar en Capture One que
   ajustes, máscaras, keywords y rating coinciden. Esto resuelve las dudas 2 y 3.
2. **Integración en la app** (una o dos sesiones): al elegir *Move* aparece un selector
   de catálogo destino (existente o "Crear nuevo…"); la app abre ambos documentos en
   Capture One, exporta por lotes a una carpeta temporal, importa, recrea álbumes y
   grupos, y muestra el progreso y la verificación (recuento de variantes y comparación
   de rating, color y keywords vía AppleScript).
3. **Verificación**: relectura en el destino de rating, color, keywords y número de capas
   por variante; informe CSV como el actual.

Descartar A salvo que se quiera trabajar sin Capture One abierto, en cuyo caso habría
que restringirlo a catálogos nuevos y aceptar el coste de validar cada release.

## 4. Resultados de la prueba de concepto (4 de septiembre de 2026, tarde)

Catálogo de pruebas `Pruebas Claude.cocatalog` creado a mano por el usuario; álbum
"Tuberias Escaldes 2026" de SonyA1 (80 ARW, 8 capas locales con máscara, ratings 0/3/5).

| Prueba | Resultado |
|---|---|
| Abrir catálogo por AppleScript (`open POSIX file`) | Correcto. Falló antes solo porque el disco estaba lleno |
| Importar EIP exportados a mano por el usuario | 80/80. Todos los ajustes, capas y máscaras idénticos al origen |
| Exportar el álbum desde SonyA1 por AppleScript (`export originals`, `packed`, `include adjustments`) e importarlo | 80/80. Idéntico al origen en todas las columnas de ajuste, metadatos, capas y máscaras |
| Única diferencia detectada | Balance de blancos: redondeo en la sexta cifra decimal (serialización XML del `.cos`) |
| Imagen con dos variantes (`_SA12328.ARW`) | Cada EIP contiene **todas** las variantes de la imagen. Exportar las dos variantes genera dos EIP y al importar salen dos imágenes con dos variantes cada una. **Exportar una sola variante por imagen** |
| TIF con keywords (`ScanImage0453/0480.tif`) | Los no RAW no se empaquetan: con `packed: false` e `include adjustments: true` salen `.cos` y `.comask` en `CaptureOne/Settings1680/`. Al importar: ajustes idénticos, keywords en la variante **y en el árbol de keywords** del destino (8 creadas) |
| Máscaras en disco | 7 `.comask` del álbum en origen → 7 por copia en `Adjustments/LAM` del destino |
| Álbum en destino | `make new collection {kind: album}` + `add inside` funciona; el álbum se persiste en la base de datos |

Detalles de la API confirmados en la práctica:

- `import source` acepta una **ruta de texto** (no `POSIX file` ni lista). Antes hay que poner
  `destination collection of import settings` a `recent`, porque con "álbum seleccionado" falla.
- `export originals` es un trabajo en cola: si el destino falla (disco lleno) el trabajo
  sigue y escribe en el destino que esté configurado en ese momento. Hay que esperar a
  que termine antes de cambiar la configuración de exportación.
- El `import` devuelve enseguida; se comprueba el fin contando `images of collection "All Images"`.
- `whose name contains` sobre variantes funciona para seleccionar por nombre de fichero.

Decisiones de diseño para *Move* derivadas de la prueba:

1. Por cada imagen del álbum se exporta **una** variante (la primaria): el EIP lleva todas.
2. RAW (ARW, DNG, NEF, RW2…): `packed: true`. JPG, TIF, PSD, vídeo: `packed: false`, con
   `include adjustments: true` para que salga el `.cos` lateral. Dos pasadas por lote.
3. Importar lote a lote con `include existing adjustments: true` y `exclude duplicates: false`.
4. Recrear el grupo y el álbum en destino y añadir las variantes importadas, identificadas
   por nombre de fichero y hash del original.
5. Verificar en destino: recuento de imágenes y variantes, rating, color, keywords y número
   de capas por variante, comparando con la base de datos del origen (solo lectura).

## 5. Lo que no cambia respecto a la app actual

La opción *Copy* (extraer ficheros con XMP) sigue igual. *Move* deja de significar
"mover ficheros a una carpeta" para significar "trasladar álbumes a otro catálogo",
sin borrar nada del origen. El borrado en el origen queda como acción manual del
usuario en Capture One.

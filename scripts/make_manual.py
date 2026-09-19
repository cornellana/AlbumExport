#!/usr/bin/env python3
"""Genera docs/AlbumExport-Manual.pdf (manual de usuario en castellano) con reportlab."""
import os
from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (BaseDocTemplate, Frame, PageBreak, PageTemplate, Paragraph, Spacer, Table,
                                TableStyle, KeepTogether, Image)
from reportlab.platypus.tableofcontents import TableOfContents

FONTS = "/System/Library/Fonts/Supplemental/"
pdfmetrics.registerFont(TTFont("Body", FONTS + "Arial.ttf"))
pdfmetrics.registerFont(TTFont("Body-Bold", FONTS + "Arial Bold.ttf"))
pdfmetrics.registerFont(TTFont("Body-Italic", FONTS + "Arial Italic.ttf"))
pdfmetrics.registerFont(TTFont("Mono", FONTS + "Courier New.ttf"))
pdfmetrics.registerFontFamily("Body", normal="Body", bold="Body-Bold", italic="Body-Italic", boldItalic="Body-Bold")

INK = colors.HexColor("#1d2733"); ACCENT = colors.HexColor("#0a6e8a"); SOFT = colors.HexColor("#eef4f6")
WARN = colors.HexColor("#fff4e0"); WARN_EDGE = colors.HexColor("#d98a00"); RULE = colors.HexColor("#c9d5da")

body = ParagraphStyle("body", fontName="Body", fontSize=10, leading=14.5, textColor=INK, spaceAfter=6)
h1 = ParagraphStyle("h1", parent=body, fontName="Body-Bold", fontSize=19, leading=24, textColor=ACCENT, spaceBefore=16, spaceAfter=10, keepWithNext=1)
h2 = ParagraphStyle("h2", parent=body, fontName="Body-Bold", fontSize=13, leading=17, textColor=INK, spaceBefore=12, spaceAfter=5, keepWithNext=1)
h3 = ParagraphStyle("h3", parent=body, fontName="Body-Bold", fontSize=10.5, leading=14, textColor=ACCENT, spaceBefore=8, spaceAfter=3, keepWithNext=1)
bullet = ParagraphStyle("bullet", parent=body, leftIndent=14, bulletIndent=3, spaceAfter=3)
step = ParagraphStyle("step", parent=body, leftIndent=18, bulletIndent=0, spaceAfter=4)
cell = ParagraphStyle("cell", parent=body, fontSize=9, leading=12.5, spaceAfter=0)
cellb = ParagraphStyle("cellb", parent=cell, fontName="Body-Bold")
note = ParagraphStyle("note", parent=body, fontSize=9.5, leading=13.5, spaceAfter=0)
toc1 = ParagraphStyle("toc1", parent=body, fontName="Body-Bold", fontSize=10.5, leading=17)
toc2 = ParagraphStyle("toc2", parent=body, fontSize=9.5, leading=14, leftIndent=14)


class Doc(BaseDocTemplate):
    def afterFlowable(self, flowable):
        if isinstance(flowable, Paragraph) and flowable.style.name in ("h1", "h2"):
            level = 0 if flowable.style.name == "h1" else 1
            key = "h%d" % id(flowable)
            self.canv.bookmarkPage(key)
            self.canv.addOutlineEntry(flowable.getPlainText(), key, level=level, closed=level == 0)
            self.notify("TOCEntry", (level, flowable.getPlainText(), self.page, key))


def footer(canvas, doc):
    canvas.saveState()
    canvas.setStrokeColor(RULE); canvas.line(20 * mm, 14 * mm, A4[0] - 20 * mm, 14 * mm)
    canvas.setFont("Body", 8); canvas.setFillColor(colors.HexColor("#6b7a85"))
    canvas.drawString(20 * mm, 9.5 * mm, "AlbumExport · Manual de usuario")
    canvas.drawRightString(A4[0] - 20 * mm, 9.5 * mm, "%d" % doc.page)
    canvas.restoreState()


def P(text): return Paragraph(text, body)
def B(items): return [Paragraph(t, bullet, bulletText="•") for t in items]
def S(items): return [Paragraph(t, step, bulletText="%d." % (i + 1)) for i, t in enumerate(items)]
def ui(en, es): return '<b>%s</b> <font color="#6b7a85">(%s)</font>' % (en, es)


def box(text, warn=False):
    t = Table([[Paragraph(text, note)]], colWidths=[170 * mm])
    t.setStyle(TableStyle([("BACKGROUND", (0, 0), (-1, -1), WARN if warn else SOFT),
                           ("LINEBEFORE", (0, 0), (0, -1), 3, WARN_EDGE if warn else ACCENT),
                           ("LEFTPADDING", (0, 0), (-1, -1), 9), ("RIGHTPADDING", (0, 0), (-1, -1), 9),
                           ("TOPPADDING", (0, 0), (-1, -1), 7), ("BOTTOMPADDING", (0, 0), (-1, -1), 7)]))
    return [Spacer(1, 3), t, Spacer(1, 8)]


def table(rows, widths, header=True):
    data = [[Paragraph(c, cellb if (header and r == 0) else cell) for c in row] for r, row in enumerate(rows)]
    t = Table(data, colWidths=[w * mm for w in widths], repeatRows=1 if header else 0)
    style = [("VALIGN", (0, 0), (-1, -1), "TOP"), ("LINEBELOW", (0, 0), (-1, -1), 0.4, RULE),
             ("LEFTPADDING", (0, 0), (-1, -1), 5), ("RIGHTPADDING", (0, 0), (-1, -1), 5),
             ("TOPPADDING", (0, 0), (-1, -1), 4), ("BOTTOMPADDING", (0, 0), (-1, -1), 4)]
    if header: style += [("BACKGROUND", (0, 0), (-1, 0), SOFT), ("LINEBELOW", (0, 0), (-1, 0), 0.8, ACCENT)]
    t.setStyle(TableStyle(style))
    return [t, Spacer(1, 8)]


story = []
# ---------- Portada ----------
icon = os.path.join(os.path.dirname(__file__), "..", "AlbumExport", "Assets.xcassets", "AppIcon.appiconset", "icon_512.png")
story += [Spacer(1, 30 * mm)]
if os.path.exists(icon):
    img = Image(icon, 38 * mm, 38 * mm); img.hAlign = "CENTER"; story += [img, Spacer(1, 10 * mm)]
story += [Paragraph("AlbumExport", ParagraphStyle("t", parent=h1, fontSize=34, leading=40, alignment=TA_CENTER)),
          Paragraph("Manual de usuario", ParagraphStyle("st", parent=body, fontSize=15, leading=20, alignment=TA_CENTER)),
          Spacer(1, 8 * mm),
          Paragraph("Copiar álbumes de Capture One a una carpeta con sus metadatos, trasladarlos a otro catálogo "
                    "y verificar y sanear el catálogo.", ParagraphStyle("d", parent=body, alignment=TA_CENTER, textColor=colors.HexColor("#4a5863"))),
          Spacer(1, 60 * mm),
          Paragraph("Versión 1.0 · septiembre de 2026 · macOS 14 o posterior<br/>github.com/cornellana/AlbumExport",
                    ParagraphStyle("v", parent=body, fontSize=9, alignment=TA_CENTER, textColor=colors.HexColor("#6b7a85"))),
          PageBreak()]

# ---------- Índice ----------
story += [Paragraph("Contenido", ParagraphStyle("toch", parent=h1))]
toc = TableOfContents(); toc.levelStyles = [toc1, toc2]; toc.dotsMinLevel = 0
story += [toc, PageBreak()]

# ---------- 1 ----------
story += [Paragraph("1. Qué es AlbumExport", h1),
          P("AlbumExport es una aplicación nativa de macOS que trabaja con catálogos y sesiones de <b>Capture One</b>. "
            "Hace tres cosas, que se eligen al principio de la ventana:"),
          *table([["Acción", "Para qué sirve", "Escribe en el catálogo"],
                  [ui("Copy photos to a folder", "Copiar fotos a una carpeta"),
                   "Saca las fotos de uno o varios álbumes a una carpeta (disco, NAS) y graba dentro de cada fichero "
                   "los metadatos del catálogo: rating, color, keywords, título, lugar, copyright…", "No"],
                  [ui("Move albums to another catalog", "Trasladar álbumes a otro catálogo"),
                   "Lleva álbumes completos a otro catálogo de Capture One con todos sus ajustes, capas y máscaras.",
                   "Solo en el de destino"],
                  [ui("Verify catalog", "Verificar el catálogo"),
                   "Compara lo que hay en disco con lo que el catálogo cree tener: huérfanos, perdidos y fotos sin álbum. "
                   "Ofrece acciones para sanearlo.", "Solo si pulsas un botón de acción y confirmas"]],
                 [48, 92, 30]),
          Paragraph("Cómo trata tu catálogo", h2),
          P("La app <b>nunca abre la base de datos de tu catálogo</b>. Al elegir un catálogo copia su base de datos a una "
            "carpeta temporal y consulta la copia, de modo que leer, planificar y verificar no tocan nada. "
            "Las únicas operaciones que modifican algo son las que lanzas tú con un botón y confirmas en un diálogo; "
            "todas se describen en este manual con la etiqueta <b>«Modifica»</b>."),
          *box("Los textos de la interfaz salen en el idioma del Mac (inglés, castellano o catalán). En este manual cada "
               "control aparece con su nombre en inglés y, entre paréntesis, el castellano."),
          Paragraph("Requisitos", h2),
          *B(["macOS 14 (Sonoma) o posterior.",
              "<b>exiftool</b> para escribir metadatos: <font name='Mono'>brew install exiftool</font>. Sin él se puede copiar, "
              "pero no grabar XMP.",
              "<b>Capture One Pro</b> instalado para las funciones que lo manejan (trasladar álbumes, crear álbumes de fotos "
              "sin clasificar, importar huérfanos). La primera vez macOS pide permiso para que AlbumExport controle "
              "Capture One: hay que aceptarlo.",
              "La app no viene del App Store. En otro Mac, la primera vez se abre con clic derecho &gt; Abrir."]),
          PageBreak()]

# ---------- 2 ----------
story += [Paragraph("2. La ventana", h1),
          P("La ventana se recorre de arriba abajo:"),
          *S(["<b>What do you want to do?</b> (¿Qué quieres hacer?): el selector de acción. Según lo elegido, la ventana "
              "pide solo los datos de esa acción.",
              ui("Open Catalog…", "Abrir catálogo…") + ": elige el catálogo <font name='Mono'>.cocatalog</font> o el fichero "
              "<font name='Mono'>.cosessiondb</font> de una sesión. Debajo aparece la versión de Capture One y el formato "
              "del catálogo; si la app detecta un formato que no conoce, avisa ahí y sigue.",
              "La lista de <b>álbumes</b> del catálogo, con sus grupos, y el campo de <b>patrones</b> (acciones Copiar y Trasladar).",
              "El <b>destino</b>: una carpeta (Copiar) o un catálogo (Trasladar).",
              "El <b>plan</b>: la tabla con lo que se va a hacer, foto a foto, antes de hacerlo.",
              "El botón de acción (<b>Export</b>, <b>Move</b> o <b>Verify</b>) y, durante el trabajo, el progreso."]),
          P("Al arrancar, la app recuerda el último catálogo, los patrones, los álbumes marcados, el destino y las opciones. "
            "Por seguridad, la acción de trasladar nunca se recuerda (siempre arranca en Copiar), y si el destino no está "
            "montado (NAS apagado) queda sin elegir."),
          Paragraph("Elegir álbumes: patrones y marcas", h2),
          P("Los álbumes se eligen marcándolos en la lista o escribiendo patrones, separados por punto y coma o en líneas distintas:"),
          *table([["Patrón", "Qué elige"],
                  ["<font name='Mono'>Andorra 20??</font>", "«Andorra 2024», «Andorra 2025»… (<font name='Mono'>?</font> = un carácter cualquiera)"],
                  ["<font name='Mono'>Isla*</font>", "Todo álbum que empiece por «Isla» (<font name='Mono'>*</font> = cualquier texto)"],
                  ["<font name='Mono'>Viajes/*</font>", "Con <font name='Mono'>/</font> se compara la ruta completa Grupo/Álbum: todos los álbumes del grupo «Viajes»"],
                  ["<font name='Mono'>Andorra 20??; Isla*</font>", "Varios patrones a la vez"]], [55, 115]),
          *B(["No distingue mayúsculas de minúsculas.",
              "Los <i>smart albums</i> nunca se incluyen: su contenido no está guardado en el catálogo.",
              "Los álbumes automáticos (Recent Imports, Recent Captures) y los que crea esta app en los grupos "
              "«Sin clasificar» y «Huérfanos recuperados» solo entran si activas "
              + ui("Include automatic albums", "Incluir álbumes automáticos") + ". Así un patrón como "
              "<font name='Mono'>Barcelona*</font> no arrastra también los descartes de Barcelona."]),
          PageBreak()]

# ---------- 3 ----------
story += [Paragraph("3. Copiar fotos a una carpeta", h1),
          P("Saca las fotos de los álbumes elegidos a una carpeta y escribe en cada copia los metadatos que tiene en el "
            "catálogo. Los originales del catálogo no se tocan."),
          Paragraph("Paso a paso", h2),
          *S(["Elige la acción <b>Copy photos to a folder</b> y abre el catálogo.",
              "Marca álbumes o escribe patrones.",
              "En " + ui("Destination folder", "Carpeta de destino") + " pulsa <b>Choose…</b>. No puede estar dentro del catálogo.",
              "Revisa el plan: cuántas fotos, cuánto ocupan, tiempo estimado y, por foto, rating, color y keywords.",
              "Pulsa <b>Export</b>. Al terminar, <b>Show Report</b> abre el informe y <b>Show in Finder</b> la carpeta."]),
          Paragraph("Opciones", h2),
          *table([["Opción", "Qué hace"],
                  [ui("Write metadata (XMP)", "Escribir metadatos"), "Graba los metadatos del catálogo dentro de cada fichero copiado (también en los RAW). Activada por defecto."],
                  [ui("Adjustments JSON", "Ajustes en JSON"), "Los ajustes de revelado no tienen formato estándar: se vuelcan a un fichero <font name='Mono'>&lt;foto&gt;.captureone.json</font> junto a cada foto."],
                  [ui("Refresh already exported", "Actualizar las ya exportadas"), "Reescribe los metadatos de las fotos que ya estaban en el destino (por ejemplo, si has cambiado ratings en Capture One)."],
                  [ui("Include trash", "Incluir papelera"), "Incluye las fotos que están en la papelera del catálogo."],
                  [ui("Include automatic albums", "Incluir álbumes automáticos"), "Permite elegir Recent Imports y los álbumes generados por esta app."]],
                 [58, 112]),
          Paragraph("Qué queda en el destino", h2),
          P("<font name='Mono'>&lt;destino&gt;/&lt;patrón sin comodines&gt;/&lt;álbum&gt;/&lt;fichero&gt;</font> y un informe "
            "<font name='Mono'>AlbumExport_&lt;fecha&gt;.csv</font> en la raíz del destino."),
          *B(["Si dos fotos del mismo álbum se llaman igual, la segunda recibe el sufijo <font name='Mono'>_1</font>, <font name='Mono'>_2</font>…",
              "Cada carpeta de álbum guarda un fichero oculto <font name='Mono'>.albumexport.json</font> que recuerda qué foto del "
              "catálogo es cada fichero. Gracias a él, repetir la exportación no duplica nada.",
              "Un fichero que ya estuviera en la carpeta con el mismo nombre y tamaño que el original (copia hecha a mano) se "
              "adopta: recibe los metadatos y no se duplica.",
              "Los vídeos se copian sin metadatos."]),
          Paragraph("Cortes de red, cancelación y reanudación", h2),
          P("Está pensada para exportar muchos gigabytes a un NAS sin perder lo hecho:"),
          *B(["Trabaja en lotes de 40 fotos y guarda el estado tras cada lote.",
              "Cada fichero se copia con un nombre temporal y solo recibe el definitivo cuando está completo y su tamaño comprobado. "
              "Un corte nunca deja un fichero a medias con nombre bueno.",
              "Si el destino es un volumen de red, cada lote se prepara en el disco local (copia + metadatos) y se sube una sola vez.",
              "Si el destino desaparece, la exportación se detiene con un aviso. <b>Cancel export</b> para limpiamente al acabar el fichero en curso.",
              "Para reanudar, pulsa <b>Export</b> otra vez con el mismo destino: lo completo aparece como <i>Already exported</i> y solo se transfiere lo que falta."]),
          Paragraph("Metadatos que se graban", h2),
          *table([["Del catálogo", "Campo en el fichero"],
                  ["Rating", "XMP Rating"], ["Etiqueta de color", "XMP Label (Red, Orange, Yellow, Green, Blue, Pink, Purple)"],
                  ["Keywords", "Keywords XMP e IPTC, y la jerarquía (HierarchicalSubject) que entiende Lightroom"],
                  ["Título, titular, descripción", "Title, Headline, Description"],
                  ["Ciudad, provincia, país, localización", "City, State, Country, CountryCode, Location"],
                  ["Creador, contacto, copyright, términos de uso", "Creator, Creator contact info, Copyright, UsageTerms, Credit, Source"]],
                 [70, 100]),
          P("Tras escribir, la app relee rating, color y keywords de cada fichero y marca en rojo cualquier diferencia con el catálogo. "
            "En los RAW solo se reescribe la cabecera de metadatos: los datos de imagen quedan idénticos."),
          PageBreak()]

# ---------- 4 ----------
story += [Paragraph("4. Trasladar álbumes a otro catálogo", h1),
          P("Lleva los álbumes elegidos a otro catálogo de Capture One <b>con todo</b>: ajustes, capas, máscaras, retoque, rating, "
            "color, keywords e IPTC, y recrea el grupo y el álbum. <b>No borra nada del catálogo de origen</b>; quitar allí los "
            "álbumes trasladados es una decisión tuya, a mano, en Capture One."),
          Paragraph("Paso a paso", h2),
          *S(["Elige <b>Move albums to another catalog</b>, abre el catálogo de origen y elige los álbumes.",
              "En el destino pulsa " + ui("Choose existing…", "Elegir existente…") + " o " + ui("Create new…", "Crear nuevo…") + ".",
              "Revisa el plan y pulsa <b>Move</b>. La app pide confirmación.",
              "Capture One se abre solo, con los dos catálogos. No lo uses mientras dura el traslado."]),
          Paragraph("Cómo lo hace", h2),
          *B(["Por lotes de 20 fotos, pide a Capture One que exporte los originales: los RAW empaquetados en <b>EIP</b> (original + todas las "
              "variantes + máscaras + metadatos) y los JPG/TIF con su fichero de ajustes al lado.",
              "Los importa en el catálogo de destino con sus ajustes, los añade al álbum y relee rating, color y keywords para verificar.",
              "Una foto con varias variantes (clones) viaja una sola vez y llega con todas.",
              "Si el álbum ya existe en el destino, se añade a él y se omiten las fotos que ya contiene: permite reanudar un traslado interrumpido.",
              "Deja un informe <font name='Mono'>AlbumExport_transfer_&lt;fecha&gt;.csv</font> junto al catálogo de destino."]),
          *box("<b>Modifica</b> el catálogo de destino (importa fotos y crea álbumes). Está validado con álbumes de 8 y 80 fotos; "
               "para un álbum muy grande o con vídeos, prueba antes con un catálogo de destino nuevo.", warn=True),
          PageBreak()]

# ---------- 5 ----------
story += [Paragraph("5. Verificar el catálogo", h1),
          P("Al elegir <b>Verify catalog</b> la verificación arranca sola (unos segundos). Compara la carpeta "
            "<font name='Mono'>Originals</font> que hay dentro del catálogo con su base de datos. Se puede cancelar, repetir con "
            + ui("Verify again", "Verificar de nuevo") + " y guardar todo en un CSV con " + ui("Save report…", "Guardar informe…") + "."),
          Paragraph("La línea de resumen", h2),
          P("Al dejar el cursor quieto sobre cada cifra aparece una explicación de lo que significa."),
          *table([["Cifra", "Significado"],
                  [ui("Files in Originals", "Ficheros en Originals"), "Todo fichero que existe físicamente dentro del catálogo, lo conozca Capture One o no."],
                  [ui("Referenced by the index", "Referenciadas por el índice"), "Las fotos que la base de datos conoce, incluidas las guardadas fuera del catálogo y las de su papelera."],
                  [ui("Orphans", "Huérfanos"), "Ficheros en Originals a los que ningún registro apunta: ocupan disco y Capture One no los ve. Se indica cuánto ocupan."],
                  [ui("Missing files", "Perdidos"), "El catálogo tiene la foto pero su fichero no está donde lo espera: en Capture One sale <i>offline</i>."],
                  [ui("Not in any album", "Sin álbum"), "Fotos bien catalogadas y con su fichero, pero que no están en ninguno de tus álbumes."]],
                 [58, 112]),
          P("Las cifras no tienen por qué sumar: el índice cuenta fotos guardadas fuera de Originals, y en Originals hay ficheros "
            "de acompañamiento (<font name='Mono'>.xmp</font>, <font name='Mono'>.cos</font>…) que ni son fotos referenciadas ni cuentan como huérfanos."),

          Paragraph("5.1 Pestaña Orphan files (huérfanos)", h2),
          P("La app lee la hora de captura de cada huérfano y lo clasifica en la columna " + ui("In the catalog", "En el catálogo") + ":"),
          *table([["Estado", "Qué es", "Qué hacer"],
                  ["Copia de una foto del álbum X / del catálogo", "El catálogo ya tiene esa foto (mismo nombre y misma hora de captura). El fichero sobra: suele venir de importaciones repetidas.", "Eliminarla"],
                  ["Copia repetida de otro huérfano", "Hay otro huérfano con la misma foto, que ya figura antes en la lista.", "Eliminarla"],
                  ["No está en el catálogo", "Una foto que nunca llegó a entrar en el catálogo, o que se quitó de él sin borrar el fichero. La columna <b>Probable album</b> dice a qué álbum parece pertenecer.", "Importarla, o moverla fuera"],
                  ["No es una foto", "Bases de datos o ficheros de otras aplicaciones.", "Moverlos fuera"]],
                 [45, 90, 35]),
          Paragraph("Botones", h3),
          *table([["Botón", "Qué hace"],
                  [ui("Remove the N spare copies…", "Eliminar las N copias sobrantes…"),
                   "<b>Modifica.</b> Elimina las copias sobrantes. El diálogo deja elegir entre <b>Move to Trash</b> (a la Papelera del Mac, recuperable "
                   "hasta que la vacíes) y <b>Delete permanently</b> (libera el espacio ya; no se puede deshacer). Solo cuenta como sobrante el huérfano "
                   "cuya foto está viva en el catálogo (no en su papelera) y con su fichero en disco; se excluyen los huérfanos reservados para "
                   "restaurar un perdido, y justo antes de borrar cada fichero se comprueba otra vez que la otra copia sigue ahí y está completa."],
                  [ui("Import the N photos not in the catalog…", "Importar las N fotos que no están en el catálogo…"),
                   "<b>Modifica.</b> Capture One importa una copia de cada foto ausente (una sola vez aunque haya varias copias huérfanas) y la coloca en el "
                   "grupo <b>Recovered orphans</b> (Huérfanos recuperados), en un subálbum con el nombre de su álbum probable, o en «Sin álbum probable». "
                   "Los ficheros huérfanos no se tocan: después de importar pasan a ser copias sobrantes y se eliminan con el botón anterior."],
                  [ui("Move orphans to folder…", "Mover huérfanos a una carpeta…"),
                   "<b>Modifica.</b> Saca todos los huérfanos del catálogo a la carpeta que elijas, conservando la estructura de carpetas por fecha, "
                   "y deja allí un <font name='Mono'>AlbumExport_orphans.csv</font>. No toca ningún fichero que el catálogo use."]],
                 [62, 108]),

          Paragraph("5.2 Pestaña Missing files (perdidos)", h2),
          P("Para cada foto perdida se muestra dónde la espera el catálogo y, si se ha localizado, dónde está. La app busca por este orden:"),
          *S(["<b>Entre los huérfanos del propio catálogo</b>, automáticamente: si coinciden, el fichero solo cambió de carpeta (en la tabla lleva delante una flecha circular).",
              "Donde tú le digas, con el menú " + ui("Search in…", "Buscar en…") + ": un disco o tarjeta montados, " + ui("Other folder…", "Otra carpeta…")
              + " o <b>Spotlight</b>. La búsqueda entra en todas las subcarpetas y en otros catálogos, se puede cancelar, y los encontrados aparecen en la tabla al momento."]),
          P("Un fichero se acepta como el original si tiene el mismo nombre y el mismo tamaño que el registrado; o, con la marca <b>≈</b>, el mismo nombre, "
            "un tamaño muy parecido y la <b>misma hora de captura</b>. Esto último cubre los originales de la tarjeta, que miden unos KB menos que la copia "
            "importada si al importar se les incrustó el lugar u otros metadatos. Una foto distinta con el mismo nombre (contador de la cámara repetido) "
            "tiene otra hora de captura y se descarta."),
          P("El texto naranja <i>Already indexed at…</i> señala que esa foto ya está en el catálogo por otra ruta: es una importación duplicada y lo que "
            "sobra es el registro perdido, que se quita en Capture One."),
          *box("<b>Modifica.</b> " + ui("Restore found files into the catalog", "Restaurar en el catálogo los encontrados")
               + " lleva cada fichero a la ruta que el catálogo espera: los huérfanos del propio catálogo se mueven y lo encontrado fuera se copia. "
               "Nunca sobrescribe un fichero existente.", warn=True),

          Paragraph("5.3 Pestaña Not in any album (sin álbum)", h2),
          P("Son fotos que están en el catálogo pero en ninguno de tus álbumes; Recent Imports no cuenta como álbum y, además, Capture One solo conserva "
            "las diez últimas importaciones. Lo habitual es que sean fotos que quitaste de un álbum al hacer limpieza. La tabla las separa en:"),
          *B(["<b>Duplicados</b> (columna naranja): tienen el mismo nombre y la misma hora de captura que una foto que sí está en un álbum. Son importaciones repetidas.",
              "<b>El resto</b>, con su " + ui("Probable album", "Álbum probable") + "."]),
          Paragraph("Cómo se deduce el álbum probable", h3),
          *S(["Se ordenan por hora de captura las fotos que ya están en álbumes. Si la foto anterior y la siguiente (a menos de 24 horas) están en un mismo álbum, es ese.",
              "En la frontera entre dos álbumes decide la secuencia del nombre (<font name='Mono'>_AM21178</font>, <font name='Mono'>_AM21179</font>…) y, si no aclara nada, la foto más cercana en el tiempo. Estas propuestas llevan la marca <b>≈</b>: son menos seguras.",
              "Si valen varios álbumes, gana el que abarca menos tiempo: el de la sesión, no una recopilación tipo «Portfolio».",
              "Sin ninguna foto clasificada a menos de 24 horas, o sin hora de captura, no hay propuesta."]),
          *box("<b>Modifica.</b> " + ui("Create “Unfiled” group in Capture One", "Crear grupo «Sin clasificar» en Capture One")
               + " crea el grupo con un subálbum por cada álbum probable (con su mismo nombre), <b>No probable album</b> (Sin álbum probable) para el resto "
               "y <b>Duplicates</b> (Duplicados) para las copias repetidas. Solo añade fotos a álbumes: no mueve ni borra nada, y se puede repetir.", warn=True),
          P("Una vez en esos subálbumes las fotos cuentan como clasificadas y dejan de salir en esta pestaña. Decidir qué haces con ellas —pasarlas a su álbum "
            "definitivo o borrarlas— es un trabajo aparte que se hace en Capture One. Esos subálbumes no se usan como referencia para proponer álbum a otras fotos."),
          PageBreak()]

# ---------- 6 ----------
story += [Paragraph("6. Tareas habituales", h1),
          Paragraph("Purgar los descartes", h2),
          *S(["Verify &gt; <b>Not in any album</b> &gt; crea el grupo «Unfiled».",
              "En Capture One, abre cada subálbum y revisa. Para borrar de verdad, selecciona las fotos y usa en el menú <b>Image</b> la orden "
              "<b>Delete (Move to Catalog Trash)</b>. La tecla Supr sola, dentro de un álbum, solo las quita del álbum. Comprueba que está activo "
              "«Edit Selected Variants» para que afecte a toda la selección.",
              "Cuando estés seguro: <b>File &gt; Empty Catalog Trash…</b>. Es lo que borra los ficheros y libera el espacio; no tiene vuelta atrás.",
              "Vuelve a AlbumExport y pulsa <b>Verify again</b>."]),
          Paragraph("Recuperar espacio de los huérfanos", h2),
          *S(["Verify &gt; <b>Orphan files</b>. Mira cuántas son copias sobrantes y cuánto ocupan (lo dice el propio botón).",
              "Si hay fotos «No está en el catálogo» que te interesan, impórtalas primero.",
              "Pulsa <b>Remove the N spare copies…</b> y elige <b>Move to Trash</b>.",
              "Abre Capture One, comprueba un par de álbumes y, si todo está bien, vacía la Papelera del Mac."]),
          *box("Haz la purga de descartes <b>antes</b> de importar huérfanos. Cuando borras una foto del catálogo, su copia huérfana deja de ser «copia» "
               "y pasa a «no está en el catálogo»: si importas sin mirar la columna de álbum probable, puedes recuperar descartes."),
          Paragraph("Recuperar fotos perdidas desde la tarjeta o una copia de seguridad", h2),
          *S(["Conecta la tarjeta o el disco.", "Verify &gt; <b>Missing files</b> &gt; <b>Search in…</b> y elige el volumen.",
              "Cuando termine, pulsa <b>Restore found files into the catalog</b> y confirma.", "Pulsa <b>Verify again</b>: las restauradas ya no aparecen."]),
          Paragraph("Copia de un viaje al NAS", h2),
          *S(["Acción <b>Copy photos to a folder</b>, patrón del viaje (p. ej. <font name='Mono'>Islandia 2025</font>), destino en el NAS.",
              "Pulsa <b>Export</b>. Si se corta la red, vuelve a pulsar <b>Export</b> cuando vuelva: continúa donde estaba."]),

          Paragraph("7. Si algo no va", h1),
          *table([["Síntoma", "Causa y solución"],
                  ["No se escriben metadatos", "Falta exiftool. Instálalo con <font name='Mono'>brew install exiftool</font> y vuelve a abrir la app."],
                  ["Capture One no responde a la app", "macOS no tiene concedido el permiso de automatización: Ajustes del Sistema &gt; Privacidad y seguridad &gt; Automatización &gt; AlbumExport &gt; Capture One."],
                  ["«Capture One no ha añadido N fotos»", "A veces Capture One no añade fotos a un álbum sin dar error. La app cuenta lo que ha entrado de verdad y reintenta; si aun así faltan, pulsa el botón otra vez."],
                  ["El destino aparece sin elegir al abrir", "El volumen no estaba montado (NAS apagado). Móntalo y elígelo de nuevo."],
                  ["Aviso de formato de catálogo desconocido", "Capture One ha actualizado el formato. La app sigue funcionando con lo que reconoce; los formatos validados van de 16.5 a 16.8."],
                  ["Las cifras de Verify no cuadran con Capture One", "Pulsa <b>Verify again</b>: la app vuelve a leer el catálogo tal como está en disco en ese momento. Hazlo siempre después de cambiar algo en Capture One y antes de restaurar o eliminar ficheros."]],
                 [60, 110]),
          Paragraph("Resumen de lo que modifica y lo que no", h2),
          *table([["Operación", "Toca el catálogo", "Reversible"],
                  ["Abrir catálogo, planificar, Verify, Save report", "No", "—"],
                  ["Copy (copiar)", "No", "—"],
                  ["Move albums (trasladar)", "Solo el de destino", "Borrando lo importado"],
                  ["Create «Unfiled» group", "Sí: crea álbumes", "Sí: borra el grupo"],
                  ["Import orphans", "Sí: importa fotos", "Sí: bórralas en Capture One"],
                  ["Remove spare copies › Move to Trash", "Sí: quita ficheros sobrantes", "Sí, hasta vaciar la Papelera"],
                  ["Remove spare copies › Delete permanently", "Sí: quita ficheros sobrantes", "<b>No</b>"],
                  ["Move orphans to folder", "Sí: saca ficheros sobrantes", "Sí: están en la carpeta"],
                  ["Restore found files", "Sí: repone ficheros que faltan", "Sí"]],
                 [80, 50, 40])]

out = os.path.join(os.path.dirname(__file__), "..", "docs", "AlbumExport-Manual.pdf")
doc = Doc(out, pagesize=A4, leftMargin=20 * mm, rightMargin=20 * mm, topMargin=18 * mm, bottomMargin=20 * mm,
          title="AlbumExport · Manual de usuario", author="Francisco Cornellana", subject="Manual de usuario de AlbumExport", lang="es")
frame = Frame(doc.leftMargin, doc.bottomMargin, doc.width, doc.height, id="f")
doc.addPageTemplates([PageTemplate(id="p", frames=[frame], onPage=footer)])
doc.multiBuild(story)
print(os.path.abspath(out))

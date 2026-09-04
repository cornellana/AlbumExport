#!/usr/bin/env python3
"""
co_album_export.py — Extrae las fotos de uno o varios álbumes de un catálogo
(o sesión) de Capture One a una carpeta, y graba en XMP dentro de cada fichero
(RAW incluidos) los metadatos del índice: rating, etiqueta de color, keywords,
título, descripción, contacto, copyright, localización, etc.

Principios de seguridad:
  * El catálogo original NUNCA se abre ni se modifica. Se copia la base de
    datos SQLite (con su WAL) a un temporal y se consulta la copia.
  * Por defecto se COPIA. Mover requiere `--move` y confirmación explícita,
    porque en catálogos con originales dentro del bundle deja las fotos offline.
  * Los metadatos se escriben solo en los ficheros ya copiados al destino.

Uso rápido:
  python3 co_album_export.py --list --catalog ~/Pictures/X.cocatalog
  python3 co_album_export.py --catalog ~/Pictures/X.cocatalog --dest ~/Export "Andorra 20??" "Isla*"
  python3 co_album_export.py            (modo interactivo con diálogos)

Estructura de salida:
  <dest>/<patrón sin comodines>/<nombre del álbum>/<fichero>
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import fnmatch
import html
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

# MARK: - Constantes

# Índice de etiqueta de color de Capture One (ZCOLOR_TAG_INDEX) -> nombre XMP.
# Orden verificado en las cadenas del binario de Capture One 16.8.
COLOR_NAMES = {1: "Red", 2: "Orange", 3: "Yellow", 4: "Green", 5: "Blue", 6: "Pink", 7: "Purple"}

# Carpetas virtuales cuyos álbumes hijos son automáticos (uno por importación).
AUTO_FOLDERS = {"Recent Imports", "Recent Captures"}

# Extensiones a las que no se les escribe XMP (vídeo, formatos raros).
NO_METADATA_EXT = {".mp4", ".mov", ".avi", ".m4v", ".eic", ".iff"}

# Columna de ZVARIANTMETADATA -> tag exiftool (valores escalares, solo si no vacíos).
# Los tags MWG: escriben XMP y, si el fichero ya lleva IPTC (Photo Mechanic, escáner),
# también el campo IPTC equivalente para que ambos bloques queden coherentes.
SCALAR_TAGS = [
    ("ZSTATUS_TITLE", "XMP-dc:Title"),
    ("ZCONTENT_HEADLINE", "XMP-photoshop:Headline"),
    ("ZCONTENT_DESCRIPTION", "MWG:Description"),
    ("ZCONTENT_DESCRIPTIONWRITER", "XMP-photoshop:CaptionWriter"),
    ("ZCONTENT_CATEGORY", "XMP-photoshop:Category"),
    ("ZIMAGE_INTELLECTUALGENRE", "XMP-iptcCore:IntellectualGenre"),
    ("ZIMAGE_LOCATION", "MWG:Location"),
    ("ZIMAGE_CITY", "MWG:City"),
    ("ZIMAGE_STATE", "MWG:State"),
    ("ZIMAGE_COUNTRY", "MWG:Country"),
    ("ZIMAGE_ISOCOUNTRYCODE", "XMP-iptcCore:CountryCode"),
    ("ZCONTACT_CREATOR", "MWG:Creator"),
    ("ZCONTACT_CREATORSTITLE", "XMP-photoshop:AuthorsPosition"),
    ("ZCONTACT_ADDRESS", "XMP-iptcCore:CreatorAddress"),
    ("ZCONTACT_CITY", "XMP-iptcCore:CreatorCity"),
    ("ZCONTACT_STATE_PROVINCE", "XMP-iptcCore:CreatorRegion"),
    ("ZCONTACT_POSTALCODE", "XMP-iptcCore:CreatorPostalCode"),
    ("ZCONTACT_COUNTRY", "XMP-iptcCore:CreatorCountry"),
    ("ZCONTACT_PHONES", "XMP-iptcCore:CreatorWorkTelephone"),
    ("ZCONTACT_EMAILS", "XMP-iptcCore:CreatorWorkEmail"),
    ("ZCONTACT_WEBSITES", "XMP-iptcCore:CreatorWorkURL"),
    ("ZSTATUS_COPYRIGHTNOTICE", "MWG:Copyright"),
    ("ZSTATUS_USAGETERMS", "XMP-xmpRights:UsageTerms"),
    ("ZSTATUS_PROVIDER", "XMP-photoshop:Credit"),
    ("ZSTATUS_SOURCE", "XMP-photoshop:Source"),
    ("ZSTATUS_INSTRUCTIONS", "XMP-photoshop:Instructions"),
    ("ZSTATUS_JOBIDENTIFIER", "XMP-photoshop:TransmissionReference"),
    ("ZGETTY_PARENTMEID", "XMP-getty:ParentMEID"),
    ("ZGETTY_ORIGINALFILENAME", "XMP-getty:OriginalFileName"),
    ("ZGETTY_PERSONALITY", "XMP-getty:Personality"),
]

# Columnas con listas separadas por coma -> tag de lista exiftool.
LIST_TAGS = [
    ("ZCONTENT_SUPPLEMENTALCATEGORIES", "XMP-photoshop:SupplementalCategories"),
    ("ZCONTENT_SUBJECTCODE", "XMP-iptcCore:SubjectCode"),
    ("ZIMAGE_SCENE", "XMP-iptcCore:Scene"),
]


# MARK: - Modelos

@dataclass
class Album:
    pk: int
    name: str
    path: str          # "Grupo/Álbum"
    is_auto: bool      # álbum automático de "Recent Imports"/"Recent Captures"
    is_smart: bool


@dataclass
class Photo:
    image_pk: int
    image_uuid: str
    filename: str
    source: Path | None      # None si la ruta no se pudo resolver
    trashed: bool
    inside_catalog: bool
    variant_pk: int | None = None
    rating: int | None = None
    color_index: int | None = None
    keywords: list[str] = field(default_factory=list)
    hierarchical: list[str] = field(default_factory=list)
    metadata: dict = field(default_factory=dict)


@dataclass
class Job:
    pattern: str
    album: Album
    photo: Photo
    dest: Path | None = None
    status: str = ""


# MARK: - Catálogo

class Catalog:
    """Acceso de solo lectura a un catálogo o sesión de Capture One vía copia temporal."""

    def __init__(self, path: Path):
        self.db_path, self.root = self._resolve(path)
        self._tmp = tempfile.TemporaryDirectory(prefix="co_export_")
        snapshot = Path(self._tmp.name) / self.db_path.name
        # Copiamos db + wal + shm para leer un estado consistente sin tocar el original.
        for suffix in ("", "-wal", "-shm"):
            src = self.db_path.with_name(self.db_path.name + suffix)
            if src.exists():
                shutil.copy2(src, snapshot.with_name(snapshot.name + suffix))
        self.conn = sqlite3.connect(snapshot)
        self.conn.row_factory = sqlite3.Row
        self.ent = {r["ZNAME"]: r["Z_ENT"] for r in self.conn.execute("SELECT Z_ENT, ZNAME FROM ZENTITIES")}
        self._keyword_parents = self._load_keyword_tree()

    @staticmethod
    def _resolve(path: Path) -> tuple[Path, Path]:
        p = path.expanduser().resolve()
        if p.is_dir():
            for pattern in ("*.cocatalogdb", "*.cosessiondb"):
                found = sorted(p.glob(pattern))
                if found:
                    return found[0], p
            raise SystemExit(f"No se encontró .cocatalogdb ni .cosessiondb en {p}")
        if p.suffix.lower() in (".cocatalogdb", ".cosessiondb"):
            return p, p.parent
        raise SystemExit(f"Ruta de catálogo no reconocida: {p}")

    def close(self):
        self.conn.close()
        self._tmp.cleanup()

    # MARK: Álbumes

    def albums(self) -> list[Album]:
        rows = {r["Z_PK"]: r for r in self.conn.execute(
            "SELECT Z_PK, Z_ENT, ZNAME, ZPARENT FROM ZCOLLECTION")}
        ent_album = self.ent.get("AlbumCollection")
        ent_smart = self.ent.get("SmartCollection")
        ent_folder = self.ent.get("VirtualFolderCollection")
        ent_project = self.ent.get("ProjectCollection")

        def path_of(pk: int) -> list[str]:
            parts = []
            seen = set()
            while pk in rows and pk not in seen:
                seen.add(pk)
                r = rows[pk]
                if r["Z_ENT"] == ent_project:
                    break
                parts.append(r["ZNAME"] or "")
                pk = r["ZPARENT"]
            return list(reversed(parts))

        result = []
        for r in rows.values():
            if r["Z_ENT"] not in (ent_album, ent_smart):
                continue
            parent = rows.get(r["ZPARENT"])
            is_auto = bool(parent and parent["Z_ENT"] == ent_folder and parent["ZNAME"] in AUTO_FOLDERS)
            result.append(Album(
                pk=r["Z_PK"], name=r["ZNAME"] or "", path="/".join(path_of(r["Z_PK"])),
                is_auto=is_auto, is_smart=(r["Z_ENT"] == ent_smart)))
        result.sort(key=lambda a: a.path.casefold())
        return result

    # MARK: Fotos

    def photos_in_album(self, album: Album) -> list[Photo]:
        sql = """
            SELECT i.Z_PK, i.ZIMAGEUUID, i.ZIMAGEFILENAME, i.ZISTRASHED, i.ZISINSIDECATALOG,
                   p.ZISRELATIVE, p.ZMACROOT, p.ZRELATIVEPATH
            FROM ZIMAGEINCOLLECTION ic
            JOIN ZIMAGE i ON i.Z_PK = ic.ZIMAGE
            LEFT JOIN ZPATHLOCATION p ON p.Z_PK = i.ZIMAGELOCATION
            WHERE ic.ZCOLLECTION = ?
            ORDER BY i.ZIMAGEFILENAME COLLATE NOCASE
        """
        photos = []
        for r in self.conn.execute(sql, (album.pk,)):
            source = self._resolve_source(r)
            photo = Photo(
                image_pk=r["Z_PK"], image_uuid=r["ZIMAGEUUID"] or str(r["Z_PK"]),
                filename=r["ZIMAGEFILENAME"], source=source,
                trashed=bool(r["ZISTRASHED"]), inside_catalog=bool(r["ZISINSIDECATALOG"]))
            self._load_metadata(photo, album)
            photos.append(photo)
        return photos

    def _resolve_source(self, r: sqlite3.Row) -> Path | None:
        rel = r["ZRELATIVEPATH"]
        if rel is None:
            return None
        if r["ZISRELATIVE"]:
            return self.root / rel / r["ZIMAGEFILENAME"]
        root = r["ZMACROOT"] or "/"
        # ZRELATIVEPATH puede venir con o sin barra inicial según el volumen.
        return Path(root) / rel.lstrip("/") / r["ZIMAGEFILENAME"]

    def _load_metadata(self, photo: Photo, album: Album):
        # Se prefiere la variante que está en el álbum; si no, la primaria (menor ZINDEX).
        row = self.conn.execute("""
            SELECT v.Z_PK, v.ZCOMBINEDSETTINGS, v.ZADJUSTMENTLAYER, v.ZDEFAULTLAYER,
                   (vc.Z_PK IS NOT NULL) AS in_album
            FROM ZVARIANT v
            LEFT JOIN ZVARIANTINCOLLECTION vc ON vc.ZVARIANT = v.Z_PK AND vc.ZCOLLECTION = ?
            WHERE v.ZIMAGE = ?
            ORDER BY in_album DESC, v.ZINDEX ASC
            LIMIT 1
        """, (album.pk, photo.image_pk)).fetchone()
        if row is None:
            return
        photo.variant_pk = row["Z_PK"]
        # La capa "combinada" contiene los valores efectivos (ajuste sobre defecto).
        meta = self._layer_metadata(row["ZCOMBINEDSETTINGS"])
        if meta is None:
            adjust = self._layer_metadata(row["ZADJUSTMENTLAYER"]) or {}
            default = self._layer_metadata(row["ZDEFAULTLAYER"]) or {}
            meta = {k: (adjust.get(k) if adjust.get(k) is not None else default.get(k))
                    for k in set(adjust) | set(default)}
        photo.metadata = meta
        photo.rating = meta.get("ZBASIC_RATING")
        photo.color_index = meta.get("ZCOLOR_TAG_INDEX")
        photo.keywords = self._parse_keywords(meta.get("ZCONTENT_KEYWORDS"))
        photo.hierarchical = [self._hierarchical(k) for k in photo.keywords]

    def _layer_metadata(self, layer_pk) -> dict | None:
        if layer_pk is None:
            return None
        row = self.conn.execute("""
            SELECT m.* FROM ZVARIANTLAYER l JOIN ZVARIANTMETADATA m ON m.Z_PK = l.ZMETADATA
            WHERE l.Z_PK = ?
        """, (layer_pk,)).fetchone()
        return dict(row) if row else None

    # MARK: Keywords

    def _load_keyword_tree(self) -> dict[str, str | None]:
        """Nombre de keyword -> nombre del padre (para dc:subject jerárquico)."""
        try:
            rows = self.conn.execute("SELECT Z_PK, ZNAME, ZPARENT FROM ZKEYWORD").fetchall()
        except sqlite3.Error:
            return {}
        by_pk = {r["Z_PK"]: r for r in rows}
        return {r["ZNAME"]: (by_pk[r["ZPARENT"]]["ZNAME"] if r["ZPARENT"] in by_pk else None)
                for r in rows if r["ZNAME"]}

    @staticmethod
    def _parse_keywords(raw: str | None) -> list[str]:
        # Formato observado: "Nombre||0,Otro||1" (nombre, separador, índice de orden).
        if not raw:
            return []
        out = []
        for entry in raw.split(","):
            name = entry.split("||")[0].strip()
            if name and name not in out:
                out.append(name)
        return out

    def _hierarchical(self, name: str) -> str:
        chain = [name]
        seen = {name}
        parent = self._keyword_parents.get(name)
        while parent and parent not in seen:
            chain.append(parent)
            seen.add(parent)
            parent = self._keyword_parents.get(parent)
        return "|".join(reversed(chain))

    # MARK: Ajustes (opcional)

    def adjustments(self, variant_pk: int) -> dict:
        """Volcado de las columnas no nulas de las capas de ajuste/defecto de la variante."""
        out = {}
        row = self.conn.execute(
            "SELECT ZADJUSTMENTLAYER, ZDEFAULTLAYER FROM ZVARIANT WHERE Z_PK = ?", (variant_pk,)).fetchone()
        if not row:
            return out
        for label, pk in (("adjustment", row["ZADJUSTMENTLAYER"]), ("default", row["ZDEFAULTLAYER"])):
            if pk is None:
                continue
            layer = self.conn.execute("SELECT * FROM ZVARIANTLAYER WHERE Z_PK = ?", (pk,)).fetchone()
            if layer:
                out[label] = {k[1:].lower(): v for k, v in dict(layer).items()
                              if v is not None and k.startswith("Z") and k not in ("Z_ENT", "Z_PK", "ZMETADATA", "ZVARIANT")}
        return out


# MARK: - Utilidades

def sanitize(name: str, strip_wildcards: bool = False) -> str:
    if strip_wildcards:
        name = name.replace("*", "").replace("?", "")
    name = re.sub(r'[/\\:\x00-\x1f]', " ", name)
    name = re.sub(r"\s+", " ", name).strip(" .")
    return name or "album"


def match_albums(albums: list[Album], pattern: str, include_auto: bool) -> list[Album]:
    pat = pattern.casefold()
    hits = []
    for a in albums:
        if a.is_smart:
            continue  # los smart albums no tienen pertenencia explícita en la BD
        if a.is_auto and not include_auto:
            continue
        target = a.path if "/" in pat else a.name
        if fnmatch.fnmatchcase(target.casefold(), pat):
            hits.append(a)
    return hits


def unique_dest(folder: Path, filename: str, used: set[str]) -> Path:
    """Nombre libre en la carpeta: añade sufijo _1, _2... si ya existe (en disco o en esta ejecución)."""
    stem, ext = os.path.splitext(filename)
    candidate = filename
    n = 1
    while candidate.casefold() in used or (folder / candidate).exists():
        candidate = f"{stem}_{n}{ext}"
        n += 1
    used.add(candidate.casefold())
    return folder / candidate


def load_manifest(folder: Path) -> dict:
    # Restos de copias interrumpidas en una ejecución anterior.
    for stale in folder.glob(".co_export-partial-*"):
        stale.unlink(missing_ok=True)
    f = folder / ".co_export.json"
    if f.exists():
        try:
            return json.loads(f.read_text())
        except json.JSONDecodeError:
            return {}
    return {}


def save_manifest(folder: Path, manifest: dict):
    (folder / ".co_export.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=1))


def esc(value) -> str:
    """Escapa un valor para el argfile de exiftool con -E (saltos de línea incluidos)."""
    s = html.escape(str(value), quote=False)
    return s.replace("\r", "&#13;").replace("\n", "&#10;")


# MARK: - Metadatos con exiftool

def exiftool_args(photo: Photo) -> list[str]:
    """Argumentos exiftool para un fichero (sin la ruta)."""
    args = ["-overwrite_original", "-P", "-E", "-m"]
    if photo.rating is not None:
        args.append(f"-XMP-xmp:Rating={int(photo.rating)}")
    if photo.color_index is not None:
        color = COLOR_NAMES.get(int(photo.color_index))
        args.append(f"-XMP-xmp:Label={color}" if color else "-XMP-xmp:Label=")
    # Keywords: se reemplazan por las del catálogo (el catálogo es la fuente de verdad).
    # Nota: en exiftool, varios "-TAG=valor" seguidos sustituyen la lista entera;
    # "-TAG=" seguido de "-TAG+=valor" NO la borra y duplica los valores existentes.
    args += _list_args("MWG:Keywords", photo.keywords)
    args += _list_args("XMP-lr:HierarchicalSubject", photo.hierarchical)
    m = photo.metadata
    for column, tag in SCALAR_TAGS:
        v = m.get(column)
        if v not in (None, ""):
            args.append(f"-{tag}={esc(v)}")
    for column, tag in LIST_TAGS:
        v = m.get(column)
        if v not in (None, ""):
            args += _list_args(tag, [s.strip() for s in str(v).split(",") if s.strip()])
    return args


def _list_args(tag: str, values: list[str]) -> list[str]:
    """Argumentos que dejan la lista `tag` exactamente igual a `values` (vacía si no hay)."""
    if not values:
        return [f"-{tag}="]
    return [f"-{tag}={esc(v)}" for v in values]


def write_metadata(jobs: list[Job], exiftool: str) -> dict[str, str]:
    """Escribe XMP en lote con un único proceso exiftool. Devuelve {ruta: 'ok'|'error: ...'}."""
    targets = [j for j in jobs if j.dest and j.status == "copiado" and j.dest.suffix.lower() not in NO_METADATA_EXT]
    if not targets:
        return {}
    with tempfile.NamedTemporaryFile("w", suffix=".args", delete=False, encoding="utf-8") as f:
        for j in targets:
            for a in exiftool_args(j.photo):
                f.write(a + "\n")
            f.write(str(j.dest) + "\n-execute\n")
        argfile = f.name
    try:
        proc = subprocess.run([exiftool, "-@", argfile], capture_output=True, text=True)
    finally:
        os.unlink(argfile)
    results = {str(j.dest): "ok" for j in targets}
    for line in (proc.stderr + "\n" + proc.stdout).splitlines():
        if line.startswith("Error") or "files weren't updated" in line:
            for path in results:
                if path in line:
                    results[path] = f"error: {line.strip()}"
            if " - " in line:
                path = line.rsplit(" - ", 1)[-1].strip()
                if path in results:
                    results[path] = f"error: {line.strip()}"
    return results


def verify_metadata(jobs: list[Job], exiftool: str) -> dict[str, dict]:
    """Relee rating/label/keywords de los ficheros escritos para comprobar la escritura."""
    paths = [str(j.dest) for j in jobs if j.dest and j.status == "ok"]
    if not paths:
        return {}
    with tempfile.NamedTemporaryFile("w", suffix=".args", delete=False, encoding="utf-8") as f:
        f.write("\n".join(paths) + "\n")
        argfile = f.name
    try:
        proc = subprocess.run([exiftool, "-j", "-XMP-xmp:Rating", "-XMP-xmp:Label", "-XMP-dc:Subject", "-@", argfile],
                              capture_output=True, text=True)
    finally:
        os.unlink(argfile)
    try:
        data = json.loads(proc.stdout or "[]")
    except json.JSONDecodeError:
        return {}
    return {d["SourceFile"]: d for d in data}


def metadata_matches(photo: Photo, read: dict) -> bool:
    """Compara rating, etiqueta de color y keywords releídos con lo que dice el catálogo."""
    if photo.rating is not None and str(read.get("Rating", "")) != str(int(photo.rating)):
        return False
    if photo.color_index is not None:
        expected = COLOR_NAMES.get(int(photo.color_index)) or ""
        if (read.get("Label") or "") != expected:
            return False
    subject = read.get("Subject", [])
    subject = [subject] if isinstance(subject, str) else list(subject)
    return subject == photo.keywords


# MARK: - Interfaz interactiva

def pick_catalog() -> Path | None:
    try:
        import tkinter as tk
        from tkinter import filedialog
    except ImportError:
        return None
    root = tk.Tk()
    root.withdraw()
    chosen = filedialog.askopenfilename(
        title="Selecciona el catálogo (.cocatalog / .cocatalogdb) o sesión (.cosessiondb)",
        filetypes=[("Capture One", "*.cocatalog *.cocatalogdb *.cosessiondb"), ("Todos", "*")])
    if not chosen:
        chosen = filedialog.askdirectory(title="O selecciona la carpeta del catálogo / sesión")
    root.destroy()
    return Path(chosen) if chosen else None


def pick_directory(title: str) -> Path | None:
    try:
        import tkinter as tk
        from tkinter import filedialog
    except ImportError:
        return None
    root = tk.Tk()
    root.withdraw()
    chosen = filedialog.askdirectory(title=title)
    root.destroy()
    return Path(chosen) if chosen else None


def print_albums(albums: list[Album], include_auto: bool):
    print("\nÁlbumes del catálogo:")
    for a in albums:
        if a.is_auto and not include_auto:
            continue
        flag = " [smart, no exportable]" if a.is_smart else (" [automático]" if a.is_auto else "")
        print(f"  {a.path}{flag}")
    print()


# MARK: - Programa principal

def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Exporta álbumes de Capture One con sus metadatos en XMP.")
    ap.add_argument("patterns", nargs="*", help="Patrones de álbum con * y ? (p. ej. 'Andorra 20??'). 'Grupo/Álbum' compara la ruta completa.")
    ap.add_argument("--catalog", "-c", help="Ruta al .cocatalog, .cocatalogdb o .cosessiondb")
    ap.add_argument("--dest", "-d", help="Carpeta de destino")
    ap.add_argument("--list", "-l", action="store_true", help="Solo listar los álbumes y salir")
    ap.add_argument("--dry-run", "-n", action="store_true", help="Mostrar qué se haría sin copiar nada")
    ap.add_argument("--move", action="store_true", help="Mover en vez de copiar (pide confirmación)")
    ap.add_argument("--yes", "-y", action="store_true", help="No pedir confirmación")
    ap.add_argument("--include-trashed", action="store_true", help="Incluir fotos que están en la papelera del catálogo")
    ap.add_argument("--include-auto-albums", action="store_true", help="Incluir los álbumes automáticos de Recent Imports/Captures")
    ap.add_argument("--no-metadata", action="store_true", help="No escribir XMP en los ficheros")
    ap.add_argument("--adjustments-json", action="store_true", help="Guardar además un JSON con los ajustes de revelado de cada foto")
    ap.add_argument("--refresh", action="store_true", help="Reescribir metadatos en fotos ya exportadas en ejecuciones anteriores")
    ap.add_argument("--exiftool", default=shutil.which("exiftool") or "exiftool", help="Ruta a exiftool")
    args = ap.parse_args(argv)

    # Catálogo
    catalog_path = Path(args.catalog) if args.catalog else pick_catalog()
    if not catalog_path:
        print("No se seleccionó catálogo.", file=sys.stderr)
        return 2
    if subprocess.run(["pgrep", "-x", "Capture One"], capture_output=True).returncode == 0:
        print("Aviso: Capture One está abierto; la lectura será de una instantánea del catálogo.")
    catalog = Catalog(catalog_path)
    print(f"Catálogo: {catalog.db_path}\nRaíz de originales relativos: {catalog.root}")
    albums = catalog.albums()

    if args.list or not args.patterns:
        print_albums(albums, args.include_auto_albums)
        if args.list:
            catalog.close()
            return 0

    patterns = args.patterns or [p.strip() for p in input("Patrones de álbum (separados por ;): ").split(";") if p.strip()]
    if not patterns:
        print("Sin patrones.", file=sys.stderr)
        catalog.close()
        return 2

    dest_root = Path(args.dest).expanduser() if args.dest else pick_directory("Carpeta de destino")
    if not dest_root:
        print("No se seleccionó destino.", file=sys.stderr)
        catalog.close()
        return 2
    dest_root = dest_root.resolve()
    if catalog.root in dest_root.parents or dest_root == catalog.root:
        print("El destino no puede estar dentro del catálogo.", file=sys.stderr)
        catalog.close()
        return 2
    if not args.no_metadata and not shutil.which(args.exiftool):
        print(f"No se encuentra exiftool ({args.exiftool}); instálalo con 'brew install exiftool' o usa --no-metadata.", file=sys.stderr)
        catalog.close()
        return 2

    # Plan
    jobs: list[Job] = []
    for pattern in patterns:
        hits = match_albums(albums, pattern, args.include_auto_albums)
        if not hits:
            print(f"Patrón '{pattern}': ningún álbum coincide.")
            continue
        print(f"Patrón '{pattern}': {len(hits)} álbum(es) -> {', '.join(a.path for a in hits)}")
        for album in hits:
            for photo in catalog.photos_in_album(album):
                jobs.append(Job(pattern=pattern, album=album, photo=photo))

    skipped_trash = 0
    missing = 0
    planned = []
    for j in jobs:
        if j.photo.trashed and not args.include_trashed:
            j.status = "omitido (papelera)"
            skipped_trash += 1
        elif j.photo.source is None or not j.photo.source.exists():
            j.status = "omitido (fichero no encontrado)"
            missing += 1
        else:
            planned.append(j)

    total_bytes = sum(j.photo.source.stat().st_size for j in planned)
    inside = sum(1 for j in planned if j.photo.inside_catalog)
    print(f"\nFotos a {'mover' if args.move else 'copiar'}: {len(planned)}  ({total_bytes / 1e9:.2f} GB)")
    print(f"  dentro del bundle del catálogo: {inside}   referenciadas fuera: {len(planned) - inside}")
    print(f"  omitidas: papelera {skipped_trash}, no encontradas {missing}")
    print(f"Destino: {dest_root}")
    if args.move and inside:
        print("\n¡ATENCIÓN! Mover fotos que viven dentro del bundle las dejará OFFLINE en Capture One.")

    if args.dry_run:
        for j in planned:
            color = COLOR_NAMES.get(j.photo.color_index or 0, "-")
            print(f"  [{sanitize(j.pattern, True)}/{sanitize(j.album.name)}] {j.photo.filename}  "
                  f"rating={j.photo.rating} color={color} kw={','.join(j.photo.keywords)}  <- {j.photo.source}")
        catalog.close()
        return 0

    if not planned:
        catalog.close()
        return 0

    if not args.yes:
        if args.move:
            if input("Escribe MOVER para confirmar que quieres mover los originales: ").strip() != "MOVER":
                print("Cancelado.")
                catalog.close()
                return 1
        elif input("¿Continuar? [s/N] ").strip().lower() not in ("s", "si", "sí", "y", "yes"):
            print("Cancelado.")
            catalog.close()
            return 1

    # Copia / movimiento
    used_names: dict[Path, set[str]] = {}
    manifests: dict[Path, dict] = {}
    for idx, j in enumerate(planned, 1):
        folder = dest_root / sanitize(j.pattern, True) / sanitize(j.album.name)
        folder.mkdir(parents=True, exist_ok=True)
        manifest = manifests.setdefault(folder, load_manifest(folder))
        used = used_names.setdefault(folder, set())
        previous = manifest.get(j.photo.image_uuid)
        if previous and (folder / previous).exists():
            j.dest = folder / previous
            j.status = "copiado" if args.refresh else "ya exportado"
            used.add(previous.casefold())
            print(f"[{idx}/{len(planned)}] = {j.dest.relative_to(dest_root)} ({j.status})")
            continue
        j.dest = unique_dest(folder, j.photo.filename, used)
        # Copia a nombre temporal y renombrado final: un corte (NAS, red) nunca deja un
        # fichero truncado con el nombre definitivo. El manifiesto se guarda tras cada foto.
        partial = j.dest.with_name(".co_export-partial-" + j.dest.name)
        try:
            if args.move:
                shutil.move(str(j.photo.source), str(partial))
            else:
                shutil.copy2(j.photo.source, partial)
            if not args.move and partial.stat().st_size != j.photo.source.stat().st_size:
                raise OSError("tamaño distinto tras copiar")
            partial.rename(j.dest)
            j.status = "copiado"
            manifest[j.photo.image_uuid] = j.dest.name
            save_manifest(folder, manifest)
            print(f"[{idx}/{len(planned)}] + {j.dest.relative_to(dest_root)}")
        except OSError as e:
            if args.move and partial.exists() and not j.photo.source.exists():
                shutil.move(str(partial), str(j.photo.source))
            else:
                partial.unlink(missing_ok=True)
            j.status = f"error copia: {e}"
            print(f"[{idx}/{len(planned)}] ! {j.photo.filename}: {e}", file=sys.stderr)
            if not dest_root.exists():
                print("El destino ha dejado de ser accesible; se detiene. Vuelve a ejecutar para continuar.", file=sys.stderr)
                break
        if args.adjustments_json and j.photo.variant_pk and j.status == "copiado":
            j.dest.with_name(j.dest.name + ".co-adjustments.json").write_text(
                json.dumps(catalog.adjustments(j.photo.variant_pk), ensure_ascii=False, indent=1, default=str))
    for folder, manifest in manifests.items():
        save_manifest(folder, manifest)

    # Metadatos
    if not args.no_metadata:
        print("\nEscribiendo metadatos XMP con exiftool...")
        results = write_metadata(planned, args.exiftool)
        for j in planned:
            if j.status == "copiado":
                r = results.get(str(j.dest))
                if r is None:
                    j.status = "ok (sin XMP: tipo no soportado)" if j.dest.suffix.lower() in NO_METADATA_EXT else "copiado (sin resultado exiftool)"
                elif r == "ok":
                    j.status = "ok"
                else:
                    j.status = r
        checks = verify_metadata(planned, args.exiftool)
        bad = 0
        for j in planned:
            if j.status != "ok":
                continue
            c = checks.get(str(j.dest))
            if c is None or not metadata_matches(j.photo, c):
                j.status = "escrito pero verificación fallida"
                bad += 1
        print(f"Verificación de relectura: {sum(1 for j in planned if j.status == 'ok')} correctas, {bad} fallidas")
    else:
        for j in planned:
            if j.status == "copiado":
                j.status = "ok (sin metadatos)"

    # Informe
    stamp = dt.datetime.now().strftime("%Y%m%d_%H%M%S")
    report = dest_root / f"co_export_{stamp}.csv"
    with open(report, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["patron", "album", "fichero_origen", "fichero_destino", "rating", "color", "keywords", "estado"])
        for j in jobs:
            w.writerow([j.pattern, j.album.path, str(j.photo.source or ""), str(j.dest or ""),
                        j.photo.rating, COLOR_NAMES.get(j.photo.color_index or 0, ""), "; ".join(j.photo.keywords), j.status])
    ok = sum(1 for j in jobs if j.status.startswith("ok"))
    print(f"\nHecho: {ok} correctas de {len(jobs)}. Informe: {report}")
    catalog.close()
    return 0 if ok == len(planned) else 1


if __name__ == "__main__":
    sys.exit(main())

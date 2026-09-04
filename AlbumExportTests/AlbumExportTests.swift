import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AlbumExport

// MARK: - Catálogo de prueba

/// Construye un catálogo sintético con el esquema mínimo que usa la app, con ficheros reales.
struct FixtureCatalog {
    let root: URL
    let bundle: URL
    let externalFolder: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AlbumExportTests-\(UUID().uuidString)", isDirectory: true)
        bundle = root.appendingPathComponent("Fixture.cocatalog", isDirectory: true)
        externalFolder = root.appendingPathComponent("External", isDirectory: true)
        let originals = bundle.appendingPathComponent("Originals/2026/01/01/1", isDirectory: true)
        let originals2 = bundle.appendingPathComponent("Originals/2026/01/02/2", isDirectory: true)
        for folder in [originals, originals2, externalFolder] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Self.writeJPEG(to: originals.appendingPathComponent("IMG_0001.jpg"))
        try Self.writeJPEG(to: originals.appendingPathComponent("IMG_0002.jpg"))
        try Self.writeJPEG(to: originals2.appendingPathComponent("IMG_0001.jpg"))   // mismo nombre, otra carpeta
        try Self.writeJPEG(to: originals2.appendingPathComponent("LONE.jpg"))
        try Self.writeJPEG(to: originals2.appendingPathComponent("img_0002.JPG"))
        try Self.writeJPEG(to: externalFolder.appendingPathComponent("EXT_0001.jpg"))

        let db = try SQLiteDatabase(path: bundle.appendingPathComponent("Fixture.cocatalogdb").path, create: true)
        try db.execute("""
            CREATE TABLE ZENTITIES (Z_ENT INTEGER, ZNAME VARCHAR);
            INSERT INTO ZENTITIES VALUES (1,'Collection'),(2,'AlbumCollection'),(5,'SmartCollection'),(7,'ProjectCollection'),(8,'VirtualFolderCollection');
            CREATE TABLE ZCOLLECTION (Z_ENT INTEGER, Z_PK INTEGER PRIMARY KEY, ZNAME VARCHAR, ZPARENT INTEGER);
            INSERT INTO ZCOLLECTION VALUES (7,1,'root',NULL),(8,2,'Recent Imports',1),(2,3,'March 7, 2026 at 11:48 AM',2),
                (8,4,'Viajes',1),(2,5,'Andorra 2025',4),(2,6,'Andorra 2024',1),(5,7,'Five Stars',1);
            CREATE TABLE ZPATHLOCATION (Z_PK INTEGER PRIMARY KEY, ZISRELATIVE BOOLEAN, ZMACROOT VARCHAR, ZRELATIVEPATH VARCHAR);
            INSERT INTO ZPATHLOCATION VALUES (1,1,NULL,'Originals/2026/01/01/1'),(2,1,NULL,'Originals/2026/01/02/2'),
                (3,0,'/','\(externalFolder.path.dropFirst())');
            CREATE TABLE ZIMAGE (Z_PK INTEGER PRIMARY KEY, ZIMAGEUUID VARCHAR, ZIMAGEFILENAME VARCHAR, ZISTRASHED BOOLEAN, ZISINSIDECATALOG BOOLEAN, ZIMAGELOCATION INTEGER);
            INSERT INTO ZIMAGE VALUES (10,'U10','IMG_0001.jpg',0,1,1),(11,'U11','IMG_0002.jpg',0,1,1),(12,'U12','IMG_0001.jpg',0,1,2),
                (13,'U13','EXT_0001.jpg',0,0,3),(14,'U14','MISSING.jpg',0,1,1),(15,'U15','IMG_0002.jpg',1,1,1),
                (16,'U16','LONE.jpg',0,1,2),(17,'U17','img_0002.JPG',0,1,2);   -- sin álbum: uno propio y un duplicado por nombre
            CREATE TABLE ZIMAGEINCOLLECTION (Z_PK INTEGER PRIMARY KEY, ZCOLLECTION INTEGER, ZIMAGE INTEGER);
            INSERT INTO ZIMAGEINCOLLECTION (ZCOLLECTION, ZIMAGE) VALUES (5,10),(5,11),(5,12),(5,14),(5,15),(6,13),(3,10);
            CREATE TABLE ZVARIANTMETADATA (Z_PK INTEGER PRIMARY KEY, ZBASIC_RATING INTEGER, ZCOLOR_TAG_INDEX INTEGER, ZCONTENT_KEYWORDS VARCHAR,
                ZCONTENT_DESCRIPTION VARCHAR, ZIMAGE_CITY VARCHAR, ZSTATUS_TITLE VARCHAR, ZBASIC_LABEL VARCHAR);
            INSERT INTO ZVARIANTMETADATA VALUES (100,5,4,'David||0,Judit||1','Línea 1\nLínea 2 & más','Andorra la Vella','Título',NULL),
                (101,0,0,'',NULL,NULL,NULL,NULL),(102,NULL,NULL,NULL,NULL,NULL,NULL,NULL),(103,3,1,'David||0',NULL,NULL,NULL,NULL),
                (104,2,0,NULL,NULL,NULL,NULL,NULL),(105,4,5,'Judit||0',NULL,NULL,NULL,NULL);
            CREATE TABLE ZVARIANTLAYER (Z_PK INTEGER PRIMARY KEY, ZMETADATA INTEGER, ZVARIANT INTEGER, ZEXPOSURE FLOAT);
            INSERT INTO ZVARIANTLAYER VALUES (200,100,20,0.5),(201,101,21,NULL),(202,102,22,NULL),(203,103,22,NULL),(204,104,23,NULL),(205,105,24,NULL);
            CREATE TABLE ZVARIANT (Z_PK INTEGER PRIMARY KEY, ZIMAGE INTEGER, ZINDEX INTEGER, ZCOMBINEDSETTINGS INTEGER, ZADJUSTMENTLAYER INTEGER, ZDEFAULTLAYER INTEGER);
            INSERT INTO ZVARIANT VALUES (20,10,127,200,200,200),(21,11,127,201,201,201),
                (22,12,127,NULL,203,202),   -- sin capa combinada: fusión de ajuste sobre defecto
                (23,13,127,204,204,204),(24,14,127,205,205,205),(25,15,127,201,201,201),(26,16,127,201,201,201),(27,17,127,201,201,201);
            CREATE TABLE ZVARIANTINCOLLECTION (Z_PK INTEGER PRIMARY KEY, ZCOLLECTION INTEGER, ZVARIANT INTEGER);
            INSERT INTO ZVARIANTINCOLLECTION (ZCOLLECTION, ZVARIANT) VALUES (5,20),(5,21),(5,22),(6,23);
            CREATE TABLE ZKEYWORD (Z_PK INTEGER PRIMARY KEY, ZNAME VARCHAR, ZPARENT INTEGER);
            INSERT INTO ZKEYWORD VALUES (1,'Familia',NULL),(2,'David',1),(3,'Judit',NULL);
            CREATE TABLE ZVERSIONINFO (Z_PK INTEGER PRIMARY KEY, ZAUTHOR VARCHAR, ZVERSION INTEGER);
            INSERT INTO ZVERSIONINFO VALUES (1,'16.8.5.30 Pro Mac',160800);
            """)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    static func writeJPEG(to url: URL) throws {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.setFillColor(CGColor(colorSpace: space, components: [0.2, 0.5, 0.8, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}

// MARK: - Unidades puras

@Test func patternsParseAndMatch() {
    #expect(PatternMatcher.parse(" Andorra 20?? ; Isla*\n Toscana ") == ["Andorra 20??", "Isla*", "Toscana"])
    #expect(PatternMatcher.matches("andorra 20??", "Andorra 2025"))
    #expect(!PatternMatcher.matches("Andorra 20??", "Andorra 202"))
    #expect(PatternMatcher.matches("*feroes*", "Islas Feroes 2025"))
}

@Test func keywordParsing() {
    #expect(CatalogReader.parseKeywords("David||0,Judit||1,David||2") == ["David", "Judit"])
    #expect(CatalogReader.parseKeywords(nil).isEmpty)
    #expect(CatalogReader.parseKeywords("").isEmpty)
}

@Test func folderNameSanitizing() {
    #expect(ExportPlanner.sanitize("Andorra 20??", stripWildcards: true) == "Andorra 20")
    #expect(ExportPlanner.sanitize("Diapositivas/Zoo*: 1984", stripWildcards: true) == "Diapositivas Zoo 1984")
    #expect(ExportPlanner.sanitize("***", stripWildcards: true) == "album")
}

@Test func uniqueNamesGetSuffixes() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("names-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try Data().write(to: folder.appendingPathComponent("A.ARW"))
    var allocator = NameAllocator(folder: folder)
    #expect(allocator.unique("A.ARW").lastPathComponent == "A_1.ARW")
    #expect(allocator.unique("a.arw").lastPathComponent == "a_2.arw")
    #expect(allocator.unique("B.ARW").lastPathComponent == "B.ARW")
}

@Test func exiftoolArgumentsReplaceListsAndEscape() {
    var photo = Photo(id: 1, uuid: "u", filename: "x.jpg", source: nil, isTrashed: false, isInsideCatalog: true)
    photo.rating = 5
    photo.colorTag = .green
    photo.keywords = ["David", "Judit"]
    photo.hierarchicalKeywords = ["Familia|David", "Judit"]
    photo.fields = ["ZCONTENT_DESCRIPTION": "Línea 1\nLínea 2 & más"]
    let args = ExifToolWriter.arguments(for: photo)
    #expect(args.contains("-XMP-xmp:Rating=5"))
    #expect(args.contains("-XMP-xmp:Label=Green"))
    #expect(args.contains("-MWG:Keywords=David"))
    #expect(args.contains("-MWG:Keywords=Judit"))
    #expect(!args.contains(where: { $0.hasPrefix("-MWG:Keywords+=") }))
    #expect(args.contains("-XMP-lr:HierarchicalSubject=Familia|David"))
    #expect(args.contains("-MWG:Description=Línea 1&#10;Línea 2 &amp; más"))

    photo.keywords = []
    photo.hierarchicalKeywords = []
    photo.colorTag = ColorTag.none
    let cleared = ExifToolWriter.arguments(for: photo)
    #expect(cleared.contains("-MWG:Keywords="))
    #expect(cleared.contains("-XMP-xmp:Label="))
}

/// La relectura interpreta el JSON de exiftool aunque venga precedido de texto, y tolera
/// valores en formatos distintos (número, cadena, lista de un elemento).
@Test func readBackParsing() {
    let json = """
    [{"SourceFile":"/a/x.ARW","Rating":5,"Label":"Green","Subject":["David","Judit"]},
     {"SourceFile":"/a/y.DNG"},
     {"SourceFile":"/a/z.tif","Rating":"3","Subject":"Solo"}]
    """
    let parsed = ExifToolWriter.parseReadBack(json)
    #expect(parsed["/a/x.ARW"]?.rating == 5)
    #expect(parsed["/a/x.ARW"]?.label == "Green")
    #expect(parsed["/a/x.ARW"]?.subject == ["David", "Judit"])
    #expect(parsed["/a/y.DNG"]?.rating == nil)
    #expect(parsed["/a/y.DNG"]?.subject == [])
    #expect(parsed["/a/z.tif"]?.rating == 3)
    #expect(parsed["/a/z.tif"]?.subject == ["Solo"])
    #expect(ExifToolWriter.parseReadBack("Warning: something\n" + json).count == 3)
    #expect(ExifToolWriter.parseReadBack("").isEmpty)

    // Sin rating ni color en el catálogo (DNG del dron), la verificación solo compara keywords.
    let photo = Photo(id: 1, uuid: "u", filename: "y.DNG", source: nil, isTrashed: false, isInsideCatalog: true)
    #expect(ExifToolWriter.matches(photo, parsed["/a/y.DNG"]!))
}

// MARK: - Lectura del catálogo

@Test func readsAlbumsPathsAndMetadata() throws {
    let fixture = try FixtureCatalog()
    defer { fixture.cleanup() }
    let reader = try CatalogReader(url: fixture.bundle)
    #expect(reader.version?.format == 160800)
    #expect(reader.warnings.isEmpty)

    let albums = try reader.albums()
    #expect(albums.map(\.path) == ["Andorra 2024", "Five Stars", "Recent Imports/March 7, 2026 at 11:48 AM", "Viajes/Andorra 2025"])
    #expect(albums.first { $0.name == "March 7, 2026 at 11:48 AM" }?.isAuto == true)
    #expect(albums.first { $0.name == "Five Stars" }?.isSmart == true)
    #expect(PatternMatcher.albums(matching: "Andorra 20??", in: albums, includeAuto: false).count == 2)
    #expect(PatternMatcher.albums(matching: "Viajes/*", in: albums, includeAuto: false).map(\.name) == ["Andorra 2025"])
    #expect(PatternMatcher.albums(matching: "*", in: albums, includeAuto: false).count == 2)
    #expect(PatternMatcher.albums(matching: "*", in: albums, includeAuto: true).count == 3)

    let andorra2025 = try #require(albums.first { $0.name == "Andorra 2025" })
    let photos = try reader.photos(in: andorra2025)
    #expect(photos.count == 5)
    let first = try #require(photos.first { $0.uuid == "U10" })
    #expect(first.source?.path == fixture.bundle.appendingPathComponent("Originals/2026/01/01/1/IMG_0001.jpg").path)
    #expect(first.rating == 5)
    #expect(first.colorTag == .green)
    #expect(first.keywords == ["David", "Judit"])
    #expect(first.hierarchicalKeywords == ["Familia|David", "Judit"])
    #expect(first.fields["ZIMAGE_CITY"] == "Andorra la Vella")
    #expect(first.fields["ZCONTENT_DESCRIPTION"] == "Línea 1\nLínea 2 & más")

    // Sin capa combinada: el ajuste (rating 3, rojo, David) pisa al defecto (vacío).
    let merged = try #require(photos.first { $0.uuid == "U12" })
    #expect(merged.rating == 3)
    #expect(merged.colorTag == .red)
    #expect(merged.keywords == ["David"])
    let trashed = try #require(photos.first { $0.uuid == "U15" })
    #expect(trashed.isTrashed)

    let andorra2024 = try #require(albums.first { $0.name == "Andorra 2024" })
    let external = try #require(try reader.photos(in: andorra2024).first)
    #expect(external.source?.path == fixture.externalFolder.appendingPathComponent("EXT_0001.jpg").path)
    #expect(!external.isInsideCatalog)
}

/// Lee el catálogo real del usuario si existe (solo lectura, vía copia temporal); si no, se omite.
@Test func readsRealCatalogWhenAvailable() throws {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/SonyA1.cocatalog")
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    let reader = try CatalogReader(url: url)
    #expect(reader.version?.format ?? 0 >= 160800)
    let albums = try reader.albums()
    #expect(albums.count > 50)
    let matched = PatternMatcher.albums(matching: "Barcelona 202?", in: albums, includeAuto: false)
    #expect(matched.map(\.name).sorted() == ["Barcelona 2024", "Barcelona 2025", "Barcelona 2026"])
    let album = try #require(albums.first { $0.name == "Barcelona 2026" })
    let photos = try reader.photos(in: album)
    #expect(photos.count == 8)
    #expect(photos.allSatisfy { $0.source.map { FileManager.default.fileExists(atPath: $0.path) } == true })
    #expect(photos.allSatisfy { $0.fields["ZCONTACT_CREATOR"] == "© Cornellana" })
}

/// Verificación: un fichero en Originals sin registro es huérfano; un registro sin fichero, ausente.
/// Mover los huérfanos conserva la estructura de carpetas y los saca del bundle.
@Test func verifiesOrphansAndMissingFiles() throws {
    let fixture = try FixtureCatalog()
    defer { fixture.cleanup() }
    let orphan = fixture.bundle.appendingPathComponent("Originals/2026/01/01/1/ORPHAN.jpg")
    try FixtureCatalog.writeJPEG(to: orphan)
    try Data().write(to: fixture.bundle.appendingPathComponent("Originals/2026/01/01/1/.DS_Store"))   // oculto: se ignora
    try Data("<xmp/>".utf8).write(to: fixture.bundle.appendingPathComponent("Originals/2026/01/01/1/IMG_0001.xmp"))   // lateral: no es huérfano
    let reader = try CatalogReader(url: fixture.bundle)

    let result = try CatalogVerifier.scan(catalog: reader)
    #expect(result.filesOnDisk == 7)          // 5 registrados + el huérfano + el lateral
    #expect(result.referenced == 6)           // rutas distintas: la foto en papelera comparte fichero con otra
    #expect(result.orphans.map(\.relativePath) == ["Originals/2026/01/01/1/ORPHAN.jpg"])
    #expect(result.missing.map(\.filename) == ["MISSING.jpg"])

    let target = fixture.root.appendingPathComponent("Huerfanos")
    let errors = CatalogVerifier.moveOrphans(result.orphans, to: target)
    #expect(errors.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: orphan.path))
    #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("Originals/2026/01/01/1/ORPHAN.jpg").path))
    #expect(try CatalogVerifier.scan(catalog: reader).orphans.isEmpty)
}

/// Búsqueda de perdidos por nombre y tamaño en una carpeta, y restauración a la ruta esperada.
@Test func findsAndRestoresMissingFiles() throws {
    let fixture = try FixtureCatalog()
    defer { fixture.cleanup() }
    let reader = try CatalogReader(url: fixture.bundle)
    let missing = try reader.missingFiles()
    #expect(missing.map(\.filename) == ["MISSING.jpg"])
    #expect(missing[0].alsoIndexedAt == nil)

    // Un candidato con el nombre correcto fuera del catálogo.
    let elsewhere = fixture.root.appendingPathComponent("Backup/2026/MISSING.jpg")
    try FileManager.default.createDirectory(at: elsewhere.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FixtureCatalog.writeJPEG(to: elsewhere)
    let found = CatalogVerifier.search(missing, in: fixture.root.appendingPathComponent("Backup"), catalogRoot: fixture.bundle)
    #expect(found.first?.candidate?.resolvingSymlinksInPath().path == elsewhere.resolvingSymlinksInPath().path)

    let errors = CatalogVerifier.restore(found)
    #expect(errors.isEmpty)
    #expect(FileManager.default.fileExists(atPath: fixture.bundle.appendingPathComponent("Originals/2026/01/01/1/MISSING.jpg").path))
    #expect(try reader.missingFiles().isEmpty)
    #expect(FileManager.default.fileExists(atPath: elsewhere.path))   // se copia, no se mueve
}

/// Un perdido cuyo fichero está como huérfano en otra carpeta de Originals se resuelve sin salir del bundle.
@Test func matchesMissingFilesWithOrphans() throws {
    let fixture = try FixtureCatalog()
    defer { fixture.cleanup() }
    let stray = fixture.bundle.appendingPathComponent("Originals/2026/01/02/2/MISSING.jpg")
    try FixtureCatalog.writeJPEG(to: stray)
    let reader = try CatalogReader(url: fixture.bundle)
    let result = try CatalogVerifier.scan(catalog: reader)
    #expect(result.orphans.map(\.relativePath) == ["Originals/2026/01/02/2/MISSING.jpg"])
    let missing = try #require(result.missing.first)
    #expect(missing.candidateIsOrphan)
    #expect(missing.candidate?.resolvingSymlinksInPath().path == stray.resolvingSymlinksInPath().path)
    #expect(CatalogVerifier.restore(result.missing).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: stray.path))                                  // movido, no copiado
    #expect(FileManager.default.fileExists(atPath: fixture.bundle.appendingPathComponent("Originals/2026/01/01/1/MISSING.jpg").path))
    let again = try CatalogVerifier.scan(catalog: reader)
    #expect(again.orphans.isEmpty && again.missing.isEmpty)
}

@Test func listsImagesNotInAnyAlbum() throws {
    let fixture = try FixtureCatalog()
    defer { fixture.cleanup() }
    let reader = try CatalogReader(url: fixture.bundle)
    let unfiled = try reader.imagesNotInAnyAlbum()
    #expect(unfiled.map(\.filename) == ["LONE.jpg", "img_0002.JPG"])
    #expect(unfiled[0].duplicateInAlbum == nil)
    #expect(unfiled[1].duplicateInAlbum == "Andorra 2025")          // mismo nombre que IMG_0002.jpg, ya clasificada
    let result = try CatalogVerifier.scan(catalog: reader)
    #expect(result.unfiledToFile.map(\.imageID) == [16])
    #expect(result.unfiledDuplicates == 1)
    #expect(try reader.variantIDs(forImages: [16, 17]) == [26, 27])
}

// MARK: - Traslado entre catálogos (partes sin Capture One)

@Test func transferHelpers() {
    #expect(CatalogTransferEngine.isPackable("_AM21178.ARW"))
    #expect(CatalogTransferEngine.isPackable("DJI_0001.DNG"))
    #expect(!CatalogTransferEngine.isPackable("scan.tif"))
    #expect(!CatalogTransferEngine.isPackable("clip.mp4"))
    #expect(CatalogTransferEngine.exportedName(for: "_AM21178.ARW") == "_AM21178.eip")
    #expect(CatalogTransferEngine.exportedName(for: "Festival Astronomia.tif") == "Festival Astronomia.tif")
    #expect(CaptureOneDriver.documentName(for: URL(fileURLWithPath: "/Users/x/Pictures/SonyA1.cocatalog")) == "SonyA1")
    #expect(CaptureOneDriver.collectionReference(path: ["Diapositivas", "Zoo 1984"]) == "collection \"Zoo 1984\" of collection \"Diapositivas\"")
    #expect(AppleScriptRunner.quote("Año \"84\" \\ fin") == "\"Año \\\"84\\\" \\\\ fin\"")
    #expect(AppleScriptRunner.list([1, 2, 3]) == "{1, 2, 3}")

    var photo = Photo(id: 1, uuid: "u", filename: "x.ARW", source: nil, isTrashed: false, isInsideCatalog: true)
    photo.rating = 5
    photo.colorTag = .green
    photo.keywords = ["David", "Judit"]
    let ok = CaptureOneDriver.VariantReadBack(id: 9, name: "x", rating: 5, colorTag: 4, keywords: ["judit", "David"], layerCount: 2)
    #expect(CatalogTransferEngine.matches(photo, ok))
    let bad = CaptureOneDriver.VariantReadBack(id: 9, name: "x", rating: 4, colorTag: 4, keywords: ["David", "Judit"], layerCount: 2)
    #expect(!CatalogTransferEngine.matches(photo, bad))
}

// MARK: - Exportación

@Test func plansCopiesAndKeepsManifest() throws {
    let fixture = try FixtureCatalog()
    defer { fixture.cleanup() }
    let reader = try CatalogReader(url: fixture.bundle)
    let albums = try reader.albums()
    let destination = fixture.root.appendingPathComponent("Export")
    let options = ExportOptions(writeMetadata: false)

    let plan = try ExportPlanner.plan(patterns: ["Andorra 20??"], selectedAlbumIDs: [], albums: albums, catalog: reader, options: options)
    #expect(plan.matchedAlbums.count == 2)
    #expect(plan.jobs.count == 6)
    #expect(plan.plannedCount == 4)
    #expect(plan.skippedTrashed == 1)
    #expect(plan.missingSources == 1)
    #expect(plan.insideCatalogCount == 3)

    let engine = ExportEngine(catalog: reader, destination: destination, options: options, writer: nil, cancellation: CancellationToken())
    let result = try engine.run(plan: plan) { _ in }
    #expect(result.summary.successCount == 4)
    let folder = destination.appendingPathComponent("Andorra 20/Andorra 2025")
    let names = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
    #expect(names.isSuperset(of: ["IMG_0001.jpg", "IMG_0001_1.jpg", "IMG_0002.jpg", Manifest.filename]))
    #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Andorra 20/Andorra 2024/EXT_0001.jpg").path))
    #expect(result.summary.reportURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)
    // Los originales siguen en su sitio (copia, no movimiento).
    #expect(FileManager.default.fileExists(atPath: fixture.bundle.appendingPathComponent("Originals/2026/01/01/1/IMG_0001.jpg").path))

    // Segunda ejecución: nada se duplica.
    let again = try engine.run(plan: plan) { _ in }
    #expect(again.jobs.filter { $0.status == .alreadyExported }.count == 4)
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == names.count)

    // Al planificar con el destino conocido, lo completo ya se marca y sale del recuento.
    let replanned = try ExportPlanner.plan(patterns: ["Andorra 20??"], selectedAlbumIDs: [], albums: albums, catalog: reader, options: options, destination: destination)
    #expect(replanned.alreadyExportedCount == 4)
    #expect(replanned.plannedCount == 0)
    #expect(replanned.totalBytes == 0)
    #expect(replanned.jobs.filter { $0.status == .alreadyExported }.count == 4)
    // Con "refrescar" vuelven a estar pendientes.
    let refresh = try ExportPlanner.plan(patterns: ["Andorra 20??"], selectedAlbumIDs: [], albums: albums, catalog: reader,
                                         options: ExportOptions(writeMetadata: false, refreshExisting: true), destination: destination)
    #expect(refresh.plannedCount == 4)
}

/// Simula un corte: fichero truncado, manifiesto con metadatos pendientes, resto parcial y cancelación.
@Test func resumesAfterInterruption() throws {
    let fixture = try FixtureCatalog()
    defer { fixture.cleanup() }
    let reader = try CatalogReader(url: fixture.bundle)
    let albums = try reader.albums()
    let destination = fixture.root.appendingPathComponent("Export")
    let options = ExportOptions(writeMetadata: false)
    let plan = try ExportPlanner.plan(patterns: ["Viajes/Andorra 2025"], selectedAlbumIDs: [], albums: albums, catalog: reader, options: options)
    let folder = destination.appendingPathComponent("Viajes Andorra 2025/Andorra 2025")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    // Estado dejado por una ejecución cortada: IMG_0002 truncado, IMG_0001 sin metadatos, un parcial huérfano.
    try Data([1, 2, 3]).write(to: folder.appendingPathComponent("IMG_0002.jpg"))
    try FixtureCatalog.writeJPEG(to: folder.appendingPathComponent("IMG_0001.jpg"))
    try Data([9]).write(to: folder.appendingPathComponent(Manifest.partialPrefix + "IMG_0001_1.jpg"))
    var manifest = Manifest(folder: folder)
    manifest.record(uuid: "U11", filename: "IMG_0002.jpg", metadataDone: false)
    manifest.record(uuid: "U10", filename: "IMG_0001.jpg", metadataDone: false)
    try manifest.save()

    // Cancelación inmediata: nada cambia salvo la limpieza del parcial.
    let cancelled = CancellationToken()
    cancelled.cancel()
    let stopped = try ExportEngine(catalog: reader, destination: destination, options: options, writer: nil, cancellation: cancelled).run(plan: plan) { _ in }
    #expect(stopped.summary.interruption == .cancelled)
    #expect(stopped.jobs.allSatisfy { $0.status == .pending || $0.status == .skippedTrashed || $0.status == .missingSource })

    let result = try ExportEngine(catalog: reader, destination: destination, options: options, writer: nil, cancellation: CancellationToken()).run(plan: plan) { _ in }
    #expect(result.summary.interruption == nil)
    #expect(result.summary.successCount == 3)
    let names = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
    #expect(names == ["IMG_0001.jpg", "IMG_0001_1.jpg", "IMG_0002.jpg", Manifest.filename])
    // El truncado se volvió a copiar entero; el que tenía metadatos pendientes se reutilizó.
    let source2 = fixture.bundle.appendingPathComponent("Originals/2026/01/01/1/IMG_0002.jpg")
    #expect(ExportPlanner.fileSize(folder.appendingPathComponent("IMG_0002.jpg")) == ExportPlanner.fileSize(source2))
    let allMetadataDone = Manifest(folder: folder).entries.values.allSatisfy { $0.metadataDone }
    #expect(allMetadataDone)
    #expect(result.jobs.first { $0.photo.uuid == "U10" }?.status == .doneWithoutMetadata)
}

/// `fileSize` debe reflejar el tamaño actual aunque el fichero se haya reescrito (URL cachea atributos).
@Test func fileSizeIsAlwaysFresh() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("size-\(UUID().uuidString).bin")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data(count: 10).write(to: url)
    #expect(ExportPlanner.fileSize(url) == 10)
    try Data(count: 25).write(to: url)
    #expect(ExportPlanner.fileSize(url) == 25)
}

/// Ficheros ya presentes con el mismo nombre y tamaño (sin manifiesto) se adoptan en vez de duplicarse.
@Test func adoptsExistingFilesWithoutManifest() throws {
    let fixture = try FixtureCatalog()
    defer { fixture.cleanup() }
    let reader = try CatalogReader(url: fixture.bundle)
    let albums = try reader.albums()
    let destination = fixture.root.appendingPathComponent("Export")
    let options = ExportOptions(writeMetadata: false)
    let plan = try ExportPlanner.plan(patterns: ["Viajes/Andorra 2025"], selectedAlbumIDs: [], albums: albums, catalog: reader, options: options)
    let folder = destination.appendingPathComponent("Viajes Andorra 2025/Andorra 2025")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    // Copia previa hecha a mano (mismo contenido) y otra de distinto tamaño (no adoptable).
    try FileManager.default.copyItem(at: fixture.bundle.appendingPathComponent("Originals/2026/01/01/1/IMG_0001.jpg"), to: folder.appendingPathComponent("IMG_0001.jpg"))
    try Data([1, 2, 3]).write(to: folder.appendingPathComponent("IMG_0002.jpg"))

    let result = try ExportEngine(catalog: reader, destination: destination, options: options, writer: nil, cancellation: CancellationToken()).run(plan: plan) { _ in }
    #expect(result.summary.successCount == 3)
    let names = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
    // IMG_0001 adoptado (sin _1); IMG_0002 de distinto tamaño se conserva y la foto va a IMG_0002_1.
    #expect(names == ["IMG_0001.jpg", "IMG_0001_1.jpg", "IMG_0002.jpg", "IMG_0002_1.jpg", Manifest.filename])
    #expect(Manifest(folder: folder).entries["U10"]?.file == "IMG_0001.jpg")
    #expect(Manifest(folder: folder).entries["U11"]?.file == "IMG_0002_1.jpg")
}

/// Varios fallos de copia seguidos (carpeta sin permiso de escritura) detienen la exportación
/// como destino inaccesible, dejando el resto pendiente y sin marcar todo como error.
@Test func stopsAfterConsecutiveCopyFailures() throws {
    let fixture = try FixtureCatalog()
    defer { fixture.cleanup() }
    let reader = try CatalogReader(url: fixture.bundle)
    let albums = try reader.albums()
    let destination = fixture.root.appendingPathComponent("Export")
    let options = ExportOptions(writeMetadata: false)
    let plan = try ExportPlanner.plan(patterns: ["Andorra 20??"], selectedAlbumIDs: [], albums: albums, catalog: reader, options: options)
    #expect(plan.plannedCount == 4)
    let folder = destination.appendingPathComponent("Andorra 20/Andorra 2025")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

    let result = try ExportEngine(catalog: reader, destination: destination, options: options, writer: nil, cancellation: CancellationToken()).run(plan: plan) { _ in }
    #expect(result.summary.interruption == .destinationUnavailable(destination.path))
    let failed = result.jobs.filter { if case .failed = $0.status { return true } else { return false } }
    #expect(failed.count == ExportEngine.maxConsecutiveFailures)
    // La foto del otro álbum (carpeta escribible, va antes en el orden) sí se copió.
    #expect(result.jobs.first { $0.album.name == "Andorra 2024" }?.status == .doneWithoutMetadata)

    // Recuento tras la ejecución: lo fallido vuelve a contar como pendiente, lo hecho como exportado.
    var after = plan
    after.jobs = result.jobs
    after.recount()
    #expect(after.plannedCount == 3)
    #expect(after.alreadyExportedCount == 1)
}

@Test func writesAndVerifiesMetadataWithExiftool() throws {
    guard let exiftool = ExifToolLocator.find() else {
        Issue.record("exiftool no está instalado: prueba de metadatos omitida")
        return
    }
    let fixture = try FixtureCatalog()
    defer { fixture.cleanup() }
    let reader = try CatalogReader(url: fixture.bundle)
    let albums = try reader.albums()
    let destination = fixture.root.appendingPathComponent("Export")
    let options = ExportOptions()
    let plan = try ExportPlanner.plan(patterns: ["Viajes/Andorra 2025"], selectedAlbumIDs: [], albums: albums, catalog: reader, options: options)
    let engine = ExportEngine(catalog: reader, destination: destination, options: options, writer: ExifToolWriter(executable: exiftool), cancellation: CancellationToken())
    let result = try engine.run(plan: plan) { _ in }
    #expect(result.jobs.filter { $0.status == .done }.count == 3)
    #expect(result.summary.interruption == nil)

    let written = try #require(result.jobs.first { $0.photo.uuid == "U10" }?.destination)
    let read = try ExifToolWriter(executable: exiftool).readBack([written])[written.path]
    #expect(read?.rating == 5)
    #expect(read?.label == "Green")
    #expect(read?.subject == ["David", "Judit"])
    // -b devuelve el valor en bruto (con el salto de línea real, sin sustituirlo por un punto).
    let description = try ExifToolLocator.run(exiftool, arguments: ["-b", "-XMP-dc:Description", written.path])
    #expect(description == "Línea 1\nLínea 2 & más")
    let city = try ExifToolLocator.run(exiftool, arguments: ["-b", "-XMP-photoshop:City", written.path])
    #expect(city == "Andorra la Vella")
}

/// Verificación del catálogo real (solo lectura), con tiempos y recuentos en el registro.
@Test func verifiesRealCatalogWhenAvailable() throws {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/SonyA1.cocatalog")
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    let start = Date()
    let reader = try CatalogReader(url: url)
    let result = try CatalogVerifier.scan(catalog: reader)
    print("VERIFY-REAL files=\(result.filesOnDisk) referenced=\(result.referenced) orphans=\(result.orphans.count) missing=\(result.missing.count) unfiled=\(result.unfiled.count) matched=\(result.foundCount) seconds=\(Int(Date().timeIntervalSince(start)))")
    for o in result.orphans.prefix(5) { print("VERIFY-REAL orphan \(o.relativePath) \(o.size)") }
    for m in result.missing.prefix(5) { print("VERIFY-REAL missing \(m.expectedPath) -> \(m.candidate?.path ?? "-")") }
    #expect(result.filesOnDisk > 0)
}


/// Un perdido cuyo nombre ya está indexado con fichero presente se señala como importación duplicada.
@Test func flagsMissingEntriesAlreadyIndexedElsewhere() throws {
    let fixture = try FixtureCatalog()
    defer { fixture.cleanup() }
    let db = try SQLiteDatabase(path: fixture.bundle.appendingPathComponent("Fixture.cocatalogdb").path)
    // Segunda entrada de IMG_0001.jpg apuntando a una carpeta que no existe.
    try db.execute("INSERT INTO ZPATHLOCATION VALUES (9,1,NULL,'Originals/2020/01/01/9'); INSERT INTO ZIMAGE VALUES (18,'U18','IMG_0001.jpg',0,1,9); INSERT INTO ZVARIANT VALUES (28,18,127,201,201,201);")
    let reader = try CatalogReader(url: fixture.bundle)
    let dup = try #require(try reader.missingFiles().first { $0.imageID == 18 })
    #expect(dup.alsoIndexedAt?.hasSuffix("Originals/2026/01/01/1/IMG_0001.jpg") == true)
}

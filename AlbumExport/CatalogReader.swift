import Foundation

/// Lector de solo lectura de un catálogo (`.cocatalog`) o sesión (`.cosessiondb`) de Capture One.
///
/// El original nunca se abre: se copian la base de datos y sus ficheros WAL/SHM a un
/// directorio temporal y se consulta la copia. Al abrir, se sondea el esquema para
/// adaptarse a las diferencias entre versiones de Capture One (columnas o tablas ausentes).
final class CatalogReader: @unchecked Sendable {
    /// Base de datos original (informativa; no se abre).
    let databaseURL: URL
    /// Carpeta respecto a la que se resuelven las rutas relativas (`Originals/...`).
    let rootURL: URL
    /// Versión y formato del catálogo, si `ZVERSIONINFO` existe.
    let version: CatalogVersion?
    /// Avisos de compatibilidad detectados al sondear el esquema.
    let warnings: [String]

    private let db: SQLiteDatabase
    private let temporaryDirectory: URL
    private let entities: [String: Int]
    private let keywordParents: [String: String]
    private let capabilities: Capabilities

    /// Carpetas virtuales cuyos álbumes hijos son automáticos (uno por importación o captura).
    private static let autoFolderNames: Set<String> = ["Recent Imports", "Recent Captures"]

    /// Rasgos del esquema que pueden faltar en versiones antiguas o futuras.
    private struct Capabilities {
        var hasCombinedLayer = false
        var hasKeywordTable = false
        var hasTrashedFlag = false
        var hasImageUUID = false
        var hasInsideCatalogFlag = false
        var hasVariantInCollection = false
        var metadataColumns: Set<String> = []
    }

    enum Error: Swift.Error, LocalizedError {
        case notFound(URL)
        case incompatible([String])

        var errorDescription: String? {
            switch self {
            case .notFound(let url):
                String(localized: "No Capture One database found at \(url.path)", comment: "Error al abrir catálogo")
            case .incompatible(let missing):
                String(localized: "This catalog format is not supported. Missing: \(missing.joined(separator: ", "))", comment: "Error de esquema incompatible")
            }
        }
    }

    // MARK: - Apertura

    /// - Parameter url: Bundle `.cocatalog`, fichero `.cocatalogdb`/`.cosessiondb`, o carpeta de sesión.
    init(url: URL) throws {
        let (database, root) = try Self.resolve(url)
        databaseURL = database
        rootURL = root

        // Instantánea: db + wal + shm. Así se lee un estado consistente sin tocar el original.
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("AlbumExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        temporaryDirectory = temp
        let snapshot = temp.appendingPathComponent(database.lastPathComponent)
        for suffix in ["", "-wal", "-shm"] {
            let source = database.deletingLastPathComponent().appendingPathComponent(database.lastPathComponent + suffix)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: temp.appendingPathComponent(snapshot.lastPathComponent + suffix))
            }
        }
        db = try SQLiteDatabase(path: snapshot.path)

        // Sondeo del esquema: lo imprescindible aborta; lo opcional degrada con aviso.
        let tables = db.tables()
        let required = ["ZCOLLECTION", "ZIMAGE", "ZVARIANT", "ZVARIANTLAYER", "ZVARIANTMETADATA", "ZPATHLOCATION", "ZIMAGEINCOLLECTION", "ZENTITIES"]
        let missing = required.filter { !tables.contains($0) }
        guard missing.isEmpty else { throw Error.incompatible(missing) }

        var caps = Capabilities()
        var warnings: [String] = []
        let variantColumns = db.columns(of: "ZVARIANT")
        let imageColumns = db.columns(of: "ZIMAGE")
        caps.hasCombinedLayer = variantColumns.contains("ZCOMBINEDSETTINGS")
        caps.hasKeywordTable = tables.contains("ZKEYWORD")
        caps.hasTrashedFlag = imageColumns.contains("ZISTRASHED")
        caps.hasImageUUID = imageColumns.contains("ZIMAGEUUID")
        caps.hasInsideCatalogFlag = imageColumns.contains("ZISINSIDECATALOG")
        caps.hasVariantInCollection = tables.contains("ZVARIANTINCOLLECTION")
        caps.metadataColumns = db.columns(of: "ZVARIANTMETADATA")
        if !caps.hasCombinedLayer {
            warnings.append(String(localized: "Older catalog: effective metadata will be merged from adjustment and default layers.", comment: "Aviso de compatibilidad"))
        }
        for column in ["ZBASIC_RATING", "ZCOLOR_TAG_INDEX", "ZCONTENT_KEYWORDS"] where !caps.metadataColumns.contains(column) {
            warnings.append(String(localized: "Column \(column) not found: that field will not be exported.", comment: "Aviso de compatibilidad"))
        }
        capabilities = caps

        entities = Dictionary(uniqueKeysWithValues: (try? db.query("SELECT Z_ENT, ZNAME FROM ZENTITIES"))?
            .compactMap { row -> (String, Int)? in
                guard let name = row.string("ZNAME"), let ent = row.int("Z_ENT") else { return nil }
                return (name, ent)
            } ?? [])

        var version: CatalogVersion?
        if tables.contains("ZVERSIONINFO"),
           let row = try? db.query("SELECT ZAUTHOR, ZVERSION FROM ZVERSIONINFO ORDER BY Z_PK DESC LIMIT 1").first {
            version = CatalogVersion(application: row.string("ZAUTHOR") ?? "?", format: row.int("ZVERSION") ?? 0)
            if version?.isNewerThanTested == true {
                warnings.append(String(localized: "Catalog format \(version?.format ?? 0) is newer than the versions this app was tested with. Check the results.", comment: "Aviso de compatibilidad"))
            } else if version?.isOlderThanTested == true {
                warnings.append(String(localized: "Catalog format \(version?.format ?? 0) is older than the versions this app was tested with. Check the results.", comment: "Aviso de compatibilidad"))
            }
        } else {
            warnings.append(String(localized: "No version information in this catalog.", comment: "Aviso de compatibilidad"))
        }
        self.version = version
        self.warnings = warnings

        // Jerarquía de keywords (nombre -> padre) para lr:hierarchicalSubject.
        var parents: [String: String] = [:]
        if caps.hasKeywordTable, let rows = try? db.query("SELECT Z_PK, ZNAME, ZPARENT FROM ZKEYWORD") {
            let byPK = Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (Int, String)? in
                guard let pk = row.int("Z_PK"), let name = row.string("ZNAME") else { return nil }
                return (pk, name)
            })
            for row in rows {
                if let name = row.string("ZNAME"), let parent = row.int("ZPARENT"), let parentName = byPK[parent] {
                    parents[name] = parentName
                }
            }
        }
        keywordParents = parents
    }

    deinit {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    private static func resolve(_ url: URL) throws -> (database: URL, root: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { throw Error.notFound(url) }
        if isDirectory.boolValue {
            let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            for ext in ["cocatalogdb", "cosessiondb"] {
                if let found = contents.filter({ $0.pathExtension.lowercased() == ext }).sorted(by: { $0.path < $1.path }).first {
                    return (found, url)
                }
            }
            throw Error.notFound(url)
        }
        guard ["cocatalogdb", "cosessiondb"].contains(url.pathExtension.lowercased()) else { throw Error.notFound(url) }
        return (url, url.deletingLastPathComponent())
    }

    // MARK: - Álbumes

    /// Todos los álbumes y smart albums, ordenados por ruta.
    func albums() throws -> [Album] {
        let rows = try db.query("""
            SELECT c.Z_PK, c.Z_ENT, c.ZNAME, c.ZPARENT,
                   (SELECT COUNT(*) FROM ZIMAGEINCOLLECTION ic WHERE ic.ZCOLLECTION = c.Z_PK) AS n
            FROM ZCOLLECTION c
            """)
        struct Node { let ent: Int; let name: String; let parent: Int?; let count: Int }
        var nodes: [Int: Node] = [:]
        for row in rows {
            guard let pk = row.int("Z_PK") else { continue }
            nodes[pk] = Node(ent: row.int("Z_ENT") ?? 0, name: row.string("ZNAME") ?? "", parent: row.int("ZPARENT"), count: row.int("n") ?? 0)
        }
        let albumEnt = entities["AlbumCollection"]
        let smartEnt = entities["SmartCollection"]
        let folderEnt = entities["VirtualFolderCollection"]
        let projectEnt = entities["ProjectCollection"]

        func path(of pk: Int) -> String {
            var parts: [String] = []
            var current: Int? = pk
            var seen: Set<Int> = []
            while let id = current, let node = nodes[id], !seen.contains(id), node.ent != projectEnt {
                seen.insert(id)
                parts.append(node.name)
                current = node.parent
            }
            return parts.reversed().joined(separator: "/")
        }

        return nodes.compactMap { pk, node -> Album? in
            guard node.ent == albumEnt || node.ent == smartEnt else { return nil }
            let parent = node.parent.flatMap { nodes[$0] }
            let isAuto = parent.map { $0.ent == folderEnt && Self.autoFolderNames.contains($0.name) } ?? false
            return Album(id: pk, name: node.name, path: path(of: pk), isAuto: isAuto, isSmart: node.ent == smartEnt, imageCount: node.count)
        }
        .sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    // MARK: - Fotos

    /// Fotos de un álbum con la ruta del original y los metadatos efectivos de su variante.
    func photos(in album: Album) throws -> [Photo] {
        let trashed = capabilities.hasTrashedFlag ? "i.ZISTRASHED" : "0"
        let uuid = capabilities.hasImageUUID ? "i.ZIMAGEUUID" : "NULL"
        let inside = capabilities.hasInsideCatalogFlag ? "i.ZISINSIDECATALOG" : "p.ZISRELATIVE"
        let rows = try db.query("""
            SELECT i.Z_PK, \(uuid) AS uuid, i.ZIMAGEFILENAME, \(trashed) AS trashed, \(inside) AS inside,
                   p.ZISRELATIVE, p.ZMACROOT, p.ZRELATIVEPATH
            FROM ZIMAGEINCOLLECTION ic
            JOIN ZIMAGE i ON i.Z_PK = ic.ZIMAGE
            LEFT JOIN ZPATHLOCATION p ON p.Z_PK = i.ZIMAGELOCATION
            WHERE ic.ZCOLLECTION = ?
            ORDER BY i.ZIMAGEFILENAME COLLATE NOCASE
            """, [album.id])
        return try rows.compactMap { row in
            guard let pk = row.int("Z_PK"), let filename = row.string("ZIMAGEFILENAME") else { return nil }
            var photo = Photo(
                id: pk,
                uuid: row.string("uuid") ?? String(pk),
                filename: filename,
                source: resolveSource(row: row, filename: filename),
                isTrashed: row.bool("trashed"),
                isInsideCatalog: row.bool("inside"))
            try loadMetadata(into: &photo, album: album)
            return photo
        }
    }

    private func resolveSource(row: SQLiteDatabase.Row, filename: String) -> URL? {
        guard let relative = row.string("ZRELATIVEPATH") else { return nil }
        if row.bool("ZISRELATIVE") {
            return rootURL.appendingPathComponent(relative).appendingPathComponent(filename)
        }
        // Rutas absolutas: ZMACROOT ("/", "/Volumes/X") + ZRELATIVEPATH (con o sin barra inicial).
        let root = row.string("ZMACROOT") ?? "/"
        let trimmed = relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
        return URL(fileURLWithPath: root).appendingPathComponent(trimmed).appendingPathComponent(filename)
    }

    private func loadMetadata(into photo: inout Photo, album: Album) throws {
        // Se prefiere la variante que está en el álbum; si no, la primaria (menor ZINDEX).
        let inAlbum = capabilities.hasVariantInCollection
            ? "LEFT JOIN ZVARIANTINCOLLECTION vc ON vc.ZVARIANT = v.Z_PK AND vc.ZCOLLECTION = ?"
            : ""
        let inAlbumFlag = capabilities.hasVariantInCollection ? "(vc.Z_PK IS NOT NULL)" : "0"
        let combined = capabilities.hasCombinedLayer ? "v.ZCOMBINEDSETTINGS" : "NULL"
        let params: [Any?] = capabilities.hasVariantInCollection ? [album.id, photo.id] : [photo.id]
        guard let row = try db.query("""
            SELECT v.Z_PK, \(combined) AS combined, v.ZADJUSTMENTLAYER, v.ZDEFAULTLAYER, \(inAlbumFlag) AS in_album
            FROM ZVARIANT v
            \(inAlbum)
            WHERE v.ZIMAGE = ?
            ORDER BY in_album DESC, v.ZINDEX ASC
            LIMIT 1
            """, params).first else { return }
        photo.variantID = row.int("Z_PK")

        // La capa "combinada" contiene los valores efectivos (ajuste sobre defecto).
        // Si no existe (catálogos antiguos) se fusionan a mano las dos capas.
        var metadata = try layerMetadata(row.int("combined"))
        if metadata == nil {
            let adjust = try layerMetadata(row.int("ZADJUSTMENTLAYER")) ?? [:]
            let base = try layerMetadata(row.int("ZDEFAULTLAYER")) ?? [:]
            metadata = base.merging(adjust) { _, new in new }
        }
        guard let meta = metadata else { return }

        photo.rating = (meta["ZBASIC_RATING"] as? Int64).map(Int.init)
        photo.colorTag = (meta["ZCOLOR_TAG_INDEX"] as? Int64).flatMap { ColorTag(rawValue: Int($0)) }
        photo.keywords = Self.parseKeywords(meta["ZCONTENT_KEYWORDS"] as? String)
        photo.hierarchicalKeywords = photo.keywords.map(hierarchicalPath)
        var fields: [String: String] = [:]
        for (column, value) in meta {
            if let text = value as? String, !text.isEmpty, column != "ZCONTENT_KEYWORDS", column != "ZBASIC_LABEL" {
                fields[column] = text
            }
        }
        photo.fields = fields
    }

    private func layerMetadata(_ layerID: Int?) throws -> [String: Any]? {
        guard let layerID else { return nil }
        return try db.query("""
            SELECT m.* FROM ZVARIANTLAYER l JOIN ZVARIANTMETADATA m ON m.Z_PK = l.ZMETADATA WHERE l.Z_PK = ?
            """, [layerID]).first?.values
    }

    // MARK: - Verificación

    private struct ImageLocation {
        let id: Int
        let filename: String
        let relative: Bool
        let root: String?
        let path: String?
        let size: Int64?
    }

    private func allImageLocations() throws -> [ImageLocation] {
        let hasSize = db.columns(of: "ZIMAGE").contains("ZFILE_SIZE")
        return try db.query("""
            SELECT i.Z_PK AS pk, i.ZIMAGEFILENAME AS f, \(hasSize ? "i.ZFILE_SIZE" : "NULL") AS size,
                   p.ZISRELATIVE AS rel, p.ZMACROOT AS root, p.ZRELATIVEPATH AS path
            FROM ZIMAGE i LEFT JOIN ZPATHLOCATION p ON p.Z_PK = i.ZIMAGELOCATION
            """).compactMap { row in
            guard let pk = row.int("pk"), let f = row.string("f") else { return nil }
            return ImageLocation(id: pk, filename: f, relative: row.bool("rel"), root: row.string("root"), path: row.string("path"),
                                 size: row.int("size").map(Int64.init))
        }
    }

    private func expectedURL(_ loc: ImageLocation) -> URL? {
        guard let path = loc.path else { return nil }
        if loc.relative {
            return rootURL.appendingPathComponent(path).appendingPathComponent(loc.filename)
        }
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return URL(fileURLWithPath: loc.root ?? "/").appendingPathComponent(trimmed).appendingPathComponent(loc.filename)
    }

    /// Rutas relativas al bundle (en minúsculas) de todos los originales que el índice
    /// referencia dentro del catálogo, papelera incluida.
    func referencedRelativePaths() throws -> Set<String> {
        var set: Set<String> = []
        for loc in try allImageLocations() where loc.relative {
            guard let path = loc.path else { continue }
            set.insert((path + "/" + loc.filename).lowercased())
        }
        return set
    }

    /// Imágenes del índice cuyo fichero no existe donde el catálogo espera (offline).
    /// Los volúmenes no montados se resuelven sin consultar el disco, para no bloquearse.
    func missingFiles(cancellation: CancellationToken? = nil, progress: ((Int, Int) -> Void)? = nil) throws -> [MissingFile] {
        var missing: [MissingFile] = []
        let locations = try allImageLocations()
        let mounted = Set((FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []).map { $0.standardizedFileURL.path })
        var checked = 0
        var presentByName: [String: String] = [:]   // nombre en minúsculas -> ruta de un fichero indexado que sí existe
        for loc in locations {
            if cancellation?.isCancelled == true { throw ExportInterruptionError.cancelled }
            checked += 1
            if checked % 500 == 0 { progress?(checked, locations.count) }
            if !loc.relative, let root = loc.root, root.hasPrefix("/Volumes/"), !mounted.contains(where: { root.hasPrefix($0) }) {
                missing.append(MissingFile(imageID: loc.id, filename: loc.filename, expectedPath: expectedURL(loc)?.path ?? "?", size: loc.size))
                continue
            }
            guard let url = expectedURL(loc) else {
                missing.append(MissingFile(imageID: loc.id, filename: loc.filename, expectedPath: "?", size: loc.size))
                continue
            }
            if !FileManager.default.fileExists(atPath: url.path) {
                missing.append(MissingFile(imageID: loc.id, filename: loc.filename, expectedPath: url.path, size: loc.size))
            } else if presentByName[loc.filename.lowercased()] == nil {
                presentByName[loc.filename.lowercased()] = url.path
            }
        }
        // Un perdido cuyo nombre ya está indexado con fichero presente es una importación duplicada.
        return missing.map { item in
            var updated = item
            updated.alsoIndexedAt = presentByName[item.filename.lowercased()]
            return updated
        }.sorted { $0.expectedPath < $1.expectedPath }
    }

    /// Imágenes del índice que no están en ningún álbum creado por el usuario (ni en la
    /// papelera). Los álbumes automáticos de "Recent Imports" / "Recent Captures" no cuentan.
    /// Cada resultado indica si otra foto con el mismo nombre ya está en algún álbum.
    func imagesNotInAnyAlbum() throws -> [UnfiledImage] {
        guard let albumEnt = entities["AlbumCollection"] else { return [] }
        let folderEnt = entities["VirtualFolderCollection"] ?? -1
        let trashed = db.columns(of: "ZIMAGE").contains("ZISTRASHED") ? "AND IFNULL(i.ZISTRASHED, 0) = 0" : ""
        let autoNames = Self.autoFolderNames.map { "'\($0)'" }.joined(separator: ", ")
        let userAlbumMembership = """
            SELECT ic.ZIMAGE AS image, c.ZNAME AS album FROM ZIMAGEINCOLLECTION ic
            JOIN ZCOLLECTION c ON c.Z_PK = ic.ZCOLLECTION
            LEFT JOIN ZCOLLECTION p ON p.Z_PK = c.ZPARENT
            WHERE c.Z_ENT = \(albumEnt) AND NOT (p.Z_ENT = \(folderEnt) AND p.ZNAME IN (\(autoNames)))
            """
        let rows = try db.query("""
            SELECT i.Z_PK AS pk FROM ZIMAGE i
            WHERE NOT EXISTS (SELECT 1 FROM (\(userAlbumMembership)) m WHERE m.image = i.Z_PK) \(trashed)
            """)
        let ids = Set(rows.compactMap { $0.int("pk") })
        // Nombre de fichero (minúsculas) -> primer álbum de usuario que contiene una foto con ese nombre.
        var filedNames: [String: String] = [:]
        for row in try db.query("""
            SELECT LOWER(i.ZIMAGEFILENAME) AS name, MIN(m.album) AS album
            FROM (\(userAlbumMembership)) m JOIN ZIMAGE i ON i.Z_PK = m.image GROUP BY LOWER(i.ZIMAGEFILENAME)
            """) {
            if let name = row.string("name"), let album = row.string("album") { filedNames[name] = album }
        }
        return try allImageLocations().filter { ids.contains($0.id) }
            .map { UnfiledImage(imageID: $0.id, filename: $0.filename, path: expectedURL($0)?.path ?? "?",
                                duplicateInAlbum: filedNames[$0.filename.lowercased()]) }
            .sorted { $0.path < $1.path }
    }

    /// Identificadores de variante (= `id` en AppleScript) de las imágenes dadas.
    func variantIDs(forImages imageIDs: [Int]) throws -> [Int] {
        guard !imageIDs.isEmpty else { return [] }
        let list = imageIDs.map(String.init).joined(separator: ",")
        return try db.query("SELECT Z_PK FROM ZVARIANT WHERE ZIMAGE IN (\(list)) ORDER BY ZIMAGE, ZINDEX").compactMap { $0.int("Z_PK") }
    }

    // MARK: - Keywords

    /// Descompone `ZCONTENT_KEYWORDS` ("Nombre||0,Otro||1": nombre, separador, índice de orden).
    static func parseKeywords(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        var result: [String] = []
        for entry in raw.split(separator: ",") {
            let name = entry.components(separatedBy: "||").first?.trimmingCharacters(in: .whitespaces) ?? ""
            if !name.isEmpty, !result.contains(name) { result.append(name) }
        }
        return result
    }

    private func hierarchicalPath(_ keyword: String) -> String {
        var chain = [keyword]
        var seen: Set<String> = [keyword]
        var parent = keywordParents[keyword]
        while let p = parent, !seen.contains(p) {
            chain.append(p)
            seen.insert(p)
            parent = keywordParents[p]
        }
        return chain.reversed().joined(separator: "|")
    }

    // MARK: - Ajustes de revelado

    /// Columnas no nulas de las capas de ajuste y por defecto de la variante, como JSON.
    func adjustmentsJSON(variantID: Int) throws -> Data {
        guard let row = try db.query("SELECT ZADJUSTMENTLAYER, ZDEFAULTLAYER FROM ZVARIANT WHERE Z_PK = ?", [variantID]).first else {
            return Data("{}".utf8)
        }
        var result: [String: [String: Any]] = [:]
        for (label, key) in [("adjustment", "ZADJUSTMENTLAYER"), ("default", "ZDEFAULTLAYER")] {
            guard let layerID = row.int(key),
                  let layer = try db.query("SELECT * FROM ZVARIANTLAYER WHERE Z_PK = ?", [layerID]).first else { continue }
            var values: [String: Any] = [:]
            for (column, value) in layer.values where column.hasPrefix("Z") && !["Z_ENT", "Z_PK", "ZMETADATA", "ZVARIANT"].contains(column) {
                values[String(column.dropFirst()).lowercased()] = value
            }
            result[label] = values
        }
        return try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    }
}

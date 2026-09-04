import Foundation

/// Construye el plan de exportación: qué fotos, de qué álbumes, a qué carpeta.
enum ExportPlanner {
    /// Nombre de carpeta seguro: sin comodines (opcional), sin separadores ni caracteres de control.
    static func sanitize(_ name: String, stripWildcards: Bool = false) -> String {
        var text = name
        if stripWildcards {
            text = text.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "?", with: "")
        }
        let forbidden = CharacterSet(charactersIn: "/\\:").union(.controlCharacters)
        text = text.unicodeScalars.map { forbidden.contains($0) ? " " : Character($0) }.map(String.init).joined()
        text = text.split(separator: " ").joined(separator: " ")
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return text.isEmpty ? "album" : text
    }

    /// Carpeta de destino de un álbum: `<destino>/<patrón sin comodines>/<álbum>`.
    static func folder(for pattern: String, album: Album, in destination: URL) -> URL {
        destination
            .appendingPathComponent(sanitize(pattern, stripWildcards: true), isDirectory: true)
            .appendingPathComponent(sanitize(album.name), isDirectory: true)
    }

    /// Genera el plan leyendo el catálogo. Se ejecuta fuera del hilo principal.
    /// - Parameters:
    ///   - patterns: Patrones con comodines escritos por el usuario.
    ///   - selectedAlbumIDs: Álbumes marcados a mano en la lista (se unen a los patrones).
    ///   - destination: Si se conoce, se consultan sus manifiestos para marcar de antemano
    ///     las fotos ya exportadas (sin tocar nada en disco).
    static func plan(patterns: [String], selectedAlbumIDs: Set<Int>, albums: [Album],
                     catalog: CatalogReader, options: ExportOptions, destination: URL? = nil) throws -> ExportPlan {
        var plan = ExportPlan()
        var jobs: [ExportJob] = []
        var seenAlbums: Set<Int> = []
        var nextID = 0
        var manifests: [URL: Manifest] = [:]

        func alreadyExported(_ job: ExportJob, size: Int64) -> Bool {
            guard let destination, !options.refreshExisting else { return false }
            let folder = folder(for: job.pattern, album: job.album, in: destination)
            if manifests[folder] == nil { manifests[folder] = Manifest(folder: folder) }
            return manifests[folder]?.existingFile(for: job.photo.uuid, expectedSize: size, repair: false)?.metadataDone == true
        }

        func add(album: Album, pattern: String) throws {
            guard !seenAlbums.contains(album.id) else { return }
            seenAlbums.insert(album.id)
            plan.matchedAlbums.append(album)
            for photo in try catalog.photos(in: album) {
                jobs.append(ExportJob(id: nextID, pattern: pattern, album: album, photo: photo))
                nextID += 1
            }
        }

        for pattern in patterns {
            for album in PatternMatcher.albums(matching: pattern, in: albums, includeAuto: options.includeAutoAlbums) {
                try add(album: album, pattern: pattern)
            }
        }
        // Los álbumes marcados a mano usan su propio nombre como "patrón" de carpeta.
        for album in albums where selectedAlbumIDs.contains(album.id) && !album.isSmart {
            try add(album: album, pattern: album.name)
        }

        for index in jobs.indices {
            let photo = jobs[index].photo
            if photo.isTrashed && !options.includeTrashed {
                jobs[index].status = .skippedTrashed
                plan.skippedTrashed += 1
            } else if let source = photo.source, FileManager.default.fileExists(atPath: source.path) {
                let size = fileSize(source)
                if alreadyExported(jobs[index], size: size) {
                    jobs[index].status = .alreadyExported
                    plan.alreadyExportedCount += 1
                    continue
                }
                plan.plannedCount += 1
                plan.totalBytes += size
                if photo.isInsideCatalog { plan.insideCatalogCount += 1 }
            } else {
                jobs[index].status = .missingSource
                plan.missingSources += 1
            }
        }
        plan.jobs = jobs
        return plan
    }

    /// Tamaño actual del fichero en disco.
    ///
    /// Se consulta con `FileManager` y no con `URL.resourceValues`, que cachea el valor en
    /// la instancia de URL: tras reescribir el fichero (exiftool) devolvería el tamaño antiguo.
    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

// MARK: - Manifiesto

/// Registro por carpeta de álbum (UUID de imagen -> fichero y estado) para no duplicar
/// fotos en ejecuciones repetidas y retomar exportaciones interrumpidas.
struct Manifest {
    static let filename = ".albumexport.json"
    /// Prefijo de los ficheros en curso de copia; se renombran al terminar.
    static let partialPrefix = ".albumexport-partial-"

    struct Entry: Codable, Equatable {
        var file: String
        var metadataDone: Bool
    }

    private(set) var entries: [String: Entry]
    let folder: URL

    init(folder: URL) {
        self.folder = folder
        let url = folder.appendingPathComponent(Self.filename)
        if let data = try? Data(contentsOf: url) {
            if let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
                entries = decoded
            } else if let legacy = try? JSONDecoder().decode([String: String].self, from: data) {
                // Formato de la primera versión (solo nombre): se asume completado.
                entries = legacy.mapValues { Entry(file: $0, metadataDone: true) }
            } else {
                entries = [:]
            }
        } else {
            entries = [:]
        }
    }

    /// Fichero ya exportado para esa imagen, si existe y tiene el tamaño esperado.
    /// - Parameter repair: Si es `true`, un fichero truncado por un corte se elimina para
    ///   copiarlo de nuevo (solo durante la exportación, nunca al planificar).
    func existingFile(for uuid: String, expectedSize: Int64, repair: Bool = true) -> (url: URL, metadataDone: Bool)? {
        guard let entry = entries[uuid] else { return nil }
        let url = folder.appendingPathComponent(entry.file)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // Tras escribir XMP el tamaño cambia unos KB; solo se desconfía si aún no se escribieron metadatos.
        if !entry.metadataDone, ExportPlanner.fileSize(url) != expectedSize {
            if repair { try? FileManager.default.removeItem(at: url) }
            return nil
        }
        return (url, entry.metadataDone)
    }

    /// `true` si ningún registro del manifiesto reclama ese nombre de fichero.
    func isUnclaimed(filename: String) -> Bool {
        !entries.values.contains { $0.file.caseInsensitiveCompare(filename) == .orderedSame }
    }

    mutating func record(uuid: String, filename: String, metadataDone: Bool) {
        entries[uuid] = Entry(file: filename, metadataDone: metadataDone)
    }

    mutating func markMetadataDone(uuid: String) {
        entries[uuid]?.metadataDone = true
    }

    func save() throws {
        let data = try JSONEncoder().encode(entries)
        try data.write(to: folder.appendingPathComponent(Self.filename), options: .atomic)
    }

    /// Borra restos de copias interrumpidas en la carpeta.
    static func removePartialFiles(in folder: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix(partialPrefix) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}

/// Reparte nombres únicos dentro de una carpeta: añade `_1`, `_2`... si el nombre ya existe
/// en disco o ya se ha asignado en esta ejecución.
struct NameAllocator {
    private var used: Set<String> = []
    let folder: URL

    init(folder: URL) { self.folder = folder }

    mutating func reserve(_ name: String) { used.insert(name.lowercased()) }

    mutating func unique(_ filename: String) -> URL {
        let ext = (filename as NSString).pathExtension
        let stem = (filename as NSString).deletingPathExtension
        var candidate = filename
        var counter = 1
        while used.contains(candidate.lowercased()) || FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(stem)_\(counter)" : "\(stem)_\(counter).\(ext)"
            counter += 1
        }
        used.insert(candidate.lowercased())
        return folder.appendingPathComponent(candidate)
    }
}

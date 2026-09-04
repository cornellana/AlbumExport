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
    static func plan(patterns: [String], selectedAlbumIDs: Set<Int>, albums: [Album],
                     catalog: CatalogReader, options: ExportOptions) throws -> ExportPlan {
        var plan = ExportPlan()
        var jobs: [ExportJob] = []
        var seenAlbums: Set<Int> = []
        var nextID = 0

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
                plan.plannedCount += 1
                plan.totalBytes += fileSize(source)
                if photo.isInsideCatalog { plan.insideCatalogCount += 1 }
            } else {
                jobs[index].status = .missingSource
                plan.missingSources += 1
            }
        }
        plan.jobs = jobs
        return plan
    }

    static func fileSize(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
    }
}

// MARK: - Manifiesto

/// Registro por carpeta de álbum (UUID de imagen -> nombre de fichero) para no duplicar
/// fotos en ejecuciones repetidas.
struct Manifest {
    static let filename = ".albumexport.json"
    private(set) var entries: [String: String]
    let folder: URL

    init(folder: URL) {
        self.folder = folder
        let url = folder.appendingPathComponent(Self.filename)
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    /// Fichero ya exportado para esa imagen, si sigue existiendo en la carpeta.
    func existingFile(for uuid: String) -> URL? {
        guard let name = entries[uuid] else { return nil }
        let url = folder.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    mutating func record(uuid: String, filename: String) {
        entries[uuid] = filename
    }

    func save() throws {
        let data = try JSONEncoder().encode(entries)
        try data.write(to: folder.appendingPathComponent(Self.filename), options: .atomic)
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

import Foundation

/// Traslada álbumes de un catálogo a otro usando Capture One como motor (AppleScript):
/// exporta los originales con todos los ajustes (EIP para RAW, `.cos` lateral para el
/// resto), los importa en el catálogo destino y recrea grupo y álbum. No borra nada del
/// origen.
///
/// Fotos que ya están en el álbum destino (mismo nombre de fichero) se dan por
/// trasladadas, lo que permite reanudar y "añadir al álbum existente".
struct CatalogTransferEngine {
    let sourceCatalogURL: URL
    let destinationCatalogURL: URL
    let cancellation: CancellationToken
    let driver = CaptureOneDriver()

    /// Fotos por lote: acota el tamaño de la exportación temporal y da progreso.
    static let batchSize = 20
    /// Extensiones que Capture One empaqueta en EIP (RAW).
    static let packableExtensions: Set<String> = ["arw", "dng", "nef", "rw2", "cr2", "cr3", "raf", "orf", "pef", "srw", "3fr", "fff", "iiq", "eip"]

    static func isPackable(_ filename: String) -> Bool {
        packableExtensions.contains((filename as NSString).pathExtension.lowercased())
    }

    /// Nombre de fichero que producirá la exportación (`[Image Name]` + eip para RAW).
    static func exportedName(for filename: String) -> String {
        isPackable(filename) ? ((filename as NSString).deletingPathExtension + ".eip") : filename
    }

    func run(plan: ExportPlan, events: @escaping @Sendable (ExportEvent) -> Void) throws -> (jobs: [ExportJob], summary: ExportSummary) {
        var jobs = plan.jobs
        var interruption: ExportInterruption?
        let source = CaptureOneDriver.documentName(for: sourceCatalogURL)
        let destination = CaptureOneDriver.documentName(for: destinationCatalogURL)

        func update(_ index: Int, _ status: JobStatus) {
            jobs[index].status = status
            events(.status(jobID: jobs[index].id, status: status, destination: nil))
        }
        func log(_ text: String) { events(.log(text)) }

        // MARK: Capture One y documentos
        log(String(localized: "Opening Capture One and both catalogs…", comment: "Registro de traslado"))
        try driver.launch()
        try driver.openCatalog(sourceCatalogURL)
        if FileManager.default.fileExists(atPath: destinationCatalogURL.path) {
            try driver.openCatalog(destinationCatalogURL)
        } else {
            log(String(localized: "Creating catalog \(destination)…", comment: "Registro de traslado"))
            try driver.createCatalog(at: destinationCatalogURL)
        }

        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("AlbumExport-transfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        // MARK: Por álbum
        let pending = jobs.indices.filter { jobs[$0].status == .pending && jobs[$0].photo.variantID != nil }
        let total = pending.count
        var completed = 0
        var batchNumber = 0
        let byAlbum = Dictionary(grouping: pending) { jobs[$0].album.id }
        let albumOrder = byAlbum.keys.sorted { jobs[byAlbum[$0]![0]].album.path < jobs[byAlbum[$1]![0]].album.path }

        albums: for albumID in albumOrder {
            let indices = byAlbum[albumID]!
            let album = jobs[indices[0]].album
            let path = album.path.split(separator: "/").map(String.init)
            let existing = Set(try driver.ensureAlbum(document: destination, path: path).map { $0.lowercased() })
            // Imágenes que ya están en el catálogo destino aunque no en el álbum (una ejecución
            // anterior cortada, u otro álbum): se adoptan sin volver a exportar ni duplicar.
            var inCatalog: [String: Int] = [:]
            for (id, filename) in try driver.allImageNames(document: destination) {
                let stem = (filename as NSString).deletingPathExtension.lowercased()
                if inCatalog[stem] == nil { inCatalog[stem] = id }
            }

            // Ya presentes en el álbum destino (por nombre sin extensión) y duplicados de imagen.
            var toTransfer: [Int] = []
            var toAdopt: [(index: Int, imageID: Int)] = []
            var seenImages: Set<Int> = []
            for index in indices {
                let stem = (jobs[index].photo.filename as NSString).deletingPathExtension.lowercased()
                if existing.contains(stem) {
                    update(index, .alreadyExported)
                    completed += 1
                } else if seenImages.contains(jobs[index].photo.id) {
                    update(index, .alreadyExported)   // clon: el EIP de la imagen lleva todas las variantes
                    completed += 1
                } else if let imageID = inCatalog[stem] {
                    seenImages.insert(jobs[index].photo.id)
                    toAdopt.append((index, imageID))
                } else {
                    seenImages.insert(jobs[index].photo.id)
                    toTransfer.append(index)
                }
            }
            if !toAdopt.isEmpty {
                log(String(localized: "\(toAdopt.count) photos already in \(destination): adding them to the album without re-importing.", comment: "Registro de traslado"))
                let details = try driver.imageDetails(document: destination, imageIDs: toAdopt.map(\.imageID))
                let variantsByImage = Dictionary(uniqueKeysWithValues: details.map { ($0.id, $0.variantIDs) })
                try driver.addToAlbum(document: destination, path: path, variantIDs: toAdopt.flatMap { variantsByImage[$0.imageID] ?? [] })
                let readBack = try driver.readBack(document: destination, variantIDs: toAdopt.compactMap { variantsByImage[$0.imageID]?.first })
                let readByID = Dictionary(uniqueKeysWithValues: readBack.map { ($0.id, $0) })
                for (index, imageID) in toAdopt {
                    if let first = variantsByImage[imageID]?.first, let r = readByID[first], Self.matches(jobs[index].photo, r) {
                        update(index, .done)
                    } else {
                        update(index, .verificationFailed)
                    }
                    completed += 1
                }
            }
            events(.progress(completed: completed, total: total, bytesDone: 0, bytesTransferred: 0, current: album.name))

            for batch in stride(from: 0, to: toTransfer.count, by: Self.batchSize).map({ Array(toTransfer[$0..<min($0 + Self.batchSize, toTransfer.count)]) }) {
                if cancellation.isCancelled { interruption = .cancelled; break albums }
                batchNumber += 1
                let folder = staging.appendingPathComponent("batch\(batchNumber)", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

                // MARK: Exportar (RAW empaquetado, resto con .cos lateral)
                let packable = batch.filter { Self.isPackable(jobs[$0].photo.filename) }
                let others = batch.filter { !Self.isPackable(jobs[$0].photo.filename) }
                events(.progress(completed: completed, total: total, bytesDone: 0, bytesTransferred: 0,
                                 current: String(localized: "Exporting \(batch.count) photos from \(album.name)…", comment: "Fase de traslado")))
                if !packable.isEmpty {
                    try driver.exportOriginals(document: source, collectionPath: path, variantIDs: packable.map { jobs[$0].photo.variantID! }, to: folder, packed: true)
                }
                if !others.isEmpty {
                    try driver.exportOriginals(document: source, collectionPath: path, variantIDs: others.map { jobs[$0].photo.variantID! }, to: folder, packed: false)
                }
                let expected = batch.map { Self.exportedName(for: jobs[$0].photo.filename) }
                do {
                    try waitForFiles(expected, in: folder)
                } catch {
                    for index in batch { update(index, .failed(error.localizedDescription)) }
                    log(error.localizedDescription)
                    continue
                }

                // MARK: Importar
                events(.progress(completed: completed, total: total, bytesDone: 0, bytesTransferred: 0,
                                 current: String(localized: "Importing \(batch.count) photos into \(destination)…", comment: "Fase de traslado")))
                let before = try driver.imageIDs(document: destination)
                try driver.importFolder(document: destination, folder: folder)
                let after = try waitForImport(document: destination, before: before.count, expected: expected.count)
                let newIDs = Array(after.subtracting(before)).sorted()
                let details = try driver.imageDetails(document: destination, imageIDs: newIDs)

                // MARK: Emparejar, añadir al álbum y verificar
                var byStem: [String: (id: Int, filename: String, variantIDs: [Int])] = [:]
                for d in details { byStem[(d.filename as NSString).deletingPathExtension.lowercased()] = d }
                var matched: [(index: Int, variantIDs: [Int])] = []
                for index in batch {
                    let stem = (jobs[index].photo.filename as NSString).deletingPathExtension.lowercased()
                    if let d = byStem[stem] {
                        matched.append((index, d.variantIDs))
                    } else {
                        update(index, .failed(String(localized: "Not found in the destination catalog after import", comment: "Error de traslado")))
                    }
                }
                try driver.addToAlbum(document: destination, path: path, variantIDs: matched.flatMap(\.variantIDs))
                let readBack = try driver.readBack(document: destination, variantIDs: matched.map { $0.variantIDs[0] })
                let readByID = Dictionary(uniqueKeysWithValues: readBack.map { ($0.id, $0) })
                for (index, variantIDs) in matched {
                    let photo = jobs[index].photo
                    if let r = readByID[variantIDs[0]], Self.matches(photo, r) {
                        update(index, .done)
                    } else {
                        update(index, .verificationFailed)
                    }
                    completed += 1
                }
                events(.progress(completed: completed, total: total, bytesDone: 0, bytesTransferred: 0, current: album.name))
                try? FileManager.default.removeItem(at: folder)
            }
        }

        let success = jobs.filter { $0.status.isSuccess }.count
        let reportURL = try? writeReport(jobs)
        if let interruption {
            log(String(localized: "Export interrupted: \(interruption.message)", comment: "Línea de registro"))
        } else {
            log(String(localized: "Finished: \(success) of \(jobs.count) photos exported correctly.", comment: "Línea de registro"))
        }
        return (jobs, ExportSummary(successCount: success, totalCount: jobs.count, reportURL: reportURL, bytesTransferred: 0, interruption: interruption))
    }

    /// Rating, color y keywords releídos del destino coinciden con el origen.
    static func matches(_ photo: Photo, _ read: CaptureOneDriver.VariantReadBack) -> Bool {
        if let rating = photo.rating, rating != read.rating { return false }
        if let color = photo.colorTag, color.rawValue != read.colorTag { return false }
        return Set(photo.keywords.map { $0.lowercased() }) == Set(read.keywords.map { $0.lowercased() })
    }

    // MARK: - Esperas

    /// La exportación es un trabajo en cola: se espera a que existan todos los ficheros y
    /// sus tamaños dejen de cambiar.
    private func waitForFiles(_ names: [String], in folder: URL, timeout: TimeInterval = 1800) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastSizes: [String: Int64] = [:]
        var stableRounds = 0
        while Date() < deadline {
            if cancellation.isCancelled { throw CaptureOneError.timeout(String(localized: "Cancelled by user", comment: "Motivo de interrupción")) }
            let sizes = Dictionary(uniqueKeysWithValues: names.map { ($0, ExportPlanner.fileSize(folder.appendingPathComponent($0))) })
            let allPresent = names.allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
            if allPresent && sizes == lastSizes {
                stableRounds += 1
                if stableRounds >= 2 { return }
            } else {
                stableRounds = 0
            }
            lastSizes = sizes
            Thread.sleep(forTimeInterval: 2)
        }
        let missing = names.filter { !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
        throw CaptureOneError.timeout(String(localized: "export of \(missing.count) files (e.g. \(missing.first ?? ""))", comment: "Detalle de espera agotada"))
    }

    private func waitForImport(document: String, before: Int, expected: Int, timeout: TimeInterval = 1800) throws -> Set<Int> {
        let deadline = Date().addingTimeInterval(timeout)
        var lastCount = -1
        var stableRounds = 0
        while Date() < deadline {
            let count = try driver.imageCount(document: document)
            if count >= before + expected { return try driver.imageIDs(document: document) }
            // Si el recuento deja de crecer (duplicados descartados), aceptar lo que haya.
            if count == lastCount { stableRounds += 1 } else { stableRounds = 0 }
            if stableRounds >= 10, count > before { return try driver.imageIDs(document: document) }
            lastCount = count
            Thread.sleep(forTimeInterval: 3)
        }
        throw CaptureOneError.timeout(String(localized: "import into \(document)", comment: "Detalle de espera agotada"))
    }

    private func writeReport(_ jobs: [ExportJob]) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let url = destinationCatalogURL.deletingLastPathComponent().appendingPathComponent("AlbumExport_transfer_\(formatter.string(from: Date())).csv")
        func cell(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = ["album,file,rating,color,keywords,status"]
        for job in jobs {
            lines.append([job.album.path, job.photo.filename, job.photo.rating.map(String.init) ?? "",
                          job.photo.colorTag?.xmpLabel ?? "", job.photo.keywords.joined(separator: "; "), job.status.label].map(cell).joined(separator: ","))
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

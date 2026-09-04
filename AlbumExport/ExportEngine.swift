import Foundation

/// Sucesos que emite el motor mientras exporta, para actualizar la interfaz.
enum ExportEvent: Sendable {
    case progress(completed: Int, total: Int, current: String)
    case log(String)
}

/// Ejecuta un plan: copia (o mueve) los ficheros, escribe los metadatos y genera el informe.
struct ExportEngine {
    let catalog: CatalogReader
    let destination: URL
    let options: ExportOptions
    let writer: ExifToolWriter?

    /// Tamaño de lote para exiftool: limita la longitud del fichero de argumentos y da progreso.
    private static let metadataBatchSize = 40

    func run(plan: ExportPlan, events: @escaping @Sendable (ExportEvent) -> Void) throws -> (jobs: [ExportJob], summary: ExportSummary) {
        var jobs = plan.jobs
        let pendingIndices = jobs.indices.filter { jobs[$0].status == .pending }
        let total = pendingIndices.count
        var manifests: [URL: Manifest] = [:]
        var allocators: [URL: NameAllocator] = [:]

        // MARK: Copia o movimiento
        for (step, index) in pendingIndices.enumerated() {
            let job = jobs[index]
            guard let source = job.photo.source else { continue }
            let folder = ExportPlanner.folder(for: job.pattern, album: job.album, in: destination)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if manifests[folder] == nil {
                manifests[folder] = Manifest(folder: folder)
                allocators[folder] = NameAllocator(folder: folder)
            }
            events(.progress(completed: step, total: total, current: job.photo.filename))

            if let existing = manifests[folder]?.existingFile(for: job.photo.uuid) {
                jobs[index].destination = existing
                jobs[index].status = options.refreshExisting ? .copied : .alreadyExported
                allocators[folder]?.reserve(existing.lastPathComponent)
                continue
            }
            let target = allocators[folder]!.unique(job.photo.filename)
            do {
                if options.move {
                    try FileManager.default.moveItem(at: source, to: target)
                } else {
                    try FileManager.default.copyItem(at: source, to: target)
                    if ExportPlanner.fileSize(target) != ExportPlanner.fileSize(source) {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
                jobs[index].destination = target
                jobs[index].status = .copied
                manifests[folder]?.record(uuid: job.photo.uuid, filename: target.lastPathComponent)
                if options.adjustmentsJSON, let variant = job.photo.variantID {
                    let json = try catalog.adjustmentsJSON(variantID: variant)
                    try json.write(to: target.appendingPathExtension("captureone.json"))
                }
            } catch {
                jobs[index].status = .failed(error.localizedDescription)
                events(.log(String(localized: "Failed to copy \(job.photo.filename): \(error.localizedDescription)", comment: "Línea de registro")))
            }
        }
        for manifest in manifests.values {
            try manifest.save()
        }
        events(.progress(completed: total, total: total, current: ""))

        // MARK: Metadatos
        if options.writeMetadata, let writer {
            let targets = jobs.indices.filter { jobs[$0].status == .copied }
            let writable = targets.filter { ExifToolWriter.supports(jobs[$0].destination!) }
            for index in targets where !ExifToolWriter.supports(jobs[index].destination!) {
                jobs[index].status = .doneWithoutMetadata
            }
            events(.log(String(localized: "Writing metadata to \(writable.count) files with exiftool…", comment: "Línea de registro")))
            var written = 0
            for batch in stride(from: 0, to: writable.count, by: Self.metadataBatchSize).map({ Array(writable[$0..<min($0 + Self.metadataBatchSize, writable.count)]) }) {
                let errors = try writer.write(batch.map { (jobs[$0].photo, jobs[$0].destination!) })
                let readBack = try writer.readBack(batch.map { jobs[$0].destination! })
                for index in batch {
                    let path = jobs[index].destination!.path
                    if let error = errors[path] {
                        jobs[index].status = .failed(error)
                    } else if let read = readBack[path], ExifToolWriter.matches(jobs[index].photo, read) {
                        jobs[index].status = .done
                    } else {
                        jobs[index].status = .verificationFailed
                    }
                }
                written += batch.count
                events(.progress(completed: written, total: writable.count, current: String(localized: "Metadata", comment: "Fase de progreso")))
            }
        } else {
            for index in jobs.indices where jobs[index].status == .copied {
                jobs[index].status = .doneWithoutMetadata
            }
        }

        // MARK: Informe
        let reportURL = try writeReport(jobs)
        let success = jobs.filter { $0.status.isSuccess }.count
        events(.log(String(localized: "Finished: \(success) of \(jobs.count) photos exported correctly.", comment: "Línea de registro")))
        return (jobs, ExportSummary(successCount: success, totalCount: jobs.count, reportURL: reportURL))
    }

    private func writeReport(_ jobs: [ExportJob]) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let url = destination.appendingPathComponent("AlbumExport_\(formatter.string(from: Date())).csv")
        func cell(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = ["pattern,album,source,destination,rating,color,keywords,status"]
        for job in jobs {
            lines.append([
                job.pattern, job.album.path, job.photo.source?.path ?? "", job.destination?.path ?? "",
                job.photo.rating.map(String.init) ?? "", job.photo.colorTag?.xmpLabel ?? "",
                job.photo.keywords.joined(separator: "; "), job.status.label,
            ].map(cell).joined(separator: ","))
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

/// Serializa el acceso al catálogo (la conexión SQLite no es segura entre hilos) y saca el
/// trabajo pesado del hilo principal.
actor CatalogWorker {
    let reader: CatalogReader

    init(reader: CatalogReader) {
        self.reader = reader
    }

    func albums() throws -> [Album] {
        try reader.albums()
    }

    func plan(patterns: [String], selectedAlbumIDs: Set<Int>, albums: [Album], options: ExportOptions) throws -> ExportPlan {
        try ExportPlanner.plan(patterns: patterns, selectedAlbumIDs: selectedAlbumIDs, albums: albums, catalog: reader, options: options)
    }

    func export(plan: ExportPlan, destination: URL, options: ExportOptions, writer: ExifToolWriter?,
                events: @escaping @Sendable (ExportEvent) -> Void) throws -> (jobs: [ExportJob], summary: ExportSummary) {
        try ExportEngine(catalog: reader, destination: destination, options: options, writer: writer).run(plan: plan, events: events)
    }
}

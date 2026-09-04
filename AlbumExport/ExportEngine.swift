import Foundation

/// Sucesos que emite el motor mientras exporta, para actualizar la interfaz.
enum ExportEvent: Sendable {
    /// `bytesTransferred` cuenta solo los bytes realmente copiados en esta ejecución
    /// (sirve para medir la velocidad); `bytesDone` incluye también lo que ya estaba hecho.
    case progress(completed: Int, total: Int, bytesDone: Int64, bytesTransferred: Int64, current: String)
    case log(String)
    /// Cambio de estado de una foto, para que la tabla se actualice mientras se exporta.
    case status(jobID: Int, status: JobStatus, destination: URL?)
}

/// Motivo por el que una exportación se detuvo antes de terminar. El estado ya hecho
/// queda registrado en los manifiestos y se retoma al volver a exportar.
enum ExportInterruption: Equatable, Sendable {
    case cancelled
    case destinationUnavailable(String)

    var message: String {
        switch self {
        case .cancelled:
            String(localized: "Cancelled by user", comment: "Motivo de interrupción")
        case .destinationUnavailable(let path):
            String(localized: "Destination is no longer reachable: \(path)", comment: "Motivo de interrupción")
        }
    }
}

/// Errores propios del motor, con detalle suficiente para diagnosticar.
enum ExportError: Error, LocalizedError {
    case sizeMismatch(expected: Int64, actual: Int64)

    var errorDescription: String? {
        switch self {
        case .sizeMismatch(let expected, let actual):
            String(localized: "Size mismatch after copy: \(actual.formatted(.byteCount(style: .file))) instead of \(expected.formatted(.byteCount(style: .file)))",
                   comment: "Error de copia con tamaños")
        }
    }
}

/// Señal de cancelación compartida entre la interfaz y el motor.
final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() { lock.withLock { cancelled = true } }
}

/// Ejecuta un plan: copia (o mueve) los ficheros, escribe los metadatos y genera el informe.
///
/// Diseñado para sobrevivir a cortes (NAS, red, cierre de la app): trabaja por lotes,
/// copia a un nombre temporal y renombra al terminar, guarda el manifiesto de cada
/// carpeta tras cada lote y anota por foto si los metadatos ya se escribieron. Al
/// relanzar, lo hecho se conserva y solo se completa lo que falta.
///
/// Si el destino es un volumen de red y se copia (no se mueve), cada lote se prepara en
/// disco local (copia + XMP) y se sube una sola vez; así exiftool no reescribe ficheros
/// de decenas de MB a través de la red.
struct ExportEngine {
    let catalog: CatalogReader
    let destination: URL
    let options: ExportOptions
    let writer: ExifToolWriter?
    let cancellation: CancellationToken

    /// Tamaño de lote: acota la pérdida ante un corte y la longitud del argfile de exiftool.
    static let batchSize = 40
    /// Fallos de copia seguidos a partir de los cuales se da el destino por inaccesible.
    static let maxConsecutiveFailures = 3

    /// `true` si el destino está en un volumen que no es local (NAS, SMB, AFP).
    static func isNetworkVolume(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey])
        return values?.volumeIsLocal == false
    }

    /// Estado de trabajo de una foto dentro de un lote.
    private struct Work {
        let index: Int
        let folder: URL
        var workURL: URL          // donde se escriben los metadatos
        var finalURL: URL         // nombre definitivo en el destino
        var needsUpload: Bool     // workURL está en la zona local de preparación
        var bytes: Int64
    }

    func run(plan: ExportPlan, events: @escaping @Sendable (ExportEvent) -> Void) throws -> (jobs: [ExportJob], summary: ExportSummary) {
        var jobs = plan.jobs
        let pending = jobs.indices.filter { jobs[$0].status == .pending }
        let total = pending.count
        var manifests: [URL: Manifest] = [:]
        var allocators: [URL: NameAllocator] = [:]
        var completed = 0
        var bytesDone: Int64 = 0
        var bytesTransferred: Int64 = 0
        var interruption: ExportInterruption?
        // Un NAS caído puede seguir "existiendo" como punto de montaje: varios fallos seguidos
        // de copia se tratan como destino inaccesible en vez de fallar foto a foto hasta el final.
        var consecutiveFailures = 0

        func noteFailure() -> Bool {
            consecutiveFailures += 1
            return consecutiveFailures >= Self.maxConsecutiveFailures || !FileManager.default.fileExists(atPath: destination.path)
        }

        // Zona local de preparación: solo al copiar hacia un volumen de red. Al mover no se
        // usa, para que un fallo a medias nunca deje originales en una carpeta temporal.
        let staging: URL? = (!options.move && Self.isNetworkVolume(destination)) ? makeStagingDirectory() : nil
        defer { if let staging { try? FileManager.default.removeItem(at: staging) } }
        if staging != nil {
            events(.log(String(localized: "Network destination: each batch is prepared locally and uploaded once.", comment: "Línea de registro")))
        }

        func update(_ index: Int, _ status: JobStatus) {
            jobs[index].status = status
            events(.status(jobID: jobs[index].id, status: status, destination: jobs[index].destination))
        }

        func progress(_ current: String) {
            events(.progress(completed: completed, total: total, bytesDone: bytesDone, bytesTransferred: bytesTransferred, current: current))
        }

        func prepare(folder: URL) throws {
            guard manifests[folder] == nil else { return }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            Manifest.removePartialFiles(in: folder)
            manifests[folder] = Manifest(folder: folder)
            allocators[folder] = NameAllocator(folder: folder)
        }

        func saveManifests() {
            for manifest in manifests.values { try? manifest.save() }
        }

        let batches = stride(from: 0, to: pending.count, by: Self.batchSize).map { Array(pending[$0..<min($0 + Self.batchSize, pending.count)]) }
        batches: for batch in batches {
            var works: [Work] = []

            // MARK: Fase 1: obtener la copia de trabajo de cada foto del lote
            for index in batch {
                if cancellation.isCancelled { interruption = .cancelled; break }
                let job = jobs[index]
                guard let source = job.photo.source else { continue }
                let size = ExportPlanner.fileSize(source)
                let folder = ExportPlanner.folder(for: job.pattern, album: job.album, in: destination)
                do {
                    try prepare(folder: folder)
                } catch {
                    interruption = .destinationUnavailable(destination.path)
                    break
                }
                progress(job.photo.filename)

                if let existing = manifests[folder]?.existingFile(for: job.photo.uuid, expectedSize: size) {
                    jobs[index].destination = existing.url
                    allocators[folder]?.reserve(existing.url.lastPathComponent)
                    completed += 1
                    bytesDone += size
                    if existing.metadataDone && !options.refreshExisting {
                        update(index, .alreadyExported)
                    } else {
                        // Metadatos pendientes (corte anterior) o refresco: se escriben sobre el fichero ya subido.
                        update(index, .copied)
                        works.append(Work(index: index, folder: folder, workURL: existing.url, finalURL: existing.url, needsUpload: false, bytes: 0))
                    }
                    continue
                }

                // Fichero con el mismo nombre y tamaño ya presente pero sin registrar (copia manual
                // o versión anterior de la app): se adopta en vez de duplicarlo con sufijo.
                let sameName = folder.appendingPathComponent(job.photo.filename)
                if manifests[folder]?.isUnclaimed(filename: job.photo.filename) == true,
                   FileManager.default.fileExists(atPath: sameName.path), ExportPlanner.fileSize(sameName) == size {
                    jobs[index].destination = sameName
                    update(index, .copied)
                    allocators[folder]?.reserve(job.photo.filename)
                    manifests[folder]?.record(uuid: job.photo.uuid, filename: job.photo.filename, metadataDone: false)
                    completed += 1
                    bytesDone += size
                    works.append(Work(index: index, folder: folder, workURL: sameName, finalURL: sameName, needsUpload: false, bytes: 0))
                    continue
                }

                let target = allocators[folder]!.unique(job.photo.filename)
                let workURL = staging.map { $0.appendingPathComponent("\(job.photo.uuid)-\(target.lastPathComponent)") }
                    ?? target.deletingLastPathComponent().appendingPathComponent(Manifest.partialPrefix + target.lastPathComponent)
                do {
                    try transfer(from: source, to: workURL)
                    consecutiveFailures = 0
                    jobs[index].destination = target
                    update(index, .copied)
                    works.append(Work(index: index, folder: folder, workURL: workURL, finalURL: target, needsUpload: staging != nil, bytes: size))
                    if staging == nil {
                        completed += 1
                        bytesDone += size
                        bytesTransferred += size
                    }
                    if options.adjustmentsJSON, let variant = job.photo.variantID {
                        try catalog.adjustmentsJSON(variantID: variant).write(to: workURL.appendingPathExtension("captureone.json"))
                    }
                } catch {
                    update(index, .failed(error.localizedDescription))
                    events(.log(String(localized: "Failed to copy \(job.photo.filename): \(error.localizedDescription)", comment: "Línea de registro")))
                    if noteFailure() { interruption = .destinationUnavailable(destination.path); break }
                }
            }

            // MARK: Fase 2: metadatos sobre las copias de trabajo
            let copied = works.filter { jobs[$0.index].status == .copied }
            var metadataOK: Set<Int> = []
            if options.writeMetadata, let writer, interruption == nil {
                let writable = copied.filter { ExifToolWriter.supports($0.finalURL) }
                if !writable.isEmpty {
                    progress(String(localized: "Metadata", comment: "Fase de progreso"))
                    let errors = try writer.write(writable.map { (jobs[$0.index].photo, $0.workURL) })
                    let readBack = try writer.readBack(writable.map(\.workURL))
                    for work in writable {
                        let path = work.workURL.path
                        if let error = errors[path] {
                            update(work.index, .failed(error))
                        } else if let read = readBack[path], ExifToolWriter.matches(jobs[work.index].photo, read) {
                            metadataOK.insert(work.index)
                        } else {
                            update(work.index, .verificationFailed)
                        }
                    }
                }
                for work in copied where !ExifToolWriter.supports(work.finalURL) {
                    update(work.index, .doneWithoutMetadata)
                }
            } else if interruption == nil {
                for work in copied { update(work.index, .doneWithoutMetadata) }
            }

            // MARK: Fase 3: colocar cada fichero con su nombre definitivo y registrar el manifiesto
            for work in works {
                let job = jobs[work.index]
                let failed: Bool
                if case .failed = job.status { failed = true } else { failed = false }
                // Se descarta la copia de trabajo si falló o si, tras una interrupción, aún había que
                // subirla a un destino en red. Una copia local ya terminada se conserva aunque se
                // interrumpa: solo le faltarán los metadatos, que se escriben al reanudar.
                if failed || (interruption != nil && work.needsUpload) {
                    discard(work, sourceURL: job.photo.source)
                    if interruption != nil, job.status == .copied { update(work.index, .pending) }
                    continue
                }
                if interruption != nil, job.status == .copied, !options.writeMetadata {
                    update(work.index, .doneWithoutMetadata)
                }
                if work.workURL != work.finalURL {
                    do {
                        if work.needsUpload {
                            progress(job.photo.filename)
                            try upload(work)
                            completed += 1
                            bytesDone += work.bytes
                            bytesTransferred += work.bytes
                        } else {
                            try FileManager.default.moveItem(at: work.workURL, to: work.finalURL)
                            try? moveSidecar(from: work.workURL, to: work.finalURL)
                        }
                        consecutiveFailures = 0
                    } catch {
                        update(work.index, .failed(error.localizedDescription))
                        events(.log(String(localized: "Failed to copy \(job.photo.filename): \(error.localizedDescription)", comment: "Línea de registro")))
                        discard(work, sourceURL: job.photo.source)
                        if noteFailure() { interruption = .destinationUnavailable(destination.path) }
                        continue
                    }
                }
                let done = metadataOK.contains(work.index) || jobs[work.index].status == .doneWithoutMetadata
                if metadataOK.contains(work.index) { update(work.index, .done) }
                manifests[work.folder]?.record(uuid: job.photo.uuid, filename: work.finalURL.lastPathComponent, metadataDone: done)
            }
            saveManifests()
            if interruption != nil { break batches }
        }

        progress("")

        // MARK: Informe
        let reportURL = try? writeReport(jobs)
        let success = jobs.filter { $0.status.isSuccess }.count
        if let interruption {
            events(.log(String(localized: "Export interrupted: \(interruption.message)", comment: "Línea de registro")))
        } else {
            events(.log(String(localized: "Finished: \(success) of \(jobs.count) photos exported correctly.", comment: "Línea de registro")))
        }
        return (jobs, ExportSummary(successCount: success, totalCount: jobs.count, reportURL: reportURL,
                                    bytesTransferred: bytesTransferred, interruption: interruption))
    }

    // MARK: - Transferencias

    private static let stagingPrefix = "AlbumExport-staging-"

    private func makeStagingDirectory() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(Self.stagingPrefix + UUID().uuidString, isDirectory: true)
        return (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) != nil ? url : nil
    }

    /// Borra zonas de preparación de ejecuciones anteriores que no llegaron a limpiarse
    /// (cierre forzado, caída). Se llama al arrancar la app; solo contienen copias, nunca originales.
    static func removeOrphanStagingDirectories() {
        let temp = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? []
        for name in names where name.hasPrefix(stagingPrefix) {
            try? FileManager.default.removeItem(at: temp.appendingPathComponent(name))
        }
    }

    /// Copia (o mueve) comprobando el tamaño al terminar.
    private func transfer(from source: URL, to target: URL) throws {
        try? FileManager.default.removeItem(at: target)
        let expected = ExportPlanner.fileSize(source)
        do {
            if options.move {
                try FileManager.default.moveItem(at: source, to: target)
            } else {
                try FileManager.default.copyItem(at: source, to: target)
            }
            let actual = ExportPlanner.fileSize(target)
            guard actual == expected else { throw ExportError.sizeMismatch(expected: expected, actual: actual) }
        } catch {
            if options.move, FileManager.default.fileExists(atPath: target.path), !FileManager.default.fileExists(atPath: source.path) {
                try? FileManager.default.moveItem(at: target, to: source)
            } else {
                try? FileManager.default.removeItem(at: target)
            }
            throw error
        }
    }

    /// Sube una copia preparada en local: primero con nombre parcial, después renombrado.
    private func upload(_ work: Work) throws {
        let partial = work.finalURL.deletingLastPathComponent().appendingPathComponent(Manifest.partialPrefix + work.finalURL.lastPathComponent)
        try? FileManager.default.removeItem(at: partial)
        do {
            try FileManager.default.copyItem(at: work.workURL, to: partial)
            let expected = ExportPlanner.fileSize(work.workURL)
            let actual = ExportPlanner.fileSize(partial)
            guard actual == expected else { throw ExportError.sizeMismatch(expected: expected, actual: actual) }
            try FileManager.default.moveItem(at: partial, to: work.finalURL)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        try? moveSidecar(from: work.workURL, to: work.finalURL)
        try? FileManager.default.removeItem(at: work.workURL)
    }

    private func moveSidecar(from work: URL, to final: URL) throws {
        let sidecar = work.appendingPathExtension("captureone.json")
        guard FileManager.default.fileExists(atPath: sidecar.path) else { return }
        let target = final.appendingPathExtension("captureone.json")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: sidecar, to: target)
    }

    private func discard(_ work: Work, sourceURL: URL?) {
        guard work.workURL != work.finalURL else { return }
        if options.move, let sourceURL, !FileManager.default.fileExists(atPath: sourceURL.path) {
            try? FileManager.default.moveItem(at: work.workURL, to: sourceURL)
        } else {
            try? FileManager.default.removeItem(at: work.workURL)
        }
        try? FileManager.default.removeItem(at: work.workURL.appendingPathExtension("captureone.json"))
    }

    // MARK: - Informe

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

    func verify() throws -> VerifyResult {
        try CatalogVerifier.scan(catalog: reader)
    }

    func moveOrphans(_ orphans: [OrphanFile], to folder: URL) -> [String: String] {
        CatalogVerifier.moveOrphans(orphans, to: folder)
    }

    func plan(patterns: [String], selectedAlbumIDs: Set<Int>, albums: [Album], options: ExportOptions, destination: URL?) throws -> ExportPlan {
        try ExportPlanner.plan(patterns: patterns, selectedAlbumIDs: selectedAlbumIDs, albums: albums, catalog: reader, options: options, destination: destination)
    }

    func export(plan: ExportPlan, destination: URL, options: ExportOptions, writer: ExifToolWriter?, cancellation: CancellationToken,
                events: @escaping @Sendable (ExportEvent) -> Void) throws -> (jobs: [ExportJob], summary: ExportSummary) {
        try ExportEngine(catalog: reader, destination: destination, options: options, writer: writer, cancellation: cancellation)
            .run(plan: plan, events: events)
    }
}

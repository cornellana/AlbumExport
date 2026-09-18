import Foundation
import ImageIO

/// Fichero presente en `Originals/` del bundle que ningún registro del índice referencia.
struct OrphanFile: Identifiable, Hashable, Sendable {
    /// Ruta relativa al bundle (p. ej. `Originals/2026/01/26/1518/_AM21178.ARW`).
    let relativePath: String
    let url: URL
    let size: Int64
    /// Hora de captura EXIF del fichero, para compararlo con el índice y proponer álbum.
    var captureDate: Date? = nil
    /// El índice ya tiene esta foto (mismo nombre y hora de captura): el fichero sobra.
    var copyOfIndexed = false
    /// Álbum de usuario donde está la foto indexada de la que este fichero es copia.
    var indexedAlbum: String? = nil
    /// Otra copia huérfana de una foto nueva que ya figura antes en la lista.
    var repeatedOrphan = false
    /// Álbum al que probablemente pertenece una foto que no está en el catálogo.
    var suggestion: AlbumSuggestion? = nil
    var id: String { relativePath }
    var filename: String { (relativePath as NSString).lastPathComponent }
    /// Tipos que Capture One sabe importar; el resto (bases de datos, laterales de otras apps) no.
    var isImportable: Bool { Self.importableExtensions.contains((relativePath as NSString).pathExtension.lowercased()) }
    /// Foto que no está en el catálogo y merece importarse.
    var isRecoverable: Bool { !copyOfIndexed && !repeatedOrphan && isImportable }
    static let importableExtensions: Set<String> = ["arw", "dng", "tif", "tiff", "jpg", "jpeg", "png", "heic", "heif", "cr2", "cr3", "nef", "raf", "orf", "rw2", "eip", "psd"]
}

/// Imagen del índice cuyo fichero no existe en la ruta esperada (offline).
struct MissingFile: Identifiable, Hashable, Sendable {
    let imageID: Int
    let filename: String
    let expectedPath: String
    /// Tamaño registrado en el índice (`ZFILE_SIZE`), para validar candidatos.
    let size: Int64?
    /// Fichero encontrado en disco con el mismo nombre (y tamaño, si se conoce).
    var candidate: URL?
    /// El candidato es un huérfano dentro del propio bundle: restaurar lo mueve en vez de copiarlo.
    var candidateIsOrphan = false
    /// Otra entrada del índice con el mismo nombre cuyo fichero sí existe: la foto ya está en el
    /// catálogo por otra vía (importación duplicada); este registro perdido sobra.
    var alsoIndexedAt: String?
    /// Fecha de captura registrada en el índice (`ZEXP_DATE`: hora local de cámara tratada como UTC).
    var captureDate: Date?
    /// El candidato es la misma toma pero no mide igual que el registro (p. ej. el original de
    /// la tarjeta, sin los metadatos que otra app incrustó después en la copia importada).
    var candidateSizeDiffers = false
    var id: Int { imageID }
}

/// Imagen del índice que no pertenece a ningún álbum de usuario.
struct UnfiledImage: Identifiable, Hashable, Sendable {
    let imageID: Int
    let filename: String
    let path: String
    /// Álbum que ya contiene otra foto con el mismo nombre de fichero: probable duplicado.
    let duplicateInAlbum: String?
    /// Fecha de captura registrada en el índice (`ZEXP_DATE`).
    var captureDate: Date? = nil
    /// Álbum al que probablemente pertenece, por hora de captura y secuencia del nombre.
    var suggestion: AlbumSuggestion? = nil
    var id: Int { imageID }
}

/// Cómo se ha identificado un fichero candidato como el original de una entrada perdida.
enum CandidateMatch: Equatable, Sendable {
    /// Mismo nombre y mismo tamaño que el registrado.
    case exact
    /// Mismo nombre, tamaño muy próximo y mismo instante de captura EXIF.
    case sameShot
}

/// Recuento de una búsqueda de perdidos, para que el usuario vea que se recorrió todo.
struct SearchStats: Sendable, Equatable {
    var files = 0
    var folders = 0
    var unreadable = 0
}

/// Resultado de la verificación de un catálogo.
struct VerifyResult: Sendable {
    var filesOnDisk = 0
    var referenced = 0
    var orphans: [OrphanFile] = []
    var missing: [MissingFile] = []
    var unfiled: [UnfiledImage] = []
    var orphanBytes: Int64 { orphans.reduce(0) { $0 + $1.size } }
    /// Huérfanos que son fotos ausentes del catálogo (una por foto): candidatos a importar.
    var recoverableOrphans: [OrphanFile] { orphans.filter(\.isRecoverable) }
    var orphanCopies: Int { orphans.filter { $0.copyOfIndexed || $0.repeatedOrphan }.count }
    var foundCount: Int { missing.filter { $0.candidate != nil }.count }
    /// Sin álbum y sin otra foto del mismo nombre ya clasificada: candidatas al álbum "Sin clasificar".
    var unfiledToFile: [UnfiledImage] { unfiled.filter { $0.duplicateInAlbum == nil } }
    var unfiledDuplicates: Int { unfiled.count - unfiledToFile.count }
    /// Candidatas para las que se ha deducido un álbum probable.
    var unfiledWithSuggestion: Int { unfiledToFile.filter { $0.suggestion != nil }.count }
    /// Álbumes distintos propuestos.
    var suggestedAlbumCount: Int { Set(unfiledToFile.compactMap { $0.suggestion?.album }).count }
}

/// Compara los ficheros de `Originals/` con el índice del catálogo.
///
/// Solo lee el catálogo (vía la copia temporal de `CatalogReader`). Mover huérfanos y
/// restaurar perdidos son las únicas operaciones que tocan el bundle: la primera solo
/// afecta a ficheros que el índice no conoce; la segunda solo crea ficheros que faltan.
enum CatalogVerifier {
    static let originalsFolder = "Originals"
    /// Ficheros laterales que acompañan a un original referenciado: no son huérfanos.
    static let companionExtensions: Set<String> = ["xmp", "cos", "comask", "cop", "cof", "cot"]

    /// Avance de la verificación, para la interfaz.
    enum Progress: Sendable {
        case readingIndex
        case checkingMissing(done: Int, total: Int)
        case scanningFiles(count: Int)
        case readingOrphans(done: Int, total: Int)
    }

    static func scan(catalog: CatalogReader, cancellation: CancellationToken? = nil,
                     progress: (@Sendable (Progress) -> Void)? = nil) throws -> VerifyResult {
        var result = VerifyResult()
        progress?(.readingIndex)
        let referenced = try catalog.referencedRelativePaths()
        result.referenced = referenced.count
        // Carpeta + nombre sin extensión de cada original referenciado, para reconocer laterales.
        let referencedStems = Set(referenced.map { ($0 as NSString).deletingPathExtension })
        result.missing = try catalog.missingFiles(cancellation: cancellation) { done, total in progress?(.checkingMissing(done: done, total: total)) }
        if cancellation?.isCancelled == true { throw ExportInterruptionError.cancelled }
        result.unfiled = try catalog.imagesNotInAnyAlbum()

        let originals = catalog.rootURL.appendingPathComponent(originalsFolder, isDirectory: true)
        let rootPath = catalog.rootURL.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: originals, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else {
            return result
        }
        for case let url as URL in enumerator {
            if cancellation?.isCancelled == true { throw ExportInterruptionError.cancelled }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            result.filesOnDisk += 1
            if result.filesOnDisk % 500 == 0 { progress?(.scanningFiles(count: result.filesOnDisk)) }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(rootPath + "/") else { continue }
            let relative = String(full.dropFirst(rootPath.count + 1))
            // APFS no distingue mayúsculas: se compara en minúsculas.
            let lower = relative.lowercased()
            if referenced.contains(lower) { continue }
            if companionExtensions.contains((lower as NSString).pathExtension), referencedStems.contains((lower as NSString).deletingPathExtension) {
                continue   // lateral (.xmp, .cos…) de un original que sí está en el índice
            }
            result.orphans.append(OrphanFile(relativePath: relative, url: url, size: Int64(values?.fileSize ?? 0)))
        }
        result.orphans.sort { $0.relativePath < $1.relativePath }
        // Hora de captura de cada huérfano importable, para saber si el índice ya tiene esa foto.
        for index in result.orphans.indices where result.orphans[index].isImportable {
            if cancellation?.isCancelled == true { throw ExportInterruptionError.cancelled }
            if index % 25 == 0 { progress?(.readingOrphans(done: index, total: result.orphans.count)) }
            result.orphans[index].captureDate = captureDate(of: result.orphans[index].url)
        }
        result.orphans = try catalog.classify(result.orphans)
        result.missing = matchOrphans(result.missing, orphans: result.orphans)
        return result
    }

    /// Primera comprobación, sin salir del bundle: un perdido puede ser un huérfano que cambió
    /// de carpeta. Se emparejan por nombre y tamaño; cada huérfano se usa una sola vez.
    static func matchOrphans(_ missing: [MissingFile], orphans: [OrphanFile]) -> [MissingFile] {
        var available: [String: [OrphanFile]] = [:]
        for orphan in orphans {
            available[(orphan.relativePath as NSString).lastPathComponent.lowercased(), default: []].append(orphan)
        }
        return missing.map { item in
            guard item.candidate == nil else { return item }
            var updated = item
            let name = item.filename.lowercased()
            if let index = available[name]?.firstIndex(where: { orphan in
                match(item, candidateSize: orphan.size) { captureDate(of: orphan.url) } != nil
            }) {
                let orphan = available[name]!.remove(at: index)
                updated.candidateSizeDiffers = match(item, candidateSize: orphan.size) { captureDate(of: orphan.url) } == .sameShot
                updated.candidate = orphan.url
                updated.candidateIsOrphan = true
            }
            return updated
        }
    }

    // MARK: - Huérfanos

    /// Mueve los huérfanos a `folder` conservando su ruta relativa (`Originals/AAAA/MM/...`),
    /// para poder reimportarlos con la misma estructura.
    /// - Returns: Mensaje de error por ruta relativa; ausencia = movido.
    static func moveOrphans(_ orphans: [OrphanFile], to folder: URL) -> [String: String] {
        var errors: [String: String] = [:]
        for orphan in orphans {
            let target = folder.appendingPathComponent(orphan.relativePath)
            do {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: target.path) {
                    throw CocoaError(.fileWriteFileExists)
                }
                try FileManager.default.moveItem(at: orphan.url, to: target)
            } catch {
                errors[orphan.relativePath] = error.localizedDescription
            }
        }
        return errors
    }

    // MARK: - Perdidos

    /// Volúmenes montados donde buscar (excluye el sistema y los ocultos).
    static func mountedVolumes() -> [URL] {
        (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey], options: [.skipHiddenVolumes]) ?? [])
            .filter { !$0.path.hasPrefix("/System/") }
    }

    // MARK: Identidad del candidato

    /// Diferencia de tamaño admitida entre el registro y el candidato cuando la fecha de captura
    /// coincide: metadatos incrustados (XMP/IPTC) cambian el tamaño de un RAW en unos KB.
    static func sizeTolerance(for indexedSize: Int64) -> Int64 {
        max(262_144, indexedSize / 100)
    }

    /// Decide si un candidato es el original de una entrada perdida.
    ///
    /// El tamaño del índice solo coincide al byte en el 96 % de los ficheros: si otra aplicación
    /// incrustó metadatos en la copia importada, el original virgen (tarjeta, copia de seguridad)
    /// mide unos KB menos. En ese caso se exige el mismo instante de captura EXIF.
    /// - Parameter candidateDate: se evalúa solo si hace falta (leer EXIF cuesta tiempo).
    static func match(_ item: MissingFile, candidateSize: Int64, candidateDate: () -> Date?) -> CandidateMatch? {
        guard let indexed = item.size, indexed > 0 else { return .exact }   // índice sin tamaño: basta el nombre
        if indexed == candidateSize { return .exact }
        guard abs(indexed - candidateSize) <= sizeTolerance(for: indexed),
              let wanted = item.captureDate, let actual = candidateDate() else { return nil }
        // Se admite un desfase de horas enteras por zonas horarias mal interpretadas; los minutos
        // y segundos deben coincidir.
        let delta = abs(wanted.timeIntervalSince(actual))
        let remainder = delta.truncatingRemainder(dividingBy: 3600)
        let wholeHours = min(remainder, 3600 - remainder) <= 2 && delta <= 14 * 3600 + 2
        return wholeHours ? .sameShot : nil
    }

    private static let exifDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    /// Fecha de captura EXIF de un fichero (RAW incluidos), leída con ImageIO sin decodificar la imagen.
    /// Se interpreta como UTC, igual que la guarda el catálogo.
    static func captureDate(of url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let text = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String) ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)
        return text.flatMap { exifDateFormatter.date(from: $0) }
    }

    // MARK: Búsqueda

    /// Busca los ficheros perdidos por nombre en una carpeta o volumen, recorriendo todas sus
    /// subcarpetas (también otros catálogos), o, si `folder` es `nil`, en los volúmenes indexados
    /// por Spotlight. Un candidato vale si `match` lo identifica como el mismo original. Se ignora
    /// el propio catálogo y los perdidos ya resueltos con un huérfano.
    /// - Parameters:
    ///   - progress: ficheros recorridos hasta ahora.
    ///   - onFound: se llama en cuanto un perdido queda emparejado, con su `imageID` y el fichero.
    ///   - stats: recuento final de ficheros y carpetas recorridos y de carpetas ilegibles.
    static func search(_ missing: [MissingFile], in folder: URL?, catalogRoot: URL,
                       cancellation: CancellationToken? = nil, progress: (@Sendable (Int) -> Void)? = nil,
                       onFound: (@Sendable (Int, URL) -> Void)? = nil,
                       stats: ((SearchStats) -> Void)? = nil) -> [MissingFile] {
        guard !missing.isEmpty else { return missing }
        let pending = missing.filter { $0.candidate == nil }
        let wanted = Set(pending.map { $0.filename.lowercased() })
        var pendingByName: [String: [MissingFile]] = Dictionary(grouping: pending) { $0.filename.lowercased() }
        var resolved: [Int: (url: URL, kind: CandidateMatch)] = [:]
        let rootPath = catalogRoot.standardizedFileURL.path + "/"
        var counts = SearchStats()

        func consider(_ url: URL, name: String) {
            guard var items = pendingByName[name], !items.isEmpty else { return }
            let size = ExportPlanner.fileSize(url)
            var cachedDate: Date??
            let date: () -> Date? = {
                if cachedDate == nil { cachedDate = .some(captureDate(of: url)) }
                return cachedDate!
            }
            for (i, item) in items.enumerated() {
                if let kind = match(item, candidateSize: size, candidateDate: date) {
                    resolved[item.imageID] = (url, kind)
                    onFound?(item.imageID, url)
                    items.remove(at: i)
                    pendingByName[name] = items
                    return
                }
            }
        }

        if let folder {
            let enumerator = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) { _, _ in
                counts.unreadable += 1
                return true   // una carpeta ilegible no detiene el recorrido
            }
            while let url = enumerator?.nextObject() as? URL {
                if cancellation?.isCancelled == true { break }
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    counts.folders += 1
                    continue
                }
                counts.files += 1
                if counts.files % 1000 == 0 { progress?(counts.files) }
                let name = url.lastPathComponent.lowercased()
                guard wanted.contains(name), !url.standardizedFileURL.path.hasPrefix(rootPath) else { continue }
                consider(url, name: name)
            }
        } else {
            for name in wanted {
                if cancellation?.isCancelled == true { break }
                for path in spotlight(name: name) where !path.hasPrefix(rootPath) {
                    counts.files += 1
                    consider(URL(fileURLWithPath: path), name: name)
                }
            }
        }
        stats?(counts)
        return missing.map { item in
            guard item.candidate == nil, let hit = resolved[item.imageID] else { return item }
            var updated = item
            updated.candidate = hit.url
            updated.candidateIsOrphan = false
            updated.candidateSizeDiffers = hit.kind == .sameShot
            return updated
        }
    }

    private static func spotlight(name: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-name", name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
            .filter { ($0 as NSString).lastPathComponent.lowercased() == name }
    }

    /// Lleva cada candidato encontrado a la ruta que el catálogo espera, para que Capture One
    /// vuelva a ver el fichero: los huérfanos del propio bundle se mueven, el resto se copia.
    /// Nunca sobrescribe.
    /// - Returns: Mensaje de error por fichero; ausencia = restaurado.
    static func restore(_ missing: [MissingFile]) -> [String: String] {
        var errors: [String: String] = [:]
        for item in missing {
            guard let candidate = item.candidate else { continue }
            let target = URL(fileURLWithPath: item.expectedPath)
            do {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: target.path) { throw CocoaError(.fileWriteFileExists) }
                if item.candidateIsOrphan {
                    try FileManager.default.moveItem(at: candidate, to: target)
                } else {
                    try FileManager.default.copyItem(at: candidate, to: target)
                }
                // Integridad de la copia: contra el candidato, no contra el índice (que puede
                // diferir unos KB si la copia original llevaba metadatos incrustados).
                if !item.candidateIsOrphan {
                    let expected = ExportPlanner.fileSize(candidate)
                    let actual = ExportPlanner.fileSize(target)
                    if expected != actual {
                        try? FileManager.default.removeItem(at: target)
                        throw ExportError.sizeMismatch(expected: expected, actual: actual)
                    }
                }
            } catch {
                errors[item.expectedPath] = error.localizedDescription
            }
        }
        return errors
    }

    // MARK: - Informe

    static func writeReport(_ result: VerifyResult, catalogName: String, to url: URL) throws {
        func cell(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = ["kind,path,size,found_at_or_album"]
        for o in result.orphans { lines.append([cell(o.copyOfIndexed || o.repeatedOrphan ? "orphan_copy" : "orphan"), cell(o.relativePath), String(o.size), cell(o.indexedAlbum ?? o.suggestion?.album ?? "")].joined(separator: ",")) }
        for m in result.missing { lines.append([cell("missing"), cell(m.expectedPath), m.size.map(String.init) ?? "", cell(m.candidate?.path ?? "")].joined(separator: ",")) }
        for u in result.unfiled { lines.append([cell(u.duplicateInAlbum == nil ? "not_in_album" : "not_in_album_duplicate"), cell(u.path), "", cell(u.duplicateInAlbum ?? u.suggestion?.album ?? "")].joined(separator: ",")) }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}


/// Error que señala una verificación cancelada por el usuario.
enum ExportInterruptionError: Error, LocalizedError {
    case cancelled
    var errorDescription: String? { String(localized: "Cancelled by user", comment: "Motivo de interrupción") }
}

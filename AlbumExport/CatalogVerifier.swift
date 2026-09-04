import Foundation

/// Fichero presente en `Originals/` del bundle que ningún registro del índice referencia.
struct OrphanFile: Identifiable, Hashable, Sendable {
    /// Ruta relativa al bundle (p. ej. `Originals/2026/01/26/1518/_AM21178.ARW`).
    let relativePath: String
    let url: URL
    let size: Int64
    var id: String { relativePath }
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
    var id: Int { imageID }
}

/// Imagen del índice que no pertenece a ningún álbum de usuario.
struct UnfiledImage: Identifiable, Hashable, Sendable {
    let imageID: Int
    let filename: String
    let path: String
    var id: Int { imageID }
}

/// Resultado de la verificación de un catálogo.
struct VerifyResult: Sendable {
    var filesOnDisk = 0
    var referenced = 0
    var orphans: [OrphanFile] = []
    var missing: [MissingFile] = []
    var unfiled: [UnfiledImage] = []
    var orphanBytes: Int64 { orphans.reduce(0) { $0 + $1.size } }
    var foundCount: Int { missing.filter { $0.candidate != nil }.count }
}

/// Compara los ficheros de `Originals/` con el índice del catálogo.
///
/// Solo lee el catálogo (vía la copia temporal de `CatalogReader`). Mover huérfanos y
/// restaurar perdidos son las únicas operaciones que tocan el bundle: la primera solo
/// afecta a ficheros que el índice no conoce; la segunda solo crea ficheros que faltan.
enum CatalogVerifier {
    static let originalsFolder = "Originals"

    static func scan(catalog: CatalogReader) throws -> VerifyResult {
        var result = VerifyResult()
        let referenced = try catalog.referencedRelativePaths()
        result.referenced = referenced.count
        result.missing = try catalog.missingFiles()
        result.unfiled = try catalog.imagesNotInAnyAlbum()

        let originals = catalog.rootURL.appendingPathComponent(originalsFolder, isDirectory: true)
        let rootPath = catalog.rootURL.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: originals, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else {
            return result
        }
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            result.filesOnDisk += 1
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(rootPath + "/") else { continue }
            let relative = String(full.dropFirst(rootPath.count + 1))
            // APFS no distingue mayúsculas: se compara en minúsculas.
            if !referenced.contains(relative.lowercased()) {
                result.orphans.append(OrphanFile(relativePath: relative, url: url, size: Int64(values?.fileSize ?? 0)))
            }
        }
        result.orphans.sort { $0.relativePath < $1.relativePath }
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
                guard let size = item.size, size > 0 else { return true }
                return orphan.size == size
            }) {
                let orphan = available[name]!.remove(at: index)
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

    /// Busca los ficheros perdidos por nombre en una carpeta o volumen (recursivo) o, si
    /// `folder` es `nil`, en los volúmenes indexados por Spotlight. Un candidato solo vale si
    /// coincide el tamaño registrado (cuando se conoce). Se ignora el propio catálogo y los
    /// perdidos ya resueltos con un huérfano.
    static func search(_ missing: [MissingFile], in folder: URL?, catalogRoot: URL) -> [MissingFile] {
        guard !missing.isEmpty else { return missing }
        var index: [String: [URL]] = [:]   // nombre en minúsculas -> rutas encontradas
        let wanted = Set(missing.map { $0.filename.lowercased() })
        let rootPath = catalogRoot.standardizedFileURL.path + "/"
        if let folder {
            if let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                for case let url as URL in enumerator {
                    let name = url.lastPathComponent.lowercased()
                    guard wanted.contains(name), !url.standardizedFileURL.path.hasPrefix(rootPath) else { continue }
                    index[name, default: []].append(url)
                }
            }
        } else {
            for name in wanted {
                for path in spotlight(name: name) where !path.hasPrefix(rootPath) {
                    index[name, default: []].append(URL(fileURLWithPath: path))
                }
            }
        }
        return missing.map { item in
            guard item.candidate == nil else { return item }   // ya resuelto (p. ej. con un huérfano)
            var updated = item
            let candidates = index[item.filename.lowercased()] ?? []
            updated.candidate = candidates.first { candidate in
                guard let size = item.size, size > 0 else { return true }
                return ExportPlanner.fileSize(candidate) == size
            }
            updated.candidateIsOrphan = false
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
                if let size = item.size, size > 0, ExportPlanner.fileSize(target) != size {
                    try? FileManager.default.removeItem(at: target)
                    throw ExportError.sizeMismatch(expected: size, actual: ExportPlanner.fileSize(target))
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
        var lines = ["kind,path,size,found_at"]
        for o in result.orphans { lines.append([cell("orphan"), cell(o.relativePath), String(o.size), ""].joined(separator: ",")) }
        for m in result.missing { lines.append([cell("missing"), cell(m.expectedPath), m.size.map(String.init) ?? "", cell(m.candidate?.path ?? "")].joined(separator: ",")) }
        for u in result.unfiled { lines.append([cell("not_in_album"), cell(u.path), "", ""].joined(separator: ",")) }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

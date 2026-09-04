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
    let filename: String
    let expectedPath: String
    var id: String { expectedPath }
}

/// Resultado de la verificación de un catálogo.
struct VerifyResult: Sendable {
    var filesOnDisk = 0
    var referenced = 0
    var orphans: [OrphanFile] = []
    var missing: [MissingFile] = []
    var orphanBytes: Int64 { orphans.reduce(0) { $0 + $1.size } }
}

/// Compara los ficheros de `Originals/` con el índice del catálogo.
///
/// Solo lee el catálogo (vía la copia temporal de `CatalogReader`). Mover huérfanos es la
/// única operación que toca el bundle, y solo afecta a ficheros que el índice no conoce.
enum CatalogVerifier {
    static let originalsFolder = "Originals"

    static func scan(catalog: CatalogReader) throws -> VerifyResult {
        var result = VerifyResult()
        let referenced = try catalog.referencedRelativePaths()
        result.referenced = referenced.count
        result.missing = try catalog.missingFiles()

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
        return result
    }

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

    /// Informe CSV con huérfanos y ficheros ausentes.
    static func writeReport(_ result: VerifyResult, catalogName: String, to url: URL) throws {
        func cell(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = ["kind,path,size"]
        for o in result.orphans { lines.append([cell("orphan"), cell(o.relativePath), String(o.size)].joined(separator: ",")) }
        for m in result.missing { lines.append([cell("missing"), cell(m.expectedPath), ""].joined(separator: ",")) }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

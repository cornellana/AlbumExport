import AppKit
import Foundation

/// Error al automatizar Capture One.
enum CaptureOneError: Error, LocalizedError {
    case notInstalled
    case script(String)
    case timeout(String)
    case documentNotOpen(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            String(localized: "Capture One is not installed.", comment: "Error de automatización")
        case .script(let message):
            String(localized: "Capture One error: \(message)", comment: "Error de automatización")
        case .timeout(let what):
            String(localized: "Timed out waiting for Capture One: \(what)", comment: "Error de automatización")
        case .documentNotOpen(let name):
            String(localized: "Capture One did not open the catalog \(name).", comment: "Error de automatización")
        }
    }
}

/// Ejecuta AppleScript con `osascript` y devuelve el resultado como texto.
enum AppleScriptRunner {
    static func run(_ source: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-"]
        let input = Pipe(), output = Pipe(), error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        input.fileHandleForWriting.write(Data(source.utf8))
        try? input.fileHandleForWriting.close()
        var errorData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errorData = error.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        group.wait()
        let stdout = String(decoding: outputData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw CaptureOneError.script(stderr.isEmpty ? stdout : stderr)
        }
        return stdout
    }

    /// Escapa un texto para incrustarlo entre comillas en AppleScript.
    static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Lista de enteros en sintaxis AppleScript: `{1, 2, 3}`.
    static func list(_ ids: [Int]) -> String {
        "{" + ids.map(String.init).joined(separator: ", ") + "}"
    }
}

/// Operaciones de alto nivel sobre Capture One necesarias para trasladar álbumes.
///
/// Los identificadores `id` de imagen y variante en AppleScript coinciden con `Z_PK` de
/// `ZIMAGE` y `ZVARIANT` en la base de datos del catálogo (verificado en 16.8.5).
struct CaptureOneDriver {
    static let bundleIdentifier = "com.captureone.captureone16"
    static let appName = "Capture One"

    /// Nombre de documento con el que Capture One se refiere a un catálogo: el del bundle sin extensión.
    static func documentName(for catalogURL: URL) -> String {
        catalogURL.deletingPathExtension().lastPathComponent
    }

    /// Referencia AppleScript a una colección por su ruta "Grupo/Álbum", relativa a un documento.
    static func collectionReference(path: [String]) -> String {
        path.reversed().map { "collection \(AppleScriptRunner.quote($0))" }.joined(separator: " of ")
    }

    private func tell(_ body: String, timeout: Int = 120) throws -> String {
        try AppleScriptRunner.run("""
            with timeout of \(timeout) seconds
            tell application \(AppleScriptRunner.quote(Self.appName))
            \(body)
            end tell
            end timeout
            """)
    }

    // MARK: - Aplicación y documentos

    func launch() throws {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
        if running.isEmpty {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier)
                ?? NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: "/tmp/x.cocatalog")) else {
                throw CaptureOneError.notInstalled
            }
            let semaphore = DispatchSemaphore(value: 0)
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in semaphore.signal() }
            semaphore.wait()
            Thread.sleep(forTimeInterval: 8)
        }
    }

    func documentNames() throws -> [String] {
        let out = try tell("""
            set AppleScript's text item delimiters to linefeed
            return (name of every document) as text
            """, timeout: 30)
        return out.split(separator: "\n").map(String.init)
    }

    /// Abre el catálogo si no lo está y espera a que aparezca entre los documentos.
    func openCatalog(_ url: URL) throws {
        let name = Self.documentName(for: url)
        if try documentNames().contains(name) { return }
        _ = try tell("open (POSIX file \(AppleScriptRunner.quote(url.path)))", timeout: 180)
        for _ in 0..<60 {
            if try documentNames().contains(name) { return }
            Thread.sleep(forTimeInterval: 2)
        }
        throw CaptureOneError.documentNotOpen(name)
    }

    /// Crea un catálogo nuevo. Capture One lo crea en ~/Documents sin diálogo; después se
    /// cierra, se mueve a la carpeta elegida y se vuelve a abrir.
    func createCatalog(at url: URL) throws {
        let name = Self.documentName(for: url)
        let created = try tell("""
            set d to make new document with properties {kind:catalog, name:\(AppleScriptRunner.quote(name))}
            return POSIX path of (folder of d as alias)
            """, timeout: 120)
        let createdBundle = URL(fileURLWithPath: created).appendingPathComponent(name + ".cocatalog", isDirectory: true)
        if createdBundle.standardizedFileURL != url.standardizedFileURL {
            _ = try tell("close document \(AppleScriptRunner.quote(name))", timeout: 60)
            Thread.sleep(forTimeInterval: 2)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: createdBundle, to: url)
            try openCatalog(url)
        }
    }

    // MARK: - Exportación e importación

    /// Exporta los originales de las variantes a una carpeta (`[Image Name]` como nombre).
    /// Los elementos `variant id N` solo resuelven dentro de una colección concreta (los del
    /// documento son los de la colección activa), por eso se pasa la ruta del álbum.
    func exportOriginals(document: String, collectionPath: [String], variantIDs: [Int], to folder: URL, packed: Bool) throws {
        _ = try tell("""
            tell document \(AppleScriptRunner.quote(document))
            set col to \(Self.collectionReference(path: collectionPath))
            set vs to {}
            repeat with n in \(AppleScriptRunner.list(variantIDs))
            set end of vs to variant id n of col
            end repeat
            set destination folder of export original settings to (POSIX file \(AppleScriptRunner.quote(folder.path)))
            set sub folder of export original settings to ""
            set packed of export original settings to \(packed)
            set include adjustments of export original settings to true
            set include movies of export original settings to true
            set naming method of export original settings to text and tokens
            set naming format of export original settings to "[Image Name]"
            set notify of export original settings to false
            export originals it variants vs
            end tell
            """)
    }

    /// Importa una carpeta dentro del catálogo, con los ajustes existentes.
    func importFolder(document: String, folder: URL) throws {
        _ = try tell("""
            tell document \(AppleScriptRunner.quote(document))
            set destination collection of import settings to recent
            set destination type of import settings to inside catalog
            set include existing adjustments of import settings to true
            set exclude duplicates of import settings to false
            set include subfolders of import settings to false
            set import collection action of import settings to no action
            import source \(AppleScriptRunner.quote(folder.path))
            end tell
            """)
    }

    func imageCount(document: String) throws -> Int {
        Int(try tell("tell document \(AppleScriptRunner.quote(document)) to return count of images of collection \"All Images\"", timeout: 60)) ?? 0
    }

    func imageIDs(document: String) throws -> Set<Int> {
        let out = try tell("""
            tell document \(AppleScriptRunner.quote(document))
            set AppleScript's text item delimiters to linefeed
            return (id of every image of collection "All Images") as text
            end tell
            """, timeout: 120)
        return Set(out.split(separator: "\n").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
    }

    /// Identificador y nombre de fichero de todas las imágenes del catálogo (dos listas
    /// paralelas: una sola ida y vuelta aunque haya miles de imágenes).
    func allImageNames(document: String) throws -> [(id: Int, filename: String)] {
        let out = try tell("""
            tell document \(AppleScriptRunner.quote(document))
            set AppleScript's text item delimiters to linefeed
            set idText to (id of every image of collection "All Images") as text
            set nameText to (name of every image of collection "All Images") as text
            return idText & "\\n===\\n" & nameText
            end tell
            """, timeout: 300)
        let parts = out.components(separatedBy: "\n===\n")
        guard parts.count == 2 else { return [] }
        let ids = parts[0].split(separator: "\n").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let names = parts[1].split(separator: "\n").map(String.init)
        guard ids.count == names.count else { return [] }
        return Array(zip(ids, names))
    }

    /// Nombre de fichero y variantes de cada imagen: `[(imageID, filename, [variantID])]`.
    func imageDetails(document: String, imageIDs: [Int]) throws -> [(id: Int, filename: String, variantIDs: [Int])] {
        guard !imageIDs.isEmpty else { return [] }
        let out = try tell("""
            tell document \(AppleScriptRunner.quote(document))
            set outList to {}
            repeat with n in \(AppleScriptRunner.list(imageIDs))
            set im to image id n of collection "All Images"
            set AppleScript's text item delimiters to ","
            set vids to (id of every variant of im) as text
            set end of outList to (n as text) & tab & (name of im) & tab & vids
            end repeat
            set AppleScript's text item delimiters to linefeed
            return outList as text
            end tell
            """, timeout: 300)
        return out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 3, let id = Int(parts[0]) else { return nil }
            return (id, String(parts[1]), parts[2].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
        }
    }

    // MARK: - Álbumes

    /// Crea (si hace falta) la cadena de grupos y el álbum, y devuelve los nombres de las
    /// variantes que ya contiene.
    func ensureAlbum(document: String, path: [String]) throws -> [String] {
        guard let albumName = path.last else { return [] }
        var body = "set parentRef to it\n"
        for group in path.dropLast() {
            body += """
                if not (exists collection \(AppleScriptRunner.quote(group)) of parentRef) then make new collection at parentRef with properties {kind:group, name:\(AppleScriptRunner.quote(group))}
                set parentRef to collection \(AppleScriptRunner.quote(group)) of parentRef

                """
        }
        body += """
            if not (exists collection \(AppleScriptRunner.quote(albumName)) of parentRef) then make new collection at parentRef with properties {kind:album, name:\(AppleScriptRunner.quote(albumName))}
            set alb to collection \(AppleScriptRunner.quote(albumName)) of parentRef
            set AppleScript's text item delimiters to linefeed
            return (name of every variant of alb) as text
            """
        let out = try tell("tell document \(AppleScriptRunner.quote(document))\n\(body)\nend tell", timeout: 120)
        return out.split(separator: "\n").map(String.init)
    }

    func addToAlbum(document: String, path: [String], variantIDs: [Int]) throws {
        guard !variantIDs.isEmpty else { return }
        _ = try tell("""
            tell document \(AppleScriptRunner.quote(document))
            set alb to \(Self.collectionReference(path: path))
            set vs to {}
            repeat with n in \(AppleScriptRunner.list(variantIDs))
            set end of vs to variant id n of collection "All Images"
            end repeat
            add inside alb variants vs
            end tell
            """)
    }

    // MARK: - Verificación

    struct VariantReadBack {
        let id: Int
        let name: String
        let rating: Int
        let colorTag: Int
        let keywords: [String]
        let layerCount: Int
    }

    func readBack(document: String, variantIDs: [Int]) throws -> [VariantReadBack] {
        guard !variantIDs.isEmpty else { return [] }
        let out = try tell("""
            tell document \(AppleScriptRunner.quote(document))
            set outList to {}
            repeat with n in \(AppleScriptRunner.list(variantIDs))
            set v to variant id n of collection "All Images"
            set AppleScript's text item delimiters to "|"
            set kws to (name of every keyword of v) as text
            set end of outList to (n as text) & tab & (name of v) & tab & (rating of v) & tab & (color tag of v) & tab & kws & tab & (count of layers of v)
            end repeat
            set AppleScript's text item delimiters to linefeed
            return outList as text
            end tell
            """, timeout: 300)
        return out.split(separator: "\n").compactMap { line in
            let p = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard p.count >= 6, let id = Int(p[0]) else { return nil }
            let keywords = p[4].split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return VariantReadBack(id: id, name: p[1], rating: Int(p[2]) ?? 0, colorTag: Int(p[3]) ?? 0, keywords: keywords, layerCount: Int(p[5]) ?? 0)
        }
    }
}

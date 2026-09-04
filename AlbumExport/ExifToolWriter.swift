import Foundation

/// Localiza el ejecutable de exiftool: primero uno incluido en la app, después Homebrew y rutas habituales.
enum ExifToolLocator {
    static func find() -> URL? {
        var candidates: [URL] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("exiftool/exiftool") {
            candidates.append(bundled)
        }
        candidates += ["/opt/homebrew/bin/exiftool", "/usr/local/bin/exiftool", "/usr/bin/exiftool"].map { URL(fileURLWithPath: $0) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Versión instalada, o `nil` si no arranca.
    static func version(of url: URL) -> String? {
        let output = try? run(url, arguments: ["-ver"])
        return output?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func run(_ url: URL, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

/// Escribe los metadatos del catálogo en XMP (y en IPTC cuando ya existe) con exiftool.
///
/// Todo el lote se escribe con un único proceso mediante un fichero de argumentos y `-execute`.
struct ExifToolWriter {
    let executable: URL

    /// Extensiones a las que no se escribe XMP (vídeo y formatos raros).
    static let unsupportedExtensions: Set<String> = ["mp4", "mov", "avi", "m4v", "eic", "iff"]

    /// Columna de `ZVARIANTMETADATA` -> tag exiftool. Los tags `MWG:` escriben XMP y, si el
    /// fichero ya lleva IPTC (Photo Mechanic, escáner), también el campo IPTC equivalente.
    static let scalarTags: [(column: String, tag: String)] = [
        ("ZSTATUS_TITLE", "XMP-dc:Title"),
        ("ZCONTENT_HEADLINE", "XMP-photoshop:Headline"),
        ("ZCONTENT_DESCRIPTION", "MWG:Description"),
        ("ZCONTENT_DESCRIPTIONWRITER", "XMP-photoshop:CaptionWriter"),
        ("ZCONTENT_CATEGORY", "XMP-photoshop:Category"),
        ("ZIMAGE_INTELLECTUALGENRE", "XMP-iptcCore:IntellectualGenre"),
        ("ZIMAGE_LOCATION", "MWG:Location"),
        ("ZIMAGE_CITY", "MWG:City"),
        ("ZIMAGE_STATE", "MWG:State"),
        ("ZIMAGE_COUNTRY", "MWG:Country"),
        ("ZIMAGE_ISOCOUNTRYCODE", "XMP-iptcCore:CountryCode"),
        ("ZCONTACT_CREATOR", "MWG:Creator"),
        ("ZCONTACT_CREATORSTITLE", "XMP-photoshop:AuthorsPosition"),
        ("ZCONTACT_ADDRESS", "XMP-iptcCore:CreatorAddress"),
        ("ZCONTACT_CITY", "XMP-iptcCore:CreatorCity"),
        ("ZCONTACT_STATE_PROVINCE", "XMP-iptcCore:CreatorRegion"),
        ("ZCONTACT_POSTALCODE", "XMP-iptcCore:CreatorPostalCode"),
        ("ZCONTACT_COUNTRY", "XMP-iptcCore:CreatorCountry"),
        ("ZCONTACT_PHONES", "XMP-iptcCore:CreatorWorkTelephone"),
        ("ZCONTACT_EMAILS", "XMP-iptcCore:CreatorWorkEmail"),
        ("ZCONTACT_WEBSITES", "XMP-iptcCore:CreatorWorkURL"),
        ("ZSTATUS_COPYRIGHTNOTICE", "MWG:Copyright"),
        ("ZSTATUS_USAGETERMS", "XMP-xmpRights:UsageTerms"),
        ("ZSTATUS_PROVIDER", "XMP-photoshop:Credit"),
        ("ZSTATUS_SOURCE", "XMP-photoshop:Source"),
        ("ZSTATUS_INSTRUCTIONS", "XMP-photoshop:Instructions"),
        ("ZSTATUS_JOBIDENTIFIER", "XMP-photoshop:TransmissionReference"),
        ("ZGETTY_PARENTMEID", "XMP-getty:ParentMEID"),
        ("ZGETTY_ORIGINALFILENAME", "XMP-getty:OriginalFileName"),
        ("ZGETTY_PERSONALITY", "XMP-getty:Personality"),
    ]

    /// Columnas con listas separadas por coma -> tag de lista.
    static let listTags: [(column: String, tag: String)] = [
        ("ZCONTENT_SUPPLEMENTALCATEGORIES", "XMP-photoshop:SupplementalCategories"),
        ("ZCONTENT_SUBJECTCODE", "XMP-iptcCore:SubjectCode"),
        ("ZIMAGE_SCENE", "XMP-iptcCore:Scene"),
    ]

    /// Lo que se relee del fichero para verificar la escritura.
    struct ReadBack {
        let rating: Int?
        let label: String?
        let subject: [String]
    }

    static func supports(_ url: URL) -> Bool {
        !unsupportedExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - Argumentos

    /// Escapa un valor para el fichero de argumentos con `-E`: entidades HTML y saltos de línea.
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\r", with: "&#13;")
            .replacingOccurrences(of: "\n", with: "&#10;")
    }

    /// Varios `-TAG=valor` seguidos sustituyen la lista entera; `-TAG=` sola la borra.
    /// (`-TAG=` seguido de `-TAG+=valor` NO borra y duplica los valores existentes.)
    static func listArguments(tag: String, values: [String]) -> [String] {
        values.isEmpty ? ["-\(tag)="] : values.map { "-\(tag)=\(escape($0))" }
    }

    static func arguments(for photo: Photo) -> [String] {
        var args = ["-overwrite_original", "-P", "-E", "-m"]
        if let rating = photo.rating {
            args.append("-XMP-xmp:Rating=\(rating)")
        }
        if let color = photo.colorTag {
            args.append(color.xmpLabel.map { "-XMP-xmp:Label=\($0)" } ?? "-XMP-xmp:Label=")
        }
        args += listArguments(tag: "MWG:Keywords", values: photo.keywords)
        args += listArguments(tag: "XMP-lr:HierarchicalSubject", values: photo.hierarchicalKeywords)
        for (column, tag) in scalarTags {
            if let value = photo.fields[column] {
                args.append("-\(tag)=\(escape(value))")
            }
        }
        for (column, tag) in listTags {
            if let value = photo.fields[column] {
                let items = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                args += listArguments(tag: tag, values: items)
            }
        }
        return args
    }

    // MARK: - Escritura

    /// Escribe los metadatos de cada trabajo en su fichero de destino.
    /// - Returns: Mensaje de error por ruta de destino; ausencia = correcto.
    func write(_ jobs: [(photo: Photo, destination: URL)]) throws -> [String: String] {
        guard !jobs.isEmpty else { return [:] }
        var content = ""
        for job in jobs {
            content += Self.arguments(for: job.photo).joined(separator: "\n")
            content += "\n\(job.destination.path)\n-execute\n"
        }
        let argfile = try writeArgFile(content)
        defer { try? FileManager.default.removeItem(at: argfile) }
        let output = try ExifToolLocator.run(executable, arguments: ["-@", argfile.path])

        var errors: [String: String] = [:]
        for line in output.split(separator: "\n") where line.hasPrefix("Error") {
            // Formato de exiftool: "Error: <mensaje> - <ruta>"
            if let range = line.range(of: " - ", options: .backwards) {
                errors[String(line[range.upperBound...])] = String(line)
            }
        }
        return errors
    }

    /// Relee rating, etiqueta y keywords para comprobar la escritura.
    func readBack(_ urls: [URL]) throws -> [String: ReadBack] {
        guard !urls.isEmpty else { return [:] }
        let argfile = try writeArgFile(urls.map(\.path).joined(separator: "\n") + "\n")
        defer { try? FileManager.default.removeItem(at: argfile) }
        let output = try ExifToolLocator.run(executable, arguments: ["-j", "-XMP-xmp:Rating", "-XMP-xmp:Label", "-XMP-dc:Subject", "-@", argfile.path])
        guard let start = output.firstIndex(of: "["),
              let array = try? JSONSerialization.jsonObject(with: Data(output[start...].utf8)) as? [[String: Any]] else {
            return [:]
        }
        var result: [String: ReadBack] = [:]
        for entry in array {
            guard let path = entry["SourceFile"] as? String else { continue }
            let subject: [String]
            switch entry["Subject"] {
            case let s as String: subject = [s]
            case let list as [Any]: subject = list.map { String(describing: $0) }
            default: subject = []
            }
            let rating: Int?
            switch entry["Rating"] {
            case let n as NSNumber: rating = n.intValue
            case let s as String: rating = Int(s)
            default: rating = nil
            }
            result[path] = ReadBack(rating: rating, label: entry["Label"] as? String, subject: subject)
        }
        return result
    }

    /// `true` si lo releído coincide con lo que dice el catálogo.
    static func matches(_ photo: Photo, _ read: ReadBack) -> Bool {
        if let rating = photo.rating, read.rating != rating { return false }
        if let color = photo.colorTag, (read.label ?? "") != (color.xmpLabel ?? "") { return false }
        return read.subject == photo.keywords
    }

    private func writeArgFile(_ content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("albumexport-\(UUID().uuidString).args")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

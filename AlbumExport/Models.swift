import Foundation

// MARK: - Etiqueta de color

/// Etiqueta de color de Capture One, tal como se almacena en `ZCOLOR_TAG_INDEX`.
///
/// El orden 1...7 está verificado contra las cadenas del binario de Capture One 16.8.
enum ColorTag: Int, Codable, CaseIterable, Sendable {
    case none = 0
    case red, orange, yellow, green, blue, pink, purple

    /// Valor de `xmp:Label` que entienden Capture One, Lightroom y Photo Mechanic.
    /// `nil` para "sin etiqueta" (se borra el campo en el fichero).
    var xmpLabel: String? {
        switch self {
        case .none: nil
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .pink: "Pink"
        case .purple: "Purple"
        }
    }

    /// Nombre visible al usuario.
    var localizedName: String {
        switch self {
        case .none: String(localized: "No color", comment: "Etiqueta de color ausente")
        case .red: String(localized: "Red", comment: "Etiqueta de color")
        case .orange: String(localized: "Orange", comment: "Etiqueta de color")
        case .yellow: String(localized: "Yellow", comment: "Etiqueta de color")
        case .green: String(localized: "Green", comment: "Etiqueta de color")
        case .blue: String(localized: "Blue", comment: "Etiqueta de color")
        case .pink: String(localized: "Pink", comment: "Etiqueta de color")
        case .purple: String(localized: "Purple", comment: "Etiqueta de color")
        }
    }
}

// MARK: - Catálogo

/// Versión y formato del catálogo, leídos de `ZVERSIONINFO`.
struct CatalogVersion: Sendable {
    /// Versión de Capture One que escribió el catálogo por última vez (p. ej. "16.8.5.30 Pro Mac").
    let application: String
    /// Número de formato interno (p. ej. 160800). Cambia con las releases que migran el esquema.
    let format: Int
    /// Mayor formato con el que se ha validado esta app.
    static let highestTestedFormat = 160800
    /// Menor formato con el que se ha validado esta app.
    static let lowestTestedFormat = 1650

    var isNewerThanTested: Bool { format > Self.highestTestedFormat }
    var isOlderThanTested: Bool { format < Self.lowestTestedFormat }
}

/// Álbum (o smart album) del catálogo.
struct Album: Identifiable, Hashable, Sendable {
    /// `Z_PK` de `ZCOLLECTION`.
    let id: Int
    let name: String
    /// Ruta completa "Grupo/Álbum" para álbumes anidados en grupos.
    let path: String
    /// Álbum automático de "Recent Imports" / "Recent Captures".
    let isAuto: Bool
    /// Smart album: su contenido no está materializado en la base de datos.
    let isSmart: Bool
    let imageCount: Int
}

/// Imagen del catálogo con los metadatos efectivos de su variante.
struct Photo: Identifiable, Hashable, Sendable {
    /// `Z_PK` de `ZIMAGE`.
    let id: Int
    let uuid: String
    let filename: String
    /// Ruta del original en disco; `nil` si no se pudo resolver.
    let source: URL?
    let isTrashed: Bool
    let isInsideCatalog: Bool
    var variantID: Int?
    var rating: Int?
    var colorTag: ColorTag?
    var keywords: [String] = []
    var hierarchicalKeywords: [String] = []
    /// Columnas de texto no vacías de `ZVARIANTMETADATA` (nombre de columna -> valor).
    var fields: [String: String] = [:]
}

// MARK: - Exportación

/// Opciones de la exportación elegidas por el usuario.
struct ExportOptions: Hashable, Codable, Sendable {
    var move = false
    var includeTrashed = false
    var includeAutoAlbums = false
    var writeMetadata = true
    var adjustmentsJSON = false
    var refreshExisting = false
}

/// Estado de cada foto dentro de una exportación.
enum JobStatus: Hashable, Sendable {
    case pending
    case skippedTrashed
    case missingSource
    case alreadyExported
    case copied
    case done
    case doneWithoutMetadata
    case verificationFailed
    case failed(String)

    var label: String {
        switch self {
        case .pending: String(localized: "Pending", comment: "Estado de foto")
        case .skippedTrashed: String(localized: "Skipped (trash)", comment: "Estado de foto")
        case .missingSource: String(localized: "Skipped (file not found)", comment: "Estado de foto")
        case .alreadyExported: String(localized: "Already exported", comment: "Estado de foto")
        case .copied: String(localized: "Copied", comment: "Estado de foto")
        case .done: String(localized: "Done", comment: "Estado de foto")
        case .doneWithoutMetadata: String(localized: "Done (no metadata)", comment: "Estado de foto")
        case .verificationFailed: String(localized: "Written, verification failed", comment: "Estado de foto")
        case .failed(let message): String(localized: "Error: \(message)", comment: "Estado de foto con mensaje de error")
        }
    }

    var isSuccess: Bool {
        switch self {
        case .done, .doneWithoutMetadata, .alreadyExported: true
        default: false
        }
    }
}

/// Una foto a exportar, con su álbum, patrón de origen y destino.
struct ExportJob: Identifiable, Hashable, Sendable {
    let id: Int
    let pattern: String
    let album: Album
    let photo: Photo
    var destination: URL?
    var status: JobStatus = .pending
}

/// Plan completo antes de ejecutar: trabajos y totales para el resumen.
struct ExportPlan: Sendable {
    var jobs: [ExportJob] = []
    var plannedCount = 0
    var totalBytes: Int64 = 0
    var insideCatalogCount = 0
    var skippedTrashed = 0
    var missingSources = 0
    var matchedAlbums: [Album] = []
}

/// Resultado final de una exportación.
struct ExportSummary: Sendable {
    let successCount: Int
    let totalCount: Int
    let reportURL: URL?
    /// Bytes realmente transferidos en esta ejecución (para medir la velocidad).
    let bytesTransferred: Int64
    /// Si se detuvo antes de terminar, el motivo. Lo hecho queda registrado y se retoma.
    let interruption: ExportInterruption?
}

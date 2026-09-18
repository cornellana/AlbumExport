import Foundation

/// Álbum al que muy probablemente pertenece una foto sin clasificar.
struct AlbumSuggestion: Hashable, Sendable {
    /// Cómo de firme es la propuesta.
    enum Confidence: Hashable, Sendable {
        /// La foto anterior y la siguiente (por hora de captura) están en ese álbum.
        case between
        /// Solo una foto vecina cercana está en ese álbum.
        case nearby
    }
    let album: String
    let confidence: Confidence
}

/// Propone álbum para las fotos sin clasificar a partir de las ya clasificadas.
///
/// Las fotos de una sesión llevan horas de captura contiguas y nombres en secuencia
/// (`_AM21178`, `_AM21179`…). Medido sobre el catálogo real, el 95 % de las fotos sin álbum
/// quedan entre dos fotos de un mismo álbum: son descartes de la selección, no otra sesión.
enum AlbumSuggester {
    /// Foto que ya está en algún álbum de usuario.
    struct FiledPhoto: Sendable {
        let filename: String
        let captureDate: Date
        let albumIDs: Set<Int>
    }

    /// Álbum de usuario con el intervalo de captura que abarcan sus fotos.
    struct AlbumInfo: Sendable {
        let name: String
        /// Segundos entre su primera y su última foto: distingue el álbum de una sesión
        /// (días) de una recopilación que cruza años.
        let span: TimeInterval
    }

    /// Separación máxima con una foto clasificada para considerarla de la misma sesión.
    static let maximumGap: TimeInterval = 24 * 3600

    /// - Parameters:
    ///   - photos: fotos sin clasificar, con nombre y fecha de captura (sin fecha no hay propuesta).
    ///   - filed: fotos ya clasificadas.
    ///   - albums: nombre e intervalo de cada álbum, por identificador.
    /// - Returns: propuesta por identificador de foto; ausencia = ningún álbum encaja.
    static func suggest(for photos: [(id: Int, filename: String, captureDate: Date?)],
                        filed: [FiledPhoto], albums: [Int: AlbumInfo]) -> [Int: AlbumSuggestion] {
        let sorted = filed.sorted { $0.captureDate < $1.captureDate }
        guard !sorted.isEmpty else { return [:] }
        var result: [Int: AlbumSuggestion] = [:]
        for photo in photos {
            guard let date = photo.captureDate else { continue }
            // Búsqueda binaria de la primera clasificada con fecha >= la de la foto.
            var low = 0, high = sorted.count
            while low < high {
                let mid = (low + high) / 2
                if sorted[mid].captureDate < date { low = mid + 1 } else { high = mid }
            }
            let previous = low > 0 ? sorted[low - 1] : nil
            let next = low < sorted.count ? sorted[low] : nil
            let previousNear = previous.map { date.timeIntervalSince($0.captureDate) <= maximumGap } ?? false
            let nextNear = next.map { $0.captureDate.timeIntervalSince(date) <= maximumGap } ?? false

            if previousNear, nextNear, let previous, let next,
               let album = mostSpecific(previous.albumIDs.intersection(next.albumIDs), albums) {
                result[photo.id] = AlbumSuggestion(album: album, confidence: .between)
                continue
            }
            // Frontera entre dos álbumes, o un solo vecino: decide la secuencia del nombre y,
            // si no aclara nada, la cercanía en el tiempo.
            let candidates = [previousNear ? previous : nil, nextNear ? next : nil].compactMap { $0 }
            let best = candidates.min { a, b in
                let da = sequenceDistance(photo.filename, a.filename), db = sequenceDistance(photo.filename, b.filename)
                if da != db { return da < db }
                return abs(a.captureDate.timeIntervalSince(date)) < abs(b.captureDate.timeIntervalSince(date))
            }
            if let best, let album = mostSpecific(best.albumIDs, albums) {
                result[photo.id] = AlbumSuggestion(album: album, confidence: .nearby)
            }
        }
        return result
    }

    /// De varios álbumes posibles, el de intervalo de captura más corto: el de la sesión antes
    /// que una recopilación ("Portfolio", "Mejores 2025") que también contenga a las vecinas.
    private static func mostSpecific(_ ids: Set<Int>, _ albums: [Int: AlbumInfo]) -> String? {
        ids.compactMap { albums[$0] }.min { ($0.span, $0.name) < ($1.span, $1.name) }?.name
    }

    /// Prefijo y contador de un nombre de cámara (`_AM21178.ARW` -> `_am`, 21178); `nil` si no acaba en cifras.
    static func sequence(of filename: String) -> (prefix: String, number: Int)? {
        let stem = (filename as NSString).deletingPathExtension.lowercased()
        let digits = stem.reversed().prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9, let number = Int(String(digits.reversed())) else { return nil }
        return (String(stem.dropLast(digits.count)), number)
    }

    /// Distancia entre contadores si los dos nombres comparten prefijo; si no, infinita.
    private static func sequenceDistance(_ a: String, _ b: String) -> Int {
        guard let sa = sequence(of: a), let sb = sequence(of: b), sa.prefix == sb.prefix else { return .max }
        return abs(sa.number - sb.number)
    }
}

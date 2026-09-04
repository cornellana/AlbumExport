import Darwin
import Foundation

/// Coincidencia de nombres de álbum con comodines `*` y `?` (semántica de `fnmatch`).
enum PatternMatcher {
    /// Divide el texto del usuario en patrones: separados por `;` o saltos de línea.
    static func parse(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == ";" || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// `true` si `name` encaja con `pattern`, sin distinguir mayúsculas.
    static func matches(_ pattern: String, _ name: String) -> Bool {
        // Se normaliza a minúsculas en Swift (Unicode) en vez de usar FNM_CASEFOLD (solo ASCII).
        fnmatch(pattern.lowercased(), name.lowercased(), 0) == 0
    }

    /// Álbumes que encajan con un patrón. Con `/` en el patrón se compara la ruta completa
    /// "Grupo/Álbum"; si no, solo el nombre. Los smart albums nunca se incluyen.
    static func albums(matching pattern: String, in albums: [Album], includeAuto: Bool) -> [Album] {
        let usesPath = pattern.contains("/")
        return albums.filter { album in
            guard !album.isSmart, includeAuto || !album.isAuto else { return false }
            return matches(pattern, usesPath ? album.path : album.name)
        }
    }
}

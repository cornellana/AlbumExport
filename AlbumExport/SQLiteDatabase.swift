import Foundation
import SQLite3

/// Envoltorio mínimo sobre la API C de SQLite para consultas de lectura.
///
/// Se abre siempre sobre la copia temporal del catálogo, nunca sobre el original.
final class SQLiteDatabase {
    private var handle: OpaquePointer?

    /// Fila de resultado con acceso tipado por nombre de columna.
    struct Row {
        let values: [String: Any]

        func int(_ column: String) -> Int? {
            switch values[column] {
            case let v as Int64: Int(v)
            case let v as Double: Int(v)
            case let v as String: Int(v)
            default: nil
            }
        }

        func string(_ column: String) -> String? {
            switch values[column] {
            case let v as String: v
            case let v as Int64: String(v)
            case let v as Double: String(v)
            default: nil
            }
        }

        func bool(_ column: String) -> Bool { (int(column) ?? 0) != 0 }
    }

    enum Error: Swift.Error, LocalizedError {
        case open(String)
        case prepare(String)
        case step(String)

        var errorDescription: String? {
            switch self {
            case .open(let m), .prepare(let m), .step(let m):
                String(localized: "SQLite error: \(m)", comment: "Error de base de datos")
            }
        }
    }

    /// - Parameter path: Ruta a la copia del catálogo. Se abre en lectura/escritura para que
    ///   SQLite pueda aplicar el WAL copiado; la copia es desechable.
    /// - Parameter create: Crear el fichero si no existe (solo para catálogos de prueba).
    init(path: String, create: Bool = false) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0)
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw Error.open(message)
        }
        handle = db
    }

    deinit {
        sqlite3_close(handle)
    }

    /// Ejecuta una consulta con parámetros posicionales (`?`).
    /// - Returns: Todas las filas; las columnas NULL no aparecen en el diccionario.
    func query(_ sql: String, _ params: [Any?] = []) throws -> [Row] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Error.prepare(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }

        // SQLITE_TRANSIENT obliga a SQLite a copiar el texto: el String de Swift no sobrevive a la llamada.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, param) in params.enumerated() {
            let position = Int32(index + 1)
            switch param {
            case nil: sqlite3_bind_null(statement, position)
            case let v as Int: sqlite3_bind_int64(statement, position, Int64(v))
            case let v as Int64: sqlite3_bind_int64(statement, position, v)
            case let v as Double: sqlite3_bind_double(statement, position, v)
            case let v as String: sqlite3_bind_text(statement, position, v, -1, transient)
            case let v as Bool: sqlite3_bind_int(statement, position, v ? 1 : 0)
            default: sqlite3_bind_text(statement, position, String(describing: param!), -1, transient)
            }
        }

        let columnCount = Int(sqlite3_column_count(statement))
        let names = (0..<columnCount).map { String(cString: sqlite3_column_name(statement, Int32($0))) }
        var rows: [Row] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw Error.step(String(cString: sqlite3_errmsg(handle))) }
            var values: [String: Any] = [:]
            for i in 0..<columnCount {
                let col = Int32(i)
                switch sqlite3_column_type(statement, col) {
                case SQLITE_INTEGER: values[names[i]] = sqlite3_column_int64(statement, col)
                case SQLITE_FLOAT: values[names[i]] = sqlite3_column_double(statement, col)
                case SQLITE_TEXT: values[names[i]] = String(cString: sqlite3_column_text(statement, col))
                default: break
                }
            }
            rows.append(Row(values: values))
        }
        return rows
    }

    /// Ejecuta sentencias sin resultado. Solo se usa para construir catálogos de prueba:
    /// la app nunca escribe en un catálogo real.
    func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(message)
            throw Error.step(text)
        }
    }

    /// Nombres de columna de una tabla, o vacío si la tabla no existe.
    func columns(of table: String) -> Set<String> {
        let rows = (try? query("PRAGMA table_info(\"\(table)\")")) ?? []
        return Set(rows.compactMap { $0.string("name") })
    }

    /// Nombres de todas las tablas.
    func tables() -> Set<String> {
        let rows = (try? query("SELECT name FROM sqlite_master WHERE type = 'table'")) ?? []
        return Set(rows.compactMap { $0.string("name") })
    }
}

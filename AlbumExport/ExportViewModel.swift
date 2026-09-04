import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// Estado de la ventana principal: catálogo abierto, selección, plan y progreso.
@MainActor
@Observable
final class ExportViewModel {
    // MARK: Catálogo
    private(set) var catalogURL: URL?
    private(set) var worker: CatalogWorker?
    private(set) var albums: [Album] = []
    private(set) var catalogVersion: CatalogVersion?
    private(set) var catalogWarnings: [String] = []

    // MARK: Acción y selección
    /// Acción elegida; la interfaz solo pide los datos que esa acción necesita.
    var action: AppAction = .copy
    var patternsText = ""
    var selectedAlbumIDs: Set<Int> = []
    var albumFilter = ""
    /// Carpeta de salida (modo Copy).
    var destinationURL: URL?
    /// Catálogo de destino (modo Move): puede no existir todavía; la app lo creará.
    var destinationCatalogURL: URL?
    var options = ExportOptions()

    // MARK: Plan y ejecución
    private(set) var plan: ExportPlan?
    private(set) var isPlanning = false
    private(set) var isRunning = false
    private(set) var progressCompleted = 0
    private(set) var progressTotal = 0
    private(set) var bytesDone: Int64 = 0
    private(set) var bytesTransferred: Int64 = 0
    private(set) var currentFile = ""
    private(set) var logLines: [String] = []
    private(set) var summary: ExportSummary?
    var errorMessage: String?
    var showMoveConfirmation = false

    // MARK: Velocidad y estimación
    /// Bytes por segundo medidos en la ejecución en curso (media desde el inicio).
    private(set) var throughput: Double?
    /// Velocidad de la última ejecución con volumen suficiente, para estimar antes de empezar.
    private(set) var lastThroughput: Double = UserDefaults.standard.double(forKey: ExportViewModel.throughputKey)
    private static let throughputKey = "lastThroughputBytesPerSecond"
    private var startDate: Date?
    private var cancellation: CancellationToken?

    // MARK: exiftool
    private(set) var exiftoolURL: URL? = ExifToolLocator.find()
    private(set) var exiftoolVersion: String?

    private var planGeneration = 0
    private var autoRun = false
    private var autoQuit = false

    init() {
        ExportEngine.removeOrphanStagingDirectories()
        if let url = exiftoolURL {
            Task.detached { [url] in
                let version = ExifToolLocator.version(of: url)
                await MainActor.run { self.exiftoolVersion = version }
            }
        }
        // Argumentos de línea de comandos (útil para automatizar y para pruebas):
        //   AlbumExport <catálogo> [<destino>] [<patrones separados por ;>] [--move-to <catálogo>] [--run] [--quit]
        // --run lanza la exportación en cuanto el plan está listo; --quit cierra la app al acabar.
        let all = CommandLine.arguments.dropFirst()
        autoRun = all.contains("--run")
        autoQuit = all.contains("--quit")
        if all.contains("--dump-layout") { scheduleLayoutDump() }
        if all.contains("--verify") { action = .verify }
        if let i = all.firstIndex(of: "--move-to"), all.indices.contains(i + 1) {
            destinationCatalogURL = URL(fileURLWithPath: all[i + 1])
            options.move = true
            action = .move
        }
        var positional: [String] = []
        var skipNext = false
        for arg in all {
            if skipNext { skipNext = false; continue }
            if arg == "--move-to" { skipNext = true; continue }
            if arg.hasPrefix("-") { continue }
            positional.append(arg)
        }
        if let catalogPath = positional.first, FileManager.default.fileExists(atPath: catalogPath) {
            if positional.count > 1 { destinationURL = URL(fileURLWithPath: positional[1]) }
            if positional.count > 2 { patternsText = positional[2] }
            open(URL(fileURLWithPath: catalogPath))
        } else {
            restoreLastSession()
        }
    }

    // MARK: - Última sesión

    private enum Keys {
        static let catalog = "lastCatalogPath"
        static let destination = "lastDestinationPath"
        static let destinationCatalog = "lastDestinationCatalogPath"
        static let patterns = "lastPatterns"
        static let selectedAlbums = "lastSelectedAlbumPaths"
        static let options = "lastOptions"
    }

    /// Rutas de los álbumes marcados en la sesión anterior, pendientes de resolver al abrir el catálogo.
    private var pendingSelectedAlbumPaths: [String]?

    /// Al arrancar sin argumentos, se recupera lo último usado: catálogo, patrones, álbumes, destinos y opciones.
    private func restoreLastSession() {
        let defaults = UserDefaults.standard
        patternsText = defaults.string(forKey: Keys.patterns) ?? ""
        if let data = defaults.data(forKey: Keys.options), let saved = try? JSONDecoder().decode(ExportOptions.self, from: data) {
            options = saved
            action = saved.move ? .move : .copy
        }
        if let path = defaults.string(forKey: Keys.destination), FileManager.default.fileExists(atPath: path) {
            destinationURL = URL(fileURLWithPath: path)
        }
        if let path = defaults.string(forKey: Keys.destinationCatalog) {
            destinationCatalogURL = URL(fileURLWithPath: path)
        }
        pendingSelectedAlbumPaths = defaults.stringArray(forKey: Keys.selectedAlbums)
        if let path = defaults.string(forKey: Keys.catalog), FileManager.default.fileExists(atPath: path) {
            open(URL(fileURLWithPath: path))
        }
    }

    /// Guarda la selección actual para la próxima vez.
    private func saveSession() {
        let defaults = UserDefaults.standard
        defaults.set(catalogURL?.path, forKey: Keys.catalog)
        defaults.set(destinationURL?.path, forKey: Keys.destination)
        defaults.set(destinationCatalogURL?.path, forKey: Keys.destinationCatalog)
        defaults.set(patternsText, forKey: Keys.patterns)
        defaults.set(albums.filter { selectedAlbumIDs.contains($0.id) }.map(\.path), forKey: Keys.selectedAlbums)
        defaults.set(try? JSONEncoder().encode(options), forKey: Keys.options)
    }

    // MARK: - Derivados

    var patterns: [String] { PatternMatcher.parse(patternsText) }

    /// Álbumes que encajan con los patrones actuales (para resaltarlos en la lista).
    var matchedAlbumIDs: Set<Int> {
        Set(patterns.flatMap { PatternMatcher.albums(matching: $0, in: albums, includeAuto: options.includeAutoAlbums).map(\.id) })
    }

    var filteredAlbums: [Album] {
        albums.filter { album in
            (options.includeAutoAlbums || !album.isAuto)
                && (albumFilter.isEmpty || album.path.localizedCaseInsensitiveContains(albumFilter))
        }
    }

    /// `true` si el catálogo abierto es un catálogo (no una sesión): solo entonces se puede trasladar.
    var sourceIsCatalog: Bool {
        catalogURL?.pathExtension.lowercased() == "cocatalog"
    }

    var canExport: Bool {
        guard !isRunning, worker != nil, (plan?.plannedCount ?? 0) > 0 else { return false }
        if options.move {
            return destinationCatalogURL != nil && sourceIsCatalog
        }
        return destinationURL != nil && (!options.writeMetadata || exiftoolURL != nil)
    }

    /// `true` si el destino elegido está en un volumen de red.
    var destinationIsNetwork: Bool {
        destinationURL.map(ExportEngine.isNetworkVolume) ?? false
    }

    /// Segundos que faltan, según la velocidad medida ahora o la de la última ejecución.
    var estimatedRemainingSeconds: TimeInterval? {
        guard let plan, !options.move else { return nil }
        if isRunning {
            guard let throughput, throughput > 0 else { return nil }
            return Double(max(plan.totalBytes - bytesDone, 0)) / throughput
        }
        guard lastThroughput > 0, plan.plannedCount > 0 else { return nil }
        return Double(plan.totalBytes) / lastThroughput
    }

    // MARK: - Catálogo

    func chooseCatalog() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose a Capture One catalog or session", comment: "Título del diálogo de apertura")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        // El .cocatalog es un paquete: tratado como fichero se puede elegir de un clic.
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func open(_ url: URL) {
        Task {
            do {
                let reader = try CatalogReader(url: url)
                let worker = CatalogWorker(reader: reader)
                let albums = try await worker.albums()
                self.catalogURL = url
                self.worker = worker
                self.albums = albums
                self.catalogVersion = reader.version
                self.catalogWarnings = reader.warnings
                if let paths = pendingSelectedAlbumPaths {
                    self.selectedAlbumIDs = Set(albums.filter { paths.contains($0.path) }.map(\.id))
                    pendingSelectedAlbumPaths = nil
                } else {
                    self.selectedAlbumIDs = []
                }
                self.summary = nil
                self.logLines = []
                self.verifyResult = nil
                refreshPlan()
                if action == .verify { verifyCatalog() }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Destino según el modo: carpeta (Copy) o catálogo existente (Move).
    func chooseDestination() {
        if options.move { chooseDestinationCatalog() } else { chooseDestinationFolder() }
    }

    private func chooseDestinationFolder() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose the destination folder", comment: "Título del diálogo de destino")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let root = worker?.reader.rootURL, url.path.hasPrefix(root.path) {
            errorMessage = String(localized: "The destination cannot be inside the catalog.", comment: "Error de destino")
            return
        }
        destinationURL = url
        refreshPlan()   // el manifiesto del nuevo destino decide qué está ya exportado
    }

    private func chooseDestinationCatalog() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose the destination catalog", comment: "Título del diálogo de catálogo destino")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        if let type = UTType(filenameExtension: "cocatalog") { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setDestinationCatalog(url)
    }

    /// Pide nombre y carpeta para un catálogo nuevo; se creará al exportar.
    func createDestinationCatalog() {
        let panel = NSSavePanel()
        panel.title = String(localized: "New destination catalog", comment: "Título del diálogo de catálogo nuevo")
        panel.nameFieldStringValue = String(localized: "New catalog", comment: "Nombre por defecto del catálogo nuevo")
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.pathExtension.lowercased() != "cocatalog" { url = url.appendingPathExtension("cocatalog") }
        setDestinationCatalog(url)
    }

    private func setDestinationCatalog(_ url: URL) {
        if url.standardizedFileURL == catalogURL?.standardizedFileURL {
            errorMessage = String(localized: "The destination catalog must be different from the source catalog.", comment: "Error de destino")
            return
        }
        destinationCatalogURL = url
        refreshPlan()
    }

    func toggleAlbum(_ album: Album) {
        if selectedAlbumIDs.contains(album.id) {
            selectedAlbumIDs.remove(album.id)
        } else {
            selectedAlbumIDs.insert(album.id)
        }
        refreshPlan()
    }

    // MARK: - Plan

    /// Recalcula el plan en segundo plano; descarta resultados de peticiones anteriores.
    func refreshPlan() {
        guard let worker else { plan = nil; return }
        saveSession()
        planGeneration += 1
        let generation = planGeneration
        let patterns = patterns
        let selected = selectedAlbumIDs
        let albums = albums
        let options = options
        let destination = options.move ? nil : destinationURL
        isPlanning = true
        Task {
            do {
                let plan = try await worker.plan(patterns: patterns, selectedAlbumIDs: selected, albums: albums, options: options, destination: destination)
                guard generation == planGeneration else { return }
                self.plan = plan
                if autoRun, !isRunning, canExport {
                    autoRun = false
                    runExport()
                }
            } catch {
                guard generation == planGeneration else { return }
                errorMessage = error.localizedDescription
            }
            if generation == planGeneration { isPlanning = false }
        }
    }

    // MARK: - Ejecución

    /// Al cambiar de acción: sincroniza el modo y recalcula el plan.
    func actionChanged() {
        options.move = action == .move
        refreshPlan()
        // Verificar no necesita más datos que el catálogo: se lanza sola al elegir la acción.
        if action == .verify, worker != nil, verifyResult == nil { verifyCatalog() }
    }

    /// Botón principal según la acción: verificar, trasladar (con confirmación) o copiar.
    var canRunAction: Bool {
        action == .verify ? (worker != nil && !isRunning && !isVerifying) : canExport
    }

    func requestExport() {
        switch action {
        case .verify:
            verifyCatalog()
        case .move:
            guard canExport else { return }
            showMoveConfirmation = true
        case .copy:
            guard canExport else { return }
            runExport()
        }
    }

    func runExport() {
        guard let worker, plan != nil else { return }
        let options = options
        let patterns = patterns
        let selected = selectedAlbumIDs
        let albums = albums
        let token = CancellationToken()
        cancellation = token
        planGeneration += 1   // invalida planificaciones en curso: la de abajo manda
        isRunning = true
        summary = nil
        logLines = []
        progressCompleted = 0
        progressTotal = plan?.plannedCount ?? 0
        bytesDone = 0
        bytesTransferred = 0
        throughput = nil
        startDate = Date()
        let folder = destinationURL
        let catalog = destinationCatalogURL
        let writer = options.writeMetadata ? exiftoolURL.map { ExifToolWriter(executable: $0) } : nil
        Task {
            do {
                // Siempre se parte de un plan recién calculado contra el destino actual: así una
                // ejecución anterior (a otro destino, o con errores) no deja estados heredados.
                var plan = try await worker.plan(patterns: patterns, selectedAlbumIDs: selected, albums: albums, options: options,
                                                 destination: options.move ? nil : folder)
                self.plan = plan
                progressTotal = plan.plannedCount
                let events: @Sendable (ExportEvent) -> Void = { event in Task { @MainActor in self.handle(event) } }
                let result: (jobs: [ExportJob], summary: ExportSummary)
                if options.move, let catalog {
                    result = try await worker.transfer(plan: plan, destinationCatalog: catalog, cancellation: token, events: events)
                } else if let folder {
                    result = try await worker.export(plan: plan, destination: folder, options: options, writer: writer, cancellation: token, events: events)
                } else {
                    return
                }
                plan.jobs = result.jobs
                plan.recount()
                self.plan = plan
                self.summary = result.summary
                rememberThroughput(bytes: result.summary.bytesTransferred)
            } catch {
                errorMessage = error.localizedDescription
                // En modo automático no hay nadie mirando la ventana: también por stderr.
                FileHandle.standardError.write(Data("AlbumExport error: \(error.localizedDescription)\n".utf8))
            }
            isRunning = false
            cancellation = nil
            if autoQuit { NSApplication.shared.terminate(nil) }
        }
    }

    func cancelExport() {
        cancellation?.cancel()
    }

    private func handle(_ event: ExportEvent) {
        switch event {
        case .progress(let completed, let total, let done, let transferred, let current):
            progressCompleted = completed
            progressTotal = total
            bytesDone = done
            bytesTransferred = transferred
            currentFile = current
            // La media se estabiliza tras unos segundos; antes no se muestra estimación.
            if let startDate, transferred > 0 {
                let elapsed = Date().timeIntervalSince(startDate)
                if elapsed > 3 { throughput = Double(transferred) / elapsed }
            }
        case .log(let line):
            logLines.append(line)
            if autoQuit { FileHandle.standardError.write(Data("AlbumExport: \(line)\n".utf8)) }
        case .status(let jobID, let status, let destination):
            // Refleja en la tabla el estado de cada foto según avanza (atenuado al completarse).
            if let index = plan?.jobs.firstIndex(where: { $0.id == jobID }) {
                plan?.jobs[index].status = status
                if let destination { plan?.jobs[index].destination = destination }
            }
        }
    }

    /// Guarda la velocidad medida si la ejecución fue lo bastante larga para ser representativa.
    private func rememberThroughput(bytes: Int64) {
        guard let startDate, bytes > 50_000_000 else { return }
        let elapsed = Date().timeIntervalSince(startDate)
        guard elapsed > 5 else { return }
        lastThroughput = Double(bytes) / elapsed
        UserDefaults.standard.set(lastThroughput, forKey: Self.throughputKey)
    }

    // MARK: - Verificación del catálogo

    private(set) var verifyResult: VerifyResult?
    private(set) var isVerifying = false
    private(set) var verifyProgress = ""
    /// Búsqueda de perdidos en curso: la tabla sigue visible y se va rellenando.
    private(set) var isSearching = false
    private var verifyCancellation: CancellationToken?
    var showVerify = false
    var showMoveOrphansConfirmation = false
    var showRestoreConfirmation = false
    private(set) var orphanTargetFolder: URL?
    private(set) var verifyMessage: String?

    /// Compara `Originals/` con el índice: huérfanos en disco, ficheros ausentes y fotos sin álbum.
    func verifyCatalog() {
        guard let worker, !isVerifying else { return }
        let token = CancellationToken()
        verifyCancellation = token
        isVerifying = true
        verifyResult = nil
        verifyMessage = nil
        verifyProgress = ""
        Task {
            do {
                let result = try await worker.verify(cancellation: token) { progress in
                    Task { @MainActor in self.verifyProgress = Self.describe(progress) }
                }
                verifyResult = result
                if autoQuit {
                    FileHandle.standardError.write(Data("AlbumExport verify: files=\(result.filesOnDisk) orphans=\(result.orphans.count) missing=\(result.missing.count) unfiled=\(result.unfiled.count)\n".utf8))
                }
            } catch {
                if !token.isCancelled { errorMessage = error.localizedDescription }
                if autoQuit { FileHandle.standardError.write(Data("AlbumExport error: \(error.localizedDescription)\n".utf8)) }
            }
            isVerifying = false
            verifyCancellation = nil
            if autoQuit { NSApplication.shared.terminate(nil) }
        }
    }

    func cancelVerify() {
        verifyCancellation?.cancel()
    }

    private static func describe(_ progress: CatalogVerifier.Progress) -> String {
        switch progress {
        case .readingIndex: String(localized: "Reading the catalog index…", comment: "Progreso de verificación")
        case .checkingMissing(let done, let total): String(localized: "Checking \(done) of \(total) indexed files…", comment: "Progreso de verificación")
        case .scanningFiles(let count): String(localized: "Scanning Originals: \(count) files…", comment: "Progreso de verificación")
        }
    }

    /// Pide la carpeta destino y la confirmación antes de sacar los huérfanos del bundle.
    func chooseOrphanFolder() {
        guard let result = verifyResult, !result.orphans.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose where to move the orphan files", comment: "Título del diálogo de huérfanos")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let root = worker?.reader.rootURL, url.path.hasPrefix(root.path) {
            errorMessage = String(localized: "The destination cannot be inside the catalog.", comment: "Error de destino")
            return
        }
        orphanTargetFolder = url
        showMoveOrphansConfirmation = true
    }

    func moveOrphans() {
        guard let worker, let result = verifyResult, let folder = orphanTargetFolder else { return }
        isVerifying = true
        verifyProgress = String(localized: "Moving orphan files…", comment: "Progreso de verificación")
        Task {
            let errors = await worker.moveOrphans(result.orphans, to: folder)
            let moved = result.orphans.count - errors.count
            verifyMessage = String(localized: "Orphans moved: \(moved), errors: \(errors.count)", comment: "Resumen tras mover huérfanos")
            try? CatalogVerifier.writeReport(result, catalogName: catalogURL?.lastPathComponent ?? "", to: folder.appendingPathComponent("AlbumExport_orphans.csv"))
            // Volver a escanear para reflejar el estado real tras el movimiento.
            if let refreshed = try? await worker.verify() { verifyResult = refreshed }
            isVerifying = false
        }
    }

    /// Volúmenes montados que se ofrecen para buscar ficheros perdidos.
    var searchVolumes: [URL] { CatalogVerifier.mountedVolumes() }

    /// Busca los ficheros ausentes en una carpeta o volumen elegido; con `nil` pide la carpeta.
    func searchMissing(in chosen: URL?) {
        guard verifyResult?.missing.isEmpty == false else { return }
        var folder = chosen
        if folder == nil {
            let panel = NSOpenPanel()
            panel.title = String(localized: "Choose the folder or volume to search for the missing files", comment: "Título del diálogo de búsqueda")
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.directoryURL = URL(fileURLWithPath: "/Volumes")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            folder = url
        }
        runSearch(folder: folder)
    }

    /// Busca con Spotlight en todos los volúmenes indexados.
    func searchMissingWithSpotlight() {
        runSearch(folder: nil)
    }

    private func runSearch(folder: URL?) {
        guard let worker, let result = verifyResult, !result.missing.isEmpty else { return }
        let token = CancellationToken()
        verifyCancellation = token
        isSearching = true
        let where_ = folder?.path ?? "Spotlight"
        verifyProgress = String(localized: "Searching in \(where_)…", comment: "Progreso de búsqueda de perdidos")
        Task {
            let updated = await worker.searchMissing(result.missing, in: folder, cancellation: token, progress: { scanned in
                Task { @MainActor in
                    self.verifyProgress = String(localized: "Searching in \(where_): \(scanned) files checked…", comment: "Progreso de búsqueda de perdidos")
                }
            }, onFound: { imageID, url in
                Task { @MainActor in
                    // Aparece en la tabla en cuanto se encuentra, sin esperar al final.
                    if let i = self.verifyResult?.missing.firstIndex(where: { $0.imageID == imageID }) {
                        self.verifyResult?.missing[i].candidate = url
                        self.verifyResult?.missing[i].candidateIsOrphan = false
                    }
                }
            })
            verifyCancellation = nil
            isSearching = false
            verifyResult?.missing = updated
            let found = updated.filter { $0.candidate != nil }.count
            verifyMessage = String(localized: "Found \(found) of \(updated.count) missing files", comment: "Resumen de búsqueda")
            verifyProgress = ""
        }
    }

    func requestRestore() {
        guard (verifyResult?.foundCount ?? 0) > 0 else { return }
        showRestoreConfirmation = true
    }

    /// Copia los ficheros encontrados a la ruta que el catálogo espera.
    func restoreMissing() {
        guard let worker, let result = verifyResult else { return }
        isVerifying = true
        verifyProgress = String(localized: "Restoring found files…", comment: "Progreso de verificación")
        Task {
            let errors = await worker.restoreMissing(result.missing)
            let restored = result.foundCount - errors.count
            verifyMessage = String(localized: "Files restored: \(restored), errors: \(errors.count)", comment: "Resumen tras restaurar")
            if let refreshed = try? await worker.verify() { verifyResult = refreshed }
            isVerifying = false
        }
    }

    var showUnfiledAlbumConfirmation = false

    /// Nombre del álbum que reúne las fotos sin clasificar.
    static var unfiledAlbumName: String { String(localized: "Unfiled", comment: "Nombre del álbum de fotos sin clasificar") }

    /// Solo a petición del usuario y tras confirmar: nunca se crea automáticamente.
    func requestUnfiledAlbum() {
        guard verifyResult?.unfiledToFile.isEmpty == false else { return }
        showUnfiledAlbumConfirmation = true
    }

    /// Crea en Capture One el álbum "Sin clasificar" con las fotos sin álbum que no sean duplicados.
    func createUnfiledAlbum() {
        guard let worker, let result = verifyResult else { return }
        isVerifying = true
        verifyProgress = String(localized: "Creating the album in Capture One…", comment: "Progreso de verificación")
        Task {
            do {
                let added = try await worker.createUnfiledAlbum(named: Self.unfiledAlbumName, images: result.unfiled)
                verifyMessage = String(localized: "Album \"\(Self.unfiledAlbumName)\": \(added) photos added.", comment: "Resumen tras crear el álbum")
            } catch {
                errorMessage = error.localizedDescription
            }
            isVerifying = false
        }
    }

    func saveVerifyReport() {
        guard let result = verifyResult else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "AlbumExport_verify.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try CatalogVerifier.writeReport(result, catalogName: catalogURL?.lastPathComponent ?? "", to: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Diagnóstico de la disposición

    /// Con `--dump-layout`: vuelca por stderr la geometría de ventana, pantalla y vistas de
    /// desplazamiento tres segundos después de arrancar, y cierra la app.
    private func scheduleLayoutDump() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            var out = ""
            if let screen = NSScreen.main { out += "screen \(screen.frame) visible \(screen.visibleFrame)\n" }
            for window in NSApplication.shared.windows {
                out += "window '\(window.title)' frame \(window.frame) contentRect \(window.contentLayoutRect) styleMask \(window.styleMask.rawValue)\n"
                func walk(_ view: NSView, depth: Int) {
                    let name = String(describing: type(of: view))
                    var line = String(repeating: "  ", count: depth) + "\(name) frame=\(view.frame)"
                    if let scroll = view as? NSScrollView {
                        line += " visible=\(scroll.documentVisibleRect) docSize=\(scroll.documentView?.frame.size ?? .zero) insets=\(scroll.contentInsets)"
                    }
                    if let table = view as? NSTableView { line += " rows=\(table.numberOfRows)" }
                    if depth < 14 && (name.contains("Scroll") || name.contains("Split") || name.contains("Hosting") || name.contains("Table") || name.contains("Outline") || depth < 4) {
                        out += line + "\n"
                    }
                    for sub in view.subviews { walk(sub, depth: depth + 1) }
                }
                if let content = window.contentView { walk(content, depth: 0) }
            }
            FileHandle.standardError.write(Data(out.utf8))
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - Finder

    func revealReport() {
        guard let url = summary?.reportURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func revealDestination() {
        guard let url = options.move ? destinationCatalogURL : destinationURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

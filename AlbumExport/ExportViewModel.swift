import AppKit
import Foundation
import Observation

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

    // MARK: Selección
    var patternsText = ""
    var selectedAlbumIDs: Set<Int> = []
    var albumFilter = ""
    var destinationURL: URL?
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

    init() {
        if let url = exiftoolURL {
            Task.detached { [url] in
                let version = ExifToolLocator.version(of: url)
                await MainActor.run { self.exiftoolVersion = version }
            }
        }
        // Argumentos de línea de comandos (útil para automatizar y para pruebas):
        //   AlbumExport <catálogo> [<destino>] [<patrones separados por ;>]
        let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if let catalogPath = arguments.first, FileManager.default.fileExists(atPath: catalogPath) {
            if arguments.count > 1 { destinationURL = URL(fileURLWithPath: arguments[arguments.startIndex + 1]) }
            if arguments.count > 2 { patternsText = arguments[arguments.startIndex + 2] }
            open(URL(fileURLWithPath: catalogPath))
        }
    }

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

    var canExport: Bool {
        !isRunning && worker != nil && destinationURL != nil && (plan?.plannedCount ?? 0) > 0
            && (!options.writeMetadata || exiftoolURL != nil)
    }

    /// `true` si el destino elegido está en un volumen de red.
    var destinationIsNetwork: Bool {
        destinationURL.map(ExportEngine.isNetworkVolume) ?? false
    }

    /// Segundos que faltan, según la velocidad medida ahora o la de la última ejecución.
    var estimatedRemainingSeconds: TimeInterval? {
        guard let plan else { return nil }
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
                self.selectedAlbumIDs = []
                self.summary = nil
                self.logLines = []
                refreshPlan()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func chooseDestination() {
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
        planGeneration += 1
        let generation = planGeneration
        let patterns = patterns
        let selected = selectedAlbumIDs
        let albums = albums
        let options = options
        isPlanning = true
        Task {
            do {
                let plan = try await worker.plan(patterns: patterns, selectedAlbumIDs: selected, albums: albums, options: options)
                guard generation == planGeneration else { return }
                self.plan = plan
            } catch {
                guard generation == planGeneration else { return }
                errorMessage = error.localizedDescription
            }
            if generation == planGeneration { isPlanning = false }
        }
    }

    // MARK: - Ejecución

    /// Punto de entrada del botón Exportar: mover pide confirmación explícita.
    func requestExport() {
        guard canExport else { return }
        if options.move {
            showMoveConfirmation = true
        } else {
            runExport()
        }
    }

    func runExport() {
        guard let worker, let destination = destinationURL, let plan else { return }
        let writer = options.writeMetadata ? exiftoolURL.map { ExifToolWriter(executable: $0) } : nil
        let options = options
        let token = CancellationToken()
        cancellation = token
        isRunning = true
        summary = nil
        logLines = []
        progressCompleted = 0
        progressTotal = plan.plannedCount
        bytesDone = 0
        bytesTransferred = 0
        throughput = nil
        startDate = Date()
        Task {
            do {
                let result = try await worker.export(plan: plan, destination: destination, options: options, writer: writer, cancellation: token) { event in
                    Task { @MainActor in self.handle(event) }
                }
                self.plan?.jobs = result.jobs
                self.summary = result.summary
                rememberThroughput(bytes: result.summary.bytesTransferred)
            } catch {
                errorMessage = error.localizedDescription
            }
            isRunning = false
            cancellation = nil
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

    func revealReport() {
        guard let url = summary?.reportURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func revealDestination() {
        guard let url = destinationURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

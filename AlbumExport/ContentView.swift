import SwiftUI

/// Ventana principal: barra lateral con álbumes y patrones (cuando la acción los necesita)
/// y detalle guiado por la acción elegida.
struct ContentView: View {
    @Bindable var model: ExportViewModel

    var body: some View {
        NavigationSplitView {
            AlbumSidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 480)
        } detail: {
            PlanView(model: model)
        }
        .navigationTitle(model.catalogURL?.deletingPathExtension().lastPathComponent
                         ?? String(localized: "Album Export", comment: "Título de la ventana sin catálogo"))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    model.chooseCatalog()
                } label: {
                    Label("Open Catalog…", systemImage: "books.vertical")
                }
                .help("Open a Capture One catalog (.cocatalog) or session")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.requestExport()
                } label: {
                    switch model.action {
                    case .copy: Label("Export", systemImage: "square.and.arrow.up")
                    case .move: Label("Move", systemImage: "arrow.right.doc.on.clipboard")
                    case .verify: Label("Verify", systemImage: "checkmark.shield")
                    }
                }
                .disabled(!model.canRunAction)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .alert("Error", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: model.errorMessage ?? "")
        }
        .confirmationDialog("Move \(model.plan?.plannedCount ?? 0) photos to \(model.destinationCatalogURL?.deletingPathExtension().lastPathComponent ?? "")?",
                            isPresented: $model.showMoveConfirmation, titleVisibility: .visible) {
            Button("Move albums") { model.runExport() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Capture One will export each photo with its adjustments and import it into the destination catalog, recreating groups and albums. Nothing is deleted from the source catalog.")
        }
        .onChange(of: model.action) { model.actionChanged() }
        .onChange(of: model.patternsText) { model.refreshPlan() }
        .onChange(of: model.options) { model.refreshPlan() }
    }
}

// MARK: - Barra lateral

/// Patrones con comodines, filtro y lista de álbumes con selección manual.
struct AlbumSidebarView: View {
    @Bindable var model: ExportViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.action.needsAlbums {
                ContentUnavailableView(
                    "Albums are not needed",
                    systemImage: "checkmark.shield",
                    description: Text("Verification checks the whole catalog."))
            } else {
                Text("Album patterns")
                    .font(.headline)
                TextField("Andorra 20??; Isla*", text: $model.patternsText, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                Text("Use * and ? as wildcards. Separate patterns with ;")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if model.worker == nil {
                    ContentUnavailableView(
                        "No catalog",
                        systemImage: "books.vertical",
                        description: Text("Open a Capture One catalog or session to list its albums."))
                } else {
                    TextField("Filter albums", text: $model.albumFilter)
                        .textFieldStyle(.roundedBorder)
                        .padding(.top, 8)
                    let matched = model.matchedAlbumIDs
                    List(model.filteredAlbums) { album in
                        AlbumRow(album: album,
                                 isMatched: matched.contains(album.id),
                                 isSelected: model.selectedAlbumIDs.contains(album.id))
                            .contentShape(Rectangle())
                            .onTapGesture { model.toggleAlbum(album) }
                    }
                    .listStyle(.inset)
                    Text("Albums: \(matched.union(model.selectedAlbumIDs).count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }
}

/// Fila de álbum: casilla de selección manual, ruta, indicador de patrón y recuento.
struct AlbumRow: View {
    let album: Album
    let isMatched: Bool
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .opacity(album.isSmart ? 0.3 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: album.name)
                    .fontWeight(isMatched ? .semibold : .regular)
                if album.path != album.name {
                    Text(verbatim: String(album.path.dropLast(album.name.count + 1)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if album.isSmart {
                Text("smart").font(.caption2).padding(.horizontal, 4).background(.quaternary, in: Capsule())
            }
            if album.isAuto {
                Text("auto").font(.caption2).padding(.horizontal, 4).background(.quaternary, in: Capsule())
            }
            if isMatched {
                Image(systemName: "asterisk.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .help("Matches a pattern")
            }
            Text(verbatim: "\(album.imageCount)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

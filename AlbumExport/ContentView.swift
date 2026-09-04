import SwiftUI

/// Ventana principal: barra lateral con álbumes y patrones, detalle con plan y ejecución.
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
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    model.chooseCatalog()
                } label: {
                    Label("Open Catalog…", systemImage: "books.vertical")
                }
                .help("Open a Capture One catalog (.cocatalog) or session")
                Button {
                    model.chooseDestination()
                } label: {
                    Label("Destination…", systemImage: "folder")
                }
                .disabled(model.worker == nil)
                .help("Choose where the photos will be exported")
                Button {
                    model.verifyCatalog()
                } label: {
                    Label("Verify", systemImage: "checkmark.shield")
                }
                .disabled(model.worker == nil || model.isRunning)
                .help("Compare the Originals folder with the catalog index and list orphan files")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.requestExport()
                } label: {
                    Label(model.options.move ? "Move" : "Export", systemImage: "square.and.arrow.up")
                }
                .disabled(!model.canExport)
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
        .confirmationDialog("Move the original files?", isPresented: $model.showMoveConfirmation, titleVisibility: .visible) {
            Button("Move files", role: .destructive) { model.runExport() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Photos stored inside the catalog bundle will become offline in Capture One. This cannot be undone from this app.")
        }
        .onChange(of: model.patternsText) { model.refreshPlan() }
        .onChange(of: model.options) { model.refreshPlan() }
        .sheet(isPresented: $model.showVerify) {
            VerifyView(model: model)
        }
    }
}

// MARK: - Barra lateral

/// Patrones con comodines, filtro y lista de álbumes con selección manual.
struct AlbumSidebarView: View {
    @Bindable var model: ExportViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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

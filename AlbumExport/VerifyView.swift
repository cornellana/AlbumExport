import SwiftUI

/// Panel de verificación: huérfanos en `Originals/`, ficheros ausentes y fotos sin álbum.
struct VerifyView: View {
    @Bindable var model: ExportViewModel
    @State private var tab: Tab = .orphans

    enum Tab: Hashable { case orphans, missing, unfiled }

    // MARK: - Explicación de cada tipo (tips al pasar el cursor)

    static let orphansHelp: LocalizedStringKey = "Orphan: a file inside the catalog's Originals folder that no catalog entry points to. It takes disk space but Capture One cannot see it. Most are spare copies left by repeated imports; a few are photos that never made it into the catalog."
    static let missingHelp: LocalizedStringKey = "Missing: the catalog has the photo but its file is not where it expects it (it shows as offline in Capture One). The file was moved, renamed, deleted, or its disk is not connected."
    static let unfiledHelp: LocalizedStringKey = "Not in any album: the photo is in the catalog and its file is fine, but it belongs to none of your albums (Recent Imports does not count). Usually photos you removed from an album while culling. Duplicates are repeated imports of a photo that is in an album."

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.worker == nil {
                ContentUnavailableView("No catalog", systemImage: "books.vertical",
                                       description: Text("Open a Capture One catalog to verify it."))
            } else if model.isVerifying {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Verifying…")
                    Text(verbatim: model.verifyProgress).foregroundStyle(.secondary)
                    Button("Cancel") { model.cancelVerify() }
                }
                Spacer()
            } else if let result = model.verifyResult {
                summary(result)
                Picker("", selection: $tab) {
                    Text("Orphan files").tag(Tab.orphans)
                    Text("Missing files").tag(Tab.missing)
                    Text("Not in any album").tag(Tab.unfiled)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 440)
                // Un control segmentado no admite un tip por segmento: se explica el tipo elegido.
                .help(tab == .orphans ? Self.orphansHelp : tab == .missing ? Self.missingHelp : Self.unfiledHelp)
                switch tab {
                case .orphans:
                    if result.orphans.isEmpty {
                        ContentUnavailableView("No orphan files", systemImage: "checkmark.seal")
                    } else {
                        Table(result.orphans) {
                            TableColumn("Path") { Text(verbatim: $0.relativePath) }
                            TableColumn("Size") { Text(verbatim: $0.size.formatted(.byteCount(style: .file))) }.width(90)
                            TableColumn("In the catalog") { item in
                                if item.copyOfIndexed {
                                    Text(item.indexedAlbum.map { "Copy of a photo in album \($0)" } ?? "Copy of a photo already in the catalog")
                                        .foregroundStyle(.secondary)
                                } else if item.repeatedOrphan {
                                    Text("Repeated copy of another orphan").foregroundStyle(.secondary)
                                } else if item.isImportable {
                                    Text("Not in the catalog").foregroundStyle(.orange)
                                } else {
                                    Text("Not a photo").foregroundStyle(.secondary)
                                }
                            }.width(260)
                            TableColumn("Probable album") { item in
                                // "≈": solo una foto vecina está en ese álbum (menos seguro).
                                Text(verbatim: item.suggestion.map { ($0.confidence == .nearby ? "≈ " : "") + $0.album } ?? "")
                            }.width(200)
                        }
                    }
                    HStack {
                        Button("Move orphans to folder…") { model.chooseOrphanFolder() }
                            .disabled(result.orphans.isEmpty)
                        Button("Import the \(result.recoverableOrphans.count) photos not in the catalog…") { model.requestRecoverOrphans() }
                            .disabled(result.recoverableOrphans.isEmpty)
                        Text("Orphans are files inside Originals that the index does not know. \(result.orphanCopies) are spare copies of photos the catalog already has (same file name and capture time); the rest can be imported into the group \"\(ExportViewModel.recoveredGroupName)\", one album per probable album. Moving orphans keeps the folder structure.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                case .missing:
                    if result.missing.isEmpty {
                        ContentUnavailableView("No missing files", systemImage: "checkmark.seal")
                    } else {
                        Table(result.missing) {
                            TableColumn("File") { Text(verbatim: $0.filename) }.width(180)
                            TableColumn("Expected location") { Text(verbatim: $0.expectedPath) }
                            TableColumn("Found at") { item in
                                if let candidate = item.candidate {
                                    Text(verbatim: (item.candidateIsOrphan ? "⟲ " : "") + (item.candidateSizeDiffers ? "≈ " : "") + candidate.path)
                                        .foregroundStyle(Color.green)
                                        .help(item.candidateSizeDiffers
                                              ? "Same shot (file name and EXIF capture time match) but a slightly different size: usually the untouched original, without metadata embedded later."
                                              : (item.candidateIsOrphan ? "Orphan inside the catalog: will be moved into place" : "Found outside the catalog: will be copied"))
                                } else if let indexed = item.alsoIndexedAt {
                                    Text("Already indexed at \(indexed)")
                                        .foregroundStyle(Color.orange)
                                        .help("Another catalog entry with the same file name has its file. This missing entry is a duplicate import; remove it in Capture One.")
                                } else {
                                    Text("")
                                }
                            }
                        }
                    }
                    if model.isSearching {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(verbatim: model.verifyProgress).foregroundStyle(.secondary)
                            Text("Found so far: \(result.foundCount)").foregroundStyle(.green)
                            Button("Cancel") { model.cancelVerify() }
                        }
                    }
                    HStack {
                        Menu("Search in…") {
                            ForEach(model.searchVolumes, id: \.self) { volume in
                                Button(volume.lastPathComponent) { model.searchMissing(in: volume) }
                            }
                            Divider()
                            Button("Other folder…") { model.searchMissing(in: nil) }
                            Button("Spotlight (indexed volumes)") { model.searchMissingWithSpotlight() }
                        }
                        .fixedSize()
                        .disabled(result.missing.isEmpty || model.isSearching)
                        Button("Restore found files into the catalog") { model.requestRestore() }
                            .disabled(result.foundCount == 0 || model.isSearching)
                        Text("Orphans inside the catalog are matched first (name and size) and restoring moves them into place; files found elsewhere are copied. Entries already indexed under another path are duplicate imports.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                case .unfiled:
                    if result.unfiled.isEmpty {
                        ContentUnavailableView("Every photo is in an album", systemImage: "checkmark.seal")
                    } else {
                        Table(result.unfiled) {
                            TableColumn("File") { Text(verbatim: $0.filename) }.width(180)
                            TableColumn("Path") { Text(verbatim: $0.path) }
                            TableColumn("Probable album") { item in
                                // "≈": solo una foto vecina está en ese álbum (menos seguro).
                                Text(verbatim: item.suggestion.map { ($0.confidence == .nearby ? "≈ " : "") + $0.album } ?? "")
                            }.width(200)
                            TableColumn("Duplicate of a photo in album") { item in
                                Text(verbatim: item.duplicateInAlbum ?? "")
                                    .foregroundStyle(.orange)
                            }.width(200)
                        }
                    }
                    HStack {
                        Button("Create \"\(ExportViewModel.unfiledAlbumName)\" group in Capture One") { model.requestUnfiledAlbum() }
                            .disabled(result.unfiled.isEmpty)
                        Text("Photos in the index but in no user album. \(result.unfiledDuplicates) are repeated copies (same file name and capture time) of a photo already in an album: they go to the album \"\(ExportViewModel.unfiledDuplicatesAlbumName)\". A probable album was found for \(result.unfiledWithSuggestion) of the rest, from capture time and file name sequence (\(result.suggestedAlbumCount) albums).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let message = model.verifyMessage {
                    Text(verbatim: message).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Verify again") { model.verifyCatalog() }
                    Button("Save report…") { model.saveVerifyReport() }
                    Spacer()
                }
            } else {
                ContentUnavailableView("Ready to verify", systemImage: "checkmark.shield",
                                       description: Text("Press Verify to compare the Originals folder with the catalog index."))
            }
        }
        .padding()
        .confirmationDialog("Move \(model.verifyResult?.orphans.count ?? 0) orphan files out of the catalog?",
                            isPresented: $model.showMoveOrphansConfirmation, titleVisibility: .visible) {
            Button("Move", role: .destructive) { model.moveOrphans() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They will be moved to \(model.orphanTargetFolder?.path ?? "") keeping their folder structure, so they can be imported again.")
        }
        .confirmationDialog("Add \(model.verifyResult?.unfiled.count ?? 0) photos to the group \"\(ExportViewModel.unfiledAlbumName)\"?",
                            isPresented: $model.showUnfiledAlbumConfirmation, titleVisibility: .visible) {
            Button("Create albums") { model.createUnfiledAlbum() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Capture One will open the catalog and create that group with one album per probable album, \"\(ExportViewModel.unfiledFallbackAlbumName)\" for the rest and \"\(ExportViewModel.unfiledDuplicatesAlbumName)\" for repeated copies of photos already in an album. Nothing is removed or moved.")
        }
        .confirmationDialog("Import \(model.verifyResult?.recoverableOrphans.count ?? 0) orphan photos into the group \"\(ExportViewModel.recoveredGroupName)\"?",
                            isPresented: $model.showRecoverOrphansConfirmation, titleVisibility: .visible) {
            Button("Import") { model.recoverOrphans() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Capture One will import a copy of each photo that is not in the catalog and file it in an album named after its probable album, or \"\(ExportViewModel.unfiledFallbackAlbumName)\". The orphan files themselves are not touched: after importing they become spare copies that you can move out. Copies of photos already in the catalog are not imported.")
        }
        .confirmationDialog("Restore \(model.verifyResult?.foundCount ?? 0) found files into the catalog?",
                            isPresented: $model.showRestoreConfirmation, titleVisibility: .visible) {
            Button("Restore") { model.restoreMissing() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Orphans found inside the catalog are moved into place; files found elsewhere are copied. Existing files are never overwritten.")
        }
    }

    private func summary(_ result: VerifyResult) -> some View {
        HStack(spacing: 16) {
            Text("Files in Originals: \(result.filesOnDisk)")
                .help("Every file physically present in the Originals folder inside the catalog, whether the catalog knows it or not.")
            Text("Referenced by the index: \(result.referenced)")
                .help("Photos the catalog database knows, including those stored outside the catalog and those in the Capture One trash.")
            Text("Orphans: \(result.orphans.count) (\(result.orphanBytes.formatted(.byteCount(style: .file))))")
                .foregroundStyle(result.orphans.isEmpty ? Color.primary : Color.orange)
                .help(Self.orphansHelp)
            Text("Missing files: \(result.missing.count)")
                .foregroundStyle(result.missing.isEmpty ? Color.primary : Color.red)
                .help(Self.missingHelp)
            Text("Not in any album: \(result.unfiled.count) (\(result.unfiledDuplicates) duplicates)")
                .help(Self.unfiledHelp)
        }
        .font(.callout)
    }
}

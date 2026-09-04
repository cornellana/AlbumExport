import SwiftUI

/// Panel de verificación: huérfanos en `Originals/`, ficheros ausentes y fotos sin álbum.
struct VerifyView: View {
    @Bindable var model: ExportViewModel
    @State private var tab: Tab = .orphans

    enum Tab: Hashable { case orphans, missing, unfiled }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.worker == nil {
                ContentUnavailableView("No catalog", systemImage: "books.vertical",
                                       description: Text("Open a Capture One catalog to verify it."))
            } else if model.isVerifying {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Verifying…")
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
                switch tab {
                case .orphans:
                    if result.orphans.isEmpty {
                        ContentUnavailableView("No orphan files", systemImage: "checkmark.seal")
                    } else {
                        Table(result.orphans) {
                            TableColumn("Path") { Text(verbatim: $0.relativePath) }
                            TableColumn("Size") { Text(verbatim: $0.size.formatted(.byteCount(style: .file))) }.width(90)
                        }
                    }
                    HStack {
                        Button("Move orphans to folder…") { model.chooseOrphanFolder() }
                            .disabled(result.orphans.isEmpty)
                        Text("Orphans are files inside Originals that the index does not know. Moving them keeps the folder structure so they can be imported again.")
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
                                    Text(verbatim: (item.candidateIsOrphan ? "⟲ " : "") + candidate.path)
                                        .foregroundStyle(Color.green)
                                        .help(item.candidateIsOrphan ? "Orphan inside the catalog: will be moved into place" : "Found outside the catalog: will be copied")
                                } else {
                                    Text("")
                                }
                            }
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
                        .disabled(result.missing.isEmpty)
                        Button("Restore found files into the catalog") { model.requestRestore() }
                            .disabled(result.foundCount == 0)
                        Text("Orphans inside the catalog are matched first (name and size) and restoring moves them into place; files found elsewhere are copied.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                case .unfiled:
                    if result.unfiled.isEmpty {
                        ContentUnavailableView("Every photo is in an album", systemImage: "checkmark.seal")
                    } else {
                        Table(result.unfiled) {
                            TableColumn("File") { Text(verbatim: $0.filename) }.width(180)
                            TableColumn("Path") { Text(verbatim: $0.path) }
                        }
                    }
                    Text("Photos that are in the catalog index but in no user album. They are still part of the catalog; this list is informative.")
                        .font(.caption).foregroundStyle(.secondary)
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
            Text("Referenced by the index: \(result.referenced)")
            Text("Orphans: \(result.orphans.count) (\(result.orphanBytes.formatted(.byteCount(style: .file))))")
                .foregroundStyle(result.orphans.isEmpty ? Color.primary : Color.orange)
            Text("Missing files: \(result.missing.count)")
                .foregroundStyle(result.missing.isEmpty ? Color.primary : Color.red)
            Text("Not in any album: \(result.unfiled.count)")
        }
        .font(.callout)
    }
}

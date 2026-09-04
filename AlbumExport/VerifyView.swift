import SwiftUI

/// Hoja con el resultado de la verificación: huérfanos en `Originals/` y ficheros ausentes.
struct VerifyView: View {
    @Bindable var model: ExportViewModel
    @State private var tab: Tab = .orphans

    enum Tab: Hashable { case orphans, missing }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Verify catalog integrity").font(.title2).bold()
            if model.isVerifying {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Verifying…")
                }
            } else if let result = model.verifyResult {
                summary(result)
                Picker("", selection: $tab) {
                    Text("Orphan files").tag(Tab.orphans)
                    Text("Missing files").tag(Tab.missing)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 320)
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
                case .missing:
                    if result.missing.isEmpty {
                        ContentUnavailableView("No missing files", systemImage: "checkmark.seal")
                    } else {
                        Table(result.missing) {
                            TableColumn("File") { Text(verbatim: $0.filename) }.width(200)
                            TableColumn("Expected location") { Text(verbatim: $0.expectedPath) }
                        }
                    }
                }
                if let summary = model.orphanMoveSummary {
                    Text(verbatim: summary).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Move orphans to folder…") { model.chooseOrphanFolder() }
                    .disabled(model.isVerifying || (model.verifyResult?.orphans.isEmpty ?? true))
                Button("Save report…") { model.saveVerifyReport() }
                    .disabled(model.isVerifying || model.verifyResult == nil)
                Spacer()
                Button("Close") { model.showVerify = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(minWidth: 760, minHeight: 480)
        .confirmationDialog("Move \(model.verifyResult?.orphans.count ?? 0) orphan files out of the catalog?",
                            isPresented: $model.showMoveOrphansConfirmation, titleVisibility: .visible) {
            Button("Move", role: .destructive) { model.moveOrphans() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They will be moved to \(model.orphanTargetFolder?.path ?? "") keeping their folder structure, so they can be imported again.")
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
        }
        .font(.callout)
    }
}

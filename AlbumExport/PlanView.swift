import SwiftUI

/// Panel de detalle: información del catálogo, opciones, tabla del plan y progreso.
struct PlanView: View {
    @Bindable var model: ExportViewModel

    var body: some View {
        VStack(spacing: 0) {
            CatalogHeaderView(model: model)
                .padding()
            Divider()
            OptionsBarView(options: $model.options)
                .padding(.horizontal)
                .padding(.vertical, 8)
            Divider()
            if let plan = model.plan, !plan.jobs.isEmpty {
                SummaryBarView(plan: plan, move: model.options.move, isPlanning: model.isPlanning)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                JobsTableView(jobs: plan.jobs)
            } else {
                ContentUnavailableView(
                    "No plan yet",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("Enter a pattern or select albums in the sidebar."))
            }
            Divider()
            FooterView(model: model)
                .padding()
        }
    }
}

// MARK: - Cabecera

struct CatalogHeaderView: View {
    let model: ExportViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Catalog") {
                if let url = model.catalogURL {
                    Text(verbatim: url.path).textSelection(.enabled)
                } else {
                    Text("Not chosen").foregroundStyle(.secondary)
                }
            }
            if let version = model.catalogVersion {
                LabeledContent("Version") {
                    Text("Capture One \(version.application), format \(version.format)")
                }
            }
            LabeledContent("Destination") {
                if let url = model.destinationURL {
                    Text(verbatim: url.path).textSelection(.enabled)
                } else {
                    Text("Not chosen").foregroundStyle(.secondary)
                }
            }
            LabeledContent("exiftool") {
                if let url = model.exiftoolURL {
                    Text("\(model.exiftoolVersion ?? "…") at \(url.path)")
                } else {
                    Text("exiftool not found. Install it with Homebrew: brew install exiftool")
                        .foregroundStyle(.red)
                }
            }
            ForEach(model.catalogWarnings, id: \.self) { warning in
                Label { Text(verbatim: warning) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Opciones

struct OptionsBarView: View {
    @Binding var options: ExportOptions

    var body: some View {
        HStack(spacing: 16) {
            Picker("Action", selection: $options.move) {
                Text("Copy").tag(false)
                Text("Move").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 140)
            Toggle("Write metadata (XMP)", isOn: $options.writeMetadata)
            Toggle("Adjustments JSON", isOn: $options.adjustmentsJSON)
            Toggle("Include trash", isOn: $options.includeTrashed)
            Toggle("Include automatic albums", isOn: $options.includeAutoAlbums)
            Toggle("Refresh already exported", isOn: $options.refreshExisting)
            Spacer()
        }
        .toggleStyle(.checkbox)
        .font(.callout)
    }
}

// MARK: - Resumen

struct SummaryBarView: View {
    let plan: ExportPlan
    let move: Bool
    let isPlanning: Bool

    var body: some View {
        HStack(spacing: 16) {
            let size = plan.totalBytes.formatted(.byteCount(style: .file))
            if move {
                Text("\(plan.plannedCount) photos to move, \(size)").fontWeight(.semibold)
            } else {
                Text("\(plan.plannedCount) photos to copy, \(size)").fontWeight(.semibold)
            }
            Text("Inside catalog bundle: \(plan.insideCatalogCount)")
            Text("Skipped: \(plan.skippedTrashed) in trash, \(plan.missingSources) not found")
            if move && plan.insideCatalogCount > 0 {
                Label("Moving photos stored inside the catalog bundle leaves them offline in Capture One.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Spacer()
            if isPlanning {
                ProgressView().controlSize(.small)
                Text("Planning…").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }
}

// MARK: - Tabla

struct JobsTableView: View {
    let jobs: [ExportJob]

    var body: some View {
        Table(jobs) {
            TableColumn("Album") { job in Text(verbatim: job.album.name) }
            TableColumn("File") { job in Text(verbatim: job.photo.filename) }
            TableColumn("Rating") { job in StarsView(rating: job.photo.rating ?? 0) }
                .width(90)
            TableColumn("Color") { job in ColorDotView(tag: job.photo.colorTag ?? .none) }
                .width(50)
            TableColumn("Keywords") { job in Text(verbatim: job.photo.keywords.joined(separator: ", ")) }
            TableColumn("Status") { job in
                Text(verbatim: job.status.label)
                    .foregroundStyle(statusColor(job.status))
            }
        }
    }

    private func statusColor(_ status: JobStatus) -> Color {
        switch status {
        case .done, .doneWithoutMetadata: .green
        case .alreadyExported, .pending, .copied: .primary
        case .skippedTrashed, .missingSource: .secondary
        case .verificationFailed, .failed: .red
        }
    }
}

/// Estrellas de valoración (0–5).
struct StarsView: View {
    let rating: Int

    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<5, id: \.self) { index in
                Image(systemName: index < rating ? "star.fill" : "star")
                    .font(.caption2)
                    .foregroundStyle(index < rating ? Color.yellow : Color.secondary.opacity(0.4))
            }
        }
        .accessibilityLabel(Text("Rating \(rating)"))
    }
}

/// Punto con el color de la etiqueta.
struct ColorDotView: View {
    let tag: ColorTag

    var body: some View {
        Circle()
            .fill(color)
            .overlay(Circle().strokeBorder(.secondary.opacity(0.4)))
            .frame(width: 14, height: 14)
            .help(tag.localizedName)
            .accessibilityLabel(Text(verbatim: tag.localizedName))
    }

    private var color: Color {
        switch tag {
        case .none: .clear
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .pink: .pink
        case .purple: .purple
        }
    }
}

// MARK: - Pie

struct FooterView: View {
    let model: ExportViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.isRunning {
                ProgressView(value: Double(model.progressCompleted), total: Double(max(model.progressTotal, 1)))
                HStack {
                    Text("\(model.progressCompleted) of \(model.progressTotal)")
                        .monospacedDigit()
                    Text(verbatim: model.currentFile)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .font(.callout)
            } else if let summary = model.summary {
                HStack {
                    Label("Exported \(summary.successCount) of \(summary.totalCount) photos", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(summary.successCount == summary.totalCount ? Color.green : Color.orange)
                    Button("Show Report") { model.revealReport() }
                    Button("Show in Finder") { model.revealDestination() }
                }
            }
            ForEach(model.logLines.suffix(3), id: \.self) { line in
                Text(verbatim: line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

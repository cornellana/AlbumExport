import SwiftUI

@main
struct AlbumExportApp: App {
    @State private var model = ExportViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Catalog…") { model.chooseCatalog() }
                    .keyboardShortcut("o")
            }
        }
    }
}

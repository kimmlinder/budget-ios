import SwiftData
import SwiftUI

@main
struct LightroomCanonApp: App {
    /// Shared SwiftData store for the catalog, edits, and presets.
    let container: ModelContainer = {
        do {
            return try ModelContainer(for: Photo.self, EditSettings.self, Preset.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            LibraryView()
        }
        .modelContainer(container)
        #if os(macOS)
        .windowStyle(.titleBar)
        #endif
    }
}

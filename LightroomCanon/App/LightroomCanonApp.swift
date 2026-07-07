import SwiftData
import SwiftUI

@main
struct LightroomCanonApp: App {
    /// Shared SwiftData store for the catalog, edits, and presets. CloudKit
    /// sync is gated behind `AppConfig.iCloudSyncEnabled` — see its doc
    /// comment for what's required to turn it on.
    let container: ModelContainer = {
        let schema = Schema([Photo.self, EditSettings.self, Preset.self, LUTPreset.self, MaskLayer.self])
        let configuration = ModelConfiguration(
            schema: schema,
            cloudKitDatabase: AppConfig.iCloudSyncEnabled ? .automatic : .none
        )
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                // Matches the reference design's dark-room-style editor
                // (see Theme) — a permanent dark UI regardless of system
                // appearance, the same convention Lightroom/Capture One/
                // Photoshop use since a bright chrome around the photo being
                // judged skews color perception.
                .preferredColorScheme(.dark)
        }
        .modelContainer(container)
        #if os(macOS)
        .windowStyle(.titleBar)
        #endif
    }
}

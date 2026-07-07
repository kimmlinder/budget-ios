import SwiftData
import SwiftUI

/// The catalog grid: imported photos as thumbnails, with an import button.
/// Tapping a photo opens the editor.
struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Photo.importDate, order: .reverse) private var photos: [Photo]

    @State private var showingImporter = false
    @State private var importError: String?
    private var clipboard: EditClipboard { .shared }

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 8)]

    var body: some View {
        NavigationStack {
            Group {
                if photos.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(photos) { photo in
                                NavigationLink(value: photo) {
                                    ThumbnailCell(photo: photo)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button {
                                        clipboard.copiedValues = photo.settings?.values
                                    } label: {
                                        Label("Copy Edit Settings", systemImage: "doc.on.doc")
                                    }
                                    if clipboard.copiedValues != nil {
                                        Button {
                                            paste(into: photo)
                                        } label: {
                                            Label("Paste Edit Settings", systemImage: "doc.on.clipboard")
                                        }
                                    }
                                    Button(role: .destructive) { delete(photo) } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding(8)
                    }
                }
            }
            .background(Theme.canvasBackground)
            .navigationTitle("Library")
            .navigationDestination(for: Photo.self) { photo in
                EditorView(photo: photo)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingImporter = true
                    } label: {
                        Label("Import", systemImage: "plus")
                    }
                }
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: ImportService.canonRAWTypes,
                allowsMultipleSelection: true
            ) { result in
                handleImport(result)
            }
            .alert("Import Failed", isPresented: .constant(importError != nil)) {
                Button("OK") { importError = nil }
            } message: {
                Text(importError ?? "")
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Photos", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("Import Canon RAW files (.CR2 / .CR3) to start editing.")
        } actions: {
            Button("Import Photos") { showingImporter = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls {
                do {
                    let photo = try ImportService.makePhoto(from: url)
                    context.insert(photo)
                    generateThumbnail(for: photo)
                } catch {
                    importError = error.localizedDescription
                }
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    private func generateThumbnail(for photo: Photo) {
        guard let url = photo.resolveURL() else { return }
        let id = photo.id
        Task.detached(priority: .utility) {
            // Heavy decode happens off the main actor using only the URL...
            let filename = ThumbnailService.generate(from: url, id: id)
            guard let filename else { return }
            // ...then we hop back to the main actor to touch the model.
            await MainActor.run {
                let descriptor = FetchDescriptor<Photo>(predicate: #Predicate { $0.id == id })
                if let fresh = try? context.fetch(descriptor).first {
                    fresh.thumbnailFilename = filename
                }
            }
        }
    }

    private func paste(into photo: Photo) {
        guard let values = clipboard.copiedValues else { return }
        if photo.settings == nil { photo.settings = EditSettings() }
        photo.settings?.apply(values)
    }

    private func delete(_ photo: Photo) {
        if let filename = photo.thumbnailFilename {
            try? FileManager.default.removeItem(at: ThumbnailService.url(for: filename))
        }
        for mask in photo.masks {
            MaskStorageService.delete(mask.maskFilename)
        }
        context.delete(photo)
    }
}

/// A single thumbnail tile with a filename caption.
private struct ThumbnailCell: View {
    let photo: Photo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                if let filename = photo.thumbnailFilename,
                   let image = Image(contentsOfFile: ThumbnailService.url(for: filename)) {
                    image
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(photo.filename)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

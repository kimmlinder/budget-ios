import SwiftData
import SwiftUI

/// Which subset of the catalog the sidebar currently selects — mirrors the
/// reference design's "CATALOG"/"COLLECTIONS" sidebar sections.
enum LibraryFilter: Hashable {
    case allPhotos, flagged, rated, unrated
    case collection(PhotoCollection)

    var title: String {
        switch self {
        case .allPhotos: return "All Photos"
        case .flagged: return "Flagged"
        case .rated: return "Rated"
        case .unrated: return "Unrated"
        case .collection(let c): return c.name
        }
    }
}

enum LibrarySortOption: String, CaseIterable, Identifiable {
    case date = "Date", rating = "Rating", name = "Name"
    var id: String { rawValue }
}

/// The catalog: a Catalog/Collections sidebar plus a photo grid, matching
/// the reference design (see `Theme`). Tapping a photo opens the editor.
struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Photo.importDate, order: .reverse) private var photos: [Photo]
    @Query(sort: \PhotoCollection.createdDate) private var collections: [PhotoCollection]

    @State private var showingImporter = false
    @State private var importError: String?
    @State private var selectedFilter: LibraryFilter = .allPhotos
    @State private var sortOption: LibrarySortOption = .date
    @State private var showingNewCollection = false
    @State private var newCollectionName = ""
    private var clipboard: EditClipboard { .shared }

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 12)]

    private var filteredPhotos: [Photo] {
        switch selectedFilter {
        case .allPhotos: return photos
        case .flagged: return photos.filter(\.isFlagged)
        case .rated: return photos.filter { $0.rating > 0 }
        case .unrated: return photos.filter { $0.rating == 0 }
        case .collection(let target): return photos.filter { $0.collections.contains { $0.id == target.id } }
        }
    }

    private var sortedPhotos: [Photo] {
        switch sortOption {
        case .date: return filteredPhotos.sorted { $0.importDate > $1.importDate }
        case .rating: return filteredPhotos.sorted { $0.rating > $1.rating }
        case .name: return filteredPhotos.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            NavigationStack {
                Group {
                    if photos.isEmpty {
                        emptyState
                    } else {
                        gridContent
                    }
                }
                .background(Theme.canvasBackground)
                .navigationTitle(selectedFilter.title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
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
                        .tint(Theme.accent)
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
        .alert("New Collection", isPresented: $showingNewCollection) {
            TextField("Name", text: $newCollectionName)
            Button("Create") { createCollection() }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List {
            Section {
                catalogRow(.allPhotos, count: photos.count)
                catalogRow(.flagged, count: photos.filter(\.isFlagged).count)
                catalogRow(.rated, count: photos.filter { $0.rating > 0 }.count)
                catalogRow(.unrated, count: photos.filter { $0.rating == 0 }.count)
            } header: {
                Text("CATALOG").font(.caption.bold()).foregroundStyle(.secondary)
            }
            Section {
                ForEach(collections) { collection in
                    catalogRow(.collection(collection), count: collection.photos.count)
                        .contextMenu {
                            Button(role: .destructive) {
                                deleteCollection(collection)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
                Button {
                    newCollectionName = ""
                    showingNewCollection = true
                } label: {
                    Label("New Collection", systemImage: "plus")
                }
                .font(.subheadline)
            } header: {
                Text("COLLECTIONS").font(.caption.bold()).foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Theme.panelBackground)
        .navigationTitle("Library")
    }

    private func catalogRow(_ filter: LibraryFilter, count: Int) -> some View {
        Button {
            selectedFilter = filter
        } label: {
            HStack {
                Text(filter.title)
                    .foregroundStyle(selectedFilter == filter ? Theme.accent : .primary)
                Spacer()
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Grid

    private var gridContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(sortedPhotos.count) photo\(sortedPhotos.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Sort", selection: $sortOption) {
                    ForEach(LibrarySortOption.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .tint(Theme.accent)
                .frame(maxWidth: 260)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.panelBackground)
            Divider()
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(sortedPhotos) { photo in
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
                            Button { photo.isFlagged.toggle() } label: {
                                Label(photo.isFlagged ? "Unflag" : "Flag", systemImage: "flag")
                            }
                            Menu("Rating") {
                                ForEach(0...5, id: \.self) { stars in
                                    Button {
                                        photo.rating = stars
                                    } label: {
                                        Label(stars == 0 ? "Unrated" : String(repeating: "★", count: stars),
                                              systemImage: photo.rating == stars ? "checkmark" : "")
                                    }
                                }
                            }
                            if !collections.isEmpty {
                                Menu("Add to Collection") {
                                    ForEach(collections) { collection in
                                        Button {
                                            toggle(photo, in: collection)
                                        } label: {
                                            Label(
                                                collection.name,
                                                systemImage: collection.photos.contains { $0.id == photo.id }
                                                    ? "checkmark" : ""
                                            )
                                        }
                                    }
                                }
                            }
                            Button(role: .destructive) { delete(photo) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(12)
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
                .tint(Theme.accent)
        }
    }

    // MARK: - Actions

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
        if case .collection(let target) = selectedFilter, target.photos.allSatisfy({ $0.id == photo.id }) {
            selectedFilter = .allPhotos
        }
        context.delete(photo)
    }

    private func createCollection() {
        let name = newCollectionName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        context.insert(PhotoCollection(name: name))
    }

    private func deleteCollection(_ collection: PhotoCollection) {
        if case .collection(let target) = selectedFilter, target.id == collection.id {
            selectedFilter = .allPhotos
        }
        context.delete(collection)
    }

    private func toggle(_ photo: Photo, in collection: PhotoCollection) {
        if let index = collection.photos.firstIndex(where: { $0.id == photo.id }) {
            collection.photos.remove(at: index)
        } else {
            collection.photos.append(photo)
        }
    }
}

/// A single thumbnail tile with filename, star rating, and flag — matching
/// the reference design's grid cell (see `Theme`).
private struct ThumbnailCell: View {
    @Bindable var photo: Photo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.panelBackground)
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
                if photo.isFlagged {
                    Image(systemName: "flag.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                        .padding(6)
                        .shadow(color: .black.opacity(0.6), radius: 2)
                }
            }
            .frame(height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(photo.isFlagged ? Theme.accent : .clear, lineWidth: 2)
            )

            Text(photo.filename)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 1) {
                ForEach(1...5, id: \.self) { star in
                    Image(systemName: star <= photo.rating ? "star.fill" : "star")
                        .font(.caption2)
                        .foregroundStyle(star <= photo.rating ? Theme.accent : .secondary)
                        .onTapGesture { photo.rating = (photo.rating == star ? 0 : star) }
                }
            }
        }
    }
}

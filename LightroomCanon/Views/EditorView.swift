import CoreImage
import SwiftData
import SwiftUI

/// The develop screen: a live Metal preview beside the adjustment panels.
///
/// Editing flows through a single local `values` snapshot. Every change updates
/// the GPU preview and is written back to the photo's persisted `EditSettings`,
/// keeping edits non-destructive (the RAW is never modified).
struct EditorView: View {
    @Bindable var photo: Photo
    @Environment(\.modelContext) private var context
    @Query(sort: \Preset.createdDate, order: .reverse) private var presets: [Preset]

    @State private var values = AdjustmentValues.neutral
    @State private var processor: RAWProcessor?
    @State private var preview: CIImage?
    @State private var sourceURL: URL?
    @State private var accessingScope = false
    @State private var loaded = false

    @State private var showingOriginal = false
    @State private var showingExport = false
    @State private var savingPreset = false
    @State private var newPresetName = ""
    @State private var loadFailed = false

    var body: some View {
        GeometryReader { geo in
            let sideBySide = geo.size.width > 720
            Group {
                if sideBySide {
                    HStack(spacing: 0) {
                        previewArea
                        Divider()
                        controlPanel.frame(width: 320)
                    }
                } else {
                    VStack(spacing: 0) {
                        previewArea.frame(height: geo.size.height * 0.5)
                        Divider()
                        controlPanel
                    }
                }
            }
        }
        .navigationTitle(photo.filename)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingExport = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(sourceURL == nil)
            }
        }
        .task { loadIfNeeded() }
        .onDisappear { stopAccess() }
        .onChange(of: values) { _, newValue in
            photo.settings?.apply(newValue)
            updatePreview()
        }
        .onChange(of: showingOriginal) { _, _ in updatePreview() }
        .sheet(isPresented: $showingExport) {
            if let sourceURL {
                ExportSheet(sourceURL: sourceURL, values: values) { showingExport = false }
            }
        }
        .alert("Couldn’t open RAW", isPresented: $loadFailed) {
            Button("OK") {}
        } message: {
            Text("This file could not be decoded. It may have moved or be an unsupported format.")
        }
    }

    // MARK: - Preview

    private var previewArea: some View {
        ZStack {
            Color.black
            if preview != nil {
                MetalImageView(image: preview)
            } else if !loadFailed {
                ProgressView().tint(.white)
            }
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        // Press-and-hold to peek at the original.
                    } label: {
                        Label("Original", systemImage: "eye")
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .opacity(0.9)
                    ._onLongPressPeek { showingOriginal = $0 }
                    .padding()
                }
            }
        }
    }

    // MARK: - Controls

    private var controlPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                presetSection
                PanelSection(title: "Light") {
                    AdjustmentSlider(title: "Exposure", value: $values.exposure)
                    AdjustmentSlider(title: "Contrast", value: $values.contrast)
                    AdjustmentSlider(title: "Highlights", value: $values.highlights)
                    AdjustmentSlider(title: "Shadows", value: $values.shadows)
                    AdjustmentSlider(title: "Whites", value: $values.whites)
                    AdjustmentSlider(title: "Blacks", value: $values.blacks)
                }
                PanelSection(title: "Color") {
                    AdjustmentSlider(title: "Temperature", value: $values.temperature)
                    AdjustmentSlider(title: "Tint", value: $values.tint)
                    AdjustmentSlider(title: "Vibrance", value: $values.vibrance)
                    AdjustmentSlider(title: "Saturation", value: $values.saturation)
                }
                geometrySection
                Button(role: .destructive) {
                    values = keepingCrop(.neutral)
                } label: {
                    Label("Reset Adjustments", systemImage: "arrow.uturn.backward")
                }
                .padding(.top, 4)
            }
            .padding()
        }
    }

    private var presetSection: some View {
        PanelSection(title: "Presets") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(presets) { preset in
                        Button(preset.name) {
                            values = preset.applied(onto: values)
                        }
                        .buttonStyle(.bordered)
                        .contextMenu {
                            Button(role: .destructive) { context.delete(preset) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            Button {
                newPresetName = ""
                savingPreset = true
            } label: {
                Label("Save Current as Preset", systemImage: "plus.square.on.square")
            }
            .alert("New Preset", isPresented: $savingPreset) {
                TextField("Name", text: $newPresetName)
                Button("Save") { savePreset() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private var geometrySection: some View {
        PanelSection(title: "Crop & Rotate") {
            HStack {
                Button { rotate(by: -90) } label: { Image(systemName: "rotate.left") }
                Button { rotate(by: 90) } label: { Image(systemName: "rotate.right") }
                Spacer()
                Menu("Aspect") {
                    Button("Original") { applyAspect(nil) }
                    Button("Square 1:1") { applyAspect(1) }
                    Button("4:3") { applyAspect(4.0 / 3.0) }
                    Button("3:2") { applyAspect(3.0 / 2.0) }
                    Button("16:9") { applyAspect(16.0 / 9.0) }
                }
            }
            .buttonStyle(.bordered)
            AdjustmentSlider(title: "Straighten", value: $values.straighten, range: -45...45)
        }
    }

    // MARK: - Actions

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if photo.settings == nil { photo.settings = EditSettings() }
        values = photo.settings?.values ?? .neutral

        guard let url = photo.resolveURL() else { loadFailed = true; return }
        accessingScope = url.startAccessingSecurityScopedResource()
        sourceURL = url
        let p = RAWProcessor(url: url)
        guard p.isValid else { loadFailed = true; return }
        processor = p
        updatePreview()
    }

    private func stopAccess() {
        if accessingScope, let sourceURL {
            sourceURL.stopAccessingSecurityScopedResource()
            accessingScope = false
        }
    }

    private func updatePreview() {
        let v = showingOriginal ? keepingCrop(.neutral) : values
        preview = processor?.makeImage(v)
    }

    /// Return `base` but with the current crop/rotation preserved.
    private func keepingCrop(_ base: AdjustmentValues) -> AdjustmentValues {
        var v = base
        v.straighten = values.straighten
        v.rotation = values.rotation
        v.cropX = values.cropX; v.cropY = values.cropY
        v.cropWidth = values.cropWidth; v.cropHeight = values.cropHeight
        return v
    }

    private func rotate(by degrees: Int) {
        values.rotation = (((values.rotation + degrees) % 360) + 360) % 360
    }

    private func applyAspect(_ ratio: Double?) {
        guard let ratio, let extent = processor?.nativeExtent, extent.height > 0 else {
            values.cropX = 0; values.cropY = 0; values.cropWidth = 1; values.cropHeight = 1
            return
        }
        let imageAspect = extent.width / extent.height
        var w = 1.0, h = 1.0
        if ratio >= imageAspect {
            h = imageAspect / ratio
        } else {
            w = ratio / imageAspect
        }
        values.cropWidth = w
        values.cropHeight = h
        values.cropX = (1 - w) / 2
        values.cropY = (1 - h) / 2
    }

    private func savePreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        context.insert(Preset(name: name, values: values))
    }
}

/// A titled group of controls with a light divider, matching the sidebar look.
struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            content
        }
    }
}

private extension View {
    /// Reports `true` while pressed and `false` on release — used for the
    /// press-and-hold "show original" peek.
    func _onLongPressPeek(_ change: @escaping (Bool) -> Void) -> some View {
        self.simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in change(true) }
                .onEnded { _ in change(false) }
        )
    }
}

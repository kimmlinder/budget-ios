import CoreImage
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The develop screen: a live Metal preview beside the adjustment panels.
///
/// Editing flows through a single local `values` snapshot. Every change updates
/// the GPU preview and is written back to the photo's persisted `EditSettings`,
/// keeping edits non-destructive (the RAW is never modified).
struct EditorView: View {
    @Bindable var photo: Photo
    @Environment(\.modelContext) private var context
    @Query(sort: \Preset.createdDate, order: .reverse) private var presets: [Preset]
    @Query(sort: \LUTPreset.createdDate, order: .reverse) private var lutPresets: [LUTPreset]

    @State private var values = AdjustmentValues.neutral
    @State private var processor: RAWProcessor?
    @State private var preview: CIImage?
    @State private var histogramData: HistogramData?
    @State private var sourceURL: URL?
    @State private var accessingScope = false
    @State private var loaded = false
    private var clipboard: EditClipboard { .shared }

    @State private var showingOriginal = false
    @State private var showingExport = false
    @State private var savingPreset = false
    @State private var newPresetName = ""
    @State private var loadFailed = false
    @State private var isDetectingGeometry = false
    @State private var geometryDetectionFailed = false
    @State private var histogramGeneration = 0
    @State private var isCloudStraightening = false
    @State private var cloudStraightenErrorMessage: String?
    @State private var showingLUTImporter = false
    @State private var lutImportError: String?
    @State private var toneCurveChannel: ToneCurveChannel = .rgb
    @State private var showingPresetPackImporter = false
    @State private var presetImportError: String?
    @State private var persistTask: Task<Void, Never>?
    @State private var history = EditHistory()
    @State private var historyPushTask: Task<Void, Never>?

    /// Cached SAM image encoding for the Masking panel's Subject/Sky/
    /// Background/tap-to-select actions — see `withSAMEmbedding()`. `nil`
    /// until the first masking action of this editing session.
    @State private var samEmbedding: SAMSegmentationService.SAMImageEmbedding?
    @State private var isSegmenting = false
    @State private var segmentationError: String?
    /// While `true`, the next tap on the preview becomes a manual SAM point
    /// prompt instead of the usual "peek at original" gesture area.
    @State private var isPickingMaskPoint = false
    @State private var selectedMaskID: UUID?
    /// Whether the Masking side panel (see `maskingSection`) is open — a
    /// dedicated `.inspector` rather than another entry in `controlPanel`'s
    /// long scrolling list, since that buried it hard enough to not be found.
    @State private var showingMaskingPanel = false

    /// Whether this photo is currently rendered from a cloud-straightened
    /// override image rather than the original RAW — see
    /// `runCloudStraighten()` and `RAWProcessor.init(overrideImageURL:)`.
    private var isOverrideMode: Bool { photo.cloudStraightenedFilename != nil }

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
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    undo()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!history.canUndo)
                Button {
                    redo()
                } label: {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
                .disabled(!history.canRedo)
                Button {
                    showingExport = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(sourceURL == nil)
                Button {
                    showingMaskingPanel.toggle()
                } label: {
                    Label("Masking", systemImage: "checkerboard.rectangle")
                }
            }
        }
        .inspector(isPresented: $showingMaskingPanel) {
            ScrollView {
                maskingSection.padding()
            }
            .navigationTitle("Masking")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .inspectorColumnWidth(min: 260, ideal: 320, max: 420)
        }
        .task { loadIfNeeded() }
        .onDisappear {
            persistTask?.cancel()
            historyPushTask?.cancel()
            photo.settings?.apply(values)
            stopAccess()
        }
        .onChange(of: values) { _, newValue in
            updatePreview()
            schedulePersist(newValue)
            scheduleHistoryPush(newValue)
        }
        .onChange(of: showingOriginal) { _, _ in updatePreview() }
        .onChange(of: values.guideLines) { _, newLines in
            if let resolved = GuidedGeometry.resolve(newLines) {
                values.geometryCorrectionKind = resolved.kind
                values.geometryCorners = resolved.corners
                applyAutoCropIfNeeded()
            } else {
                values.geometryCorrectionKind = .none
                values.geometryCorners = []
            }
        }
        .sheet(isPresented: $showingExport) {
            if let sourceURL {
                ExportSheet(
                    sourceURL: sourceURL, values: values, isOverride: isOverrideMode, masks: resolvedMasks
                ) { showingExport = false }
            }
        }
        .alert("Couldn’t open RAW", isPresented: $loadFailed) {
            Button("OK") {}
        } message: {
            Text("This file could not be decoded. It may have moved or be an unsupported format.")
        }
        .alert("Cloud Straighten Failed", isPresented: .constant(cloudStraightenErrorMessage != nil)) {
            Button("OK") { cloudStraightenErrorMessage = nil }
        } message: {
            Text(cloudStraightenErrorMessage ?? "")
        }
    }

    // MARK: - Preview

    private var previewArea: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if preview != nil {
                    MetalImageView(image: preview)
                } else if !loadFailed {
                    ProgressView().tint(.white)
                }
                if values.geometryMode == .guided, let extent = processor?.nativeExtent {
                    let rect = aspectFitRect(imageSize: extent.size, in: geo.size)
                    GuidedLinesView(lines: $values.guideLines)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
                if isPickingMaskPoint {
                    Color.white.opacity(0.001) // hit-testable overlay for the tap gesture below
                        .gesture(
                            SpatialTapGesture().onEnded { value in
                                handleMaskTap(at: value.location, containerSize: geo.size)
                            }
                        )
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
    }

    /// Where `imageSize` lands within `containerSize` under aspect-fit
    /// centering — must match `MetalImageView`'s own scaling exactly so the
    /// Guided overlay lines up with the pixels underneath them.
    private func aspectFitRect(imageSize: CGSize, in containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              containerSize.width > 0, containerSize.height > 0
        else { return CGRect(origin: .zero, size: containerSize) }
        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(x: (containerSize.width - size.width) / 2, y: (containerSize.height - size.height) / 2)
        return CGRect(origin: origin, size: size)
    }

    // MARK: - Controls

    private var controlPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HistogramView(data: histogramData)
                copyPasteSection
                presetSection
                PanelSection(title: "Light") {
                    AdjustmentSlider(title: "Exposure", value: $values.exposure)
                    AdjustmentSlider(title: "Contrast", value: $values.contrast)
                    AdjustmentSlider(title: "Highlights", value: $values.highlights)
                    AdjustmentSlider(title: "Shadows", value: $values.shadows)
                    AdjustmentSlider(title: "Whites", value: $values.whites)
                    AdjustmentSlider(title: "Blacks", value: $values.blacks)
                }
                PanelSection(title: "Presence") {
                    AdjustmentSlider(title: "Texture", value: $values.texture)
                    AdjustmentSlider(title: "Clarity", value: $values.clarity)
                    AdjustmentSlider(title: "Dehaze", value: $values.dehaze)
                }
                PanelSection(title: "Tone Curve") {
                    Picker("Channel", selection: $toneCurveChannel) {
                        ForEach(ToneCurveChannel.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    switch toneCurveChannel {
                    case .rgb: ToneCurveView(points: $values.toneCurve)
                    case .red: ToneCurveView(points: $values.redToneCurve, color: .red)
                    case .green: ToneCurveView(points: $values.greenToneCurve, color: .green)
                    case .blue: ToneCurveView(points: $values.blueToneCurve, color: .blue)
                    }
                }
                PanelSection(title: "Color") {
                    Toggle("Black & White", isOn: $values.isBlackAndWhite)
                    HStack {
                        AdjustmentSlider(
                            title: "Temperature",
                            value: temperatureBinding,
                            range: 2000...12000,
                            neutral: nativeTemperature,
                            format: { String(format: "%.0fK", $0) }
                        )
                        whiteBalancePresetMenu
                    }
                    AdjustmentSlider(title: "Tint", value: $values.tint)
                    AdjustmentSlider(title: "Vibrance", value: $values.vibrance)
                        .disabled(values.isBlackAndWhite)
                    AdjustmentSlider(title: "Saturation", value: $values.saturation)
                        .disabled(values.isBlackAndWhite)
                }
                PanelSection(title: "HSL") {
                    HSLView(bands: $values.hslBands)
                }
                PanelSection(title: "Detail") {
                    AdjustmentSlider(
                        title: "Sharpening", value: $values.sharpness,
                        range: 0...100, format: { String(format: "%.0f", $0) }
                    )
                    AdjustmentSlider(
                        title: "Noise Reduction", value: $values.noiseReduction,
                        range: 0...100, format: { String(format: "%.0f", $0) }
                    )
                }
                lensSection
                geometryModeSection
                geometrySection
                calibrationSection
                colorGradingSection
                lookSection
                Button(role: .destructive) {
                    resetAdjustments()
                } label: {
                    Label("Reset Adjustments", systemImage: "arrow.uturn.backward")
                }
                .padding(.top, 4)
            }
            .padding()
        }
    }

    private var copyPasteSection: some View {
        HStack {
            Button {
                clipboard.copiedValues = values
            } label: {
                Label("Copy Settings", systemImage: "doc.on.doc")
            }
            if clipboard.copiedValues != nil {
                Button {
                    values = clipboard.copiedValues ?? values
                } label: {
                    Label("Paste Settings", systemImage: "doc.on.clipboard")
                }
            }
        }
        .buttonStyle(.bordered)
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
            Button {
                showingPresetPackImporter = true
            } label: {
                Label("Import Presets (.zip or .xmp)…", systemImage: "shippingbox")
            }
            .buttonStyle(.bordered)
        }
        .fileImporter(
            isPresented: $showingPresetPackImporter,
            allowedContentTypes: [.zip, UTType(filenameExtension: "xmp") ?? .xml],
            allowsMultipleSelection: true
        ) { result in
            handlePresetPackImport(result)
        }
        .alert("Preset Import Failed", isPresented: .constant(presetImportError != nil)) {
            Button("OK") { presetImportError = nil }
        } message: {
            Text(presetImportError ?? "")
        }
    }

    /// Fixed Kelvin presets, matching the values most editors settle on for
    /// these lighting conditions. "As Shot" is the sentinel `0` — the
    /// camera's own as-shot white balance (see `RAWProcessor`).
    private var whiteBalancePresetMenu: some View {
        Menu {
            Button("As Shot") { values.temperature = 0 }
            Button("Daylight (5500K)") { values.temperature = 5500 }
            Button("Cloudy (6500K)") { values.temperature = 6500 }
            Button("Shade (7500K)") { values.temperature = 7500 }
            Button("Tungsten (2850K)") { values.temperature = 2850 }
            Button("Fluorescent (3800K)") { values.temperature = 3800 }
            Button("Flash (5500K)") { values.temperature = 5500 }
        } label: {
            Image(systemName: "eyedropper.halffull")
        }
        .menuIndicator(.hidden)
    }

    private var lensSection: some View {
        PanelSection(title: "Lens Corrections") {
            Toggle("Distortion, Vignette & CA", isOn: $values.lensCorrectionEnabled)
                .disabled(!(processor?.lensCorrectionSupported ?? false))
            if processor?.lensCorrectionSupported == false {
                Text("No lens profile available for this photo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var geometryModeSection: some View {
        PanelSection(title: "Geometry") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(GeometryMode.allCases.filter { $0 != .off }) { mode in
                        Button(mode.label) { toggleGeometryMode(mode) }
                            .buttonStyle(.bordered)
                            .tint(values.geometryMode == mode ? .accentColor : .secondary)
                    }
                    Button {
                        runCloudStraighten()
                    } label: {
                        Label("Cloud", systemImage: "icloud")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isCloudStraightening || isOverrideMode)
                }
            }
            if isOverrideMode {
                HStack {
                    Text("Using a cloud-straightened image.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Revert to RAW", role: .destructive) { revertToRAW() }
                        .font(.caption)
                }
            }
            if isCloudStraightening {
                ProgressView("Straightening in the cloud…")
            } else if isDetectingGeometry {
                ProgressView("Detecting…")
            } else if geometryDetectionFailed {
                Text("Couldn't find a clear \(values.geometryMode == .level ? "horizon" : "rectangle") in this photo — try Guided instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if values.geometryMode == .vertical || values.geometryMode == .full || values.geometryMode == .auto {
                Text("Best-effort: squares up the most prominent rectangle in frame (a building, door, screen). Won't find a clean line in every photo.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if values.geometryMode == .guided {
                guidedLinesEditor
            }
            if values.geometryMode != .off {
                Toggle("Auto-crop ragged corners", isOn: $values.autoCropEnabled)
                    .font(.caption)
            }
        }
    }

    private var guidedLinesEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Drag on the preview to draw 2 vertical and/or 2 horizontal lines along edges that should be straight.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(values.guideLines) { line in
                HStack {
                    Text(line.isVertical ? "Vertical guide" : "Horizontal guide")
                        .font(.caption)
                    Spacer()
                    Button {
                        values.guideLines.removeAll { $0.id == line.id }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                }
            }
            if !values.guideLines.isEmpty {
                Button("Clear Guides", role: .destructive) { values.guideLines = [] }
                    .buttonStyle(.bordered)
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

    /// Fine-tunes the RAW's Red/Green/Blue primaries, matching Lightroom's
    /// Camera Calibration panel — the last panel in the Develop module,
    /// since it underlies rather than layers on top of the other color/tone
    /// edits (see `RAWProcessor.applyCalibration`).
    private var calibrationSection: some View {
        PanelSection(title: "Calibration") {
            Text("Red Primary")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            AdjustmentSlider(title: "Hue", value: $values.redHue)
            AdjustmentSlider(title: "Saturation", value: $values.redSaturation)
            Text("Green Primary")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            AdjustmentSlider(title: "Hue", value: $values.greenHue)
            AdjustmentSlider(title: "Saturation", value: $values.greenSaturation)
            Text("Blue Primary")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            AdjustmentSlider(title: "Hue", value: $values.blueHue)
            AdjustmentSlider(title: "Saturation", value: $values.blueSaturation)
        }
    }

    /// Tints shadows, midtones, highlights, and an overall Global range —
    /// see `ColorGradingKernel`. Uses linear Hue/Saturation/Luminance
    /// sliders per range rather than Lightroom's circular color-wheel
    /// pickers — functionally the same control (a wheel is just a polar
    /// hue/saturation picker), simpler to build here.
    private var colorGradingSection: some View {
        PanelSection(title: "Color Grading") {
            colorGradeZone(title: "Shadows", hue: $values.colorGradeShadowHue,
                           saturation: $values.colorGradeShadowSaturation,
                           luminance: $values.colorGradeShadowLuminance)
            colorGradeZone(title: "Midtones", hue: $values.colorGradeMidtoneHue,
                           saturation: $values.colorGradeMidtoneSaturation,
                           luminance: $values.colorGradeMidtoneLuminance)
            colorGradeZone(title: "Highlights", hue: $values.colorGradeHighlightHue,
                           saturation: $values.colorGradeHighlightSaturation,
                           luminance: $values.colorGradeHighlightLuminance)
            colorGradeZone(title: "Global", hue: $values.colorGradeGlobalHue,
                           saturation: $values.colorGradeGlobalSaturation,
                           luminance: $values.colorGradeGlobalLuminance)
            AdjustmentSlider(
                title: "Blending", value: $values.colorGradeBlending,
                range: 0...100, neutral: 50, format: { String(format: "%.0f", $0) }
            )
            AdjustmentSlider(title: "Balance", value: $values.colorGradeBalance)
        }
    }

    private func colorGradeZone(
        title: String, hue: Binding<Double>, saturation: Binding<Double>, luminance: Binding<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            AdjustmentSlider(
                title: "Hue", value: hue, range: 0...360, format: { String(format: "%.0f°", $0) }
            )
            AdjustmentSlider(title: "Saturation", value: saturation, range: 0...100,
                              format: { String(format: "%.0f", $0) })
            AdjustmentSlider(title: "Luminance", value: luminance)
        }
    }

    /// Local-adjustment masks — Subject/Sky/Background quick actions backed
    /// by on-device SAM segmentation (see `SAMSegmentationService`), plus a
    /// manual tap-to-select tool for anything else. Selecting a mask below
    /// shows its own `MaskDetailView` sliders, composited on top of the
    /// global edit in stacking order — see `RAWProcessor.applyLocalMasks`.
    private var maskingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    addSubjectMask()
                } label: {
                    Label("Subject", systemImage: MaskKind.subject.iconName)
                }
                Button {
                    addSkyMask()
                } label: {
                    Label("Sky", systemImage: MaskKind.sky.iconName)
                }
                Button {
                    addBackgroundMask()
                } label: {
                    Label("Background", systemImage: MaskKind.background.iconName)
                }
            }
            .buttonStyle(.bordered)
            .disabled(isSegmenting)

            Button {
                isPickingMaskPoint.toggle()
            } label: {
                Label(
                    isPickingMaskPoint ? "Tap the Preview to Select…" : "Tap to Select…",
                    systemImage: MaskKind.custom.iconName
                )
            }
            .buttonStyle(.bordered)
            .tint(isPickingMaskPoint ? .accentColor : nil)
            .disabled(isSegmenting)

            if isSegmenting {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Segmenting…").font(.caption).foregroundStyle(.secondary)
                }
            }

            ForEach(photo.masks) { mask in
                MaskRowView(
                    mask: mask,
                    isSelected: mask.id == selectedMaskID,
                    onSelect: { selectedMaskID = mask.id },
                    onDelete: { deleteMask(mask) }
                )
                .onChange(of: mask.isEnabled) { _, _ in updatePreview() }
            }

            if let selectedMask = photo.masks.first(where: { $0.id == selectedMaskID }) {
                Divider()
                MaskDetailView(mask: selectedMask)
                    .onChange(of: selectedMask.values) { _, _ in updatePreview() }
            }
        }
        .alert("Segmentation Failed", isPresented: .constant(segmentationError != nil)) {
            Button("OK") { segmentationError = nil }
        } message: {
            Text(segmentationError ?? "")
        }
    }

    /// A grade from an imported `.cube` 3D LUT — see
    /// `LUTService`/`RAWProcessor.applyLUT`. Runs early, right after the
    /// highlight shoulder (like a camera-profile step), so Calibration and
    /// every Basic/HSL/tone-curve edit downstream is graded on top of it.
    private var lookSection: some View {
        PanelSection(title: "Look") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button("None") { values.lutFilename = nil }
                        .buttonStyle(.bordered)
                        .tint(values.lutFilename == nil ? .accentColor : .secondary)
                    ForEach(lutPresets) { preset in
                        Button(preset.name) {
                            values.lutFilename = preset.filename
                            if values.lutIntensity == 0 { values.lutIntensity = 100 }
                        }
                        .buttonStyle(.bordered)
                        .tint(values.lutFilename == preset.filename ? .accentColor : .secondary)
                        .contextMenu {
                            Button(role: .destructive) { deleteLUT(preset) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            if values.lutFilename != nil {
                AdjustmentSlider(
                    title: "Intensity", value: $values.lutIntensity,
                    range: 0...100, neutral: 100, format: { String(format: "%.0f", $0) }
                )
            }
            Button {
                showingLUTImporter = true
            } label: {
                Label("Import LUT (.cube)…", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)
        }
        .fileImporter(
            isPresented: $showingLUTImporter,
            allowedContentTypes: [UTType(filenameExtension: "cube") ?? .plainText]
        ) { result in
            handleLUTImport(result)
        }
        .alert("Import Failed", isPresented: .constant(lutImportError != nil)) {
            Button("OK") { lutImportError = nil }
        } message: {
            Text(lutImportError ?? "")
        }
    }

    // MARK: - Actions

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if photo.settings == nil { photo.settings = EditSettings() }
        values = photo.settings?.values ?? .neutral
        history.push(values)

        if let overrideURL = photo.resolveCloudStraightenedURL(),
           let p = RAWProcessor(overrideImageURL: overrideURL) {
            sourceURL = overrideURL
            processor = p
            updatePreview()
            return
        }

        guard let url = photo.resolveURL() else { loadFailed = true; return }
        accessingScope = url.startAccessingSecurityScopedResource()
        sourceURL = url
        // Interactive editing bakes one screen-resolution preview up front
        // and never touches the RAW's full 20-45+ megapixels again this
        // session — see `RAWProcessor.fastPreview`. Export and Cloud
        // Straighten each make their own full-quality processor instead of
        // reusing this one.
        guard let p = RAWProcessor.fastPreview(
            url: url, maxDimension: Self.screenPreviewDimension,
            lensCorrectionEnabled: values.lensCorrectionEnabled)
        else { loadFailed = true; return }
        processor = p
        updatePreview()
    }

    /// The screen's native longest edge, capped at 4K — comfortably more
    /// than any editing pane needs to display, but far short of a modern
    /// Canon RAW's native resolution (often 8000+ px on the long edge).
    private static var screenPreviewDimension: CGFloat {
        #if os(iOS)
        let screen = UIScreen.main
        return min(4096, max(screen.bounds.width, screen.bounds.height) * screen.scale)
        #elseif os(macOS)
        guard let screen = NSScreen.main else { return 2560 }
        return min(4096, max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor)
        #endif
    }

    /// The camera's as-shot white balance in Kelvin, or a reasonable default
    /// before the RAW has finished loading.
    private var nativeTemperature: Double { processor?.nativeTemperature ?? 5500 }

    /// Resolves the stored sentinel (`0` = as-shot) to the photo's actual
    /// native Kelvin for display, so the slider always reads a real value
    /// and starts parked at the camera's own white balance.
    private var temperatureBinding: Binding<Double> {
        Binding(
            get: { values.temperature > 0 ? values.temperature : nativeTemperature },
            set: { values.temperature = $0 }
        )
    }

    private func stopAccess() {
        if accessingScope, let sourceURL {
            sourceURL.stopAccessingSecurityScopedResource()
            accessingScope = false
        }
    }

    private func updatePreview() {
        // While actively placing Guided lines, show the uncorrected base
        // image so the lines stay glued to the real content — warping the
        // preview live would move the very edges the user is marking.
        let v = values.geometryMode == .guided
            ? geometryBaseValues()
            : (showingOriginal ? keepingCrop(.neutral) : values)
        let masks = showingOriginal ? [] : resolvedMasks
        preview = processor?.makeImage(v, masks: masks)
        updateHistogram()
    }

    /// Loads each enabled mask's saved bitmap from disk and pairs it with
    /// its `LocalAdjustmentValues` for `RAWProcessor.applyLocalMasks`. Reads
    /// happen on every preview update rather than being cached — masks only
    /// change when the user adds/removes/edits one (not on every slider
    /// tick of the *global* edit), so this stays cheap in practice.
    private var resolvedMasks: [RAWProcessor.ResolvedMask] {
        photo.masks.filter(\.isEnabled).compactMap { mask in
            guard let image = MaskStorageService.load(mask.maskFilename) else { return nil }
            return RAWProcessor.ResolvedMask(maskImage: image, values: mask.values)
        }
    }

    /// Recomputes the histogram off the main thread, coalesced to a 60 FPS
    /// cadence. `preview` is now always the small baked fast-preview bitmap
    /// (see `RAWProcessor.fastPreview`), and `HistogramService` downsamples
    /// it further to 256px before handing it to `CIAreaHistogram`, so each
    /// render is cheap — the ~16ms coalescing window just protects against a
    /// burst of slider ticks arriving faster than the display can show
    /// anyway (e.g. a dense trackpad drag on a ProMotion display), without
    /// throttling the histogram below an actual live frame rate the way a
    /// longer debounce would.
    private func updateHistogram() {
        guard let preview else { histogramData = nil; return }
        histogramGeneration += 1
        let generation = histogramGeneration
        Task.detached(priority: .userInitiated) {
            try? await Task.sleep(nanoseconds: 16_000_000)
            guard await MainActor.run(body: { generation == histogramGeneration }) else { return }
            let data = HistogramService.makeHistogram(for: preview)
            await MainActor.run {
                guard generation == histogramGeneration else { return }
                histogramData = data
            }
        }
    }

    /// Debounces the SwiftData write for `EditSettings` — it has ~25 stored
    /// properties, and writing all of them on every slider tick during a
    /// drag (potentially dozens per second) is needless main-thread overhead
    /// once the live preview (`updatePreview()`) already gives instant
    /// visual feedback independently. Only the tick that's still current
    /// 200ms later is actually persisted; `onDisappear` flushes immediately
    /// so a still-pending edit is never lost when leaving the screen.
    private func schedulePersist(_ newValue: AdjustmentValues) {
        persistTask?.cancel()
        persistTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            photo.settings?.apply(newValue)
        }
    }

    /// Debounces history entries the same way `schedulePersist` debounces the
    /// SwiftData write — one continuous slider drag should read as a single
    /// step to undo, not one per intermediate tick. Only the tick that's
    /// still current 500ms later is committed; `EditHistory.push` itself
    /// no-ops if that value already sits on top (e.g. right after `undo()`
    /// re-triggers this via `.onChange(of: values)`), so undo/redo never
    /// create a spurious new entry on their own.
    private func scheduleHistoryPush(_ newValue: AdjustmentValues) {
        historyPushTask?.cancel()
        historyPushTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            history.push(newValue)
        }
    }

    /// Commits whatever edit is still in flight before undoing/redoing, so a
    /// not-yet-debounced drag doesn't get silently skipped over.
    private func commitPendingHistory() {
        historyPushTask?.cancel()
        history.push(values)
    }

    private func undo() {
        commitPendingHistory()
        guard let previous = history.undo() else { return }
        values = previous
    }

    private func redo() {
        commitPendingHistory()
        guard let next = history.redo() else { return }
        values = next
    }

    /// `values` with crop/rotation/straighten reset and geometry correction
    /// disabled — the common starting point for both the Guided preview and
    /// the Auto/Level/Vertical/Full one-shot detectors, so detected corners
    /// and drawn guide lines land in the same coordinate space `RAWProcessor`
    /// applies them in.
    private func geometryBaseValues() -> AdjustmentValues {
        var v = values
        v.straighten = 0
        v.rotation = 0
        v.cropX = 0; v.cropY = 0; v.cropWidth = 1; v.cropHeight = 1
        v.geometryCorrectionKind = .none
        return v
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
        // The user is now taking manual control of the crop.
        values.cropIsAutoSet = false
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

    /// An auto-set crop only makes sense alongside the correction that
    /// produced it — trims it back to the full, uncropped frame whenever
    /// that correction is about to change or go away. A manually-chosen crop
    /// (see `applyAspect`) is left untouched.
    private func resetCropIfAutoSet() {
        guard values.cropIsAutoSet else { return }
        values.cropX = 0; values.cropY = 0; values.cropWidth = 1; values.cropHeight = 1
        values.cropIsAutoSet = false
    }

    /// Resets every tonal adjustment. Crop/rotation/straighten are normally
    /// preserved (composition, not "look" — see `keepingCrop`), except an
    /// auto-set crop, which reverts to the original, full frame along with
    /// the Upright correction it belonged to.
    private func resetAdjustments() {
        var v = keepingCrop(.neutral)
        if values.cropIsAutoSet {
            v.cropX = 0; v.cropY = 0; v.cropWidth = 1; v.cropHeight = 1
            v.cropIsAutoSet = false
        }
        values = v
        // The cached SAM embedding may no longer match the reset geometry —
        // see `withSAMEmbedding`.
        samEmbedding = nil
    }

    private func toggleGeometryMode(_ mode: GeometryMode) {
        selectGeometryMode(values.geometryMode == mode ? .off : mode)
    }

    /// Switching modes always starts from a clean slate — matching Lightroom,
    /// where picking a different Upright mode replaces rather than layers on
    /// top of the previous one.
    private func selectGeometryMode(_ mode: GeometryMode) {
        resetCropIfAutoSet()
        values.geometryMode = mode
        values.straighten = 0
        values.geometryCorrectionKind = .none
        values.geometryCorners = []
        values.guideLines = []
        geometryDetectionFailed = false

        switch mode {
        case .off, .guided:
            break
        case .level:
            runLevelDetection()
        case .vertical:
            runRectangleDetection(kind: .vertical)
        case .full:
            runRectangleDetection(kind: .combined)
        case .auto:
            runLevelDetection()
            runRectangleDetection(kind: .combined)
        }
    }

    /// Renders the detection base image synchronously on the main actor
    /// (RAWProcessor mutates shared filter state per call, so it can't safely
    /// run concurrently with the live preview), then hands the resulting
    /// — immutable, thread-safe — `CIImage` to Vision on a background task.
    private func runLevelDetection() {
        guard let processor, let image = processor.makeImage(geometryBaseValues()) else { return }
        isDetectingGeometry = true
        Task.detached(priority: .userInitiated) {
            let angle = GeometryDetectionService.detectLevelAngle(in: image)
            await MainActor.run {
                if let angle {
                    values.straighten = max(-45, min(45, angle))
                } else {
                    geometryDetectionFailed = true
                }
                isDetectingGeometry = false
            }
        }
    }

    private func runRectangleDetection(kind: GeometryCorrectionKind) {
        guard let processor, let image = processor.makeImage(geometryBaseValues()) else { return }
        isDetectingGeometry = true
        Task.detached(priority: .userInitiated) {
            let corners = GeometryDetectionService.detectRectangleCorners(in: image)
            await MainActor.run {
                if let corners {
                    values.geometryCorners = corners
                    values.geometryCorrectionKind = kind
                    applyAutoCropIfNeeded()
                } else {
                    geometryDetectionFailed = true
                }
                isDetectingGeometry = false
            }
        }
    }

    /// `values` with the current Upright correction applied but crop reset to
    /// full and rotation reset — the space `AutoCropService` needs to measure
    /// in, since `RAWProcessor.applyCrop` reads `cropX/Y/Width/Height` against
    /// exactly this post-correction, pre-rotation extent.
    private func correctedUncroppedValues() -> AdjustmentValues {
        var v = values
        v.rotation = 0
        v.cropX = 0; v.cropY = 0; v.cropWidth = 1; v.cropHeight = 1
        return v
    }

    /// After a successful Upright correction, trims the transparent, ragged
    /// corners it leaves behind (see `AutoCropService`) unless the user has
    /// turned that off for this photo.
    private func applyAutoCropIfNeeded() {
        guard values.autoCropEnabled, values.geometryCorrectionKind != .none,
              let processor, let image = processor.makeImage(correctedUncroppedValues())
        else { return }
        Task.detached(priority: .userInitiated) {
            guard let rect = AutoCropService.largestOpaqueRect(in: image) else { return }
            await MainActor.run {
                values.cropX = rect.origin.x
                values.cropY = rect.origin.y
                values.cropWidth = rect.width
                values.cropHeight = rect.height
                values.cropIsAutoSet = true
            }
        }
    }

    /// Which Adobe upright mode to run in the cloud, following whichever
    /// local mode is currently selected (defaulting to Auto for Off/Guided,
    /// since Adobe's API has no Guided equivalent).
    private var cloudUprightMode: LightroomCloudService.UprightMode {
        switch values.geometryMode {
        case .level: return .level
        case .vertical: return .vertical
        case .full: return .full
        case .off, .guided, .auto: return .auto
        }
    }

    /// Renders the current base image (uncorrected geometry, so Adobe's
    /// detector sees the same untouched frame our own detectors do — see
    /// `geometryBaseValues()`), uploads it, and swaps in the corrected result
    /// on success. Unlike the local Auto/Level/Vertical/Full detectors, this
    /// replaces the photo's working image outright rather than producing an
    /// angle/corner value — see `RAWProcessor.init(overrideImageURL:)`.
    private func runCloudStraighten() {
        guard !isCloudStraightening, !isOverrideMode, let sourceURL else { return }

        isCloudStraightening = true
        let baseValues = geometryBaseValues()
        let mode = cloudUprightMode
        let constrainCrop = values.autoCropEnabled
        let photoID = photo.id
        Task.detached(priority: .userInitiated) {
            do {
                // Uses its own full-quality processor rather than the
                // editor's `processor` (which decodes at preview resolution
                // for interactive speed — see `RAWProcessor.fastPreview`);
                // the cloud roundtrip becomes this photo's new working
                // image, so it needs every native pixel. Building it and
                // encoding it to JPEG both happen here, off the main actor —
                // full-resolution RAW decode plus encode is real work, and
                // doing it synchronously before this task even started (as
                // this used to) froze the UI with no progress feedback for
                // however long that took.
                guard let fullQualityProcessor = RAWProcessor(url: sourceURL),
                      let baseImage = fullQualityProcessor.makeImage(baseValues)
                else { throw CloudServiceError.renderFailed }
                let qualityKey = CIImageRepresentationOption(
                    rawValue: kCGImageDestinationLossyCompressionQuality as String)
                guard let data = RenderEngine.exportContext.jpegRepresentation(
                    of: baseImage, colorSpace: RenderEngine.colorSpace, options: [qualityKey: 0.92]
                ) else { throw CloudServiceError.renderFailed }

                let resultData = try await LightroomCloudService.straighten(
                    data, mode: mode, constrainCrop: constrainCrop)
                guard let filename = LightroomCloudService.saveOverride(resultData, for: photoID) else {
                    throw CloudServiceError.downloadFailed
                }
                await MainActor.run { applyCloudResult(filename: filename) }
            } catch {
                await MainActor.run {
                    cloudStraightenErrorMessage = error.localizedDescription
                    isCloudStraightening = false
                }
            }
        }
    }

    /// Switches the editor over to the cloud-straightened image and clears
    /// out the geometry values it already bakes in, so they aren't applied a
    /// second time on top of it.
    private func applyCloudResult(filename: String) {
        guard let p = RAWProcessor(overrideImageURL: LightroomCloudService.overrideURL(for: filename)) else {
            cloudStraightenErrorMessage = "The straightened photo couldn't be loaded."
            isCloudStraightening = false
            return
        }
        stopAccess()
        photo.cloudStraightenedFilename = filename
        values.geometryMode = .off
        values.geometryCorrectionKind = .none
        values.geometryCorners = []
        values.guideLines = []
        values.straighten = 0
        values.rotation = 0
        values.cropX = 0; values.cropY = 0; values.cropWidth = 1; values.cropHeight = 1
        values.cropIsAutoSet = false
        sourceURL = LightroomCloudService.overrideURL(for: filename)
        processor = p
        isCloudStraightening = false
        updatePreview()
    }

    /// Discards the cloud-straightened override and reloads the original RAW.
    private func revertToRAW() {
        if let filename = photo.cloudStraightenedFilename {
            try? FileManager.default.removeItem(at: LightroomCloudService.overrideURL(for: filename))
        }
        photo.cloudStraightenedFilename = nil
        loaded = false
        loadIfNeeded()
    }

    private func savePreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        context.insert(Preset(name: name, values: values))
    }

    // MARK: - Masking (SAM)

    /// Runs `action` against a cached SAM image encoding, computing one from
    /// the current preview first if there isn't one yet (or after a "Reset
    /// Adjustments") — see `samEmbedding`. Not invalidated on every edit: a
    /// stale embedding from before a later crop/rotate/straighten change can
    /// leave new masks slightly misaligned; deleting and recreating them
    /// after finishing geometry changes resolves that (a reasonable
    /// approximation, not worth a full re-encode on every slider tick — see
    /// `RAWProcessor`'s own doc comments for this codebase's usual tradeoff
    /// style).
    private func withSAMEmbedding(_ action: @escaping (SAMSegmentationService.SAMImageEmbedding) -> Void) {
        if let samEmbedding {
            action(samEmbedding)
            return
        }
        guard let processor, let baseImage = processor.makeImage(values, masks: resolvedMasks),
              let cgImage = RenderEngine.context.createCGImage(baseImage, from: baseImage.extent)
        else {
            segmentationError = "The photo isn't ready to segment yet."
            return
        }
        isSegmenting = true
        Task.detached(priority: .userInitiated) {
            do {
                let embedding = try SAMSegmentationService.encode(cgImage)
                await MainActor.run {
                    samEmbedding = embedding
                    isSegmenting = false
                    action(embedding)
                }
            } catch {
                await MainActor.run {
                    segmentationError = error.localizedDescription
                    isSegmenting = false
                }
            }
        }
    }

    private func addSubjectMask() {
        withSAMEmbedding { embedding in
            addMask(kind: .subject, name: "Subject") { try SAMSegmentationService.selectSubject(embedding) }
        }
    }

    private func addSkyMask() {
        withSAMEmbedding { embedding in
            addMask(kind: .sky, name: "Sky") { try SAMSegmentationService.selectSky(embedding) }
        }
    }

    private func addBackgroundMask() {
        withSAMEmbedding { embedding in
            addMask(kind: .background, name: "Background") { try SAMSegmentationService.selectBackground(embedding) }
        }
    }

    /// Maps a tap on the preview (view coordinates) to a point in the same
    /// pixel space `samEmbedding` was encoded from — both `preview` and the
    /// image handed to `SAMSegmentationService.encode` are the exact same
    /// `CIImage`, so no crop/rotate correction is needed here, only the
    /// aspect-fit scaling `previewArea` itself uses to display it.
    private func handleMaskTap(at location: CGPoint, containerSize: CGSize) {
        guard isPickingMaskPoint, let imageSize = preview?.extent.size else { return }
        let rect = aspectFitRect(imageSize: imageSize, in: containerSize)
        guard rect.contains(location) else { return }
        let imagePoint = CGPoint(
            x: (location.x - rect.minX) / rect.width * imageSize.width,
            y: (location.y - rect.minY) / rect.height * imageSize.height
        )
        isPickingMaskPoint = false
        withSAMEmbedding { embedding in
            addMask(kind: .custom, name: "Selection \(photo.masks.count + 1)") {
                try SAMSegmentationService.mask(
                    for: embedding, points: [.init(location: imagePoint, isForeground: true)])
            }
        }
    }

    private func addMask(kind: MaskKind, name: String, compute: () throws -> CIImage) {
        do {
            let maskImage = try compute()
            guard let filename = MaskStorageService.save(maskImage) else {
                segmentationError = "Couldn't save the generated mask."
                return
            }
            let mask = MaskLayer(kind: kind, name: name, maskFilename: filename)
            context.insert(mask)
            photo.masks.append(mask)
            selectedMaskID = mask.id
            updatePreview()
        } catch {
            segmentationError = error.localizedDescription
        }
    }

    private func deleteMask(_ mask: MaskLayer) {
        if selectedMaskID == mask.id { selectedMaskID = nil }
        MaskStorageService.delete(mask.maskFilename)
        photo.masks.removeAll { $0.id == mask.id }
        context.delete(mask)
        updatePreview()
    }

    private func handlePresetPackImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            Task { await importPresetFiles(from: urls) }
        case .failure(let error):
            presetImportError = error.localizedDescription
        }
    }

    /// Accepts any mix of `.zip` preset packs and standalone `.xmp` files in
    /// one selection, creating one `Preset` per `.xmp` that parses
    /// successfully (see `XMPPresetParser`) — files that are unsupported or
    /// fail to parse are skipped rather than aborting the whole import.
    private func importPresetFiles(from urls: [URL]) async {
        var importedCount = 0
        var lastError: String?
        for url in urls {
            do {
                let entries = try await xmpEntries(from: url)
                for entry in entries {
                    guard let parsedValues = try? XMPPresetParser.parse(entry.data) else { continue }
                    let name = (entry.filename as NSString).deletingPathExtension
                    context.insert(Preset(name: name, values: parsedValues))
                    importedCount += 1
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
        if importedCount == 0 {
            presetImportError = lastError ?? "None of the selected files could be parsed."
        }
    }

    /// A standalone `.xmp` file is read directly as a single entry; anything
    /// else is treated as a `.zip` pack and read via `ZIPXMPReader`.
    private func xmpEntries(from url: URL) async throws -> [ZIPXMPReader.XMPEntry] {
        guard url.pathExtension.lowercased() == "xmp" else {
            return try await ZIPXMPReader.readXMPEntries(from: url)
        }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        return [ZIPXMPReader.XMPEntry(filename: url.lastPathComponent, data: data)]
    }

    private func handleLUTImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            do {
                let filename = try LUTService.importLUT(from: url)
                let name = url.deletingPathExtension().lastPathComponent
                context.insert(LUTPreset(name: name, filename: filename))
                values.lutFilename = filename
                values.lutIntensity = 100
            } catch {
                lutImportError = error.localizedDescription
            }
        case .failure(let error):
            lutImportError = error.localizedDescription
        }
    }

    private func deleteLUT(_ preset: LUTPreset) {
        if values.lutFilename == preset.filename {
            values.lutFilename = nil
        }
        LUTService.delete(filename: preset.filename)
        context.delete(preset)
    }
}

/// A linear undo/redo stack of edit snapshots for the currently open photo —
/// session-scoped only (it lives in `EditorView`'s `@State`, so it starts
/// fresh each time a photo is opened and doesn't survive the app quitting),
/// matching Lightroom Classic's History panel in spirit without the
/// persistence.
private struct EditHistory {
    /// Caps memory for a very long editing session — each entry is small
    /// (a struct of doubles plus a handful of short arrays), so this is a
    /// generous ceiling, not a tuned limit.
    private static let maxEntries = 200

    private var states: [AdjustmentValues] = []
    private var index = -1

    var canUndo: Bool { index > 0 }
    var canRedo: Bool { index < states.count - 1 }

    /// Records `state` as the new current step, discarding any redo history
    /// beyond it. No-ops if `state` already sits on top — see
    /// `EditorView.scheduleHistoryPush`.
    mutating func push(_ state: AdjustmentValues) {
        if index >= 0, states[index] == state { return }
        if index < states.count - 1 {
            states.removeSubrange((index + 1)...)
        }
        states.append(state)
        index = states.count - 1
        if states.count > Self.maxEntries {
            states.removeFirst()
            index -= 1
        }
    }

    mutating func undo() -> AdjustmentValues? {
        guard canUndo else { return nil }
        index -= 1
        return states[index]
    }

    mutating func redo() -> AdjustmentValues? {
        guard canRedo else { return nil }
        index += 1
        return states[index]
    }
}

/// Which Tone Curve panel is currently shown/edited — a UI-only selector,
/// matching Lightroom's own Tone Curve panel (which shows one curve at a
/// time via channel buttons rather than stacking all four).
private enum ToneCurveChannel: String, CaseIterable, Identifiable {
    case rgb = "RGB", red = "Red", green = "Green", blue = "Blue"
    var id: String { rawValue }
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

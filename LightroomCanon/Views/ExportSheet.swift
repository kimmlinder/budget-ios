import SwiftUI
import UniformTypeIdentifiers

/// A minimal `FileDocument` wrapping already-encoded image bytes so we can hand
/// them to SwiftUI's `.fileExporter`.
struct ExportedImageDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.jpeg, .heic] }

    var data: Data
    var contentType: UTType

    init(data: Data, contentType: UTType) {
        self.data = data
        self.contentType = contentType
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
        self.contentType = configuration.contentType
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Lets the user choose format/quality/size, then renders and exports.
struct ExportSheet: View {
    let sourceURL: URL
    let values: AdjustmentValues
    var isOverride: Bool = false
    var masks: [RAWProcessor.ResolvedMask] = []
    var onDismiss: () -> Void

    @State private var options = ExportService.Options()
    @State private var limitDimension = false
    @State private var dimension: Double = 2048
    @State private var isRendering = false
    @State private var document: ExportedImageDocument?
    @State private var showExporter = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Picker("Format", selection: $options.format) {
                    ForEach(ExportService.Format.allCases) { Text($0.rawValue).tag($0) }
                }
                VStack(alignment: .leading) {
                    Text("Quality: \(Int(options.quality * 100))%")
                    Slider(value: $options.quality, in: 0.1...1.0)
                }
                Toggle("Limit long edge", isOn: $limitDimension)
                    .tint(Theme.accent)
                if limitDimension {
                    VStack(alignment: .leading) {
                        Text("\(Int(dimension)) px")
                        Slider(value: $dimension, in: 512...8192, step: 128)
                    }
                }
            }
            .navigationTitle("Export")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onDismiss)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export") { render() }
                        .disabled(isRendering)
                }
            }
            .overlay {
                if isRendering { ProgressView("Rendering…").padding().background(.thinMaterial) }
            }
            .alert("Export Failed", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .fileExporter(
                isPresented: $showExporter,
                document: document,
                contentType: options.format.utType,
                defaultFilename: sourceURL.deletingPathExtension().lastPathComponent
            ) { _ in
                onDismiss()
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 320)
        #endif
    }

    private func render() {
        options.maxDimension = limitDimension ? dimension : nil
        isRendering = true
        let opts = options
        Task.detached(priority: .userInitiated) {
            do {
                let data = try ExportService.render(
                    sourceURL: sourceURL, values: values, options: opts, isOverride: isOverride, masks: masks)
                await MainActor.run {
                    document = ExportedImageDocument(data: data, contentType: opts.format.utType)
                    isRendering = false
                    showExporter = true
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isRendering = false
                }
            }
        }
    }
}

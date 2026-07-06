import SwiftUI

/// The local-adjustment sliders for one selected ``MaskLayer`` — the masked
/// equivalent of `EditorView`'s Light/Color/Detail sections, scoped to
/// `LocalAdjustmentValues`' smaller slider set. `@Bindable` binds directly to
/// the SwiftData model; there's no separate value-type snapshot the way
/// `EditorView.values` mirrors `EditSettings`, since a mask's own edit isn't
/// undoable/copy-pasteable independently of the mask itself.
struct MaskDetailView: View {
    @Bindable var mask: MaskLayer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AdjustmentSlider(title: "Exposure", value: $mask.exposure)
            AdjustmentSlider(title: "Contrast", value: $mask.contrast)
            AdjustmentSlider(title: "Highlights", value: $mask.highlights)
            AdjustmentSlider(title: "Shadows", value: $mask.shadows)
            AdjustmentSlider(title: "Whites", value: $mask.whites)
            AdjustmentSlider(title: "Blacks", value: $mask.blacks)
            AdjustmentSlider(title: "Temperature", value: $mask.temperature)
            AdjustmentSlider(title: "Tint", value: $mask.tint)
            AdjustmentSlider(title: "Saturation", value: $mask.saturation)
            AdjustmentSlider(title: "Clarity", value: $mask.clarity)
            AdjustmentSlider(
                title: "Sharpening", value: $mask.sharpness,
                range: 0...100, format: { String(format: "%.0f", $0) }
            )
            AdjustmentSlider(
                title: "Noise Reduction", value: $mask.noiseReduction,
                range: 0...100, format: { String(format: "%.0f", $0) }
            )
        }
    }
}

/// One row in the Masking panel's mask list — name, enable toggle, and a
/// selection highlight matching the currently-edited mask.
struct MaskRowView: View {
    @Bindable var mask: MaskLayer
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Button(action: onSelect) {
                HStack {
                    Image(systemName: mask.kind.iconName)
                    Text(mask.name)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Toggle("", isOn: $mask.isEnabled).labelsHidden()
        }
        .padding(6)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

extension MaskKind {
    var iconName: String {
        switch self {
        case .subject: return "person.fill.viewfinder"
        case .sky: return "cloud.sun.fill"
        case .background: return "square.stack.3d.down.forward.fill"
        case .custom: return "hand.tap.fill"
        }
    }
}

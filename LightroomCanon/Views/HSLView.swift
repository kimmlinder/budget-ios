import SwiftUI

/// The HSL panel: pick one of 8 color bands, then adjust its Hue/Saturation/
/// Luminance. Matches `HSLKernel`'s band order and blending exactly, so what
/// you see here is exactly what gets rendered.
struct HSLView: View {
    @Binding var bands: [HSLBandValues]
    @State private var selected: HSLColorBand = .red

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(HSLColorBand.allCases) { band in
                    swatch(for: band)
                }
            }
            AdjustmentSlider(title: "Hue", value: bandBinding(\.hue))
            AdjustmentSlider(title: "Saturation", value: bandBinding(\.saturation))
            AdjustmentSlider(title: "Luminance", value: bandBinding(\.luminance))
        }
    }

    private func swatch(for band: HSLColorBand) -> some View {
        Button {
            selected = band
        } label: {
            Circle()
                .fill(color(for: band))
                .frame(width: 26, height: 26)
                .overlay {
                    Circle().strokeBorder(.primary, lineWidth: selected == band ? 2 : 0)
                }
                .overlay {
                    if !bands[band.rawValue].isNeutral {
                        Circle().strokeBorder(.secondary, lineWidth: 1).padding(-3)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private func bandBinding(_ keyPath: WritableKeyPath<HSLBandValues, Double>) -> Binding<Double> {
        Binding(
            get: { bands[selected.rawValue][keyPath: keyPath] },
            set: { bands[selected.rawValue][keyPath: keyPath] = $0 }
        )
    }

    /// Approximate on-screen hue for each band's swatch — display only, has
    /// no bearing on the actual band centers `HSLKernel` uses.
    private func color(for band: HSLColorBand) -> Color {
        switch band {
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .aqua: return .cyan
        case .blue: return .blue
        case .purple: return .purple
        case .magenta: return .pink
        }
    }
}

#Preview {
    struct Wrapper: View {
        @State private var bands = Array(repeating: HSLBandValues(), count: 8)
        var body: some View { HSLView(bands: $bands).padding() }
    }
    return Wrapper()
}

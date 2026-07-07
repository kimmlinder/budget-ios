import SwiftUI

/// A labeled slider with a live numeric readout and double-click/tap-to-reset,
/// styled after the reference dark-room-style editor mockup (see `Theme`):
/// a thin flat track with a circular thumb, and — since Lightroom-style
/// sliders are bipolar around a neutral point rather than a plain 0...1 fill —
/// the track fills with the accent color from `neutral` out to the thumb
/// rather than from one end.
struct AdjustmentSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = -100...100
    var neutral: Double = 0
    /// Overrides the numeric readout, e.g. for absolute values like Kelvin
    /// that shouldn't use the default "0 at neutral, otherwise signed" style.
    var format: ((Double) -> String)?

    private var displayText: String {
        if let format { return format(value) }
        return value == neutral ? "0" : String(format: "%+.0f", value)
    }

    private var fraction: Double {
        guard range.upperBound > range.lowerBound else { return 0 }
        return (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    private var neutralFraction: Double {
        guard range.upperBound > range.lowerBound else { return 0 }
        return (neutral - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                    .font(.subheadline)
                Spacer()
                Text(displayText)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(value == neutral ? .secondary : .primary)
            }
            track
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { value = neutral }
    }

    private var track: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let thumbX = width * fraction
            let neutralX = width * neutralFraction
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.15))
                    .frame(height: 3)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: abs(thumbX - neutralX), height: 3)
                    .offset(x: min(thumbX, neutralX))
                Circle()
                    .fill(Color(white: 0.92))
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.4), radius: 1, y: 0.5)
                    .offset(x: thumbX - 7)
            }
            .frame(height: 14)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let clampedX = min(max(0, drag.location.x), width)
                        let t = width > 0 ? clampedX / width : 0
                        value = range.lowerBound + t * (range.upperBound - range.lowerBound)
                    }
            )
        }
        .frame(height: 14)
    }
}

#Preview {
    struct Wrapper: View {
        @State private var v = 0.0
        var body: some View {
            AdjustmentSlider(title: "Exposure", value: $v).padding()
        }
    }
    return Wrapper()
}

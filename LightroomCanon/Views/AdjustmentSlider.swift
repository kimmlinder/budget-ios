import SwiftUI

/// A labeled slider with a live numeric readout and double-click/tap-to-reset,
/// styled after Lightroom's adjustment rows.
struct AdjustmentSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = -100...100
    var neutral: Double = 0

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(title)
                    .font(.subheadline)
                Spacer()
                Text(value == neutral ? "0" : String(format: "%+.0f", value))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(value == neutral ? .secondary : .primary)
            }
            Slider(value: $value, in: range)
                .controlSize(.small)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { value = neutral }
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

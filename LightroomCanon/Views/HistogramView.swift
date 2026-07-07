import SwiftUI

/// A small RGB histogram card, redrawn whenever the preview image changes.
/// Channels are filled with `.plusLighter` blending so overlaps read as
/// cyan/magenta/yellow/white, the same convention Lightroom's histogram uses.
struct HistogramView: View {
    let data: HistogramData?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("HISTOGRAM")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("RGB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Theme.panelBackground)
                if let data {
                    Canvas { context, size in
                        context.blendMode = .plusLighter
                        draw(data.red, color: .red, in: &context, size: size)
                        draw(data.green, color: .green, in: &context, size: size)
                        draw(data.blue, color: .blue, in: &context, size: size)
                    }
                    .padding(4)
                }
            }
            .frame(height: 80)
        }
    }

    private func draw(_ bins: [Float], color: Color, in context: inout GraphicsContext, size: CGSize) {
        guard !bins.isEmpty else { return }
        let step = size.width / CGFloat(bins.count)
        var path = Path()
        path.move(to: CGPoint(x: 0, y: size.height))
        for (i, value) in bins.enumerated() {
            let x = CGFloat(i) * step
            let y = size.height * (1 - CGFloat(value))
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        context.fill(path, with: .color(color.opacity(0.85)))
    }
}

#Preview {
    HistogramView(data: nil).padding()
}

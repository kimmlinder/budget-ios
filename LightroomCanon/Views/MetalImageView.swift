import CoreImage
import Metal
import MetalKit
import SwiftUI

/// A SwiftUI view that renders a `CIImage` on the GPU via `MTKView`.
///
/// Rendering is on-demand (`isPaused` + `enableSetNeedsDisplay`): each time the
/// bound image changes we ask the view to redraw, which scales the image to fit
/// and blits it to the drawable. This is what makes slider dragging feel live.
struct MetalImageView {
    var image: CIImage?
}

extension MetalImageView {
    final class Coordinator: NSObject, MTKViewDelegate {
        var image: CIImage?
        private let commandQueue: MTLCommandQueue?

        override init() {
            self.commandQueue = RenderEngine.device?.makeCommandQueue()
            super.init()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard
                let image,
                let drawable = view.currentDrawable,
                let commandQueue,
                let commandBuffer = commandQueue.makeCommandBuffer()
            else { return }

            let drawableSize = view.drawableSize
            guard drawableSize.width > 0, drawableSize.height > 0,
                  image.extent.width > 0, image.extent.height > 0 else { return }

            // Aspect-fit the image into the drawable, centered.
            let scale = min(drawableSize.width / image.extent.width,
                            drawableSize.height / image.extent.height)
            let scaled = image
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let tx = (drawableSize.width - scaled.extent.width) / 2 - scaled.extent.origin.x
            let ty = (drawableSize.height - scaled.extent.height) / 2 - scaled.extent.origin.y
            let centered = scaled.transformed(by: CGAffineTransform(translationX: tx, y: ty))

            // Composite over black so the full drawable is written every frame
            // (otherwise the letterboxed margins keep stale/garbage pixels).
            let background = CIImage(color: CIColor.black)
                .cropped(to: CGRect(origin: .zero, size: drawableSize))
            let composited = centered.composited(over: background)

            let destination = CIRenderDestination(
                width: Int(drawableSize.width),
                height: Int(drawableSize.height),
                pixelFormat: view.colorPixelFormat,
                commandBuffer: commandBuffer,
                mtlTextureProvider: { drawable.texture }
            )
            destination.colorSpace = RenderEngine.colorSpace

            try? RenderEngine.context.startTask(toRender: composited, to: destination)
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeMTKView(context: Coordinator) -> MTKView {
        let view = MTKView(frame: .zero, device: RenderEngine.device)
        view.delegate = context
        view.framebufferOnly = false
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.colorPixelFormat = .bgra8Unorm
        #if os(macOS)
        view.layer?.isOpaque = false
        #else
        view.isOpaque = false
        view.backgroundColor = .clear
        #endif
        context.image = image
        return view
    }

    func update(_ view: MTKView, coordinator: Coordinator) {
        coordinator.image = image
        view.setNeedsDisplay(view.bounds)
    }
}

#if os(macOS)
extension MetalImageView: NSViewRepresentable {
    func makeNSView(context: Context) -> MTKView { makeMTKView(context: context.coordinator) }
    func updateNSView(_ nsView: MTKView, context: Context) { update(nsView, coordinator: context.coordinator) }
}
#else
extension MetalImageView: UIViewRepresentable {
    func makeUIView(context: Context) -> MTKView { makeMTKView(context: context.coordinator) }
    func updateUIView(_ uiView: MTKView, context: Context) { update(uiView, coordinator: context.coordinator) }
}
#endif

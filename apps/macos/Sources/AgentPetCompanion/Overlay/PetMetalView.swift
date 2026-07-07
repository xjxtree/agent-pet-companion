import MetalKit
import SwiftUI

struct PetMetalView: NSViewRepresentable {
    var stateSeed: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.clearColor = MTLClearColor(red: 0.83, green: 0.93, blue: 1.0, alpha: 0.36)
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 12
        view.delegate = context.coordinator
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        view.preferredFramesPerSecond = stateSeed == "tool" ? 20 : 12
        context.coordinator.seed = stateSeed
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        weak var view: MTKView?
        var seed = "idle"
        private var commandQueue: MTLCommandQueue?

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            if commandQueue == nil {
                commandQueue = view.device?.makeCommandQueue()
            }
        }

        func draw(in view: MTKView) {
            if commandQueue == nil {
                commandQueue = view.device?.makeCommandQueue()
            }
            guard
                let descriptor = view.currentRenderPassDescriptor,
                let drawable = view.currentDrawable,
                let commandBuffer = commandQueue?.makeCommandBuffer(),
                let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
            else {
                return
            }

            let color = clearColor(for: seed)
            descriptor.colorAttachments[0].clearColor = color
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        private func clearColor(for seed: String) -> MTLClearColor {
            switch seed {
            case "tool":
                MTLClearColor(red: 0.77, green: 0.94, blue: 1.0, alpha: 0.46)
            case "waiting":
                MTLClearColor(red: 1.0, green: 0.92, blue: 0.76, alpha: 0.46)
            case "failed":
                MTLClearColor(red: 1.0, green: 0.82, blue: 0.85, alpha: 0.46)
            default:
                MTLClearColor(red: 0.86, green: 0.88, blue: 1.0, alpha: 0.42)
            }
        }
    }
}

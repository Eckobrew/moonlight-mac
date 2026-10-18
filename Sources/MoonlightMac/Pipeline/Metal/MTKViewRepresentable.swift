import SwiftUI
import MetalKit

public struct MTKViewRepresentable: NSViewRepresentable {
    public let preferredFps: Int

    public init(preferredFps: Int = 60) {
        self.preferredFps = preferredFps
    }

    public func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = MetalStreamRenderer.shared.device
        mtkView.delegate = MetalStreamRenderer.shared
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = false
        mtkView.preferredFramesPerSecond = preferredFps
        mtkView.framebufferOnly = false
        return mtkView
    }

    public func updateNSView(_ nsView: MTKView, context: Context) {
        nsView.preferredFramesPerSecond = preferredFps
    }
}

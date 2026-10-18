import SwiftUI
import MetalKit

public final class StreamingMTKView: MTKView {
    public var onWindowAttached: ((NSWindow) -> Void)?

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = self.window {
            onWindowAttached?(window)
        }
    }
}

public struct MTKViewRepresentable: NSViewRepresentable {
    public let preferredFps: Int
    public let onWindowAttached: ((NSWindow) -> Void)?

    public init(preferredFps: Int = 60, onWindowAttached: ((NSWindow) -> Void)? = nil) {
        self.preferredFps = preferredFps
        self.onWindowAttached = onWindowAttached
    }

    public func makeNSView(context: Context) -> StreamingMTKView {
        let mtkView = StreamingMTKView()
        mtkView.device = MetalStreamRenderer.shared.device
        mtkView.delegate = MetalStreamRenderer.shared
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = false
        mtkView.preferredFramesPerSecond = preferredFps
        mtkView.framebufferOnly = false
        mtkView.onWindowAttached = onWindowAttached
        return mtkView
    }

    public func updateNSView(_ nsView: StreamingMTKView, context: Context) {
        nsView.preferredFramesPerSecond = preferredFps
        nsView.onWindowAttached = onWindowAttached
    }
}

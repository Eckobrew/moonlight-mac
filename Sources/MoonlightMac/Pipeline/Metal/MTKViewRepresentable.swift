import AppKit
import Metal
import QuartzCore
import SwiftUI

/// Direct CAMetalLayer-backed native view for event-driven stream rendering.
@MainActor
public final class MetalStreamView: NSView {
    public var onWindowAttached: ((NSWindow) -> Void)?

    public override var wantsUpdateLayer: Bool { true }

    public override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        if let device = MetalStreamRenderer.shared.device {
            layer.device = device
        }
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.presentsWithTransaction = false
        return layer
    }

    public var metalLayer: CAMetalLayer? {
        return self.layer as? CAMetalLayer
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
        self.layer = makeBackingLayer()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.wantsLayer = true
        self.layer = makeBackingLayer()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = self.window {
            onWindowAttached?(window)
            if let layer = self.metalLayer {
                MetalStreamRenderer.shared.attachLayer(layer)
            }
        }
    }
}

@MainActor
public struct MetalStreamViewRepresentable: NSViewRepresentable {
    public let onWindowAttached: ((NSWindow) -> Void)?

    public init(onWindowAttached: ((NSWindow) -> Void)? = nil) {
        self.onWindowAttached = onWindowAttached
    }

    public func makeNSView(context: Context) -> MetalStreamView {
        let view = MetalStreamView()
        view.onWindowAttached = onWindowAttached
        if let layer = view.metalLayer {
            MetalStreamRenderer.shared.attachLayer(layer)
        }
        return view
    }

    public func updateNSView(_ nsView: MetalStreamView, context: Context) {
        nsView.onWindowAttached = onWindowAttached
    }

    public static func dismantleNSView(_ nsView: MetalStreamView, coordinator: ()) {
        MetalStreamRenderer.shared.metalLayer = nil
    }
}

/// Backwards compatibility alias for MTKViewRepresentable
public typealias MTKViewRepresentable = MetalStreamViewRepresentable

import AppKit
import Metal
import QuartzCore
import SwiftUI

/// Direct CAMetalLayer-backed native view for event-driven stream rendering.
@MainActor
public final class MetalStreamView: NSView {
    public override var acceptsFirstResponder: Bool { true }
    public var onWindowAttached: ((NSWindow) -> Void)?
    public var rendererMode: VideoRendererMode = .metal
    public var enableVsync = true

    private func attachRenderer(_ layer: CAMetalLayer) {
        if rendererMode == .libplacebo {
            LibplaceboStreamRenderer.shared.attachLayer(layer, vsync: enableVsync)
        } else {
            MetalStreamRenderer.shared.attachLayer(layer)
        }
    }

    public override var wantsUpdateLayer: Bool { true }

    public override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        if let device = MetalStreamRenderer.shared.device {
            layer.device = device
        }
        layer.pixelFormat = .bgra8Unorm
        // Never sampled from, only rendered into: keep the fast presentation path.
        layer.framebufferOnly = true
        layer.presentsWithTransaction = false
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        layer.contentsScale = scale
        if #available(macOS 10.13, *) {
            layer.allowsNextDrawableTimeout = true
        }
        if #available(macOS 10.15, *) {
            layer.maximumDrawableCount = 2
        }
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

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSize()
        if let window = self.window {
            window.acceptsMouseMovedEvents = true
            if window.attachedSheet == nil { window.makeFirstResponder(self) }
            onWindowAttached?(window)
            if let layer = self.metalLayer {
                attachRenderer(layer)
            }
        }
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    public override func layout() {
        super.layout()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        guard let layer = self.metalLayer else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        layer.contentsScale = scale
        let targetSize = CGSize(
            width: max(1, bounds.width * scale),
            height: max(1, bounds.height * scale)
        )
        if layer.drawableSize != targetSize {
            layer.drawableSize = targetSize
        }
        if rendererMode == .libplacebo {
            LibplaceboStreamRenderer.shared.resize(targetSize)
        }
    }
}

@MainActor
public struct MetalStreamViewRepresentable: NSViewRepresentable {
    public let onWindowAttached: ((NSWindow) -> Void)?
    public var rendererMode: VideoRendererMode
    public var enableVsync: Bool

    public init(rendererMode: VideoRendererMode = .metal, enableVsync: Bool = true,
                onWindowAttached: ((NSWindow) -> Void)? = nil) {
        self.rendererMode = rendererMode
        self.enableVsync = enableVsync
        self.onWindowAttached = onWindowAttached
    }

    public func makeNSView(context: Context) -> MetalStreamView {
        let view = MetalStreamView()
        view.rendererMode = rendererMode
        view.enableVsync = enableVsync
        view.onWindowAttached = onWindowAttached
        if let layer = view.metalLayer {
            if rendererMode == .libplacebo {
                LibplaceboStreamRenderer.shared.attachLayer(layer, vsync: enableVsync)
            } else {
                MetalStreamRenderer.shared.attachLayer(layer)
            }
        }
        return view
    }

    public func updateNSView(_ nsView: MetalStreamView, context: Context) {
        nsView.onWindowAttached = onWindowAttached
    }

    public static func dismantleNSView(_ nsView: MetalStreamView, coordinator: ()) {
        if nsView.rendererMode == .libplacebo {
            LibplaceboStreamRenderer.shared.reset()
        } else {
            MetalStreamRenderer.shared.metalLayer = nil
        }
    }
}

/// Backwards compatibility alias for MTKViewRepresentable
public typealias MTKViewRepresentable = MetalStreamViewRepresentable

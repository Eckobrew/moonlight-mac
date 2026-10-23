import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import SwiftUI

public final class NativeStreamPresenter: @unchecked Sendable {
    public static let shared = NativeStreamPresenter()

    private let lock = NSLock()
    public weak var displayLayer: AVSampleBufferDisplayLayer?
    private var cachedFormatDesc: CMVideoFormatDescription?
    private let presentationQueue = DispatchQueue(label: "com.moonlight.native.present", qos: .userInteractive)
    private var pendingPixelBuffer: CVPixelBuffer?
    private var isDraining = false

    // Older AVFoundation SDKs do not annotate the display layer as Sendable.
    // Retain the exact layer across dispatch; renderer operations are serialized
    // on presentationQueue, including flushes after the view has detached.
    private struct LayerReference: @unchecked Sendable {
        let layer: AVSampleBufferDisplayLayer
    }

    private init() {}

    public func setDisplayLayer(_ layer: AVSampleBufferDisplayLayer?) {
        lock.lock()
        self.displayLayer = layer
        self.cachedFormatDesc = nil
        self.pendingPixelBuffer = nil
        lock.unlock()
    }

    public func enqueue(pixelBuffer: CVPixelBuffer) {
        lock.lock()
        pendingPixelBuffer = pixelBuffer
        guard !isDraining else {
            lock.unlock()
            return
        }
        isDraining = true
        lock.unlock()

        // Native enqueue/status/flush may wait on the renderer. Never do that
        // on the decoder callback (or the CVDisplayLink callback when pacing).
        presentationQueue.async { [weak self] in self?.drainFrames() }
    }

    private func drainFrames() {
        while true {
            lock.lock()
            guard let frame = pendingPixelBuffer else {
                isDraining = false
                lock.unlock()
                return
            }
            pendingPixelBuffer = nil
            lock.unlock()
            autoreleasepool { present(pixelBuffer: frame) }
        }
    }

    private func present(pixelBuffer: CVPixelBuffer) {
        lock.lock()
        guard let displayLayer = self.displayLayer else {
            lock.unlock()
            return
        }

        var formatDesc = cachedFormatDesc
        if formatDesc == nil || !CMVideoFormatDescriptionMatchesImageBuffer(formatDesc!, imageBuffer: pixelBuffer) {
            var newDesc: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &newDesc
            )
            guard status == noErr, let desc = newDesc else {
                lock.unlock()
                return
            }
            self.cachedFormatDesc = desc
            formatDesc = desc
        }
        lock.unlock()

        guard let desc = formatDesc else { return }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: desc,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )

        guard status == noErr, let sample = sampleBuffer else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        if #available(macOS 14.0, *) {
            if displayLayer.sampleBufferRenderer.status == .failed {
                displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: false)
            }
            guard displayLayer.sampleBufferRenderer.isReadyForMoreMediaData else { return }
            displayLayer.sampleBufferRenderer.enqueue(sample)
        } else {
            if displayLayer.status == .failed {
                displayLayer.flush()
            }
            guard displayLayer.isReadyForMoreMediaData else { return }
            displayLayer.enqueue(sample)
        }
    }

    public func flush() {
        lock.lock()
        let layer = self.displayLayer
        self.cachedFormatDesc = nil
        self.pendingPixelBuffer = nil
        lock.unlock()

        guard let displayLayer = layer else { return }
        let reference = LayerReference(layer: displayLayer)
        presentationQueue.async {
            let displayLayer = reference.layer
            if #available(macOS 14.0, *) {
                displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true)
            } else {
                displayLayer.flushAndRemoveImage()
            }
        }
    }
}

@MainActor
public final class SampleBufferStreamView: NSView {
    public var onWindowAttached: ((NSWindow) -> Void)?
    public let displayLayer = AVSampleBufferDisplayLayer()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayer()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayer()
    }

    private func setupLayer() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.isOpaque = true
        displayLayer.backgroundColor = NSColor.black.cgColor
        // Display sleep prevention is handled centrally by DisplaySleepManager
        // to strictly enforce user preference and focus-only requirements across all renderers.
        displayLayer.preventsDisplaySleepDuringVideoPlayback = false
        self.layer = displayLayer
        self.wantsLayer = true
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = self.window {
            window.acceptsMouseMovedEvents = true
            onWindowAttached?(window)
        }
    }
}

@MainActor
public struct SampleBufferViewRepresentable: NSViewRepresentable {
    public let onWindowAttached: ((NSWindow) -> Void)?

    public init(onWindowAttached: ((NSWindow) -> Void)? = nil) {
        self.onWindowAttached = onWindowAttached
    }

    public func makeNSView(context: Context) -> SampleBufferStreamView {
        let view = SampleBufferStreamView()
        view.onWindowAttached = onWindowAttached
        NativeStreamPresenter.shared.setDisplayLayer(view.displayLayer)
        return view
    }

    public func updateNSView(_ nsView: SampleBufferStreamView, context: Context) {
        nsView.onWindowAttached = onWindowAttached
    }

    public static func dismantleNSView(_ nsView: SampleBufferStreamView, coordinator: ()) {
        NativeStreamPresenter.shared.setDisplayLayer(nil)
    }
}

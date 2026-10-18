import AppKit
import CoreVideo
import Foundation
import Metal
import MetalKit

/// High-performance zero-copy Metal video renderer for Moonlight.
///
/// Features:
/// - Opt-out VSync: Controls `CAMetalLayer.displaySyncEnabled` allowing unlocked presentation / tearing.
/// - Zero-copy CVPixelBuffer plane mapping via `CVMetalTextureCache`.
/// - Hardware-accelerated BT.709 (SDR) and BT.2020 (HDR10) color space conversion shaders.
/// - Event-driven presentation: Renders only when a new decoded or paced frame arrives.
public final class MetalStreamRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
    public static let shared = MetalStreamRenderer()

    public private(set) var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var pipelineStateBT709: MTLRenderPipelineState?
    private var pipelineStateBT2020: MTLRenderPipelineState?
    private var textureCache: CVMetalTextureCache?
    private var samplerState: MTLSamplerState?

    private let lock = NSLock()
    public weak var metalLayer: CAMetalLayer?
    public weak var mtkView: MTKView?

    public var isHdrActive: Bool = false
    public var enableVsync: Bool = true {
        didSet {
            updateVsyncSettings()
        }
    }

    // Geometry buffers for full-screen quad (2 triangles)
    private var positionBuffer: MTLBuffer?
    private var texCoordBuffer: MTLBuffer?

    // Aspect-ratio scaling cache
    private var lastFrameWidth: Int = -1
    private var lastFrameHeight: Int = -1
    private var lastDrawableWidth: Int = -1
    private var lastDrawableHeight: Int = -1
    private var isVideoLetterboxed: Bool = false

    // FPS calculation
    private var frameCount: UInt64 = 0
    private var lastFpsTimestamp: TimeInterval = CACurrentMediaTime()
    public private(set) var currentRenderFps: Double = 0.0

    // Cached pixel buffer for manual draw calls
    private var currentPixelBuffer: CVPixelBuffer?

    public override init() {
        super.init()
        guard let mtlDevice = MTLCreateSystemDefaultDevice() else {
            AppLogger.shared.error("[MetalStreamRenderer] Failed to get default Metal device")
            return
        }
        self.device = mtlDevice
        self.commandQueue = mtlDevice.makeCommandQueue()

        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, mtlDevice, nil, &textureCache)
        setupBuffers(device: mtlDevice)
        setupPipeline(device: mtlDevice)
        setupSampler(device: mtlDevice)
    }

    private func setupBuffers(device: MTLDevice) {
        let positions: [Float] = [
            -1.0, -1.0,
             1.0, -1.0,
            -1.0,  1.0,
             1.0, -1.0,
             1.0,  1.0,
            -1.0,  1.0
        ]
        let texCoords: [Float] = [
            0.0, 1.0,
            1.0, 1.0,
            0.0, 0.0,
            1.0, 1.0,
            1.0, 0.0,
            0.0, 0.0
        ]

        positionBuffer = device.makeBuffer(
            bytes: positions,
            length: positions.count * MemoryLayout<Float>.size,
            options: .storageModeShared
        )
        texCoordBuffer = device.makeBuffer(
            bytes: texCoords,
            length: texCoords.count * MemoryLayout<Float>.size,
            options: .storageModeShared
        )
    }

    /// Dynamically scales video vertices to maintain exact aspect ratio, matching moonlight-qt StreamUtils::scaleSourceToDestinationSurface
    private func updateVideoVertices(frameWidth: Int, frameHeight: Int, drawableWidth: Int, drawableHeight: Int) {
        guard frameWidth > 0, frameHeight > 0, drawableWidth > 0, drawableHeight > 0 else { return }

        let dstH = Int(ceil(Double(drawableWidth) * Double(frameHeight) / Double(frameWidth)))
        let dstW = Int(ceil(Double(drawableHeight) * Double(frameWidth) / Double(frameHeight)))

        var finalDstX = 0
        var finalDstY = 0
        var finalDstW = drawableWidth
        var finalDstH = drawableHeight

        if dstH > drawableHeight {
            finalDstX = (drawableWidth - dstW) / 2
            finalDstW = dstW
        } else {
            finalDstY = (drawableHeight - dstH) / 2
            finalDstH = dstH
        }

        self.isVideoLetterboxed = (finalDstW != drawableWidth || finalDstH != drawableHeight)

        let ndcX0 = (Float(finalDstX) / (Float(drawableWidth) / 2.0)) - 1.0
        let ndcX1 = (Float(finalDstX + finalDstW) / (Float(drawableWidth) / 2.0)) - 1.0
        let ndcY0 = 1.0 - (Float(finalDstY + finalDstH) / (Float(drawableHeight) / 2.0))
        let ndcY1 = 1.0 - (Float(finalDstY) / (Float(drawableHeight) / 2.0))

        let positions: [Float] = [
            ndcX0, ndcY0,
            ndcX1, ndcY0,
            ndcX0, ndcY1,
            ndcX1, ndcY0,
            ndcX1, ndcY1,
            ndcX0, ndcY1
        ]

        if let buffer = positionBuffer, buffer.length >= positions.count * MemoryLayout<Float>.size {
            buffer.contents().copyMemory(from: positions, byteCount: positions.count * MemoryLayout<Float>.size)
        } else if let device = self.device {
            positionBuffer = device.makeBuffer(
                bytes: positions,
                length: positions.count * MemoryLayout<Float>.size,
                options: .storageModeShared
            )
        }

        self.lastFrameWidth = frameWidth
        self.lastFrameHeight = frameHeight
        self.lastDrawableWidth = drawableWidth
        self.lastDrawableHeight = drawableHeight
    }

    private func setupPipeline(device: MTLDevice) {
        if let defaultLib = device.makeDefaultLibrary() {
            buildPipelines(device: device, library: defaultLib)
        } else {
            compileShadersFromSource(device: device)
        }
    }

    private func compileShadersFromSource(device: MTLDevice) {
        let metalSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexOutput {
            float4 position [[position]];
            float2 texCoord;
        };

        vertex VertexOutput streamVertexShader(
            uint vertexID [[vertex_id]],
            constant float2* positions [[buffer(0)]],
            constant float2* texCoords [[buffer(1)]]
        ) {
            VertexOutput out;
            out.position = float4(positions[vertexID], 0.0, 1.0);
            out.texCoord = texCoords[vertexID];
            return out;
        }

        constant float3x3 kColorConversion709 = float3x3(
            float3(1.164,  1.164,  1.164),
            float3(0.000, -0.213,  2.112),
            float3(1.793, -0.533,  0.000)
        );
        constant float3 kColorOffset709 = float3(-(16.0 / 255.0), -(128.0 / 255.0), -(128.0 / 255.0));

        fragment float4 streamFragmentShaderBT709(
            VertexOutput in [[stage_in]],
            texture2d<float, access::sample> textureY [[texture(0)]],
            texture2d<float, access::sample> textureUV [[texture(1)]],
            sampler textureSampler [[sampler(0)]]
        ) {
            float y = textureY.sample(textureSampler, in.texCoord).r;
            float2 uv = textureUV.sample(textureSampler, in.texCoord).rg;
            float3 yuv = float3(y, uv) + kColorOffset709;
            float3 rgb = kColorConversion709 * yuv;
            return float4(clamp(rgb, 0.0, 1.0), 1.0);
        }

        constant float3x3 kColorConversion2020 = float3x3(
            float3(1.164384,  1.164384,  1.164384),
            float3(0.000000, -0.187326,  2.141770),
            float3(1.678674, -0.650424,  0.000000)
        );

        fragment float4 streamFragmentShaderBT2020(
            VertexOutput in [[stage_in]],
            texture2d<float, access::sample> textureY [[texture(0)]],
            texture2d<float, access::sample> textureUV [[texture(1)]],
            sampler textureSampler [[sampler(0)]]
        ) {
            float y = textureY.sample(textureSampler, in.texCoord).r;
            float2 uv = textureUV.sample(textureSampler, in.texCoord).rg;
            float3 yuv = float3(y, uv) + kColorOffset709;
            float3 rgb = kColorConversion2020 * yuv;
            return float4(clamp(rgb, 0.0, 1.0), 1.0);
        }
        """

        do {
            let library = try device.makeLibrary(source: metalSource, options: nil)
            buildPipelines(device: device, library: library)
        } catch {
            AppLogger.shared.error("[MetalStreamRenderer] Shader compilation failed: \(error)")
        }
    }

    private func buildPipelines(device: MTLDevice, library: MTLLibrary) {
        let vertexFunc = library.makeFunction(name: "streamVertexShader")
        let fragFunc709 = library.makeFunction(name: "streamFragmentShaderBT709")
        let fragFunc2020 = library.makeFunction(name: "streamFragmentShaderBT2020")

        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.vertexFunction = vertexFunc
        pipelineDesc.fragmentFunction = fragFunc709
        pipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm

        self.pipelineStateBT709 = try? device.makeRenderPipelineState(descriptor: pipelineDesc)

        pipelineDesc.fragmentFunction = fragFunc2020
        self.pipelineStateBT2020 = try? device.makeRenderPipelineState(descriptor: pipelineDesc)
    }

    private func setupSampler(device: MTLDevice) {
        let desc = MTLSamplerDescriptor()
        desc.minFilter = .linear
        desc.magFilter = .linear
        desc.sAddressMode = .clampToEdge
        desc.tAddressMode = .clampToEdge
        self.samplerState = device.makeSamplerState(descriptor: desc)
    }

    /// Attach a CAMetalLayer and configure V-Sync / display synchronization.
    public func attachLayer(_ layer: CAMetalLayer) {
        lock.lock()
        self.metalLayer = layer
        applyLayerVsyncSettings(layer)
        lock.unlock()
    }

    @MainActor
    public func attachMTKView(_ view: MTKView) {
        lock.lock()
        self.mtkView = view
        if let layer = view.layer as? CAMetalLayer {
            self.metalLayer = layer
            applyLayerVsyncSettings(layer)
        }
        lock.unlock()
    }

    private func updateVsyncSettings() {
        lock.lock()
        guard let layer = metalLayer else {
            lock.unlock()
            return
        }
        applyLayerVsyncSettings(layer)
        lock.unlock()
    }

    private func applyLayerVsyncSettings(_ layer: CAMetalLayer) {
        layer.device = self.device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.presentsWithTransaction = false

        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        layer.contentsScale = scale
        if layer.bounds.width > 0 && layer.bounds.height > 0 {
            layer.drawableSize = CGSize(
                width: layer.bounds.width * scale,
                height: layer.bounds.height * scale
            )
        }

        if #available(macOS 10.13, *) {
            layer.displaySyncEnabled = self.enableVsync
            layer.allowsNextDrawableTimeout = true
        }
        if #available(macOS 10.15, *) {
            layer.maximumDrawableCount = 2
        }

        AppLogger.shared.info("[MetalStreamRenderer] CAMetalLayer configured: displaySyncEnabled=\(self.enableVsync), maxDrawables=2, allowsNextDrawableTimeout=true, contentsScale=\(scale)")
    }

    /// Render a decoded or paced frame immediately to the Metal layer.
    public func render(pixelBuffer: CVPixelBuffer) {
        lock.lock()
        self.currentPixelBuffer = pixelBuffer
        guard let layer = self.metalLayer,
              let queue = self.commandQueue,
              let cache = self.textureCache else {
            lock.unlock()
            return
        }
        lock.unlock()

        guard let drawable = layer.nextDrawable() else {
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let is10Bit = CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange

        let drawableWidth = Int(layer.drawableSize.width)
        let drawableHeight = Int(layer.drawableSize.height)

        if width != lastFrameWidth || height != lastFrameHeight || drawableWidth != lastDrawableWidth || drawableHeight != lastDrawableHeight {
            updateVideoVertices(frameWidth: width, frameHeight: height, drawableWidth: drawableWidth, drawableHeight: drawableHeight)
        }

        let yFormat: MTLPixelFormat = is10Bit ? .r16Unorm : .r8Unorm
        let uvFormat: MTLPixelFormat = is10Bit ? .rg16Unorm : .rg8Unorm

        var cvTextureY: CVMetalTexture?
        var cvTextureUV: CVMetalTexture?

        let statusY = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            yFormat,
            width,
            height,
            0,
            &cvTextureY
        )

        let statusUV = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            uvFormat,
            width / 2,
            height / 2,
            1,
            &cvTextureUV
        )

        guard statusY == kCVReturnSuccess, statusUV == kCVReturnSuccess,
              let cvY = cvTextureY, let cvUV = cvTextureUV,
              let texY = CVMetalTextureGetTexture(cvY),
              let texUV = CVMetalTextureGetTexture(cvUV) else {
            return
        }

        let renderPassDesc = MTLRenderPassDescriptor()
        renderPassDesc.colorAttachments[0].texture = drawable.texture
        renderPassDesc.colorAttachments[0].loadAction = isVideoLetterboxed ? .clear : .dontCare
        renderPassDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        renderPassDesc.colorAttachments[0].storeAction = .store

        guard let cmdBuffer = queue.makeCommandBuffer(),
              let encoder = cmdBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc) else {
            return
        }

        let pipeline = isHdrActive ? (pipelineStateBT2020 ?? pipelineStateBT709) : pipelineStateBT709
        if let pState = pipeline {
            encoder.setRenderPipelineState(pState)
            encoder.setVertexBuffer(positionBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(texCoordBuffer, offset: 0, index: 1)
            encoder.setFragmentTexture(texY, index: 0)
            encoder.setFragmentTexture(texUV, index: 1)
            encoder.setFragmentSamplerState(samplerState, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }

        encoder.endEncoding()
        cmdBuffer.present(drawable)
        cmdBuffer.commit()

        recordFps()
    }

    private func recordFps() {
        frameCount += 1
        let now = CACurrentMediaTime()
        let elapsed = now - lastFpsTimestamp
        if elapsed >= 1.0 {
            currentRenderFps = Double(frameCount) / elapsed
            frameCount = 0
            lastFpsTimestamp = now
        }
    }

    public func reset() {
        lock.lock()
        self.currentPixelBuffer = nil
        self.frameCount = 0
        self.currentRenderFps = 0.0
        self.lastFrameWidth = -1
        self.lastFrameHeight = -1
        self.lastDrawableWidth = -1
        self.lastDrawableHeight = -1
        self.isVideoLetterboxed = false
        lock.unlock()
    }

    // MARK: - MTKViewDelegate (event-driven fallback)
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        lock.lock()
        let buffer = self.currentPixelBuffer
        lock.unlock()

        if let buf = buffer {
            render(pixelBuffer: buf)
        }
    }
}

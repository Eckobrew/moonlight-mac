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
    private var pipelineStateBT709EDR: MTLRenderPipelineState?
    private var pipelineStateBT2020EDR: MTLRenderPipelineState?
    private var textureCache: CVMetalTextureCache?
    private var samplerState: MTLSamplerState?

    private let lock = NSLock()
    public weak var metalLayer: CAMetalLayer?
    public weak var mtkView: MTKView?

    /// When true the drawable is `rgba16Float` and the fragment shader emits extended-linear
    /// BT.2020 (PQ-encoded) values above 1.0, which CoreAnimation drives as EDR.
    /// Toggling this reconfigures the layer and rebuilds the on-demand pipelines.
    public var isHdrActive: Bool = false {
        didSet {
            guard isHdrActive != oldValue else { return }
            updateHDRSettings()
        }
    }

    /// Pixel format of the layer drawable. EDR requires a 16-bit float target.
    private var drawablePixelFormat: MTLPixelFormat {
        isHdrActive ? .rgba16Float : .bgra8Unorm
    }
    public var enableVsync: Bool = true {
        didSet {
            guard enableVsync != oldValue else { return }
            updateVsyncSettings()
        }
    }

    // Geometry buffers for full-screen quad (2 triangles)
    private var positionBuffer: MTLBuffer?
    private var texCoordBuffer: MTLBuffer?

    // Reused per-frame render pass descriptor (avoids one allocation per presented frame).
    // Only touched from renderQueue, so no synchronization is required.
    private let renderPassDesc = MTLRenderPassDescriptor()

    // Aspect-ratio scaling cache
    private var lastFrameWidth: Int = -1
    private var lastFrameHeight: Int = -1
    private var lastDrawableWidth: Int = -1
    private var lastDrawableHeight: Int = -1
    private var isVideoLetterboxed: Bool = false

    // FPS calculation
    private var frameCount: UInt64 = 0
    private var lastFpsTimestamp: TimeInterval = CACurrentMediaTime()
    private var storedRenderFps: Double = 0.0
    public var currentRenderFps: Double { lock.withLock { storedRenderFps } }

    // Cached pixel buffer for manual draw calls
    private var currentPixelBuffer: CVPixelBuffer?

    // Decoupled asynchronous rendering queue (matches moonlight-qt SDL_cond / m_LatestUnrenderedFrame architecture).
    // The VideoToolbox decompression callback thread NEVER blocks on CAMetalLayer presentation or nextDrawable().
    private let renderQueue = DispatchQueue(label: "com.moonlight.metal.render", qos: .userInteractive)
    private var pendingPixelBuffer: CVPixelBuffer?
    private var isRenderActive: Bool = false
    private var renderGeneration: UInt64 = 0

    /// Set while the layer's drawable format is being switched for HDR. Guarded by `lock`.
    private var isHDRTransitioning: Bool = false

    public override init() {
        super.init()
        guard let mtlDevice = MTLCreateSystemDefaultDevice() else {
            AppLogger.shared.error("[MetalStreamRenderer] Failed to get default Metal device")
            return
        }
        self.device = mtlDevice
        self.commandQueue = mtlDevice.makeCommandQueue()
        self.renderPassDesc.colorAttachments[0]?.storeAction = .store

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
        // Preferred: the precompiled `Shaders.metal` from the SwiftPM resource bundle. This avoids a
        // runtime Metal compile on every launch, which otherwise costs hundreds of milliseconds when
        // the default library is unavailable in a plain `swift build` executable.
        if let bundle = AppResources.bundle(),
           let bundledLibrary = try? device.makeDefaultLibrary(bundle: bundle) {
            AppLogger.shared.debug("[MetalStreamRenderer] Using precompiled shader library from resource bundle")
            buildPipelines(device: device, library: bundledLibrary)
            return
        }

        if let defaultLib = device.makeDefaultLibrary() {
            AppLogger.shared.debug("[MetalStreamRenderer] Using default Metal library")
            buildPipelines(device: device, library: defaultLib)
            return
        }

        AppLogger.shared.warning("[MetalStreamRenderer] No Metal library found; compiling shaders from embedded source")
        compileShadersFromSource(device: device)
    }

    private func compileShadersFromSource(device: MTLDevice) {
        if let source = ShaderResources.source(),
           let library = try? device.makeLibrary(source: source, options: nil) {
            buildPipelines(device: device, library: library)
            return
        }
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

        constant float3x3 kRec709ToRec2020 = float3x3(
            float3(0.6274, 0.0691, 0.0164),
            float3(0.3293, 0.9195, 0.0880),
            float3(0.0433, 0.0114, 0.8956)
        );

        static inline float pqToLinear(float n) {
            const float m1 = 0.1593017578125;
            const float m2 = 78.84375;
            const float c1 = 0.8359375;
            const float c2 = 18.8515625;
            const float c3 = 18.6875;
            float np = pow(max(n, 0.0), 1.0 / m2);
            float num = max(np - c1, 0.0);
            float den = c2 - c3 * np;
            return pow(num / max(den, 1e-5), 1.0 / m1);
        }

        constant float kSDRReferenceWhitePQ = 0.508;

        fragment float4 streamFragmentShaderBT2020EDR(
            VertexOutput in [[stage_in]],
            texture2d<float, access::sample> textureY [[texture(0)]],
            texture2d<float, access::sample> textureUV [[texture(1)]],
            sampler textureSampler [[sampler(0)]]
        ) {
            float y = textureY.sample(textureSampler, in.texCoord).r;
            float2 uv = textureUV.sample(textureSampler, in.texCoord).rg;
            float3 yuv = float3(y, uv) + kColorOffset709;
            float3 pq = clamp(kColorConversion2020 * yuv, 0.0, 1.0);
            float3 linearRgb = float3(pqToLinear(pq.r), pqToLinear(pq.g), pqToLinear(pq.b));
            linearRgb /= pqToLinear(kSDRReferenceWhitePQ);
            return float4(linearRgb, 1.0);
        }

        fragment float4 streamFragmentShaderBT709EDR(
            VertexOutput in [[stage_in]],
            texture2d<float, access::sample> textureY [[texture(0)]],
            texture2d<float, access::sample> textureUV [[texture(1)]],
            sampler textureSampler [[sampler(0)]]
        ) {
            float y = textureY.sample(textureSampler, in.texCoord).r;
            float2 uv = textureUV.sample(textureSampler, in.texCoord).rg;
            float3 yuv = float3(y, uv) + kColorOffset709;
            float3 rgb = clamp(kColorConversion709 * yuv, 0.0, 1.0);
            rgb = kRec709ToRec2020 * rgb;
            float3 linearRgb = select(rgb / 12.92, pow((rgb + 0.055) / 1.055, 2.4), rgb > 0.04045);
            return float4(linearRgb, 1.0);
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
        let fragFunc709EDR = library.makeFunction(name: "streamFragmentShaderBT709EDR")
        let fragFunc2020EDR = library.makeFunction(name: "streamFragmentShaderBT2020EDR")

        // SDR pipelines render into the bgra8Unorm drawable.
        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.vertexFunction = vertexFunc
        pipelineDesc.fragmentFunction = fragFunc709
        pipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm

        self.pipelineStateBT709 = try? device.makeRenderPipelineState(descriptor: pipelineDesc)

        pipelineDesc.fragmentFunction = fragFunc2020
        self.pipelineStateBT2020 = try? device.makeRenderPipelineState(descriptor: pipelineDesc)

        // EDR pipelines must match the rgba16Float drawable exactly, so they get their own
        // descriptor. Build them lazily below if the shader library predates them.
        let edrDesc = MTLRenderPipelineDescriptor()
        edrDesc.vertexFunction = vertexFunc
        edrDesc.colorAttachments[0].pixelFormat = .rgba16Float

        if let fragFunc709EDR = fragFunc709EDR {
            edrDesc.fragmentFunction = fragFunc709EDR
            self.pipelineStateBT709EDR = try? device.makeRenderPipelineState(descriptor: edrDesc)
        }
        if let fragFunc2020EDR = fragFunc2020EDR {
            edrDesc.fragmentFunction = fragFunc2020EDR
            self.pipelineStateBT2020EDR = try? device.makeRenderPipelineState(descriptor: edrDesc)
        }

        if isHdrActive && pipelineStateBT2020EDR == nil {
            AppLogger.shared.warning("[MetalStreamRenderer] HDR requested but EDR pipelines are unavailable; falling back to SDR output")
        }
    }

    /// Reconfigures the drawable for EDR and rebuilds pipelines when HDR is toggled.
    /// Called from the main actor (`StreamSessionController`), so it takes `lock` against the
    /// render queue and blocks frame presentation while the layer is mid-reconfiguration.
    private func updateHDRSettings() {
        lock.lock()
        guard let layer = metalLayer else {
            // The stream layer is attached later; attachLayer applies the current HDR state then.
            lock.unlock()
            return
        }

        isHDRTransitioning = true
        lock.unlock()

        applyLayerVsyncSettings(layer)

        lock.lock()
        isHDRTransitioning = false
        lock.unlock()

        AppLogger.shared.info("[MetalStreamRenderer] HDR \(isHdrActive ? "enabled" : "disabled") (drawable: \(isHdrActive ? "rgba16Float EDR" : "bgra8Unorm"))")
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
        let hdr = isHdrActive

        layer.device = self.device
        // EDR requires a 16-bit float drawable; SDR stays on the cheap 8-bit path.
        layer.pixelFormat = drawablePixelFormat
        // We only ever render into the drawable; never sample from it.
        // framebufferOnly = true enables the driver's fast presentation path.
        layer.framebufferOnly = true
        layer.presentsWithTransaction = false

        // Extended Dynamic Range: without this, CoreAnimation clamps the layer to SDR and the
        // shader's >1.0 linear values are lost.
        layer.wantsExtendedDynamicRangeContent = hdr
        if hdr {
            // HDR10/BT.2020 content is authored against the PQ transfer function and decoded to
            // extended linear light by the fragment shader, so tag the layer as extended-linear.
            layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)
                ?? CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        } else {
            layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        }

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
            // 3 is the documented default and avoids drawable starvation: with 2, the layer often has
            // no drawable available while the compositor holds the previous one, and nextDrawable()
            // can block for up to a second.
            layer.maximumDrawableCount = 3
        }

        AppLogger.shared.info("[MetalStreamRenderer] CAMetalLayer configured: displaySyncEnabled=\(self.enableVsync), maxDrawables=3, allowsNextDrawableTimeout=true, contentsScale=\(scale), hdr=\(hdr)")
    }

    /// Ingest a decoded or paced frame immediately without blocking the caller.
    /// Matches moonlight-qt: replaces any unrendered frame and signals the dedicated render queue.
    /// VideoToolbox decompression and UDP network reception NEVER block, preventing packet loss and bitrate collapse.
    public func render(pixelBuffer: CVPixelBuffer) {
        lock.lock()
        self.pendingPixelBuffer = pixelBuffer
        self.currentPixelBuffer = pixelBuffer

        if isRenderActive {
            // Render loop is currently active on renderQueue. It will pick up pendingPixelBuffer
            // as soon as the in-progress frame completes. Return immediately!
            lock.unlock()
            return
        }

        isRenderActive = true
        let generation = renderGeneration
        lock.unlock()

        renderQueue.async { [weak self] in
            self?.drainRenderQueue(generation: generation)
        }
    }

    /// Continuously drains pending frames on the dedicated render queue.
    /// If the window is tabbed out or occluded and nextDrawable() waits, only this queue waits;
    /// VideoToolbox continues running, constantly replacing pendingPixelBuffer with the latest frame.
    /// When presentation resumes, the newest pending frame is used.
    private func drainRenderQueue(generation: UInt64) {
        while true {
            lock.lock()
            guard generation == renderGeneration else { lock.unlock(); return }
            guard let pixelBuffer = self.pendingPixelBuffer else {
                self.isRenderActive = false
                lock.unlock()
                return
            }
            self.pendingPixelBuffer = nil
            lock.unlock()

            guard renderToMetalLayer(pixelBuffer: pixelBuffer) else {
                // Drawable unavailable (occluded/minimized window). Stop draining so the loop is not
                // busy-spinning; if a newer frame arrived while nextDrawable() waited, back off
                // briefly before retrying so it is not left stranded.
                lock.lock()
                if self.pendingPixelBuffer == nil {
                    self.isRenderActive = false
                    lock.unlock()
                    return
                }
                lock.unlock()
                renderQueue.asyncAfter(deadline: .now() + .milliseconds(16)) { [weak self] in
                    self?.drainRenderQueue(generation: generation)
                }
                return
            }
        }
    }

    /// Returns `false` when presentation was not possible (e.g. no drawable), so the caller can stop draining.
    @discardableResult
    private func renderToMetalLayer(pixelBuffer: CVPixelBuffer) -> Bool {
        var pixelBuffer = pixelBuffer
        lock.lock()
        guard let layer = self.metalLayer,
              let queue = self.commandQueue,
              let cache = self.textureCache else {
            lock.unlock()
            return false
        }
        lock.unlock()

        guard let drawable = layer.nextDrawable() else {
            // No drawable available (window occluded/minimized, or the compositor is holding all of
            // them). Do not sleep here: return and let the next decoded frame restart the drain loop.
            // Sleeping on the render queue would delay the newest frame and stall presentation.
            return false
        }

        // Obtaining a drawable can wait for the compositor. Use the newest frame
        // that arrived during that wait instead of showing a stale cursor position
        // and immediately trying to catch up with another presentation.
        lock.lock()
        if let newest = pendingPixelBuffer {
            pixelBuffer = newest
            pendingPixelBuffer = nil
        }
        let transitioning = isHDRTransitioning
        lock.unlock()

        // While the EDR layer/pipelines are being reconfigured, skip presentation rather than
        // rendering with a pipeline whose pixel format no longer matches the drawable.
        guard !transitioning else {
            return true
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let is10Bit = pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            || pixelFormat == kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange
            || pixelFormat == kCVPixelFormatType_444YpCbCr10BiPlanarFullRange

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
            CVPixelBufferGetWidthOfPlane(pixelBuffer, 1),
            CVPixelBufferGetHeightOfPlane(pixelBuffer, 1),
            1,
            &cvTextureUV
        )

        guard statusY == kCVReturnSuccess, statusUV == kCVReturnSuccess,
              let cvY = cvTextureY, let cvUV = cvTextureUV,
              let texY = CVMetalTextureGetTexture(cvY),
              let texUV = CVMetalTextureGetTexture(cvUV) else {
            // Drop stale cache entries so a failed conversion (e.g. after a resolution change)
            // does not keep failing until the cache is rebuilt.
            CVMetalTextureCacheFlush(cache, 0)
            return true
        }

        let colorAttachment = renderPassDesc.colorAttachments[0]
        colorAttachment?.texture = drawable.texture
        colorAttachment?.loadAction = isVideoLetterboxed ? .clear : .dontCare
        colorAttachment?.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        colorAttachment?.storeAction = .store

        guard let cmdBuffer = queue.makeCommandBuffer() else {
            AppLogger.shared.error("[MetalStreamRenderer] makeCommandBuffer returned nil")
            return true
        }
        guard let encoder = cmdBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc) else {
            return true
        }

        let transfer = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, nil) as? String
        let frameIsPQ = transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
        let pipeline = drawable.texture.pixelFormat == .rgba16Float
            ? (frameIsPQ ? pipelineStateBT2020EDR : pipelineStateBT709EDR)
            : (frameIsPQ ? pipelineStateBT2020 : pipelineStateBT709)
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
        return true
    }

    private func recordFps() {
        lock.lock()
        defer { lock.unlock() }
        frameCount += 1
        let now = CACurrentMediaTime()
        let elapsed = now - lastFpsTimestamp
        if elapsed >= 1.0 {
            storedRenderFps = Double(frameCount) / elapsed
            frameCount = 0
            lastFpsTimestamp = now
        }
    }

    public func reset() {
        lock.lock()
        renderGeneration &+= 1
        self.pendingPixelBuffer = nil
        self.currentPixelBuffer = nil
        self.isRenderActive = false
        self.frameCount = 0
        self.storedRenderFps = 0.0
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

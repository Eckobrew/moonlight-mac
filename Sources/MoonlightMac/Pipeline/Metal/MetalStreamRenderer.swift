import Foundation
import Metal
import MetalKit
import CoreVideo

public final class MetalStreamRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
    public static let shared = MetalStreamRenderer()

    public private(set) var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var pipelineStateBT709: MTLRenderPipelineState?
    private var pipelineStateBT2020: MTLRenderPipelineState?
    private var textureCache: CVMetalTextureCache?
    private var samplerState: MTLSamplerState?

    // Current frame buffer protected by lock
    private let lock = NSLock()
    private var currentPixelBuffer: CVPixelBuffer?
    public var isHdrActive: Bool = false

    // Geometry buffers for full-screen quad (2 triangles)
    private var positionBuffer: MTLBuffer?
    private var texCoordBuffer: MTLBuffer?

    // FPS calculation
    private var frameCount: UInt64 = 0
    private var lastFpsTimestamp: TimeInterval = CACurrentMediaTime()
    public private(set) var currentRenderFps: Double = 0.0

    public override init() {
        super.init()
        guard let mtlDevice = MTLCreateSystemDefaultDevice() else {
            print("Failed to get default Metal device")
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
        // Full screen quad coordinates
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

        positionBuffer = device.makeBuffer(bytes: positions, length: positions.count * MemoryLayout<Float>.size, options: .storageModeShared)
        texCoordBuffer = device.makeBuffer(bytes: texCoords, length: texCoords.count * MemoryLayout<Float>.size, options: .storageModeShared)
    }

    private func setupPipeline(device: MTLDevice) {
        let defaultLibrary = (try? device.makeDefaultLibrary(bundle: Bundle.module))
            ?? (try? device.makeDefaultLibrary(bundle: Bundle.main))
            ?? device.makeDefaultLibrary()

        guard let defaultLibrary else {
            // If SPM bundle default library isn't available, compile metal source dynamically
            compileShadersFromSource(device: device)
            return
        }

        buildPipelines(device: device, library: defaultLibrary)
    }

    private func compileShadersFromSource(device: MTLDevice) {
        // Metal source fallback for direct SPM builds
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

        fragment float4 streamFragmentShaderBT2020(
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
        """

        do {
            let library = try device.makeLibrary(source: metalSource, options: nil)
            buildPipelines(device: device, library: library)
        } catch {
            print("Failed to compile metal shaders dynamically: \(error)")
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

    public func setPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        self.currentPixelBuffer = pixelBuffer
        lock.unlock()
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        lock.lock()
        let pixelBuffer = self.currentPixelBuffer
        lock.unlock()

        guard let buffer = pixelBuffer,
              let cache = textureCache,
              let renderPassDesc = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let queue = commandQueue else {
            return
        }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let is10Bit = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange

        let yFormat: MTLPixelFormat = is10Bit ? .r16Unorm : .r8Unorm
        let uvFormat: MTLPixelFormat = is10Bit ? .rg16Unorm : .rg8Unorm

        // Zero-copy texture creation directly from CVPixelBuffer planes via CVMetalTextureCache
        var cvTextureY: CVMetalTexture?
        var cvTextureUV: CVMetalTexture?

        let statusY = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            buffer,
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
            buffer,
            nil,
            uvFormat,
            width / 2,
            height / 2,
            1,
            &cvTextureUV
        )

        guard statusY == kCVReturnSuccess, statusUV == kCVReturnSuccess,
              let texY = CVMetalTextureGetTexture(cvTextureY!),
              let texUV = CVMetalTextureGetTexture(cvTextureUV!) else {
            return
        }

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

        // Track FPS
        frameCount += 1
        let now = CACurrentMediaTime()
        let elapsed = now - lastFpsTimestamp
        if elapsed >= 1.0 {
            currentRenderFps = Double(frameCount) / elapsed
            frameCount = 0
            lastFpsTimestamp = now
        }
    }
}

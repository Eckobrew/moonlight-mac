import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import QuartzCore
import MoonlightCommonC

public protocol VideoDecoderDelegate: AnyObject, Sendable {
    func decoderDidOutputPixelBuffer(_ pixelBuffer: CVPixelBuffer, presentationTimeUs: UInt64, decodeTimeMs: Double)
    func decoderDidDropFrame(frameNumber: Int)
}

public final class VideoToolboxDecoder: @unchecked Sendable {
    public weak var delegate: VideoDecoderDelegate?

    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var videoFormat: Int32 = VIDEO_FORMAT_H264
    private var streamWidth: Int32 = 1920
    private var streamHeight: Int32 = 1080

    // Parameter sets storage for session recreation
    private var spsData: Data?
    private var ppsData: Data?
    private var vpsData: Data?

    // Last known good pixel buffer for frame loss concealment
    private var lastDecodedPixelBuffer: CVPixelBuffer?
    private let lock = NSLock()

    public init() {}

    public func setup(videoFormat: Int32, width: Int32, height: Int32) -> Int32 {
        self.videoFormat = videoFormat
        self.streamWidth = width
        self.streamHeight = height
        self.spsData = nil
        self.ppsData = nil
        self.vpsData = nil
        teardownSession()
        AVPacingClock.shared.reset()
        return DR_OK
    }

    public func teardownSession() {
        if let session = decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
        formatDescription = nil
        lock.lock()
        lastDecodedPixelBuffer = nil
        lock.unlock()
    }

    public func submitDecodeUnit(_ decodeUnit: PDECODE_UNIT) -> Int32 {
        let du = decodeUnit.pointee

        // Scan buffer chain for parameter sets (SPS, PPS, VPS)
        var curEntry: PLENTRY? = du.bufferList
        var picDataBuffers: [Data] = []

        while let entry = curEntry?.pointee {
            guard let dataPtr = entry.data else { break }
            let data = Data(bytes: dataPtr, count: Int(entry.length))
            let cleanNalu = stripStartCode(data)

            switch entry.bufferType {
            case BUFFER_TYPE_SPS:
                self.spsData = cleanNalu
            case BUFFER_TYPE_PPS:
                self.ppsData = cleanNalu
            case BUFFER_TYPE_VPS:
                self.vpsData = cleanNalu
            case BUFFER_TYPE_PICDATA:
                picDataBuffers.append(cleanNalu)
            default:
                picDataBuffers.append(cleanNalu)
            }

            curEntry = entry.next
        }

        // If IDR or format description not yet created, build format description
        if formatDescription == nil || du.frameType == FRAME_TYPE_IDR {
            if !createFormatDescription() {
                // Loss recovery: request keyframe immediately from host
                delegate?.decoderDidDropFrame(frameNumber: Int(du.frameNumber))
                return DR_NEED_IDR
            }
        }

        guard let formatDesc = formatDescription, let session = decompressionSession else {
            delegate?.decoderDidDropFrame(frameNumber: Int(du.frameNumber))
            return DR_NEED_IDR
        }

        // Check A/V pacing clock before expensive block buffer allocation
        let currentHostTimeUs = UInt64(CACurrentMediaTime() * 1_000_000)
        if du.frameType != FRAME_TYPE_IDR && !AVPacingClock.shared.shouldRenderFrame(presentationTimeUs: du.presentationTimeUs, currentHostTimeUs: currentHostTimeUs) {
            // Frame is late or jittered: conceal with previous frame
            delegate?.decoderDidDropFrame(frameNumber: Int(du.frameNumber))
            return DR_OK
        }

        // Assemble 4-byte big-endian length-prefixed NALUs into CMBlockBuffer
        var totalLength = 0
        for buf in picDataBuffers {
            totalLength += 4 + buf.count
        }
        if totalLength == 0 { return DR_OK }

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: totalLength,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalLength,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let buffer = blockBuffer else {
            return DR_NEED_IDR
        }

        var currentOffset = 0
        for buf in picDataBuffers {
            var naluLenBig = UInt32(buf.count).bigEndian
            _ = withUnsafeBytes(of: &naluLenBig) { ptr in
                CMBlockBufferReplaceDataBytes(
                    with: ptr.baseAddress!,
                    blockBuffer: buffer,
                    offsetIntoDestination: currentOffset,
                    dataLength: 4
                )
            }
            currentOffset += 4

            _ = buf.withUnsafeBytes { ptr in
                CMBlockBufferReplaceDataBytes(
                    with: ptr.baseAddress!,
                    blockBuffer: buffer,
                    offsetIntoDestination: currentOffset,
                    dataLength: buf.count
                )
            }
            currentOffset += buf.count
        }

        // Create CMSampleBuffer
        let pts = CMTimeMake(value: Int64(du.rtpTimestamp), timescale: 90000)
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: buffer,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )

        guard status == noErr, let sample = sampleBuffer else {
            return DR_NEED_IDR
        }

        let context = DecodeContext(
            presentationTimeUs: du.presentationTimeUs,
            frameNumber: Int(du.frameNumber),
            submissionTime: CACurrentMediaTime()
        )

        // Decode frame asynchronously with realtime playback flag
        let flags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression, ._1xRealTimePlayback]
        var infoFlagsOut: VTDecodeInfoFlags = []

        status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: flags,
            frameRefcon: Unmanaged.passRetained(context).toOpaque(),
            infoFlagsOut: &infoFlagsOut
        )

        if status != noErr {
            // Immediate error recovery: trigger reference frame refresh on corruption
            delegate?.decoderDidDropFrame(frameNumber: Int(du.frameNumber))
            return DR_NEED_IDR
        }

        return DR_OK
    }

    public func storeLastDecodedBuffer(_ buffer: CVPixelBuffer) {
        lock.lock()
        lastDecodedPixelBuffer = buffer
        lock.unlock()
    }

    public func getLastDecodedBuffer() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return lastDecodedPixelBuffer
    }

    private func createFormatDescription() -> Bool {
        guard let sps = spsData, let pps = ppsData else { return false }

        var newFormatDesc: CMVideoFormatDescription?
        var status: OSStatus = -1

        let isHevc = (videoFormat & VIDEO_FORMAT_MASK_H265) != 0

        if isHevc {
            guard let vps = vpsData else { return false }
            let pointers: [UnsafePointer<UInt8>] = [
                vps.withUnsafeBytes { $0.baseAddress!.assumingMemoryBound(to: UInt8.self) },
                sps.withUnsafeBytes { $0.baseAddress!.assumingMemoryBound(to: UInt8.self) },
                pps.withUnsafeBytes { $0.baseAddress!.assumingMemoryBound(to: UInt8.self) }
            ]
            let sizes = [vps.count, sps.count, pps.count]

            status = pointers.withUnsafeBufferPointer { ptrs in
                sizes.withUnsafeBufferPointer { szs in
                    CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 3,
                        parameterSetPointers: ptrs.baseAddress!,
                        parameterSetSizes: szs.baseAddress!,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &newFormatDesc
                    )
                }
            }
        } else {
            // H.264
            let pointers: [UnsafePointer<UInt8>] = [
                sps.withUnsafeBytes { $0.baseAddress!.assumingMemoryBound(to: UInt8.self) },
                pps.withUnsafeBytes { $0.baseAddress!.assumingMemoryBound(to: UInt8.self) }
            ]
            let sizes = [sps.count, pps.count]

            status = pointers.withUnsafeBufferPointer { ptrs in
                sizes.withUnsafeBufferPointer { szs in
                    CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 2,
                        parameterSetPointers: ptrs.baseAddress!,
                        parameterSetSizes: szs.baseAddress!,
                        nalUnitHeaderLength: 4,
                        formatDescriptionOut: &newFormatDesc
                    )
                }
            }
        }

        guard status == noErr, let formatDesc = newFormatDesc else {
            return false
        }

        self.formatDescription = formatDesc
        return createDecompressionSession(formatDesc: formatDesc)
    }

    private func createDecompressionSession(formatDesc: CMVideoFormatDescription) -> Bool {
        teardownSession()

        let is10Bit = (videoFormat & VIDEO_FORMAT_MASK_10BIT) != 0
        let pixelFormat = is10Bit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        let destinationAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferWidthKey: streamWidth,
            kCVPixelBufferHeightKey: streamHeight,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]

        let decoderSpecification: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true
        ]

        var callbackRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: decompressionOutputCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDesc,
            decoderSpecification: decoderSpecification as CFDictionary,
            imageBufferAttributes: destinationAttributes as CFDictionary,
            outputCallback: &callbackRecord,
            decompressionSessionOut: &session
        )

        guard status == noErr, let decSession = session else {
            return false
        }

        VTSessionSetProperty(decSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(decSession, key: kVTDecompressionPropertyKey_MaximizePowerEfficiency, value: kCFBooleanFalse)

        self.decompressionSession = decSession
        return true
    }

    private func stripStartCode(_ data: Data) -> Data {
        if data.count >= 4 && data[0] == 0 && data[1] == 0 && data[2] == 0 && data[3] == 1 {
            return data.subdata(in: 4..<data.count)
        } else if data.count >= 3 && data[0] == 0 && data[1] == 0 && data[2] == 1 {
            return data.subdata(in: 3..<data.count)
        }
        return data
    }
}

private final class DecodeContext {
    let presentationTimeUs: UInt64
    let frameNumber: Int
    let submissionTime: TimeInterval

    init(presentationTimeUs: UInt64, frameNumber: Int, submissionTime: TimeInterval) {
        self.presentationTimeUs = presentationTimeUs
        self.frameNumber = frameNumber
        self.submissionTime = submissionTime
    }
}

private func decompressionOutputCallback(
    decompressionOutputRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTDecodeInfoFlags,
    imageBuffer: CVImageBuffer?,
    presentationTimeStamp: CMTime,
    presentationDuration: CMTime
) {
    var presentationTimeUs: UInt64 = 0
    var decodeTimeMs: Double = 0.0

    if let frameRef = sourceFrameRefCon {
        let context = Unmanaged<DecodeContext>.fromOpaque(frameRef).takeRetainedValue()
        presentationTimeUs = context.presentationTimeUs
        decodeTimeMs = (CACurrentMediaTime() - context.submissionTime) * 1000.0
    }

    guard let refCon = decompressionOutputRefCon else { return }
    let decoder = Unmanaged<VideoToolboxDecoder>.fromOpaque(refCon).takeUnretainedValue()

    if status == noErr, let pixelBuffer = imageBuffer {
        decoder.storeLastDecodedBuffer(pixelBuffer)
        decoder.delegate?.decoderDidOutputPixelBuffer(pixelBuffer, presentationTimeUs: presentationTimeUs, decodeTimeMs: decodeTimeMs)
    } else {
        // Frame loss concealment: reuse last valid decoded frame if available
        if let fallback = decoder.getLastDecodedBuffer() {
            decoder.delegate?.decoderDidOutputPixelBuffer(fallback, presentationTimeUs: presentationTimeUs, decodeTimeMs: decodeTimeMs)
        }
    }
}

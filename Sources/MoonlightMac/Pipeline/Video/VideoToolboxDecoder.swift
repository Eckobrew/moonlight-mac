import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import QuartzCore
import MoonlightCommonC

public protocol VideoDecoderDelegate: AnyObject, Sendable {
    func decoderDidOutputPixelBuffer(_ pixelBuffer: CVPixelBuffer, presentationTimeUs: UInt64, decodeTimeMs: Double)
    func decoderDidDropFrame(frameNumber: Int)
    func decoderDidDetectNetworkFrameDrop(count: Int)
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
    private var lastFrameNumber: Int32 = 0

    // Reusable decode contexts handed to VideoToolbox via frameRefcon, so each decoded frame does not
    // allocate a class instance. Slots are drawn from a circular pool sized well above the number of
    // frames VideoToolbox can hold in flight. The submission time is only read by the output callback
    // and the callback for a forwards-ordered frame stream always resolves before the slot wraps.
    private static let decodeContextPoolSize = 64
    private let decodeContexts: UnsafeMutablePointer<DecodeContext>
    private var nextDecodeContextSlot = 0

    // Held for a whole decode submission and by teardownSession. The stream
    // library calls teardownSession / stop before joining the thread that submits frames,
    // so this lock ensures no frame is inside VideoToolbox when the session is invalidated.
    private let submitLock = NSRecursiveLock()
    private var isStopped = false

    public init() {
        decodeContexts = UnsafeMutablePointer<DecodeContext>.allocate(capacity: Self.decodeContextPoolSize)
        decodeContexts.initialize(repeating: DecodeContext(), count: Self.decodeContextPoolSize)
    }

    deinit {
        decodeContexts.deinitialize(count: Self.decodeContextPoolSize)
        decodeContexts.deallocate()
    }

    public func setup(videoFormat: Int32, width: Int32, height: Int32) -> Int32 {
        submitLock.lock()
        defer { submitLock.unlock() }

        self.videoFormat = videoFormat
        self.streamWidth = width
        self.streamHeight = height
        self.spsData = nil
        self.ppsData = nil
        self.vpsData = nil
        self.lastFrameNumber = 0
        self.isStopped = false
        teardownDecompressionSession()
        formatDescription = nil
        lock.lock()
        lastDecodedPixelBuffer = nil
        lock.unlock()
        return DR_OK
    }

    public func teardownSession() {
        submitLock.lock()
        defer { submitLock.unlock() }

        isStopped = true
        teardownDecompressionSession()
        formatDescription = nil
        lock.lock()
        lastDecodedPixelBuffer = nil
        lock.unlock()
    }

    private func teardownDecompressionSession() {
        if let session = decompressionSession {
            decompressionSession = nil
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
    }

    public func submitDecodeUnit(_ decodeUnit: PDECODE_UNIT) -> Int32 {
        submitLock.lock()
        defer { submitLock.unlock() }

        guard !isStopped else { return DR_OK }

        let du = decodeUnit.pointee

        // Detect missing network frames
        if lastFrameNumber != 0 && du.frameNumber > lastFrameNumber + 1 {
            let missing = Int(du.frameNumber - (lastFrameNumber + 1))
            delegate?.decoderDidDetectNetworkFrameDrop(count: missing)
        }
        lastFrameNumber = du.frameNumber

        // Scan buffer chain for parameter sets (SPS, PPS, VPS) and copy picture data into single contiguous buffer
        guard du.fullLength > 0 else { return DR_OK }
        guard let rawData = malloc(Int(du.fullLength))?.assumingMemoryBound(to: UInt8.self) else {
            return DR_NEED_IDR
        }

        var curEntry: PLENTRY? = du.bufferList
        var picDataOffset = 0
        var hasNewParamSets = false

        while let entry = curEntry?.pointee {
            guard let dataPtr = entry.data, entry.length > 0 else {
                curEntry = entry.next
                continue
            }
            let bytePtr = UnsafeRawPointer(dataPtr).assumingMemoryBound(to: UInt8.self)
            let length = Int(entry.length)

            switch entry.bufferType {
            case BUFFER_TYPE_SPS:
                self.spsData = extractNaluPayload(from: bytePtr, length: length)
                hasNewParamSets = true
            case BUFFER_TYPE_PPS:
                self.ppsData = extractNaluPayload(from: bytePtr, length: length)
                hasNewParamSets = true
            case BUFFER_TYPE_VPS:
                self.vpsData = extractNaluPayload(from: bytePtr, length: length)
                hasNewParamSets = true
            case BUFFER_TYPE_PICDATA:
                memcpy(rawData.advanced(by: picDataOffset), bytePtr, length)
                picDataOffset += length
            default:
                memcpy(rawData.advanced(by: picDataOffset), bytePtr, length)
                picDataOffset += length
            }

            curEntry = entry.next
        }

        // If this decode unit only contained parameter sets and no picture data, we're done
        if picDataOffset == 0 {
            free(rawData)
            if hasNewParamSets {
                _ = createFormatDescription()
            }
            return DR_OK
        }

        // If the format description is missing, or this decode unit carried new parameter sets,
        // (re)build it. An IDR without new SPS/PPS is compatible with the existing description, so
        // there is no need to rebuild it on every keyframe.
        if formatDescription == nil || hasNewParamSets {
            if let newDesc = createFormatDescription() {
                if !updateDecompressionSession(with: newDesc) {
                    free(rawData)
                    delegate?.decoderDidDropFrame(frameNumber: Int(du.frameNumber))
                    return DR_NEED_IDR
                }
            } else if formatDescription == nil {
                free(rawData)
                delegate?.decoderDidDropFrame(frameNumber: Int(du.frameNumber))
                return DR_NEED_IDR
            }
        }

        guard let formatDesc = formatDescription, let session = decompressionSession else {
            free(rawData)
            delegate?.decoderDidDropFrame(frameNumber: Int(du.frameNumber))
            return DR_NEED_IDR
        }

        // Wrap rawData into dataBlockBuffer with kCFAllocatorDefault.
        // CoreMedia takes ownership of rawData and will call free(rawData) when dataBlockBuffer is released.
        var dataBlockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: rawData,
            blockLength: picDataOffset,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: picDataOffset,
            flags: 0,
            blockBufferOut: &dataBlockBuffer
        )
        guard status == noErr, let dataBuffer = dataBlockBuffer else {
            free(rawData)
            AppLogger.shared.error("CMBlockBufferCreateWithMemoryBlock failed: \(status)")
            return DR_NEED_IDR
        }

        // Create empty frameBlockBuffer to hold 4-byte length prefixes and references to dataBuffer
        var frameBlockBuffer: CMBlockBuffer?
        status = CMBlockBufferCreateEmpty(
            allocator: kCFAllocatorDefault,
            capacity: 0,
            flags: 0,
            blockBufferOut: &frameBlockBuffer
        )
        guard status == noErr, let frameBuffer = frameBlockBuffer else {
            AppLogger.shared.error("CMBlockBufferCreateEmpty failed: \(status)")
            return DR_NEED_IDR
        }

        // Scan rawData for Annex-B NAL unit start codes (00 00 01)
        var lastNaluOffset: Int = -1
        let scanLimit = picDataOffset - 3
        if scanLimit >= 0 {
            for i in 0...scanLimit {
                if rawData[i] == 0 && rawData[i+1] == 0 && rawData[i+2] == 1 {
                    if lastNaluOffset != -1 {
                        appendNalu(
                            to: frameBuffer,
                            from: dataBuffer,
                            data: rawData,
                            startOffset: lastNaluOffset,
                            endOffset: i
                        )
                    }
                    lastNaluOffset = i
                }
            }
        }

        if lastNaluOffset != -1 {
            appendNalu(
                to: frameBuffer,
                from: dataBuffer,
                data: rawData,
                startOffset: lastNaluOffset,
                endOffset: picDataOffset
            )
        }

        let totalLength = CMBlockBufferGetDataLength(frameBuffer)
        guard totalLength > 0 else {
            return DR_OK
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
            dataBuffer: frameBuffer,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )

        guard status == noErr, let sample = sampleBuffer else {
            AppLogger.shared.error("CMSampleBufferCreateReady failed: \(status)")
            return DR_NEED_IDR
        }

        // Set sample buffer attachments for immediate display
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_IsDependedOnByOthers).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            if du.frameType == FRAME_TYPE_PFRAME {
                CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
                CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DependsOnOthers).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            } else {
                CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(), Unmanaged.passUnretained(kCFBooleanFalse).toOpaque())
                CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DependsOnOthers).toOpaque(), Unmanaged.passUnretained(kCFBooleanFalse).toOpaque())
            }
        }

        let context = decodeContexts + nextDecodeContextSlot
        nextDecodeContextSlot += 1
        if nextDecodeContextSlot >= Self.decodeContextPoolSize {
            nextDecodeContextSlot = 0
        }
        context.pointee.presentationTimeUs = du.presentationTimeUs
        context.pointee.frameNumber = Int(du.frameNumber)
        context.pointee.submissionTime = CACurrentMediaTime()

        let flags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression, ._1xRealTimePlayback]
        var infoFlagsOut: VTDecodeInfoFlags = []

        status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: flags,
            frameRefcon: UnsafeMutableRawPointer(context),
            infoFlagsOut: &infoFlagsOut
        )

        if status != noErr {
            AppLogger.shared.error("VTDecompressionSessionDecodeFrame failed: \(status) (frame: \(du.frameNumber))")
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

    private func createFormatDescription() -> CMVideoFormatDescription? {
        guard let sps = spsData, let pps = ppsData else { return nil }

        var newFormatDesc: CMVideoFormatDescription?
        var status: OSStatus = -1

        let isHevc = (videoFormat & VIDEO_FORMAT_MASK_H265) != 0

        if isHevc {
            guard let vps = vpsData else { return nil }
            status = vps.withUnsafeBytes { vpsBuf in
                sps.withUnsafeBytes { spsBuf in
                    pps.withUnsafeBytes { ppsBuf in
                        let ptrs: [UnsafePointer<UInt8>] = [
                            vpsBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                            spsBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                            ppsBuf.baseAddress!.assumingMemoryBound(to: UInt8.self)
                        ]
                        let sizes = [vps.count, sps.count, pps.count]
                        return ptrs.withUnsafeBufferPointer { ptrsBuf in
                            sizes.withUnsafeBufferPointer { sizesBuf in
                                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                                    allocator: kCFAllocatorDefault,
                                    parameterSetCount: 3,
                                    parameterSetPointers: ptrsBuf.baseAddress!,
                                    parameterSetSizes: sizesBuf.baseAddress!,
                                    nalUnitHeaderLength: 4,
                                    extensions: nil,
                                    formatDescriptionOut: &newFormatDesc
                                )
                            }
                        }
                    }
                }
            }
        } else {
            // H.264
            status = sps.withUnsafeBytes { spsBuf in
                pps.withUnsafeBytes { ppsBuf in
                    let ptrs: [UnsafePointer<UInt8>] = [
                        spsBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        ppsBuf.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    ]
                    let sizes = [sps.count, pps.count]
                    return ptrs.withUnsafeBufferPointer { ptrsBuf in
                        sizes.withUnsafeBufferPointer { sizesBuf in
                            CMVideoFormatDescriptionCreateFromH264ParameterSets(
                                allocator: kCFAllocatorDefault,
                                parameterSetCount: 2,
                                parameterSetPointers: ptrsBuf.baseAddress!,
                                parameterSetSizes: sizesBuf.baseAddress!,
                                nalUnitHeaderLength: 4,
                                formatDescriptionOut: &newFormatDesc
                            )
                        }
                    }
                }
            }
        }

        guard status == noErr, let formatDesc = newFormatDesc else {
            AppLogger.shared.error("Failed to create CMVideoFormatDescription: \(status)")
            return nil
        }

        return formatDesc
    }

    private func updateDecompressionSession(with formatDesc: CMVideoFormatDescription) -> Bool {
        if let session = decompressionSession,
           VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: formatDesc) {
            self.formatDescription = formatDesc
            return true
        }

        teardownDecompressionSession()

        let is10Bit = (videoFormat & VIDEO_FORMAT_MASK_10BIT) != 0
        // 10-bit content is HDR-capable: request full-range 10-bit output so the renderer receives
        // the complete signal range (the previous video-range-only request silently clipped it).
        let pixelFormat = is10Bit ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        // Do not constrain width/height here; allow VideoToolbox to output CVPixelBuffers at the
        // full native resolution of the incoming video stream (from the SPS parameter set),
        // preventing unwanted downscaling or blur when the host overrides resolution.
        var destinationAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]

        // Tag the buffers so CoreAnimation/CoreVideo interpret the 10-bit plane correctly.
        // (`kCVPixelBufferCGColorSpaceKey` is not exposed to Swift, so use its documented value.)
        if is10Bit {
            destinationAttributes["CVImageBufferCGColorSpaceKey" as CFString] = CGColorSpace(name: CGColorSpace.itur_2020)
            destinationAttributes[kCVPixelBufferCGImageCompatibilityKey] = false
            destinationAttributes[kCVPixelBufferCGBitmapContextCompatibilityKey] = false
        }

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
            AppLogger.shared.error("VTDecompressionSessionCreate failed with status: \(status)")
            return false
        }

        VTSessionSetProperty(decSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(decSession, key: kVTDecompressionPropertyKey_MaximizePowerEfficiency, value: kCFBooleanFalse)

        self.decompressionSession = decSession
        self.formatDescription = formatDesc
        return true
    }

    private func extractNaluPayload(from ptr: UnsafePointer<UInt8>, length: Int) -> Data {
        if length >= 4 && ptr[0] == 0 && ptr[1] == 0 && ptr[2] == 0 && ptr[3] == 1 {
            return Data(bytes: ptr.advanced(by: 4), count: length - 4)
        } else if length >= 3 && ptr[0] == 0 && ptr[1] == 0 && ptr[2] == 1 {
            return Data(bytes: ptr.advanced(by: 3), count: length - 3)
        }
        return Data(bytes: ptr, count: length)
    }

    private func appendNalu(
        to frameBuffer: CMBlockBuffer,
        from dataBuffer: CMBlockBuffer,
        data: UnsafePointer<UInt8>,
        startOffset: Int,
        endOffset: Int
    ) {
        let payloadStart = startOffset + 3
        var payloadEnd = endOffset

        // Trim trailing zeros (from byte stream padding or preceding 4-byte start codes)
        while payloadEnd > payloadStart && data[payloadEnd - 1] == 0 {
            payloadEnd -= 1
        }

        let naluLength = payloadEnd - payloadStart
        guard naluLength > 0 else { return }

        let oldOffset = CMBlockBufferGetDataLength(frameBuffer)
        let prefixSize = 4

        var status = CMBlockBufferAppendMemoryBlock(
            frameBuffer,
            memoryBlock: nil,
            length: prefixSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: prefixSize,
            flags: 0
        )
        guard status == noErr else {
            AppLogger.shared.error("CMBlockBufferAppendMemoryBlock failed: \(status)")
            return
        }

        var bigLen = UInt32(naluLength).bigEndian
        _ = withUnsafeBytes(of: &bigLen) { lenBytes in
            CMBlockBufferReplaceDataBytes(
                with: lenBytes.baseAddress!,
                blockBuffer: frameBuffer,
                offsetIntoDestination: oldOffset,
                dataLength: prefixSize
            )
        }

        // Attach the data buffer to the frame buffer by reference (zero payload copy)
        status = CMBlockBufferAppendBufferReference(
            frameBuffer,
            targetBBuf: dataBuffer,
            offsetToData: payloadStart,
            dataLength: naluLength,
            flags: 0
        )
        if status != noErr {
            AppLogger.shared.error("CMBlockBufferAppendBufferReference failed: \(status)")
        }
    }
}

private final class DecodeContext {
    var presentationTimeUs: UInt64 = 0
    var frameNumber: Int = 0
    var submissionTime: TimeInterval = 0
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
        // Successful frames resolve their own slot immediately. Error frames can resolve late, after the
        // ring slot may already have been handed to a newer frame, so they fall back to the
        // presentation timestamp VideoToolbox reported.
        if status == noErr {
            let context = frameRef.assumingMemoryBound(to: DecodeContext.self).pointee
            presentationTimeUs = context.presentationTimeUs
            decodeTimeMs = (CACurrentMediaTime() - context.submissionTime) * 1000.0
        } else if presentationTimeStamp.isNumeric {
            presentationTimeUs = UInt64(max(0, presentationTimeStamp.seconds * 1_000_000))
        }
    }

    guard let refCon = decompressionOutputRefCon else { return }
    let decoder = Unmanaged<VideoToolboxDecoder>.fromOpaque(refCon).takeUnretainedValue()

    if status == noErr, let pixelBuffer = imageBuffer {
        decoder.storeLastDecodedBuffer(pixelBuffer)
        decoder.delegate?.decoderDidOutputPixelBuffer(pixelBuffer, presentationTimeUs: presentationTimeUs, decodeTimeMs: decodeTimeMs)
    } else {
        AppLogger.shared.warning("VT decompression output error: \(status)")
        if let fallback = decoder.getLastDecodedBuffer() {
            decoder.delegate?.decoderDidOutputPixelBuffer(fallback, presentationTimeUs: presentationTimeUs, decodeTimeMs: decodeTimeMs)
        } else {
            decoder.delegate?.decoderDidDropFrame(frameNumber: 0)
        }
    }
}

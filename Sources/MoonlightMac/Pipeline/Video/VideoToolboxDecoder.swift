import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import QuartzCore
import MoonlightCommonC
import simd

public protocol VideoDecoderDelegate: AnyObject, Sendable {
    func decoderDidOutputPixelBuffer(_ pixelBuffer: CVPixelBuffer, presentationTimeUs: UInt64, decodeTimeMs: Double)
    func decoderDidDropFrame(frameNumber: Int)
    func decoderDidDetectNetworkFrameDrop(count: Int)
    func decoderDidFail(reason: String)
}
public extension VideoDecoderDelegate {
    func decoderDidFail(reason: String) {}
}

public final class VideoToolboxDecoder: @unchecked Sendable {
    public weak var delegate: VideoDecoderDelegate?
    public var decoderPreference: DecoderPreference = .automatic

    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var videoFormat: Int32 = VIDEO_FORMAT_H264
    private var streamWidth: Int32 = 1920
    private var streamHeight: Int32 = 1080

    // Parameter sets storage for session recreation
    private var spsData: Data?
    private var ppsData: Data?
    private var vpsData: Data?

    // AV1 keeps its Sequence Header OBU (complete, for the av1C configOBUs field).
    private var av1SequenceHeader: [UInt8]?

    // Last known good pixel buffer for frame loss concealment
    private var lastDecodedPixelBuffer: CVPixelBuffer?
    private let lock = NSLock()
    private var lastFrameNumber: Int32 = 0

    // Held for a whole decode submission and by teardownSession. The stream
    // library calls teardownSession / stop before joining the thread that submits frames,
    // so this lock ensures no frame is inside VideoToolbox when the session is invalidated.
    private let submitLock = NSRecursiveLock()
    private var isStopped = false

    /// Set when VideoToolbox reports an asynchronous decode error. The next submission rebuilds the
    /// decompression session and asks the host for a keyframe: an error frame means the reference
    /// picture chain is broken, so every subsequent inter frame would decode as garbage.
    private let recoveryLock = NSLock()
    private var needsRecovery = false

    public init() {}

    deinit {
        // The frame handlers capture self weakly. Invalidation also cancels any
        // pending handlers before this decoder's resources disappear.
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
        }
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
        self.av1SequenceHeader = nil
        self.lastFrameNumber = 0
        self.isStopped = false
        recoveryLock.lock()
        needsRecovery = false
        recoveryLock.unlock()
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
        let trace = VideoPipelineTrace.begin("Decode unit")
        defer { VideoPipelineTrace.end("Decode unit", trace) }
        submitLock.lock()
        defer { submitLock.unlock() }

        guard !isStopped else { return DR_OK }

        let du = decodeUnit.pointee

        // Recover from an asynchronous decode failure reported by VideoToolbox.
        // Request a fresh IDR keyframe without destroying the VTDecompressionSession: tearing down
        // the session invalidates in-flight frames (triggering cascading error callbacks) and
        // stalls the decode thread on a full XPC session recreation.
        if consumeRecoveryRequest() {
            AppLogger.shared.warning("Decoder recovering: requesting IDR after an async decode error")
            if du.frameType != FRAME_TYPE_IDR {
                delegate?.decoderDidDropFrame(frameNumber: Int(du.frameNumber))
                lastFrameNumber = du.frameNumber
                return DR_NEED_IDR
            }
        }

        // Detect missing network frames
        if lastFrameNumber != 0 && du.frameNumber > lastFrameNumber + 1 {
            let missing = Int(du.frameNumber - (lastFrameNumber + 1))
            delegate?.decoderDidDetectNetworkFrameDrop(count: missing)
        }
        lastFrameNumber = du.frameNumber

        // Scan buffer chain for parameter sets (SPS, PPS, VPS) and copy picture data into single contiguous buffer
        if du.fullLength == 0, du.bufferList == nil { return DR_OK }
        guard du.fullLength > 0 else { return DR_NEED_IDR }
        guard let rawData = malloc(Int(du.fullLength))?.assumingMemoryBound(to: UInt8.self) else {
            return DR_NEED_IDR
        }

        var curEntry: PLENTRY? = du.bufferList
        var picDataOffset = 0
        var chainBytes = 0
        var hasNewParamSets = false

        do {
            let trace = VideoPipelineTrace.begin("Copy encoded chain")
            defer { VideoPipelineTrace.end("Copy encoded chain", trace) }
            while let entry = curEntry?.pointee {
                guard let dataPtr = entry.data, entry.length > 0 else { free(rawData); return DR_NEED_IDR }
                let bytePtr = UnsafeRawPointer(dataPtr).assumingMemoryBound(to: UInt8.self)
                let length = Int(entry.length)
                guard length <= Int(du.fullLength) - chainBytes else { free(rawData); return DR_NEED_IDR }
                chainBytes += length

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
        }

        guard chainBytes == Int(du.fullLength) else { free(rawData); return DR_NEED_IDR }

        // If this decode unit only contained parameter sets and no picture data, we're done
        if picDataOffset == 0 {
            free(rawData)
            if hasNewParamSets {
                _ = createFormatDescription()
            }
            return DR_OK
        }

        // AV1 arrives as raw OBUs with no separate parameter-set entries, so the sequence header
        // has to be discovered by scanning the frame itself.
        let isAV1 = (videoFormat & VIDEO_FORMAT_MASK_AV1) != 0
        var av1ReceivedSequenceHeader = false
        if isAV1 {
            let obus = AV1OBUParser.parse(rawData, length: picDataOffset)
            for obu in obus where obu.type == AV1OBUParser.sequenceHeader {
                av1SequenceHeader = obu.raw
                av1ReceivedSequenceHeader = true
            }
        }

        // If the format description is missing, or this decode unit carried new parameter sets,
        // (re)build it. An IDR without new SPS/PPS is compatible with the existing description, so
        // there is no need to rebuild it on every keyframe.
        if formatDescription == nil || hasNewParamSets || av1ReceivedSequenceHeader {
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

        // Common-c's bytes have already been copied into our allocation. When
        // length prefixes fit before their payloads, pack in place and give VT
        // one contiguous block. Three-byte prefixes that would expand retain
        // the existing reference-based path, avoiding an extra payload copy.
        var pictureRanges: [Range<Int>]?
        var packedNALLength: Int?
        if !isAV1 {
            guard let ranges = Self.pictureNALRanges(in: UnsafeBufferPointer(start: rawData, count: picDataOffset)) else {
                free(rawData)
                return DR_NEED_IDR
            }
            pictureRanges = ranges
            packedNALLength = Self.packNALPayloadsInPlace(rawData, ranges: ranges)
        }
        let sampleDataLength = packedNALLength ?? picDataOffset

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
            dataLength: sampleDataLength,
            flags: 0,
            blockBufferOut: &dataBlockBuffer
        )
        guard status == noErr, let dataBuffer = dataBlockBuffer else {
            free(rawData)
            AppLogger.shared.error("CMBlockBufferCreateWithMemoryBlock failed: \(status)")
            return DR_NEED_IDR
        }

        // Create CMSampleBuffer
        let pts = CMTimeMake(value: Int64(du.rtpTimestamp), timescale: 90000)
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        if isAV1 || packedNALLength != nil {
            // AV1 remains an unmodified OBU stream; packed H.264/HEVC contains
            // the same NAL payloads with contiguous four-byte length prefixes.
            var sampleSize = sampleDataLength
            status = CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: dataBuffer,
                formatDescription: formatDesc,
                sampleCount: 1,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSize,
                sampleBufferOut: &sampleBuffer
            )
        } else {
            let trace = VideoPipelineTrace.begin("Assemble NAL sample")
            defer { VideoPipelineTrace.end("Assemble NAL sample", trace) }
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

            guard let ranges = pictureRanges else { return DR_NEED_IDR }
            for range in ranges {
                guard appendNalu(to: frameBuffer, from: dataBuffer, data: rawData,
                                 startOffset: range.lowerBound, endOffset: range.upperBound) else { return DR_NEED_IDR }
            }

            let totalLength = CMBlockBufferGetDataLength(frameBuffer)
            guard totalLength > 0 else { return DR_NEED_IDR }

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
        }

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

        // The VideoToolbox output handler owns this immutable value for exactly
        // as long as the decode is in flight. There is no reusable raw refcon to
        // overwrite when callbacks are delayed or arrive out of order.
        let context = DecodeContext(presentationTimeUs: du.presentationTimeUs,
                                    frameNumber: Int(du.frameNumber),
                                    submissionTime: CACurrentMediaTime())
        let flags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression, ._1xRealTimePlayback]
        var infoFlagsOut: VTDecodeInfoFlags = []
        let submissionTrace = VideoPipelineTrace.begin("VideoToolbox submit")
        status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: flags, infoFlagsOut: &infoFlagsOut
        ) { [weak self] status, infoFlags, imageBuffer, _, _ in
            self?.handleDecodedFrame(context: context, status: status,
                                     infoFlags: infoFlags, imageBuffer: imageBuffer)
        }

        VideoPipelineTrace.end("VideoToolbox submit", submissionTrace)

        if status != noErr {
            AppLogger.shared.error("VTDecompressionSessionDecodeFrame failed: \(status) (frame: \(du.frameNumber))")
            if status == kVTInvalidSessionErr || status == kVTVideoDecoderMalfunctionErr {
                teardownDecompressionSession()
                formatDescription = nil
            }
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

    /// Called from the VideoToolbox output callback when a frame fails to decode.
    /// The callback runs on a VideoToolbox thread, so this only raises a flag.
    fileprivate func signalAsyncDecodeFailure() {
        recoveryLock.lock()
        needsRecovery = true
        recoveryLock.unlock()
    }

    private func consumeRecoveryRequest() -> Bool {
        recoveryLock.lock()
        defer { recoveryLock.unlock() }
        let pending = needsRecovery
        needsRecovery = false
        return pending
    }

    public func getLastDecodedBuffer() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return lastDecodedPixelBuffer
    }

    private func createFormatDescription() -> CMVideoFormatDescription? {
        let isHevc = (videoFormat & VIDEO_FORMAT_MASK_H265) != 0
        let isAV1 = (videoFormat & VIDEO_FORMAT_MASK_AV1) != 0

        if isAV1 {
            guard let sequenceHeader = av1SequenceHeader else { return nil }
            guard let formatDesc = AV1OBUParser.makeFormatDescription(sequenceHeader: sequenceHeader) else {
                AppLogger.shared.error("Failed to create AV1 CMVideoFormatDescription from sequence header (\(sequenceHeader.count) bytes)")
                return nil
            }
            return formatDesc
        }

        guard let sps = spsData, let pps = ppsData else { return nil }

        var newFormatDesc: CMVideoFormatDescription?
        var status: OSStatus = -1

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
        let is444 = (videoFormat & VIDEO_FORMAT_MASK_YUV444) != 0
        let pixelFormat = is444
            ? (is10Bit ? kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange)
            : (is10Bit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)

        // Do not constrain width/height here; allow VideoToolbox to output CVPixelBuffers at the
        // full native resolution of the incoming video stream (from the SPS parameter set),
        // preventing unwanted downscaling or blur when the host overrides resolution.
        // Note: Do not attach CGColorSpace objects to destinationAttributes, as VTDecompressionSessionCreate
        // serializes imageBufferAttributes over XPC to VTDecoderXPCService and rejects non-plist CFTypeRefs
        // with OSStatus -17281.
        let destinationAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]

        var decoderSpecification: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: decoderPreference != .software
        ]
        if decoderPreference == .hardware {
            decoderSpecification[kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder] = true
        }

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDesc,
            decoderSpecification: decoderSpecification as CFDictionary,
            imageBufferAttributes: destinationAttributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )

        guard status == noErr, let decSession = session else {
            AppLogger.shared.error("VTDecompressionSessionCreate failed with status: \(status)")
            delegate?.decoderDidFail(reason: "VideoToolbox could not create the selected decoder (\(status)). Try Automatic decoding, a different codec, or turn off 4:4:4/HDR.")
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

    /// Picture units must contain complete Annex-B NAL payloads. Both three- and
    /// four-byte start codes are accepted; padding and empty/truncated NALs are not pictures.
    static func pictureNALRanges(in bytes: UnsafeBufferPointer<UInt8>) -> [Range<Int>]? {
        let trace = VideoPipelineTrace.begin("Scan Annex B")
        defer { VideoPipelineTrace.end("Scan Annex B", trace) }
        guard bytes.count >= 4 else { return nil }
        var ranges: [Range<Int>] = []
        var payloadStart: Int?
        func appendPreviousNAL(upTo limit: Int) -> Bool {
            guard let payload = payloadStart else { return bytes.prefix(limit).allSatisfy { $0 == 0 } }
            var end = limit
            while end > payload && bytes[end - 1] == 0 { end -= 1 }
            guard end > payload else { return false }
            ranges.append(payload..<end)
            return true
        }
        // Compare 16 start positions at once. Three overlapping 16-byte loads
        // require 18 accessible bytes; use scalar comparisons for the tail.
        let base = UnsafeRawPointer(bytes.baseAddress!)
        let zeros = SIMD16<UInt8>(repeating: 0)
        let ones = SIMD16<UInt8>(repeating: 1)
        var cursor = 0
        while cursor <= bytes.count - 18 {
            let first = base.loadUnaligned(fromByteOffset: cursor, as: SIMD16<UInt8>.self)
            let second = base.loadUnaligned(fromByteOffset: cursor + 1, as: SIMD16<UInt8>.self)
            let third = base.loadUnaligned(fromByteOffset: cursor + 2, as: SIMD16<UInt8>.self)
            let matches = (first .== zeros) .& (second .== zeros) .& (third .== ones)
            if any(matches) {
                var lane = 0
                while lane < 16 {
                    if matches[lane] {
                        let start = cursor + lane
                        guard appendPreviousNAL(upTo: start) else { return nil }
                        payloadStart = start + 3
                        // 00 00 01 cannot overlap another start in these bytes.
                        lane += 3
                    } else {
                        lane += 1
                    }
                }
            }
            cursor += 16
        }
        while cursor <= bytes.count - 3 {
            if bytes[cursor] == 0 && bytes[cursor + 1] == 0 && bytes[cursor + 2] == 1 {
                guard appendPreviousNAL(upTo: cursor) else { return nil }
                payloadStart = cursor + 3
            }
            cursor += 1
        }
        guard payloadStart != nil, appendPreviousNAL(upTo: bytes.count) else { return nil }
        return ranges
    }

    /// Ranges must come from pictureNALRanges for this owned allocation. A nil
    /// result leaves every byte untouched so the reference-based path can use it.
    static func packNALPayloadsInPlace(_ data: UnsafeMutablePointer<UInt8>, ranges: [Range<Int>]) -> Int? {
        guard !ranges.isEmpty else { return nil }
        var outputLength = 0
        for range in ranges {
            // Validate the entire layout before writing. Each destination must
            // end no later than its source, so packing cannot overwrite a later
            // payload or require growing the allocation.
            guard outputLength + 4 <= range.lowerBound else { return nil }
            outputLength += 4 + range.count
        }
        var offset = 0
        for range in ranges {
            var length = UInt32(range.count).bigEndian
            memcpy(data.advanced(by: offset), &length, 4)
            let source = data.advanced(by: range.lowerBound)
            let destination = data.advanced(by: offset + 4)
            if source != destination { memmove(destination, source, range.count) }
            offset += 4 + range.count
        }
        return outputLength
    }

    private func appendNalu(
        to frameBuffer: CMBlockBuffer,
        from dataBuffer: CMBlockBuffer,
        data: UnsafePointer<UInt8>,
        startOffset: Int,
        endOffset: Int
    ) -> Bool {
        let payloadStart = startOffset
        let payloadEnd = endOffset

        let naluLength = payloadEnd - payloadStart
        guard naluLength > 0 else { return false }

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
            return false
        }

        var bigLen = UInt32(naluLength).bigEndian
        status = withUnsafeBytes(of: &bigLen) { lenBytes in
            CMBlockBufferReplaceDataBytes(
                with: lenBytes.baseAddress!,
                blockBuffer: frameBuffer,
                offsetIntoDestination: oldOffset,
                dataLength: prefixSize
            )
        }

        guard status == noErr else { return false }

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
        return status == noErr
    }
}

private struct DecodeContext: Sendable {
    let presentationTimeUs: UInt64
    let frameNumber: Int
    let submissionTime: TimeInterval
}

extension VideoToolboxDecoder {
    private func handleDecodedFrame(context: DecodeContext, status: OSStatus,
                                    infoFlags: VTDecodeInfoFlags, imageBuffer: CVImageBuffer?) {
        if status == noErr, let pixelBuffer = imageBuffer {
            storeLastDecodedBuffer(pixelBuffer)
            delegate?.decoderDidOutputPixelBuffer(pixelBuffer,
                                                  presentationTimeUs: context.presentationTimeUs,
                                                  decodeTimeMs: (CACurrentMediaTime() - context.submissionTime) * 1000)
        } else if status == noErr && infoFlags.contains(.frameDropped) {
            delegate?.decoderDidDropFrame(frameNumber: context.frameNumber)
        } else {
            AppLogger.shared.warning("VT decompression output error: \(status)")
            signalAsyncDecodeFailure()
            delegate?.decoderDidDropFrame(frameNumber: context.frameNumber)
            if let fallback = getLastDecodedBuffer() {
                delegate?.decoderDidOutputPixelBuffer(fallback,
                                                      presentationTimeUs: context.presentationTimeUs, decodeTimeMs: 0)
            }
        }
    }
}

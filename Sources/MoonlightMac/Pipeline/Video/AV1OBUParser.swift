import CoreMedia
import CoreVideo
import Foundation

/// Builds a `CMVideoFormatDescription` for AV1 streams.
///
/// moonlight-common-c does not parse the AV1 bitstream (`VideoDepacketizer.c`: "We don't parse the
/// AV1 bitstream"), so every AV1 frame arrives as a single `BUFFER_TYPE_PICDATA` entry of raw OBUs.
///
/// VideoToolbox has parameter-set constructors for H.264 and HEVC but **not** for AV1: there is no
/// `CMVideoFormatDescriptionCreateFromAV1ParameterSets` in the SDK. An AV1 format description is
/// instead created with `CMVideoFormatDescriptionCreate` carrying an ISO-BMFF `av1C` configuration
/// record in the `SampleDescriptionExtensionAtoms` extension.
///
/// The `av1C` layout is specified by the AV1 Codec ISO Media File Format Binding (§2.3.3); each
/// field is copied out of the Sequence Header OBU per the AV1 specification §5.5.1
/// (`sequence_header_obu`) and §5.5.2 (`color_config`).
enum AV1OBUParser {
    /// A parsed OBU retaining its raw bytes (header + size field + payload).
    struct OBU {
        let type: UInt8
        let raw: [UInt8]
    }

    // OBU type values (AV1 spec §5.3.2).
    static let sequenceHeader: UInt8 = 1
    static let temporalDelimiter: UInt8 = 2

    /// Walks the OBU stream and returns every OBU it can parse.
    /// A malformed or truncated unit stops the scan rather than guessing.
    static func parse(_ data: UnsafePointer<UInt8>, length: Int) -> [OBU] {
        var obus: [OBU] = []
        var offset = 0

        while offset < length {
            guard offset + 1 < length else { break }

            let header = data[offset]
            guard header & 0x80 == 0 else { break } // forbidden bit must be zero

            let type = (header >> 3) & 0x0F
            let hasExtension = (header & 0x04) != 0
            let hasSizeField = (header & 0x02) != 0

            var headerLength = 1
            if hasExtension { headerLength += 1 }

            var payloadLength: Int
            if hasSizeField {
                // LEB128 payload size.
                var size = 0
                var shift = 0
                var sizeBytes = 0
                var index = offset + headerLength
                while index < length {
                    let byte = data[index]
                    size |= Int(byte & 0x7F) << shift
                    shift += 7
                    sizeBytes += 1
                    index += 1
                    if byte & 0x80 == 0 { break }
                    if sizeBytes > 8 { return obus }
                }
                headerLength += sizeBytes
                payloadLength = size
            } else {
                // Without a size field the OBU runs to the end of the frame.
                payloadLength = length - offset - headerLength
            }

            let payloadStart = offset + headerLength
            let end = payloadStart + payloadLength
            guard payloadLength >= 0, end <= length else { break }

            obus.append(OBU(
                type: type,
                raw: Array(UnsafeBufferPointer(start: data + offset, count: end - offset))
            ))
            offset = end
        }

        return obus
    }

    // MARK: - Format description

    /// Builds an AV1 format description from a complete Sequence Header OBU.
    static func makeFormatDescription(sequenceHeader: [UInt8]) -> CMVideoFormatDescription? {
        guard !sequenceHeader.isEmpty else { return nil }
        guard let av1C = makeAV1CConfiguration(sequenceHeader: sequenceHeader) else { return nil }

        // Dimensions come from the sequence header, not the render target, so the description stays
        // valid if the host changes resolution.
        guard let dimensions = sequenceHeaderDimensions(sequenceHeader) else { return nil }

        let extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["av1C" as CFString: av1C] as CFDictionary,
            kCMFormatDescriptionExtension_Depth: 24
        ]

        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_AV1,
            width: dimensions.width,
            height: dimensions.height,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &description
        )

        guard status == noErr, let description = description else {
            AppLogger.shared.error("[AV1] CMVideoFormatDescriptionCreate failed with status \(status)")
            return nil
        }
        return description
    }

    /// Builds the `av1C` AV1CodecConfigurationRecord (AV1 ISOBMFF binding §2.3.3).
    ///
    /// `configOBUs` stores the complete Sequence Header OBU including its header and LEB128 size
    /// field, because the record holds configOBUs in the low-overhead stream format.
    static func makeAV1CConfiguration(sequenceHeader: [UInt8]) -> Data? {
        guard sequenceHeader.count > 1, (sequenceHeader[0] >> 3) & 0x0F == Self.sequenceHeader else {
            return nil
        }
        guard let payloadStart = obuHeaderInfo(sequenceHeader), payloadStart < sequenceHeader.count else {
            return nil
        }
        let payload = Array(sequenceHeader[payloadStart...])
        guard let fields = parseSequenceHeader(payload) else { return nil }

        var config = Data()
        config.append(0x81) // marker = 1, version = 1

        // seq_profile (3) | seq_level_idx_0 (5)
        config.append((fields.seqProfile << 5) | (fields.level & 0x1F))

        // seq_tier_0(1) high_bitdepth(1) twelve_bit(1) monochrome(1)
        // chroma_subsampling_x(1) chroma_subsampling_y(1) chroma_sample_position(2)
        var b2: UInt8 = 0
        b2 |= (fields.tier & 0x01) << 7
        b2 |= (fields.highBitDepth & 0x01) << 6
        b2 |= (fields.twelveBit & 0x01) << 5
        b2 |= (fields.monochrome & 0x01) << 4
        b2 |= (fields.subsamplingX & 0x01) << 3
        b2 |= (fields.subsamplingY & 0x01) << 2
        b2 |= (fields.chromaSamplePosition & 0x03)
        config.append(b2)

        // reserved(3) | initial_presentation_delay_present(1)=0 | reserved(4)=0
        config.append(0x00)

        // configOBUs: the Sequence Header OBU itself.
        config.append(contentsOf: sequenceHeader)
        return config
    }

    /// Coded dimensions from the sequence header (`max_frame_width`/`max_frame_height`), which equal
    /// the coded size for streams that do not use superres.
    static func sequenceHeaderDimensions(_ sequenceHeader: [UInt8]) -> (width: Int32, height: Int32)? {
        guard let payloadStart = obuHeaderInfo(sequenceHeader), payloadStart < sequenceHeader.count else {
            return nil
        }
        let payload = Array(sequenceHeader[payloadStart...])
        guard let fields = parseSequenceHeader(payload) else { return nil }
        let width = Int32(fields.maxFrameWidth)
        let height = Int32(fields.maxFrameHeight)
        guard width > 0, height > 0 else { return nil }
        return (width, height)
    }

    // MARK: - Bitstream parsing

    private struct SequenceFields {
        var seqProfile: UInt8 = 0
        var level: UInt8 = 0
        var tier: UInt8 = 0
        var highBitDepth: UInt8 = 0
        var twelveBit: UInt8 = 0
        var monochrome: UInt8 = 0
        var subsamplingX: UInt8 = 0
        var subsamplingY: UInt8 = 0
        var chromaSamplePosition: UInt8 = 0
        var maxFrameWidth = 0
        var maxFrameHeight = 0
    }

    /// Parses the fields `av1C` needs, following AV1 spec §5.5.1 / §5.5.2 field order.
    private static func parseSequenceHeader(_ payload: [UInt8]) -> SequenceFields? {
        var reader = BitReader(bytes: payload)
        var f = SequenceFields()

        guard let profile = reader.read(3),
              reader.read(1) != nil,                          // still_picture
              let reduced = reader.read(1) else { return nil } // reduced_still_picture_header
        f.seqProfile = UInt8(profile)

        var frameIDNumbersPresent: UInt32 = 0

        if reduced == 1 {
            guard let level = reader.read(5) else { return nil }
            f.level = UInt8(level)
            f.tier = 0
        } else {
            guard let timingInfoPresent = reader.read(1) else { return nil }
            var decoderModelInfoPresent: UInt32 = 0
            var bufferDelayLengthMinus1: UInt32 = 0

            if timingInfoPresent == 1 {
                // timing_info(): num_units_in_display_tick(32), time_scale(32),
                // equal_picture_interval(1) [+ num_ticks_per_picture_minus_1 (uvlc)]
                guard reader.skip(64) != nil,
                      let equalInterval = reader.read(1) else { return nil }
                if equalInterval == 1, reader.skipUVLC() == nil { return nil }

                guard let dmi = reader.read(1) else { return nil }
                decoderModelInfoPresent = dmi
                if dmi == 1 {
                    // decoder_model_info(): buffer_delay_length_minus_1(5),
                    // num_units_in_decoding_tick(32), buffer_removal_time_length_minus_1(5),
                    // frame_presentation_time_length_minus_1(5)
                    guard let delayLen = reader.read(5),
                          reader.skip(32 + 5 + 5) != nil else { return nil }
                    bufferDelayLengthMinus1 = delayLen
                }
            }

            guard let initialDelayPresent = reader.read(1) else { return nil }
            guard let opCountMinus1 = reader.read(5) else { return nil }
            let opCount = Int(opCountMinus1) + 1

            for i in 0..<opCount {
                guard reader.skip(12) != nil,                       // operating_point_idc
                      let level = reader.read(5) else { return nil }
                if i == 0 { f.level = UInt8(level) }

                if level > 7 {
                    guard let tier = reader.read(1) else { return nil }
                    if i == 0 { f.tier = UInt8(tier) }
                }

                if decoderModelInfoPresent == 1 {
                    // operating_parameters_info(): decoder_buffer_delay(n), encoder_buffer_delay(n),
                    // low_delay_mode_flag(1), with n = buffer_delay_length_minus_1 + 1
                    guard let present = reader.read(1) else { return nil }
                    if present == 1 {
                        let n = Int(bufferDelayLengthMinus1) + 1
                        guard reader.skip(2 * n + 1) != nil else { return nil }
                    }
                }

                if initialDelayPresent == 1 {
                    guard let present = reader.read(1) else { return nil }
                    if present == 1, reader.read(4) == nil { return nil }
                }
            }

            guard let present = reader.read(1) else { return nil }
            frameIDNumbersPresent = present
        }

        guard let widthBitsMinus1 = reader.read(4),
              let heightBitsMinus1 = reader.read(4),
              let maxW = reader.read(Int(widthBitsMinus1) + 1),
              let maxH = reader.read(Int(heightBitsMinus1) + 1) else { return nil }
        f.maxFrameWidth = Int(maxW) + 1
        f.maxFrameHeight = Int(maxH) + 1

        if frameIDNumbersPresent == 1 {
            // delta_frame_id_length_minus_2(4), additional_frame_id_length_minus_1(3)
            guard reader.skip(7) != nil else { return nil }
        }

        guard reader.read(1) != nil,   // use_128x128_superblock
              reader.read(1) != nil,   // enable_filter_intra
              reader.read(1) != nil else { return nil } // enable_intra_edge_filter

        var enableOrderHint: UInt32 = 0

        if reduced == 0 {
            guard reader.read(1) != nil,   // enable_interintra_compound
                  reader.read(1) != nil,   // enable_masked_compound
                  reader.read(1) != nil,   // enable_warped_motion
                  reader.read(1) != nil,   // enable_dual_filter
                  let orderHint = reader.read(1) else { return nil }
            enableOrderHint = orderHint

            if enableOrderHint == 1 {
                // enable_jnt_comp(1), enable_ref_frame_mvs(1)
                guard reader.skip(2) != nil else { return nil }
            }

            guard let chooseScreenTools = reader.read(1) else { return nil }
            if chooseScreenTools == 0 {
                guard let forceScreenTools = reader.read(1) else { return nil }
                if forceScreenTools > 0 {
                    guard let chooseIntegerMV = reader.read(1) else { return nil }
                    if chooseIntegerMV == 0, reader.read(1) == nil { return nil }
                }
            }

            if enableOrderHint == 1 {
                // order_hint_bits_minus_1(3)
                guard reader.skip(3) != nil else { return nil }
            }
        }

        guard reader.read(1) != nil,   // enable_superres
              reader.read(1) != nil,   // enable_cdef
              reader.read(1) != nil else { return nil } // enable_restoration

        // MARK: color_config()
        guard let highBitDepth = reader.read(1) else { return nil }
        f.highBitDepth = UInt8(highBitDepth)

        var bitDepth = 8
        if f.seqProfile == 2 && highBitDepth == 1 {
            guard let twelve = reader.read(1) else { return nil }
            f.twelveBit = UInt8(twelve)
            bitDepth = twelve == 1 ? 12 : 10
        } else {
            bitDepth = highBitDepth == 1 ? 10 : 8
        }

        if f.seqProfile == 1 {
            f.monochrome = 0
        } else {
            guard let mono = reader.read(1) else { return nil }
            f.monochrome = UInt8(mono)
        }

        guard let hasColorDescription = reader.read(1) else { return nil }
        if hasColorDescription == 1 {
            // color_primaries(8), transfer_characteristics(8), matrix_coefficients(8)
            guard reader.skip(24) != nil else { return nil }
        }

        if f.monochrome == 1 {
            guard reader.read(1) != nil else { return nil } // color_range
            f.subsamplingX = 1
            f.subsamplingY = 1
            f.chromaSamplePosition = 0
            return f
        }

        guard reader.read(1) != nil else { return nil } // color_range

        switch f.seqProfile {
        case 0:
            f.subsamplingX = 1
            f.subsamplingY = 1
        case 1:
            f.subsamplingX = 0
            f.subsamplingY = 0
        default:
            if bitDepth == 12 {
                guard let sx = reader.read(1) else { return nil }
                f.subsamplingX = UInt8(sx)
                if sx == 1 {
                    guard let sy = reader.read(1) else { return nil }
                    f.subsamplingY = UInt8(sy)
                } else {
                    f.subsamplingY = 0
                }
            } else {
                f.subsamplingX = 1
                f.subsamplingY = 0
            }
        }

        if f.subsamplingX == 1 && f.subsamplingY == 1 {
            guard let csp = reader.read(2) else { return nil }
            f.chromaSamplePosition = UInt8(csp)
        }

        return f
    }

    /// Index of the OBU payload: after the header, optional extension, and LEB128 size field.
    private static func obuHeaderInfo(_ raw: [UInt8]) -> Int? {
        guard !raw.isEmpty else { return nil }
        let header = raw[0]
        var index = 1
        if header & 0x04 != 0 { // obu_extension_flag
            index += 1
        }
        guard header & 0x02 != 0 else {
            // No size field: the payload is the remainder.
            return index
        }
        var sizeBytes = 0
        while index < raw.count {
            let byte = raw[index]
            index += 1
            sizeBytes += 1
            if byte & 0x80 == 0 { break }
            if sizeBytes > 8 { return nil }
        }
        return index
    }

    /// MSB-first bit reader for AV1 headers.
    private struct BitReader {
        private let bytes: [UInt8]
        private var bitIndex = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        private var remaining: Int { bytes.count * 8 - bitIndex }
        private func canRead(_ count: Int) -> Bool { count >= 0 && remaining >= count }

        mutating func read(_ count: Int) -> UInt32? {
            guard canRead(count) else { return nil }
            var value: UInt32 = 0
            for _ in 0..<count {
                let byte = bytes[bitIndex >> 3]
                let bit = (byte >> (7 - UInt8(bitIndex & 7))) & 1
                value = (value << 1) | UInt32(bit)
                bitIndex += 1
            }
            return value
        }

        mutating func skip(_ count: Int) -> Bool? {
            guard canRead(count) else { return nil }
            bitIndex += count
            return true
        }

        /// Unsigned variable-length code (num_ticks_per_picture_minus_1).
        mutating func skipUVLC() -> Bool? {
            var leadingZeros = 0
            while true {
                guard let bit = read(1) else { return nil }
                if bit == 1 { break }
                leadingZeros += 1
                if leadingZeros > 32 { return nil }
            }
            return skip(leadingZeros)
        }
    }
}

import CoreVideo
import Foundation
import MoonlightCommonC

/// Requested HDR capability is independent of the host's current transfer mode.
final class StreamHDRState: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private var mastering: Data?
    private var light: Data?
    func update(enabled: Bool, metadata: SS_HDR_METADATA? = nil) {
        lock.withLock {
            self.enabled = enabled
            mastering = nil; light = nil
            guard enabled, var metadata else { return }
            var masteringBytes = [UInt8](repeating: 0, count: 24)
            var lightBytes = [UInt8](repeating: 0, count: 4)
            MoonlightCopyHDRMetadata(&metadata, &masteringBytes, &lightBytes)
            mastering = Data(masteringBytes)
            light = Data(lightBytes)
        }
    }
    func apply(to buffer: CVPixelBuffer) {
        let state = lock.withLock { (enabled, mastering, light) }
        let tenBit = [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, kCVPixelFormatType_444YpCbCr10BiPlanarFullRange].contains(CVPixelBufferGetPixelFormatType(buffer))
        let hdr = state.0 && tenBit
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
            hdr ? kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ : kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
            hdr ? kCVImageBufferColorPrimaries_ITU_R_2020 : kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
            hdr ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        if hdr, let data = state.1 { CVBufferSetAttachment(buffer, kCVImageBufferMasteringDisplayColorVolumeKey, data as CFData, .shouldPropagate) }
        else { CVBufferRemoveAttachment(buffer, kCVImageBufferMasteringDisplayColorVolumeKey) }
        if hdr, let data = state.2 { CVBufferSetAttachment(buffer, kCVImageBufferContentLightLevelInfoKey, data as CFData, .shouldPropagate) }
        else { CVBufferRemoveAttachment(buffer, kCVImageBufferContentLightLevelInfoKey) }
    }
}

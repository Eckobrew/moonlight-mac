import MoonlightCommonC
import Foundation
import Testing
@testable import MoonlightMac

@Test func codecMasksRespectHdrPreference() {
    for codec in [VideoCodec.auto, .h264, .hevc] {
        #expect(codec.limelightMask(enableHdr: false) & VIDEO_FORMAT_MASK_10BIT == 0)
    }
    #expect(VideoCodec.hevc.limelightMask(enableHdr: true) & VIDEO_FORMAT_H265_MAIN10 != 0)
}

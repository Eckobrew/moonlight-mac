import Testing
import Foundation
import MoonlightCommonC

struct MoonlightCommonCTests {
    @Test func testLaunchUrlQueryParameters() {
        let paramsPtr = LiGetLaunchUrlQueryParameters()
        #expect(paramsPtr != nil)
        if let ptr = paramsPtr {
            let str = String(cString: ptr)
            #expect(str.contains("corever="))
        }
    }

    @Test func testConfigurationInitializers() {
        var streamConfig = STREAM_CONFIGURATION()
        LiInitializeStreamConfiguration(&streamConfig)
        #expect(streamConfig.width == 0)
        #expect(streamConfig.height == 0)

        var serverInfo = SERVER_INFORMATION()
        LiInitializeServerInformation(&serverInfo)
        #expect(serverInfo.address == nil)

        var clCallbacks = CONNECTION_LISTENER_CALLBACKS()
        LiInitializeConnectionCallbacks(&clCallbacks)
        #expect(clCallbacks.stageStarting == nil)

        var drCallbacks = DECODER_RENDERER_CALLBACKS()
        LiInitializeVideoCallbacks(&drCallbacks)
        #expect(drCallbacks.setup == nil)

        var arCallbacks = AUDIO_RENDERER_CALLBACKS()
        LiInitializeAudioCallbacks(&arCallbacks)
        #expect(arCallbacks.start == nil)
    }

    @Test func testStageNames() {
        let stage0 = LiGetStageName(0)
        #expect(stage0 != nil)

        let stageRtsp = LiGetStageName(STAGE_RTSP_HANDSHAKE)
        #expect(stageRtsp != nil)
        if let name = stageRtsp {
            let str = String(cString: name)
            #expect(!str.isEmpty)
        }

        let stageVideo = LiGetStageName(STAGE_VIDEO_STREAM_START)
        #expect(stageVideo != nil)

        let stageAudio = LiGetStageName(STAGE_AUDIO_STREAM_START)
        #expect(stageAudio != nil)
    }

    @Test func testStreamVideoFormatMasks() {
        #expect((VIDEO_FORMAT_H264 & VIDEO_FORMAT_MASK_H264) != 0)
        #expect((VIDEO_FORMAT_H265 & VIDEO_FORMAT_MASK_H265) != 0)
        #expect((VIDEO_FORMAT_H265_MAIN10 & VIDEO_FORMAT_MASK_10BIT) != 0)
        #expect((VIDEO_FORMAT_AV1_MAIN8 & VIDEO_FORMAT_MASK_AV1) != 0)
        #expect((VIDEO_FORMAT_AV1_MAIN10 & VIDEO_FORMAT_MASK_10BIT) != 0)
    }

    @Test func testAudioConfigurationBitmasks() {
        func makeAudioConfig(channelCount: Int, channelMask: Int) -> Int32 {
            Int32((channelMask << 16) | (channelCount << 8) | 0xCA)
        }
        let stereo = makeAudioConfig(channelCount: 2, channelMask: 0x3)
        #expect(stereo == 0x000302CA)

        let surround51 = makeAudioConfig(channelCount: 6, channelMask: 0x3F)
        #expect(surround51 == 0x003F06CA)

        let surround71 = makeAudioConfig(channelCount: 8, channelMask: 0x63F)
        #expect(surround71 == 0x063F08CA)
    }
}

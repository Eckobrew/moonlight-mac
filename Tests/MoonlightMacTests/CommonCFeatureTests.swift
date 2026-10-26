import Foundation
import CoreVideo
import Testing
import MoonlightCommonC
@testable import MoonlightMac

@Test func featureSettingsDecodePartialAndLegacyObjects() throws {
    let partial = try JSONDecoder().decode(ClientFeatures.self, from: Data(#"{"desktopMouse":true}"#.utf8))
    #expect(partial.desktopMouse)
    #expect(partial.enableMdns && partial.gamepadMouse)
    #expect(!partial.discordPresence && partial.decoder == .automatic)
    let settings = try JSONDecoder().decode(StreamSettings.self, from: JSONEncoder().encode(StreamSettings()))
    #expect(settings.features == ClientFeatures())
}

@Test func customSettingsRejectUnsafeNegotiationValues() {
    var settings = StreamSettings()
    settings.width = 3440; settings.height = 1440; settings.fps = 165
    #expect(settings.validationMessage == nil)
    settings.width = 3439
    #expect(settings.validationMessage != nil)
    settings.width = 0; settings.height = 0
    #expect(settings.validationMessage == nil)
    settings.height = 1080
    #expect(settings.validationMessage != nil)
    settings.height = 0; settings.fps = 0
    #expect(settings.validationMessage != nil)
}

@Test func desktopMouseMapsVideoAreaAndRejectsLetterboxing() throws {
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
    let size = CGSize(width: 1920, height: 1080)
    let center = try #require(DesktopMousePosition.map(point: CGPoint(x: 500, y: 500), bounds: bounds, video: size))
    #expect(center.x == 960 && center.y == 540)
    #expect(center.width == 1920 && center.height == 1080)
    #expect(DesktopMousePosition.map(point: CGPoint(x: 500, y: 100), bounds: bounds, video: size) == nil)
    let top = try #require(DesktopMousePosition.map(point: CGPoint(x: 0, y: 781), bounds: bounds, video: size))
    #expect(top.x == 0 && top.y <= 1)
    #expect(DesktopMousePosition.map(point: .zero, bounds: .zero, video: size) == nil)
}

@Test func launchOptionsKeepControllerAndHDRNegotiationConsistent() {
    var settings = StreamSettings()
    settings.controllerMask = 0x8001
    settings.features.persistentGamepad = true
    let normal = HostLaunchOptions.query(settings: settings)
    #expect(normal.contains("remoteControllersBitmap=32769"))
    #expect(normal.contains("gcmap=32769&gcpersist=1"))
    #expect(!normal.contains("hdrMode="))
    settings.enableHdr = true
    #expect(HostLaunchOptions.query(settings: settings).contains("hdrMode=1"))
    settings.codec = .auto; settings.features.yuv444 = true
    #expect(settings.videoFormatMask & VIDEO_FORMAT_H264_HIGH8_444 != 0)
    #expect(settings.videoFormatMask & VIDEO_FORMAT_H265_REXT10_444 != 0)
    #expect(settings.videoFormatMask & VIDEO_FORMAT_MASK_AV1 == 0)
}

@Test func hdrUsesActualHostStateAndClearsStaleMetadata() throws {
    var optional: CVPixelBuffer?
    #expect(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, nil, &optional) == kCVReturnSuccess)
    let buffer = try #require(optional)
    let state = StreamHDRState()
    var metadata = SS_HDR_METADATA()
    metadata.maxDisplayLuminance = 1000
    metadata.maxContentLightLevel = 900
    metadata.maxFrameAverageLightLevel = 300
    state.update(enabled: true, metadata: metadata)
    state.apply(to: buffer)
    let transfer = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String
    #expect(transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
    let mastering = try #require(CVBufferCopyAttachment(buffer, kCVImageBufferMasteringDisplayColorVolumeKey, nil) as? Data)
    #expect(mastering.count == 24)
    #expect(Array(mastering[16..<20]) == [0, 152, 150, 128])
    state.update(enabled: false)
    state.apply(to: buffer)
    #expect(CVBufferCopyAttachment(buffer, kCVImageBufferMasteringDisplayColorVolumeKey, nil) == nil)
    #expect((CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String) == kCVImageBufferTransferFunction_ITU_R_709_2 as String)
}

@Test func discordIPCHandlesFragmentedAndConsecutiveFrames() throws {
    let frame = DiscordIPCFrame(opcode: 1, payload: Data(#"{"evt":"READY"}"#.utf8))
    var bytes = Data(frame.encoded.prefix(7))
    #expect(try DiscordIPCFrame.next(from: &bytes) == nil)
    bytes.append(frame.encoded.dropFirst(7)); bytes.append(frame.encoded)
    #expect(try DiscordIPCFrame.next(from: &bytes) == frame)
    #expect(try DiscordIPCFrame.next(from: &bytes) == frame)
    #expect(bytes.isEmpty)
    var invalid = Data([1, 0, 0, 0, 255, 255, 255, 127])
    #expect(throws: (any Error).self) { try DiscordIPCFrame.next(from: &invalid) }
}

@Test func adaptiveEffectsRejectMalformedAndDecodeBoundedNativeEffects() {
    #expect(AdaptiveTriggerEffect.decode(type: 0x21, bytes: []) == .off)
    var bytes = [UInt8](repeating: 0, count: 10)
    bytes[0] = 1; bytes[2] = 7
    #expect(AdaptiveTriggerEffect.decode(type: 0x21, bytes: bytes) == .feedback([1, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
    bytes[1] = 2
    #expect(AdaptiveTriggerEffect.decode(type: 0x25, bytes: bytes) == .weapon(start: 0, end: 1, strength: 1))
    #expect(AdaptiveTriggerEffect.decode(type: 0xFF, bytes: bytes) == .off)
}

@Test func motionSupportsSixteenSlotsAndIndependentRequests() {
    var requests = ControllerMotionRequests()
    requests.update(slot: 15, category: 1, hz: 100)
    requests.update(slot: 15, category: 2, hz: 50)
    #expect({ requests.shouldSend(slot: 15, category: 1, now: 0, value: .zero) }())
    #expect({ requests.shouldSend(slot: 15, category: 2, now: 0, value: .zero) }())
    #expect(!{ requests.shouldSend(slot: 15, category: 1, now: 0.005, value: .one) }())
    requests.update(slot: 15, category: 1, hz: 0)
    #expect(requests.isEnabled(slot: 15))
    requests.reset()
    #expect(!requests.isEnabled(slot: 15))
}

@Test func malformedDecodeChainRequestsKeyframe() {
    let decoder = VideoToolboxDecoder()
    var unit = DECODE_UNIT()
    unit.fullLength = 1
    #expect(decoder.submitDecodeUnit(&unit) == DR_NEED_IDR)
    unit.fullLength = -1
    #expect(decoder.submitDecodeUnit(&unit) == DR_NEED_IDR)
}

@Test func annexBPicturesRejectMissingAndEmptyNALs() {
    func ranges(_ bytes: [UInt8]) -> [Range<Int>]? { bytes.withUnsafeBufferPointer { VideoToolboxDecoder.pictureNALRanges(in: $0) } }
    #expect(ranges([0, 0, 1, 0x65, 0x80, 0, 0, 0, 1, 0x41, 0x80, 0]) == [3..<5, 9..<11])
    #expect(ranges([0x65, 0x80, 0, 0]) == nil)
    #expect(ranges([0, 0, 1]) == nil)
    #expect(ranges([0, 0, 1, 0x65, 0, 0, 1]) == nil)
    #expect(ranges([0xFF, 0, 0, 1, 0x65]) == nil)
}

@Test func commonCRttReadsAreGatedBeforeStartAndAfterStop() {
    let engine = StreamSessionEngine.shared
    engine.prepareConnection()
    var samples = 0
    var videoSamples = 0
    func read() -> (Double, Double)? { samples += 1; return (2, 1) }
    func videoRead() -> Int32 { videoSamples += 1; return 7 }
    #expect(engine.sampleRtt(read: read) == nil)
    #expect(engine.samplePendingVideoFrames(read: videoRead) == nil)
    engine.connectionDidStart()
    #expect(engine.sampleRtt(read: read)?.0 == 2)
    #expect(engine.samplePendingVideoFrames(read: videoRead) == 7)
    engine.connectionWillStop()
    engine.connectionDidStart() // A late startup callback must not re-enable sampling.
    #expect(engine.sampleRtt(read: read) == nil)
    #expect(engine.samplePendingVideoFrames(read: videoRead) == nil)
    #expect(samples == 1)
    #expect(videoSamples == 1)
}

@Test func controllerCountPolicyMatchesCommonCServerVersion() {
    #expect(Host(name: "Sunshine", address: "localhost", appVersion: "7.1.431.-1").supportsExtendedControllers)
    #expect(!Host(name: "GFE", address: "localhost", appVersion: "7.1.431.0").supportsExtendedControllers)
    #expect(!Host(name: "Unknown", address: "localhost").supportsExtendedControllers)
}

@Test func bundledLanguagesResolveAndFallback() {
    defer { AppLocalization.apply(language: "system") }
    for (language, value) in [("en", "Settings"), ("de", "Einstellungen"), ("fr", "Réglages"), ("es", "Ajustes")] {
        AppLocalization.apply(language: language)
        #expect(AppLocalization.text("Settings") == value)
        #expect(AppLocalization.text("An unknown technical message") == "An unknown technical message")
    }
}

@Test func desktopMouseHandlesFlippedHostingViews() throws {
    let bounds = CGRect(x: 10, y: 20, width: 1920, height: 1080)
    let size = CGSize(width: 1920, height: 1080)
    let flipped = try #require(DesktopMousePosition.map(point: CGPoint(x: 10, y: 20), bounds: bounds, video: size, flipped: true))
    #expect(flipped.x == 0 && flipped.y == 0)
    let bottom = try #require(DesktopMousePosition.map(point: CGPoint(x: 10, y: 1099), bounds: bounds, video: size, flipped: true))
    #expect(bottom.y == 1079)
}

@Test func packagedLanguagesResolveAfterRelocationWithoutBuildDirectory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("Moved Moonlight.app")
    let resources = app.appendingPathComponent("Contents/Resources/MoonlightMac_MoonlightMac.bundle")
    let language = resources.appendingPathComponent("de.lproj")
    try FileManager.default.createDirectory(at: language, withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleIdentifier": "test.\(UUID().uuidString)", "CFBundlePackageType": "APPL", "CFBundleExecutable": "MoonlightMac"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
    try #""Settings" = "Relocated settings";"#.write(to: language.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
    let appBundle = try #require(Bundle(url: app))
    let resolved = try #require(AppLocalization.resourceBundle(appBundle: appBundle))
    #expect(resolved.bundleURL.standardizedFileURL == resources.standardizedFileURL)
    let german = try #require(Bundle(url: language))
    #expect(german.localizedString(forKey: "Settings", value: nil, table: nil) == "Relocated settings")
    try FileManager.default.removeItem(at: resources)
    #expect(AppLocalization.resourceBundle(appBundle: appBundle) == nil)
}

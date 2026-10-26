import Foundation
import Testing
@testable import MoonlightMac

@Test func libplaceboRendererPreferenceRoundTrips() throws {
    var settings = StreamSettings()
    settings.videoRenderer = .libplacebo
    settings.enableVsync = false
    let restored = try JSONDecoder().decode(StreamSettings.self, from: JSONEncoder().encode(settings))
    #expect(restored.videoRenderer == .libplacebo)
    #expect(!restored.enableVsync)
}

@Test func legacySettingsKeepMetalDefault() throws {
    let encoded = try JSONEncoder().encode(StreamSettings())
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "videoRenderer")
    let restored = try JSONDecoder().decode(StreamSettings.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(restored.videoRenderer == .metal)
}

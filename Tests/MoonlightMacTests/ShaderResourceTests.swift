import Foundation
import Testing
@testable import MoonlightMac

@Test func packagedShaderLoadsAfterAppRelocation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("Moved Moonlight.app")
    let resources = app.appendingPathComponent("Contents/Resources/MoonlightMac_MoonlightMac.bundle")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleIdentifier": "test.\(UUID().uuidString)",
                                "CFBundlePackageType": "APPL", "CFBundleExecutable": "MoonlightMac"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: app.appendingPathComponent("Contents/Info.plist"))
    let shader = resources.appendingPathComponent("Shaders.metal")
    try "// relocated shader".write(to: shader, atomically: true, encoding: .utf8)
    let bundle = try #require(Bundle(url: app))
    #expect(ShaderResources.source(appBundle: bundle) == "// relocated shader")
    try FileManager.default.removeItem(at: shader)
    // Missing resources in a distributed app cannot silently use a developer's
    // build-directory bundle or fatalError inside SwiftPM's generated accessor.
    #expect(ShaderResources.source(appBundle: bundle) == nil)
}

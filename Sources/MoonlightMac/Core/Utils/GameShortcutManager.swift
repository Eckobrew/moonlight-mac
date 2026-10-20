import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
public final class GameShortcutManager {
    public static let shared = GameShortcutManager()

    private init() {}

    /// Prompts the user to select an icon (or defaults to the game's box art) and creates
    /// a standalone macOS .app shortcut bundle on the Desktop with custom icon and launch script.
    public func createShortcut(for app: StreamApp, host: Host, iconImage: NSImage?) {
        let openPanel = NSOpenPanel()
        openPanel.title = "Select Game Icon"
        openPanel.message = "Choose an icon for '\(app.title)' (.icns, .png, .ico, .jpg) or click Cancel to use the game's box art."
        openPanel.prompt = "Choose Icon"
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false

        var allowedTypes: [UTType] = [.png, .jpeg]
        if let icnsType = UTType(filenameExtension: "icns") { allowedTypes.append(icnsType) }
        if let icoType = UTType(filenameExtension: "ico") { allowedTypes.append(icoType) }
        openPanel.allowedContentTypes = allowedTypes

        var chosenImage: NSImage?
        let response = openPanel.runModal()
        if response == .OK, let selectedUrl = openPanel.url {
            chosenImage = NSImage(contentsOf: selectedUrl)
        }

        // Fall back to provided box art or default app icon
        let finalImage = chosenImage ?? iconImage ?? NSApp.applicationIconImage ?? NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: nil)!

        do {
            try writeAppBundle(app: app, host: host, image: finalImage)

            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Shortcut Created"
            alert.informativeText = "Shortcut for '\(app.title)' was created successfully on your Desktop."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Failed to Create Shortcut"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func writeAppBundle(app: StreamApp, host: Host, image: NSImage) throws {
        guard let desktopUrl = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "GameShortcutManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not access Desktop folder."])
        }

        let safeName = app.title.replacingOccurrences(of: "[:/\\\\?*\"<>|]", with: "_", options: .regularExpression)
        let bundleUrl = desktopUrl.appendingPathComponent("\(safeName).app")

        let macOsDir = bundleUrl.appendingPathComponent("Contents/MacOS")
        let resourcesDir = bundleUrl.appendingPathComponent("Contents/Resources")

        try FileManager.default.createDirectory(at: macOsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resourcesDir, withIntermediateDirectories: true)

        let slug = safeName.lowercased().replacingOccurrences(of: "[^a-z0-9]", with: "-", options: .regularExpression)
        let xmlEscapedApp = app.title
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")

        // 1. Info.plist
        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleDevelopmentRegion</key>
            <string>en</string>
            <key>CFBundleExecutable</key>
            <string>launch</string>
            <key>CFBundleIconFile</key>
            <string>app.icns</string>
            <key>CFBundleIdentifier</key>
            <string>com.moonlight-stream.shortcut.\(slug)</string>
            <key>CFBundleInfoDictionaryVersion</key>
            <string>6.0</string>
            <key>CFBundleName</key>
            <string>\(xmlEscapedApp)</string>
            <key>CFBundleDisplayName</key>
            <string>\(xmlEscapedApp)</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
            <key>CFBundleShortVersionString</key>
            <string>1.0</string>
            <key>LSMinimumSystemVersion</key>
            <string>12.0</string>
            <key>NSHighResolutionCapable</key>
            <true/>
        </dict>
        </plist>
        """
        try plistContent.write(to: bundleUrl.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)

        // 2. Icon resources (.png and .icns)
        let pngUrl = resourcesDir.appendingPathComponent("app.png")
        if let pngData = renderPNG(from: image, size: 512) {
            try pngData.write(to: pngUrl)
        }

        let icnsUrl = resourcesDir.appendingPathComponent("app.icns")
        try writeIcns(from: image, to: icnsUrl)

        // Set custom Finder icon on the bundle wrapper
        NSWorkspace.shared.setIcon(image, forFile: bundleUrl.path, options: [])

        // 3. Launch script
        let moonlightBin = Bundle.main.executablePath ?? "/Applications/Moonlight.app/Contents/MacOS/MoonlightMac"
        let escapedHost = host.name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
        let escapedApp = app.title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")

        let launchScript = """
        #!/bin/bash
        DIR="$(cd "$(dirname "$0")" && pwd)"
        ICON="$DIR/../Resources/app.png"
        if [ ! -f "$ICON" ]; then
            ICON="$DIR/../Resources/app.icns"
        fi

        MOONLIGHT_BIN="\(moonlightBin)"
        if [ ! -x "$MOONLIGHT_BIN" ]; then
            MOONLIGHT_BIN="/Applications/Moonlight.app/Contents/MacOS/MoonlightMac"
        fi
        if [ ! -x "$MOONLIGHT_BIN" ]; then
            MOONLIGHT_BIN="/Applications/Moonlight.app/Contents/MacOS/Moonlight"
        fi

        if [ -x "$MOONLIGHT_BIN" ]; then
            exec "$MOONLIGHT_BIN" stream "\(escapedHost)" "\(escapedApp)" --icon "$ICON"
        else
            open -a Moonlight --args stream "\(escapedHost)" "\(escapedApp)" --icon "$ICON"
        fi
        """

        let launchUrl = macOsDir.appendingPathComponent("launch")
        try launchScript.write(to: launchUrl, atomically: true, encoding: .utf8)

        // Make executable (chmod +x)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launchUrl.path)

        NSWorkspace.shared.noteFileSystemChanged(bundleUrl.path)
    }

    private func renderPNG(from image: NSImage, size: Int) -> Data? {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep = rep else { return nil }
        rep.size = NSSize(width: size, height: size)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }

    private func writeIcns(from image: NSImage, to outputUrl: URL) throws {
        let formats: [(tag: String, size: Int)] = [
            ("icp4", 16),
            ("icp5", 32),
            ("icp6", 64),
            ("ic07", 128),
            ("ic08", 256),
            ("ic09", 512),
            ("ic10", 1024)
        ]

        var chunksData = Data()
        for fmt in formats {
            guard let png = renderPNG(from: image, size: fmt.size), !png.isEmpty else {
                continue
            }
            guard let tagData = fmt.tag.data(using: .ascii), tagData.count == 4 else {
                continue
            }
            let chunkTotalLen = UInt32(8 + png.count).bigEndian
            chunksData.append(tagData)
            chunksData.append(contentsOf: withUnsafeBytes(of: chunkTotalLen) { Array($0) })
            chunksData.append(png)
        }

        var icnsHeader = Data()
        let magic: UInt32 = 0x69636e73 // 'icns' in big endian
        let totalFileLen = UInt32(8 + chunksData.count).bigEndian

        icnsHeader.append(contentsOf: withUnsafeBytes(of: magic.bigEndian) { Array($0) })
        icnsHeader.append(contentsOf: withUnsafeBytes(of: totalFileLen) { Array($0) })

        let completeIcns = icnsHeader + chunksData
        try completeIcns.write(to: outputUrl)
    }
}

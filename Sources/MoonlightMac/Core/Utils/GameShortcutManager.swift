import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

public enum ShortcutIconStyle: String, CaseIterable, Identifiable {
    case squircle = "Squircle"
    case circle = "Circle"
    case cutout = "Logo Cutout"
    case original = "Box Art"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .squircle: return "macOS Squircle"
        case .circle: return "macOS Circle"
        case .cutout: return "Logo Cutout"
        case .original: return "Box Art / Cover"
        }
    }
}

public enum ShortcutFillMode: String, CaseIterable, Identifiable {
    case aspectFill = "Crop to Fill"
    case aspectFit = "Fit Inside"

    public var id: String { rawValue }
}

public enum ShortcutBackdrop: String, CaseIterable, Identifiable {
    case blurred = "Blurred Art"
    case dark = "Dark"
    case black = "Black"
    case clear = "None"

    public var id: String { rawValue }
}

@MainActor
public final class GameShortcutManager {
    public static let shared = GameShortcutManager()

    private init() {}

    /// Creates a standalone macOS .app shortcut bundle on the Desktop with a custom styled icon.
    public func createShortcut(
        for app: StreamApp,
        host: Host,
        image: NSImage,
        style: ShortcutIconStyle = .squircle,
        fillMode: ShortcutFillMode = .aspectFill,
        backdrop: ShortcutBackdrop = .blurred
    ) throws {
        let formattedImage = formatIcon(from: image, style: style, fillMode: fillMode, backdrop: backdrop, size: 1024)
        try writeAppBundle(app: app, host: host, image: formattedImage)
    }

    /// Formats an image into a native macOS icon conforming exactly to Apple HIG icon grid guidelines.
    public func formatIcon(
        from image: NSImage,
        style: ShortcutIconStyle = .squircle,
        fillMode: ShortcutFillMode = .aspectFill,
        backdrop: ShortcutBackdrop = .blurred,
        size: CGFloat = 1024
    ) -> NSImage {
        let renderView = IconRenderView(
            image: image,
            style: style,
            fillMode: fillMode,
            backdrop: backdrop,
            size: size
        )
        let renderer = ImageRenderer(content: renderView)
        renderer.scale = 1.0
        if let rendered = renderer.nsImage {
            return rendered
        }
        return image
    }

    /// Legacy file picker prompt (falls back to box art if cancelled).
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

        let finalImage = chosenImage ?? iconImage ?? NSApp.applicationIconImage ?? NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: nil)!

        do {
            try createShortcut(for: app, host: host, image: finalImage, style: .squircle, fillMode: .aspectFill, backdrop: .blurred)

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

        if FileManager.default.fileExists(atPath: bundleUrl.path) {
            try? FileManager.default.removeItem(at: bundleUrl)
        }

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
        let appIconPngUrl = resourcesDir.appendingPathComponent("AppIcon.png")
        if let pngData = renderPNG(from: image, size: 1024) {
            try pngData.write(to: pngUrl)
            try? pngData.write(to: appIconPngUrl)
        }

        let icnsUrl = resourcesDir.appendingPathComponent("app.icns")
        let appIconIcnsUrl = resourcesDir.appendingPathComponent("AppIcon.icns")
        try writeIcns(from: image, to: icnsUrl)
        try? FileManager.default.copyItem(at: icnsUrl, to: appIconIcnsUrl)

        // Ensure no legacy Icon\r file exists
        let iconR = bundleUrl.appendingPathComponent("Icon\r")
        try? FileManager.default.removeItem(at: iconR)

        // Set Finder custom icon via NSWorkspace
        NSWorkspace.shared.setIcon(image, forFile: bundleUrl.path, options: [])

        // 3. Launch script
        let moonlightBin: String
        let mainExec = Bundle.main.executablePath ?? ""
        if mainExec.contains("Moonlight.app") || mainExec.contains("MoonlightMac") {
            moonlightBin = mainExec
        } else {
            moonlightBin = "/Applications/Moonlight.app/Contents/MacOS/MoonlightMac"
        }
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
        if [ ! -x "$MOONLIGHT_BIN" ]; then
            MOONLIGHT_BIN="$HOME/Applications/Moonlight.app/Contents/MacOS/MoonlightMac"
        fi

        if [ -x "$MOONLIGHT_BIN" ]; then
            exec "$MOONLIGHT_BIN" stream "\(escapedHost)" "\(escapedApp)" --icon "$ICON"
        else
            open -a Moonlight --args stream "\(escapedHost)" "\(escapedApp)" --icon "$ICON"
        fi
        """

        let launchUrl = macOsDir.appendingPathComponent("launch")
        try launchScript.write(to: launchUrl, atomically: true, encoding: .utf8)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launchUrl.path)

        // Register application bundle with LaunchServices and notify Finder
        registerBundleWithLaunchServices(bundleUrl: bundleUrl)
    }

    private func registerBundleWithLaunchServices(bundleUrl: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: bundleUrl.path)

        let lsregisterPath = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        if FileManager.default.fileExists(atPath: lsregisterPath) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: lsregisterPath)
            proc.arguments = ["-f", "-r", bundleUrl.path]
            try? proc.run()
            proc.waitUntilExit()
        }

        NSWorkspace.shared.noteFileSystemChanged(bundleUrl.path)

        // If shortcuts are pinned in Dock, restart Dock so the icon reloads immediately
        restartDockIfPinned()
    }

    private func restartDockIfPinned() {
        let tmp = NSTemporaryDirectory()
        let cDir = URL(fileURLWithPath: tmp).deletingLastPathComponent().appendingPathComponent("C")
        try? FileManager.default.removeItem(at: cDir.appendingPathComponent("com.apple.dock.iconcache"))
        try? FileManager.default.removeItem(at: cDir.appendingPathComponent("com.apple.iconservices"))

        let checkProcess = Process()
        checkProcess.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        checkProcess.arguments = ["read", "com.apple.dock", "persistent-apps"]
        let pipe = Pipe()
        checkProcess.standardOutput = pipe
        try? checkProcess.run()
        checkProcess.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8), output.contains("com.moonlight-stream.shortcut") {
            let killProc = Process()
            killProc.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            killProc.arguments = ["Dock"]
            try? killProc.run()
        }
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
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }

    private func writeIcns(from image: NSImage, to outputUrl: URL) throws {
        // Try Apple official iconutil compiler first
        let tempIconset = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".iconset")
        try FileManager.default.createDirectory(at: tempIconset, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempIconset)
        }

        let standardSizes: [(name: String, size: Int)] = [
            ("icon_16x16.png", 16),
            ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32),
            ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128),
            ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256),
            ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512),
            ("icon_512x512@2x.png", 1024)
        ]

        var allRendered = true
        for item in standardSizes {
            if let data = renderPNG(from: image, size: item.size) {
                try data.write(to: tempIconset.appendingPathComponent(item.name))
            } else {
                allRendered = false
                break
            }
        }

        if allRendered && FileManager.default.fileExists(atPath: "/usr/bin/iconutil") {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
            process.arguments = ["-c", "icns", tempIconset.path, "-o", outputUrl.path]
            try? process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 && FileManager.default.fileExists(atPath: outputUrl.path) {
                return
            }
        }

        // Fallback to manual chunk writing
        try writeIcnsManual(from: image, to: outputUrl)
    }

    private func writeIcnsManual(from image: NSImage, to outputUrl: URL) throws {
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

// MARK: - SwiftUI Icon Render View (Exact Apple HIG Grid Geometry)
private struct IconRenderView: View {
    let image: NSImage
    let style: ShortcutIconStyle
    let fillMode: ShortcutFillMode
    let backdrop: ShortcutBackdrop
    let size: CGFloat

    var body: some View {
        ZStack {
            switch style {
            case .squircle:
                // Apple HIG standard macOS squircle: 824x824 inside 1024x1024, corner radius 185 continuous
                let bodySize: CGFloat = size * (859.0 / 1024.0)
                let radius: CGFloat = size * (194.0 / 1024.0)

                // Icon body
                ZStack {
                    backdropLayer(size: bodySize)

                    if fillMode == .aspectFill {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: bodySize, height: bodySize)
                    } else {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: bodySize * 0.90, height: bodySize * 0.90)
                    }
                }
                .frame(width: bodySize, height: bodySize)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(
                    // Soft top-down sheen like native macOS icons, so dark artwork still reads as a full-size tile
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(LinearGradient(colors: [Color.white.opacity(0.14), Color.clear], startPoint: .top, endPoint: .center))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.40), lineWidth: max(2.0, size * (6.0 / 1024.0)))
                )
                // Nudge the tile down so it sits level with native Dock tiles (about 4 screen px at Dock size)
                .offset(y: size * (12.0 / 1024.0))

            case .circle:
                // Apple HIG standard circular icon (e.g. Safari / Time Machine): 844x844 diameter
                let diameter: CGFloat = size * (844.0 / 1024.0)

                // Icon body
                ZStack {
                    backdropLayer(size: diameter)

                    if fillMode == .aspectFill {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: diameter, height: diameter)
                    } else {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: diameter * 0.90, height: diameter * 0.90)
                    }
                }
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.18), lineWidth: max(1.0, size * (1.5 / 1024.0)))
                )

            case .cutout:
                // Natural transparent cutout with Apple drop shadow
                let targetSize: CGFloat = size * (824.0 / 1024.0)
                let shadowRadius: CGFloat = size * (8.0 / 1024.0)
                let shadowOffset: CGFloat = size * (6.0 / 1024.0)

                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: targetSize, height: targetSize)
                    .shadow(color: Color.black.opacity(0.30), radius: shadowRadius, x: 0, y: shadowOffset)

            case .original:
                // Full rectangular box art / banner
                let targetSize: CGFloat = size * (840.0 / 1024.0)
                let shadowRadius: CGFloat = size * (6.0 / 1024.0)
                let shadowOffset: CGFloat = size * (6.0 / 1024.0)

                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: targetSize, height: targetSize)
                    .clipShape(RoundedRectangle(cornerRadius: size * (24.0 / 1024.0), style: .continuous))
                    .shadow(color: Color.black.opacity(0.28), radius: shadowRadius, x: 0, y: shadowOffset)
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private func backdropLayer(size: CGFloat) -> some View {
        switch backdrop {
        case .blurred:
            ZStack {
                // Fully opaque dark base color ensures 100% solid squircle body
                Color(red: 0.12, green: 0.12, blue: 0.14)

                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .blur(radius: 20)
                    .opacity(0.75)
            }
        case .dark:
            Color(red: 0.14, green: 0.14, blue: 0.16)
        case .black:
            Color.black
        case .clear:
            Color.clear
        }
    }
}

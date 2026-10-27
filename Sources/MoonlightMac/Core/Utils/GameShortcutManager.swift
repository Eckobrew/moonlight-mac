import AppKit
import Foundation
import SwiftUI
import CoreServices

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

    private func writeAppBundle(app: StreamApp, host: Host, image: NSImage) throws {
        guard let desktopUrl = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "GameShortcutManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not access Desktop folder."])
        }

        let identifier = ShortcutBundleStore.identifier(host: host, app: app)
        let destination = desktopUrl.appendingPathComponent(
            ShortcutBundleStore.filename(title: app.title, hostName: host.name, identifier: identifier))
        let staging = desktopUrl.appendingPathComponent(".moonlight-shortcut-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        let bundleUrl = staging.appendingPathComponent(destination.lastPathComponent)

        let macOsDir = bundleUrl.appendingPathComponent("Contents/MacOS")
        let resourcesDir = bundleUrl.appendingPathComponent("Contents/Resources")

        try FileManager.default.createDirectory(at: macOsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resourcesDir, withIntermediateDirectories: true)

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
            <string>\(identifier)</string>
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
            <string>14.0</string>
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

        // 3. Launch script and internal binary symlinks
        let moonlightBin: String
        let mainExec = Bundle.main.executablePath ?? ""
        if mainExec.contains("Moonlight.app") || URL(fileURLWithPath: mainExec).lastPathComponent == "moonlight-mac" {
            moonlightBin = mainExec
        } else {
            moonlightBin = "/Applications/Moonlight.app/Contents/MacOS/moonlight-mac"
        }

        // Create internal symlinks so the shortcut bundle runs as its own independent bundle process
        let binSymlink = macOsDir.appendingPathComponent("moonlight-mac")
        try? FileManager.default.removeItem(at: binSymlink)
        try? FileManager.default.createSymbolicLink(at: binSymlink, withDestinationURL: URL(fileURLWithPath: moonlightBin))

        let appResources = URL(fileURLWithPath: moonlightBin).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/MoonlightMac_MoonlightMac.bundle")
        let bundleSymlink = resourcesDir.appendingPathComponent("MoonlightMac_MoonlightMac.bundle")
        try? FileManager.default.removeItem(at: bundleSymlink)
        try? FileManager.default.createSymbolicLink(at: bundleSymlink, withDestinationURL: appResources)

        let escapedHost = (host.serverId ?? host.address)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
        let escapedApp = (app.uuid ?? app.title)
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

        if [ -x "$DIR/moonlight-mac" ]; then
            exec "$DIR/moonlight-mac" stream "\(escapedHost)" "\(escapedApp)" --icon "$ICON"
        fi

        MOONLIGHT_BIN="\(moonlightBin.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "$", with: "\\$").replacingOccurrences(of: "`", with: "\\`"))"
        if [ ! -x "$MOONLIGHT_BIN" ]; then
            MOONLIGHT_BIN="/Applications/Moonlight.app/Contents/MacOS/moonlight-mac"
        fi
        if [ ! -x "$MOONLIGHT_BIN" ]; then
            MOONLIGHT_BIN="$HOME/Applications/Moonlight.app/Contents/MacOS/moonlight-mac"
        fi

        exec "$MOONLIGHT_BIN" stream "\(escapedHost)" "\(escapedApp)" --icon "$ICON"
        """

        let launchUrl = macOsDir.appendingPathComponent("launch")
        try launchScript.write(to: launchUrl, atomically: true, encoding: .utf8)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launchUrl.path)

        try ShortcutBundleStore.install(staged: bundleUrl, destination: destination, identifier: identifier)
        NSWorkspace.shared.setIcon(image, forFile: destination.path, options: [])
        LSRegisterURL(destination as CFURL, true)
        NSWorkspace.shared.noteFileSystemChanged(destination.path)
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
        // PNG-backed ICNS chunks avoid blocking the main actor on iconutil.
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

import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case video = "Display & Video"
    case audio = "Audio"
    case input = "Keyboard & Mouse"
    case host = "Host & Stream"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .video: return "display.2"
        case .audio: return "speaker.wave.2.fill"
        case .input: return "keyboard.fill"
        case .host: return "server.rack"
        }
    }

    var color: Color {
        switch self {
        case .video: return .blue
        case .audio: return .purple
        case .input: return .teal
        case .host: return .orange
        }
    }

    var description: String {
        switch self {
        case .video: return "Configure stream resolution, frame rate, HDR, and rendering performance."
        case .audio: return "Manage speaker configuration and audio output behavior."
        case .input: return "Customize mouse sensitivity, keyboard shortcuts, and PC layout mapping."
        case .host: return "Set host game optimization, clipboard sync, and disconnection rules."
        }
    }
}

public struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding public var settings: StreamSettings
    public let onSave: () -> Void

    @State private var selectedTab: SettingsTab = .video

    private var nativeResolutionLabel: String {
        let (w, h) = DisplayManager.getNativeResolution()
        return "Native (\(w)x\(h))"
    }

    private let standardResolutions: [(name: String, width: Int, height: Int)] = [
        ("720p (1280x720)", 1280, 720),
        ("1080p (1920x1080)", 1920, 1080),
        ("1440p (2560x1440)", 2560, 1440),
        ("4K UHD (3840x2160)", 3840, 2160)
    ]

    private let framerates = [30, 60, 90, 120, 144, 240]

    public init(settings: Binding<StreamSettings>, onSave: @escaping () -> Void) {
        self._settings = settings
        self.onSave = onSave
    }

    public var body: some View {
        HStack(spacing: 0) {
            // Left Sidebar
            VStack(alignment: .leading, spacing: 4) {
                Text("Settings")
                    .font(.title3)
                    .fontWeight(.bold)
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 12)

                ForEach(SettingsTab.allCases) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(selectedTab == tab ? .white : tab.color)
                                .frame(width: 20)

                            Text(tab.rawValue)
                                .font(.system(size: 13, weight: selectedTab == tab ? .semibold : .regular))
                                .foregroundStyle(selectedTab == tab ? .white : .primary)

                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selectedTab == tab ? Color.accentColor : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                }

                Spacer()

                Divider()
                    .padding(.horizontal, 14)

                Button("Done") {
                    onSave()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(width: 210)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Right Detail Area
            VStack(alignment: .leading, spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedTab.rawValue)
                        .font(.title2)
                        .fontWeight(.bold)
                    Text(selectedTab.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 12)

                Divider()

                // Content Form
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        switch selectedTab {
                        case .video:
                            videoPane
                        case .audio:
                            audioPane
                        case .input:
                            inputPane
                        case .host:
                            hostPane
                        }
                    }
                    .padding(24)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
        }
        .frame(width: 760, height: 560)
    }

    // MARK: - Video Pane
    @ViewBuilder
    private var videoPane: some View {
        GroupBox("Display & Resolution") {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Resolution:", selection: resolutionBinding) {
                    Text(nativeResolutionLabel).tag("Native")
                    ForEach(standardResolutions, id: \.name) { res in
                        Text(res.name).tag(res.name)
                    }
                }

                Picker("Display Mode:", selection: $settings.windowMode) {
                    ForEach(WindowMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }

                Picker("Frame Rate:", selection: $settings.fps) {
                    ForEach(framerates, id: \.self) { fps in
                        Text("\(fps) FPS").tag(fps)
                    }
                }
            }
            .padding(8)
        }

        GroupBox("Bitrate Controls") {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Target Bitrate:")
                        Spacer()
                        Text("\(settings.bitrateMbps) Mbps")
                            .monospacedDigit()
                            .fontWeight(.semibold)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(settings.bitrateMbps) },
                            set: { settings.bitrateMbps = Int($0) }
                        ),
                        in: 5...150,
                        step: 1
                    )
                }

                Divider()

                Toggle("Custom Bitrate for Remote Sessions", isOn: $settings.enableRemoteBitrate)
                Text("Switches to this bitrate when connecting over the Internet or Tailscale.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settings.enableRemoteBitrate {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Remote Bitrate:")
                            Spacer()
                            Text("\(settings.remoteBitrateMbps) Mbps")
                                .monospacedDigit()
                                .fontWeight(.semibold)
                        }
                        Slider(
                            value: Binding(
                                get: { Double(settings.remoteBitrateMbps) },
                                set: { settings.remoteBitrateMbps = Int($0) }
                            ),
                            in: 2...100,
                            step: 1
                        )
                    }
                    .padding(.leading, 12)
                }
            }
            .padding(8)
        }

        GroupBox("Rendering & Color") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Video Codec:", selection: $settings.codec) {
                    ForEach(VideoCodec.allCases, id: \.self) { codec in
                        Text(codec.rawValue).tag(codec)
                    }
                }

                Picker("Renderer:", selection: $settings.videoRenderer) {
                    ForEach(VideoRendererMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }

                Divider()

                Toggle("Enable V-Sync", isOn: $settings.enableVsync)
                Text("Locks frame presentation to your display refresh rate to eliminate tearing. Turn off for lowest latency.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !settings.enableVsync && settings.videoRenderer == .native {
                    Label("Disabling V-Sync requires the Metal renderer for unlocked display presentation.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Toggle("Enable Frame Pacing", isOn: $settings.enableFramePacing)
                Text("Paces video frames smoothly across display refresh intervals to prevent micro-stutter.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Toggle("Enable HDR (10-bit High Dynamic Range)", isOn: $settings.enableHdr)
                Toggle("Full Dynamic Range Color (Full vs Limited Range)", isOn: $settings.fullRangeColor)
            }
            .padding(8)
        }
    }

    // MARK: - Audio Pane
    @ViewBuilder
    private var audioPane: some View {
        GroupBox("Audio Configuration") {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Channel Layout:", selection: $settings.audioMode) {
                    ForEach(AudioConfigurationMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }

                Divider()

                Toggle("Mute host PC speakers while streaming", isOn: $settings.muteHostAudio)
                Text("Mutes physical sound on the host computer while streaming to this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }

    // MARK: - Input Pane
    @ViewBuilder
    private var inputPane: some View {
        GroupBox("Mouse Controls") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Capture mouse pointer automatically", isOn: $settings.mouseCaptureMode)
                Text("Locks the cursor to the streaming window so games receive continuous hardware mouse movements.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                HStack {
                    Text("Mouse Sensitivity:")
                    Slider(value: $settings.mouseSensitivity, in: 0.25...3.0, step: 0.05)
                    Text(String(format: "%.2fx", settings.mouseSensitivity))
                        .monospacedDigit()
                        .frame(width: 45, alignment: .trailing)
                }
                Text("Scales hardware mouse movement sent to the host PC.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }

        GroupBox("Keyboard Shortcuts & Layout") {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Capture system keyboard shortcuts:", selection: $settings.captureSystemKeys) {
                    ForEach(SystemKeyCaptureMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                Text("Sends ⌘Tab, Spotlight, Mission Control and macOS shortcuts directly to the host PC while streaming. Press ⌃⌥⇧Z to release cursor and shortcuts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Toggle("Match physical Windows PC keyboard layout (Control, Windows, Alt)", isOn: $settings.swapWinAltKeys)
                Text("Maps Control → Ctrl, Option → Windows, Command → Alt so the physical keys match a standard PC keyboard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }

        GroupBox("In-Stream Keyboard Shortcuts") {
            VStack(alignment: .leading, spacing: 8) {
                shortcutRow(keys: "⌃ ⌥ ⇧ Q", label: "Disconnect / Quit stream")
                shortcutRow(keys: "⌃ ⌥ ⇧ Z", label: "Release / recapture mouse cursor")
                shortcutRow(keys: "⌃ ⌥ ⇧ X", label: "Toggle Fullscreen / Windowed")
                shortcutRow(keys: "⌃ ⌥ ⇧ S", label: "Toggle Performance HUD overlay")
                shortcutRow(keys: "⌃ ⌥ ⇧ M", label: "Toggle Mouse Mode")
                shortcutRow(keys: "⌃ ⌥ ⇧ D", label: "Minimize Window")
                shortcutRow(keys: "⌃ ⌥ ⇧ V", label: "Type Mac clipboard text to host")
            }
            .padding(8)
        }
    }

    private func shortcutRow(keys: String, label: String) -> some View {
        HStack {
            Text(keys)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.semibold)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            Spacer()
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Host Pane
    @ViewBuilder
    private var hostPane: some View {
        GroupBox("Host & Application Behavior") {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Optimize game settings for streaming", isOn: $settings.optimizeGameSettings)
                Text("Allows the host PC to automatically tune in-game graphics for optimal streaming performance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Toggle("Quit game on host when ending stream", isOn: $settings.quitAppOnStop)
                Text("Terminates the running game on the host when you disconnect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Toggle("Synchronize clipboard with host", isOn: $settings.enableClipboardSync)
                Text("Automatically synchronizes copied text between your Mac and Apollo/Sunshine over secure HTTPS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Toggle("Hide unpaired PCs", isOn: $settings.hideUnpairedHosts)
                Text("Hides discovered PCs that have not been paired yet, while keeping paired offline PCs visible.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }

    private var resolutionBinding: Binding<String> {
        Binding(
            get: {
                if settings.width == 0 || settings.height == 0 {
                    return "Native"
                }
                return standardResolutions.first(where: { $0.width == settings.width && $0.height == settings.height })?.name
                    ?? "\(settings.width)x\(settings.height)"
            },
            set: { selectedName in
                if selectedName == "Native" {
                    settings.width = 0
                    settings.height = 0
                } else if let match = standardResolutions.first(where: { $0.name == selectedName }) {
                    settings.width = match.width
                    settings.height = match.height
                }
            }
        )
    }
}

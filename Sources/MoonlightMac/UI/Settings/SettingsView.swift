import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case video = "Display & Video"
    case audio = "Audio"
    case input = "Keyboard & Mouse"
    case host = "Host & Stream"
    case controllers = "Controllers"
    case application = "Application"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .video: return "display.2"
        case .audio: return "speaker.wave.2.fill"
        case .input: return "keyboard.fill"
        case .host: return "server.rack"
        case .controllers: return "gamecontroller"
        case .application: return "gearshape"
        }
    }

    var color: Color {
        switch self {
        case .video: return .blue
        case .audio: return .purple
        case .input: return .teal
        case .host: return .orange
        case .controllers: return .green
        case .application: return .gray
        }
    }

    var description: String {
        switch self {
        case .video: return "Configure stream resolution, frame rate, HDR, and rendering performance."
        case .audio: return "Manage speaker configuration and audio output behavior."
        case .input: return "Customize mouse sensitivity, keyboard shortcuts, and PC layout mapping."
        case .host: return "Set host game optimization, clipboard sync, and disconnection rules."
        case .controllers: return "Configure controller buttons, mouse control, and background input."
        case .application: return "Manage discovery, language, and Discord presence."
        }
    }
}

public struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding public var settings: StreamSettings
    public let onSave: () -> Void

    @State private var selectedTab: SettingsTab = .video
    @State private var audioDevices: [AudioOutputDevice] = AudioOutputDevices.available()

    /// Bridges the optional device UID to a `Picker` tag (“” = system default).
    private var audioOutputBinding: Binding<String> {
        Binding(
            get: { settings.audioOutputDeviceUID ?? "" },
            set: { settings.audioOutputDeviceUID = $0.isEmpty ? nil : $0 }
        )
    }

    private var nativeResolutionLabel: String {
        let (w, h) = DisplayManager.getNativeResolution()
        return "Native (\(w)x\(h))"
    }

    public init(settings: Binding<StreamSettings>, onSave: @escaping () -> Void) {
        self._settings = settings
        self.onSave = onSave
    }

    public var body: some View {
        HStack(spacing: 0) {
            // Left Sidebar
            VStack(alignment: .leading, spacing: 4) {
                Text(AppLocalization.text("Settings"))
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

                            Text(AppLocalization.text(tab.rawValue))
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

                Button(AppLocalization.text("Done")) {
                    onSave()
                    dismiss()
                }
                .disabled(settings.validationMessage != nil)
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
                    Text(AppLocalization.text(selectedTab.rawValue))
                        .font(.title2)
                        .fontWeight(.bold)
                    Text(AppLocalization.text(selectedTab.description))
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
                        if let message = settings.validationMessage {
                            Text(message).foregroundStyle(.red).font(.caption)
                        }
                        switch selectedTab {
                        case .video:
                            videoPane
                        case .audio:
                            audioPane
                        case .input:
                            inputPane
                        case .host:
                            hostPane
                        case .controllers:
                            ControllerSettings(features: $settings.features)
                        case .application:
                            ApplicationSettings(features: $settings.features)
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
        GroupBox(AppLocalization.text("Display & Resolution")) {
            VStack(alignment: .leading, spacing: 14) {
                ResolutionPicker(
                    width: $settings.width, height: $settings.height, nativeLabel: nativeResolutionLabel)
                Picker(AppLocalization.text("Display Mode:"), selection: $settings.windowMode) {
                    ForEach(WindowMode.allCases, id: \.self) { mode in
                        Text(AppLocalization.text(mode.rawValue)).tag(mode)
                    }
                }

                FrameRatePicker(value: $settings.fps)

                Divider()

                Toggle(
                    AppLocalization.text("Keep screen active while streaming"),
                    isOn: $settings.keepScreenActive)
                Text(
                    AppLocalization.text(
                        "Prevents your Mac display from sleeping while streaming. Only keeps the screen active when Moonlight is focused."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(8)
        }

        GroupBox(AppLocalization.text("Bitrate Controls")) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(AppLocalization.text("Target Bitrate:"))
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

                Toggle(
                    AppLocalization.text("Custom Bitrate for Remote Sessions"),
                    isOn: $settings.enableRemoteBitrate)
                Text(
                    AppLocalization.text(
                        "Switches to this bitrate when connecting over the Internet or Tailscale.")
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if settings.enableRemoteBitrate {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(AppLocalization.text("Remote Bitrate:"))
                            Spacer()
                            Text(settings.remoteBitrateMbps == 0
                                ? "Auto (\((Double(settings.streamBitrateKbps(isRemote: true)) / 1000).formatted()) Mbps)"
                                : "\(settings.remoteBitrateMbps) Mbps")
                                .monospacedDigit()
                                .fontWeight(.semibold)
                        }
                        Slider(
                            value: Binding(
                                get: { Double(settings.remoteBitrateMbps) },
                                set: { settings.remoteBitrateMbps = Int($0) }
                            ),
                            in: 0...100,
                            step: 1
                        )
                    }
                    .padding(.leading, 12)
                    Text("0 uses one quarter of the normal bitrate. Changes apply to the next stream.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(8)
        }

        GroupBox(AppLocalization.text("Rendering & Color")) {
            VStack(alignment: .leading, spacing: 12) {
                Picker(AppLocalization.text("Video Codec:"), selection: $settings.codec) {
                    ForEach(VideoCodec.allCases, id: \.self) { codec in
                        // AV1 is only offered when this Mac's VideoToolbox can decode it; a host
                        // that picks an unsupported codec produces a black stream.
                        if codec != .av1 || VideoCodec.isAV1DecodingSupported {
                            Text(AppLocalization.text(codec.rawValue)).tag(codec)
                        }
                    }
                }
                if !VideoCodec.isAV1DecodingSupported, settings.codec == .av1 {
                    Label(
                        AppLocalization.text(
                            "AV1 is not supported by this Mac's decoder. Choose Auto, H.264, or HEVC."),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                Picker(AppLocalization.text("Renderer:"), selection: $settings.videoRenderer) {
                    ForEach(VideoRendererMode.allCases, id: \.self) { mode in
                        Text(AppLocalization.text(mode.rawValue)).tag(mode)
                    }
                }

                Divider()

                if settings.videoRenderer == .native {
                    Text(
                        AppLocalization.text(
                            "Display synchronization is managed automatically by the native renderer.")
                    ).font(.caption).foregroundStyle(.secondary)
                } else {
                    Toggle(AppLocalization.text("Enable V-Sync"), isOn: $settings.enableVsync)
                    Text(
                        AppLocalization.text(
                            "Synchronizes presentation to your display refresh rate to reduce tearing.")
                    ).font(.caption).foregroundStyle(.secondary)
                }

                Toggle(AppLocalization.text("Enable Frame Pacing"), isOn: $settings.enableFramePacing)
                Text(
                    AppLocalization.text(
                        "Paces video frames smoothly across display refresh intervals to prevent micro-stutter."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Divider()

                Toggle(
                    AppLocalization.text("Enable HDR (10-bit High Dynamic Range)"), isOn: $settings.enableHdr)
                DisclosureGroup(AppLocalization.text("Advanced color options")) {
                    Toggle(
                        AppLocalization.text("Full Dynamic Range Color (Full vs Limited Range)"),
                        isOn: $settings.fullRangeColor
                    ).padding(.top, 8)
                }
                VideoCompatibilitySettings(features: $settings.features, codec: settings.codec)
            }
            .padding(8)
        }
    }

    // MARK: - Audio Pane
    @ViewBuilder
    private var audioPane: some View {
        GroupBox(AppLocalization.text("Audio Configuration")) {
            VStack(alignment: .leading, spacing: 14) {
                Picker(AppLocalization.text("Channel Layout:"), selection: $settings.audioMode) {
                    ForEach(AudioConfigurationMode.allCases, id: \.self) { mode in
                        Text(AppLocalization.text(mode.rawValue)).tag(mode)
                    }
                }

                Divider()

                Picker(AppLocalization.text("Output device:"), selection: audioOutputBinding) {
                    Text(AppLocalization.text("System Default")).tag("")
                    ForEach(audioDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                HStack(spacing: 8) {
                    Text(AppLocalization.text("Devices are listed as reported by CoreAudio."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(AppLocalization.text("Refresh")) { audioDevices = AudioOutputDevices.available() }
                        .buttonStyle(.link)
                        .font(.caption)
                }

                Divider()

                Toggle(
                    AppLocalization.text("Mute host PC speakers while streaming"),
                    isOn: $settings.muteHostAudio)
                Text(
                    AppLocalization.text(
                        "Mutes physical sound on the host computer while streaming to this Mac.")
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Toggle(
                    AppLocalization.text("Mute my Mac when Moonlight is in the background"),
                    isOn: $settings.muteAudioOnFocusLoss)
                Text(
                    AppLocalization.text(
                        "Silences streaming audio whenever another app is focused, and restores it on return.")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }

    // MARK: - Input Pane
    @ViewBuilder
    private var inputPane: some View {
        GroupBox(AppLocalization.text("Mouse Controls")) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(AppLocalization.text("Desktop mouse mode"), isOn: $settings.features.desktopMouse)
                Text(
                    AppLocalization.text(
                        "Uses the native pointer without locking it. Switch modes during a stream with ⌃⌥⇧M.")
                ).font(.caption).foregroundStyle(.secondary)
                Toggle(
                    AppLocalization.text("Swap left and right mouse buttons"),
                    isOn: $settings.features.swapMouseButtons)
                Toggle(
                    AppLocalization.text("Reverse scrolling direction"),
                    isOn: $settings.features.reverseScroll)

                if !settings.features.desktopMouse {
                    Toggle(
                        AppLocalization.text("Capture mouse pointer automatically"),
                        isOn: $settings.mouseCaptureMode)
                    Divider()
                    HStack {
                        Text(AppLocalization.text("Mouse Sensitivity:"))
                        Slider(value: $settings.mouseSensitivity, in: 0.25...3.0, step: 0.05)
                        Text(String(format: "%.2fx", settings.mouseSensitivity))
                            .monospacedDigit()
                            .frame(width: 45, alignment: .trailing)
                    }
                    Text(AppLocalization.text("Scales hardware mouse movement sent to the host PC."))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    DisclosureGroup(AppLocalization.text("Advanced mouse scaling")) {
                        HStack {
                            Text(AppLocalization.text("Horizontal scaling:"))
                            Slider(value: $settings.mouseSensitivityX, in: 0.25...3.0, step: 0.05)
                            Text(String(format: "%.2fx", settings.mouseSensitivityX))
                                .monospacedDigit()
                                .frame(width: 45, alignment: .trailing)
                        }
                        HStack {
                            Text(AppLocalization.text("Vertical scaling:"))
                            Slider(value: $settings.mouseSensitivityY, in: 0.25...3.0, step: 0.05)
                            Text(String(format: "%.2fx", settings.mouseSensitivityY))
                                .monospacedDigit()
                                .frame(width: 45, alignment: .trailing)
                        }
                        Text(
                            AppLocalization.text(
                                "Per-axis multipliers, applied on top of the global sensitivity.")
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Toggle(
                            AppLocalization.text("Preserve fractional sensitivity"),
                            isOn: $settings.mouseSubPixelAccumulation)
                        Text(
                            AppLocalization.text("Keeps slow mouse movement smooth when sensitivity is reduced.")
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(8)
        }

        GroupBox(AppLocalization.text("Keyboard Shortcuts & Layout")) {
            VStack(alignment: .leading, spacing: 14) {
                Text(
                    AppLocalization.text(
                        "Keys follow their physical positions. The PC applies its active keyboard layout; paste text to preserve exact characters."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Divider()

                Picker(
                    AppLocalization.text("Capture system keyboard shortcuts:"),
                    selection: $settings.captureSystemKeys
                ) {
                    ForEach(SystemKeyCaptureMode.allCases, id: \.self) { mode in
                        Text(AppLocalization.text(mode.rawValue)).tag(mode)
                    }
                }
                Text(
                    AppLocalization.text(
                        "Sends ⌘Tab, Spotlight, Mission Control and macOS shortcuts directly to the host PC while streaming. Press ⌃⌥⇧Z to release cursor and shortcuts."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Divider()

                Toggle(
                    AppLocalization.text("Match physical Windows PC keyboard layout (Control, Windows, Alt)"),
                    isOn: $settings.swapWinAltKeys)
                Text(
                    AppLocalization.text(
                        "Maps Control → Ctrl, Option → Windows, Command → Alt so the physical keys match a standard PC keyboard."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(8)
        }

        GroupBox(AppLocalization.text("In-Stream Keyboard Shortcuts")) {
            VStack(alignment: .leading, spacing: 8) {
                shortcutRow(keys: "⌃ ⌥ ⇧ Q", label: "Disconnect / Quit stream")
                shortcutRow(keys: "⌃ ⌥ ⇧ Z", label: "Release / recapture mouse cursor")
                shortcutRow(keys: "⌃ ⌥ ⇧ X", label: "Toggle Fullscreen / Windowed")
                shortcutRow(keys: "⌃ ⌥ ⇧ S", label: "Toggle Performance HUD overlay")
                shortcutRow(keys: "⌃ ⌥ ⇧ C", label: "Open session controls")
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
        GroupBox(AppLocalization.text("Host & Application Behavior")) {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(
                    AppLocalization.text("Quit game on host when ending stream"),
                    isOn: $settings.quitAppOnStop)
                Text(AppLocalization.text("Terminates the running game on the host when you disconnect."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Toggle(
                    AppLocalization.text("Synchronize clipboard with host"),
                    isOn: $settings.enableClipboardSync)
                Text(
                    AppLocalization.text("Synchronizes copied text with hosts that support clipboard sync.")
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Divider()

                Toggle(AppLocalization.text("Hide unpaired PCs"), isOn: $settings.hideUnpairedHosts)
                Text(
                    AppLocalization.text(
                        "Hides discovered PCs that have not been paired yet, while keeping paired offline PCs visible."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                DisclosureGroup(AppLocalization.text("Legacy GameStream options")) {
                    Toggle(
                        AppLocalization.text("Optimize game settings for streaming"),
                        isOn: $settings.optimizeGameSettings
                    )
                    .padding(.top, 8)
                    Text(
                        AppLocalization.text(
                            "Applies to NVIDIA GameStream hosts; Sunshine and Apollo manage game settings separately."
                        )
                    ).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(8)
        }
    }

}

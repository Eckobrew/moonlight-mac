import SwiftUI

public struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding public var settings: StreamSettings
    public let onSave: () -> Void

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
        VStack(spacing: 0) {
            HStack {
                Text("Streaming Preferences")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button("Done") {
                    onSave()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(Divider(), alignment: .bottom)

            Form {
                Section("Video Settings") {
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

                    Toggle("Custom Bitrate for Remote Sessions", isOn: $settings.enableRemoteBitrate)
                    Text("Uses the standard video bitrate above on your local network, and switches to this custom bitrate when connecting remotely over the Internet or Tailscale.")
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

                    Toggle("Enable V-Sync", isOn: $settings.enableVsync)
                    Text("Synchronizes frame presentation with the display refresh rate to eliminate tearing. Turn off to minimize input latency.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !settings.enableVsync && settings.videoRenderer == .native {
                        Label("Disabling V-Sync requires the Metal renderer for unlocked display presentation.", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    Toggle("Enable Frame Pacing", isOn: $settings.enableFramePacing)
                    Text("Paces frames to display refresh cycles to eliminate micro-stutter and judder. Turn off for lowest latency.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Enable HDR (10-bit color)", isOn: $settings.enableHdr)
                    Toggle("Full Dynamic Range Color", isOn: $settings.fullRangeColor)
                }

                Section("Audio Settings") {
                    Picker("Configuration:", selection: $settings.audioMode) {
                        ForEach(AudioConfigurationMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }

                    Toggle("Mute host PC speakers while streaming", isOn: $settings.muteHostAudio)
                    Text("Mutes sound on the host computer while streaming to this Mac. Turn off to play audio on both the host and Mac simultaneously.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Host & Streaming Behavior") {
                    Toggle("Optimize game settings for streaming", isOn: $settings.optimizeGameSettings)
                    Text("Allows the host PC to automatically adjust in-game graphical settings for optimal streaming performance.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Quit game on host when ending stream", isOn: $settings.quitAppOnStop)
                    Text("Terminates the active application on the host PC when you disconnect. Turn off to keep games running in the background.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Synchronize clipboard with host", isOn: $settings.enableClipboardSync)
                    Text("Automatically synchronizes copied text between your Mac and Apollo/Vibepollo/Sunshine hosts over secure HTTPS.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Hide unpaired PCs", isOn: $settings.hideUnpairedHosts)
                    Text("Hides discovered PCs that have not been paired yet, while still displaying paired offline PCs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Input & Mouse Controls") {
                    Toggle("Capture mouse pointer automatically", isOn: $settings.mouseCaptureMode)

                    HStack {
                        Text("Mouse Sensitivity:")
                        Slider(value: $settings.mouseSensitivity, in: 0.25...3.0, step: 0.05)
                        Text(String(format: "%.2fx", settings.mouseSensitivity))
                            .monospacedDigit()
                            .frame(width: 45, alignment: .trailing)
                    }
                    Text("Adjusts raw hardware mouse movement speed sent to the host PC.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("Capture system keyboard shortcuts", selection: $settings.captureSystemKeys) {
                        ForEach(SystemKeyCaptureMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    Text("Sends ⌘Tab, Spotlight, Mission Control and other macOS shortcuts to the host while the stream has the cursor captured. Press ⌃⌥⇧Z to release.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Match physical Windows PC keyboard layout (Control, Windows, Alt)", isOn: $settings.swapWinAltKeys)
                    Text("Maps Control → Ctrl, Option → Windows, Command → Alt so the physical keys match a standard PC keyboard.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Swap Command and Control keys (macOS shortcut style)", isOn: $settings.swapCommandControl)
                    Text("Maps Command → Ctrl and Control → Windows for Mac muscle memory (e.g. ⌘C for Ctrl+C).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Shortcuts: ⌃⌥⇧Q: quit | ⌃⌥⇧Z: release cursor | ⌃⌥⇧X: toggle fullscreen | ⌃⌥⇧S: toggle stats")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, 16)
        }
        .frame(width: 500, height: 640)
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

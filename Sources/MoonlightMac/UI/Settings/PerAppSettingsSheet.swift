import SwiftUI

/// Per-game override editor. Every row has an "Inherit" state so only intentional changes are
/// stored, which keeps the global settings authoritative.
struct PerAppSettingsSheet: View {
    let host: Host
    let app: StreamApp
    let globalSettings: StreamSettings

    @Environment(\.dismiss) private var dismiss
    @State private var overrides: AppStreamOverrides

    init(host: Host, app: StreamApp, globalSettings: StreamSettings) {
        self.host = host
        self.app = app
        self.globalSettings = globalSettings
        _overrides = State(initialValue: PerAppSettingsStore.shared.overrides(for: host, app: app))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Settings for “\(app.title)”")
                        .font(.title3)
                        .fontWeight(.bold)
                    Text("Overrides apply only to this game on \(host.name).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    overrideGroup("Display") {
                        optionalResolutionRow
                        optionalFPSRow
                        optionalWindowModeRow
                        if let message = globalSettings.applying(overrides).validationMessage {
                            Text(message).font(.caption).foregroundStyle(.red)
                        }
                    }

                    overrideGroup("Quality") {
                        optionalBitrateRow
                        optionalCodecRow
                    }

                    overrideGroup("Rendering") {
                        optionalToggle(
                            "Enable HDR", value: $overrides.enableHdr, inherited: globalSettings.enableHdr)
                        if globalSettings.videoRenderer == .metal {
                            optionalToggle(
                                "Enable V-Sync", value: $overrides.enableVsync,
                                inherited: globalSettings.enableVsync)
                        }
                        optionalToggle(
                            "Enable Frame Pacing", value: $overrides.enableFramePacing,
                            inherited: globalSettings.enableFramePacing)
                    }

                    overrideGroup("Audio & Input") {
                        optionalAudioModeRow
                        if !globalSettings.features.desktopMouse {
                            optionalToggle(
                                "Capture mouse pointer", value: $overrides.mouseCaptureMode,
                                inherited: globalSettings.mouseCaptureMode)
                        }
                    }

                    overrideGroup("Host") {
                        if host.capabilities?.virtualDisplayCapable == true {
                            Picker("Display", selection: $overrides.virtualDisplayMode) {
                                Text("Inherit host preference").tag(Optional<VirtualDisplayMode>.none)
                                ForEach(VirtualDisplayMode.allCases, id: \.self) { mode in Text(mode.rawValue).tag(Optional(mode)) }
                            }
                            if !app.isHostAction {
                                Toggle("This application is a Remote Monitor profile", isOn: Binding(
                                    get: { overrides.remoteMonitorProfile == true },
                                    set: { overrides.remoteMonitorProfile = $0 ? true : nil }))
                                Text("Use for a custom monitor profile configured on the host. Disconnecting will preserve the host's game session.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if !host.supportsExtendedControllers {
                            optionalToggle(
                                "Optimize game settings", value: $overrides.optimizeGameSettings,
                                inherited: globalSettings.optimizeGameSettings)
                        }
                        optionalToggle(
                            "Quit game on disconnect", value: $overrides.quitAppOnStop,
                            inherited: globalSettings.quitAppOnStop)
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Button(AppLocalization.text("Reset to Global")) {
                    overrides = AppStreamOverrides()
                }
                .disabled(overrides.isEmpty)

                Spacer()

                Button(AppLocalization.text("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button(AppLocalization.text("Save")) {
                    PerAppSettingsStore.shared.setOverrides(overrides, for: host, app: app)
                    dismiss()
                }
                .disabled(globalSettings.applying(overrides).validationMessage != nil)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 560, height: 620)
    }

    // MARK: - Rows

    private var optionalResolutionRow: some View {
        overrideRow(
            "Resolution",
            isOverridden: Binding(
                get: { overrides.width != nil },
                set: { enabled in
                    if enabled {
                        overrides.width = globalSettings.width
                        overrides.height = globalSettings.height
                    } else {
                        overrides.width = nil
                        overrides.height = nil
                    }
                }
            ), inheritedText: inheritanceLabelForResolution
        ) {
            ResolutionPicker(
                width: Binding(
                    get: { overrides.width ?? globalSettings.width }, set: { overrides.width = $0 }),
                height: Binding(
                    get: { overrides.height ?? globalSettings.height }, set: { overrides.height = $0 }),
                title: ""
            )
            .frame(maxWidth: .infinity)

        }
    }

    private var optionalFPSRow: some View {
        overrideRow(
            "Frame Rate",
            isOverridden: Binding(
                get: { overrides.fps != nil },
                set: { enabled in overrides.fps = enabled ? globalSettings.fps : nil }
            ), inheritedText: "\(globalSettings.fps) FPS"
        ) {
            FrameRatePicker(
                value: Binding(get: { overrides.fps ?? globalSettings.fps }, set: { overrides.fps = $0 }),
                title: ""
            )
            .frame(maxWidth: .infinity)

        }
    }

    private var optionalWindowModeRow: some View {
        overrideRow(
            "Display Mode",
            isOverridden: Binding(
                get: { overrides.windowMode != nil },
                set: { enabled in overrides.windowMode = enabled ? globalSettings.windowMode : nil }
            ), inheritedText: globalSettings.windowMode.rawValue
        ) {
            Picker(
                AppLocalization.text(""),
                selection: Binding(
                    get: { overrides.windowMode ?? globalSettings.windowMode },
                    set: { overrides.windowMode = $0 }
                )
            ) {
                ForEach(WindowMode.allCases, id: \.self) { mode in
                    Text(AppLocalization.text(mode.rawValue)).tag(mode)
                }
            }
            .labelsHidden()
            .frame(width: 200)
        }
    }

    private var optionalBitrateRow: some View {
        overrideRow(
            "Bitrate",
            isOverridden: Binding(
                get: { overrides.bitrateMbps != nil },
                set: { enabled in overrides.bitrateMbps = enabled ? globalSettings.bitrateMbps : nil }
            ), inheritedText: "\(globalSettings.bitrateMbps) Mbps"
        ) {
            HStack(spacing: 6) {
                Slider(
                    value: Binding(
                        get: { Double(overrides.bitrateMbps ?? globalSettings.bitrateMbps) },
                        set: { overrides.bitrateMbps = Int($0) }
                    ), in: 5...150, step: 1
                )
                .frame(width: 120)
                Text("\(overrides.bitrateMbps ?? globalSettings.bitrateMbps) Mbps")
                    .monospacedDigit()
                    .font(.caption)
                    .frame(width: 70, alignment: .trailing)
            }
        }
    }

    private var optionalCodecRow: some View {
        overrideRow(
            "Codec",
            isOverridden: Binding(
                get: { overrides.codec != nil },
                set: { enabled in overrides.codec = enabled ? globalSettings.codec : nil }
            ), inheritedText: globalSettings.codec.rawValue
        ) {
            Picker(
                AppLocalization.text(""),
                selection: Binding(
                    get: { overrides.codec ?? globalSettings.codec },
                    set: { overrides.codec = $0 }
                )
            ) {
                ForEach(VideoCodec.allCases, id: \.self) { codec in
                    if codec != .av1 || VideoCodec.isAV1DecodingSupported {
                        Text(AppLocalization.text(codec.rawValue)).tag(codec)
                    }
                }
            }
            .labelsHidden()
            .frame(width: 160)
        }
    }

    private var optionalAudioModeRow: some View {
        overrideRow(
            "Audio Layout",
            isOverridden: Binding(
                get: { overrides.audioMode != nil },
                set: { enabled in overrides.audioMode = enabled ? globalSettings.audioMode : nil }
            ), inheritedText: globalSettings.audioMode.rawValue
        ) {
            Picker(
                AppLocalization.text(""),
                selection: Binding(
                    get: { overrides.audioMode ?? globalSettings.audioMode },
                    set: { overrides.audioMode = $0 }
                )
            ) {
                ForEach(AudioConfigurationMode.allCases, id: \.self) { mode in
                    Text(AppLocalization.text(mode.rawValue)).tag(mode)
                }
            }
            .labelsHidden()
            .frame(width: 160)
        }
    }

    // MARK: - Building blocks

    @ViewBuilder
    private func overrideGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
        -> some View
    {
        GroupBox(AppLocalization.text(title)) {
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func optionalToggle(_ title: String, value: Binding<Bool?>, inherited: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(
                AppLocalization.text(title),
                isOn: Binding(
                    get: { value.wrappedValue ?? inherited },
                    set: { value.wrappedValue = $0 }
                ))
            HStack(spacing: 6) {
                if value.wrappedValue == nil {
                    Text("Using global: \(inherited ? "On" : "Off")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if value.wrappedValue != nil {
                    Button(AppLocalization.text("Inherit")) { value.wrappedValue = nil }
                        .buttonStyle(.link)
                        .font(.caption2)
                }
            }
        }
    }

    private func overrideRow<Content: View>(
        _ title: String,
        isOverridden: Binding<Bool>,
        inheritedText: String,
        @ViewBuilder control: () -> Content
    ) -> some View {
        HStack {
            Toggle(isOn: isOverridden) {
                Text(AppLocalization.text(title))
            }
            .toggleStyle(.checkbox)
            .frame(width: 150, alignment: .leading)

            if isOverridden.wrappedValue {
                control()
                Spacer()
            } else {
                Text(inheritedText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var inheritanceLabelForResolution: String {
        globalSettings.width == 0 || globalSettings.height == 0
            ? "Native"
            : "\(globalSettings.width)x\(globalSettings.height)"
    }
}

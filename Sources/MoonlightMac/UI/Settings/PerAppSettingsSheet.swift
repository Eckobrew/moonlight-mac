import SwiftUI

/// Per-game override editor. Every row has an "Inherit" state so only intentional changes are
/// stored, which keeps the global settings authoritative.
struct PerAppSettingsSheet: View {
    let host: Host
    let app: StreamApp
    let globalSettings: StreamSettings

    @Environment(\.dismiss) private var dismiss
    @State private var overrides: AppStreamOverrides

    private let resolutions: [(name: String, width: Int, height: Int)] = [
        ("720p", 1280, 720),
        ("1080p", 1920, 1080),
        ("1440p", 2560, 1440),
        ("4K", 3840, 2160)
    ]
    private let framerates = [30, 60, 90, 120, 144, 240]

    init(host: Host, app: StreamApp, globalSettings: StreamSettings) {
        self.host = host
        self.app = app
        self.globalSettings = globalSettings
        _overrides = State(initialValue: PerAppSettingsStore.shared.overrides(for: host, appId: app.id))
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
                    }

                    overrideGroup("Quality") {
                        optionalBitrateRow
                        optionalCodecRow
                    }

                    overrideGroup("Rendering") {
                        optionalToggle("Enable HDR", value: $overrides.enableHdr, inherited: globalSettings.enableHdr)
                        optionalToggle("Enable V-Sync", value: $overrides.enableVsync, inherited: globalSettings.enableVsync)
                        optionalToggle("Enable Frame Pacing", value: $overrides.enableFramePacing, inherited: globalSettings.enableFramePacing)
                    }

                    overrideGroup("Audio & Input") {
                        optionalAudioModeRow
                        optionalToggle("Capture mouse pointer", value: $overrides.mouseCaptureMode, inherited: globalSettings.mouseCaptureMode)
                    }

                    overrideGroup("Host") {
                        optionalToggle("Optimize game settings", value: $overrides.optimizeGameSettings, inherited: globalSettings.optimizeGameSettings)
                        optionalToggle("Quit game on disconnect", value: $overrides.quitAppOnStop, inherited: globalSettings.quitAppOnStop)
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Button("Reset to Global") {
                    overrides = AppStreamOverrides()
                }
                .disabled(overrides.isEmpty)

                Spacer()

                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("Save") {
                    PerAppSettingsStore.shared.setOverrides(overrides, for: host, appId: app.id)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 560, height: 620)
    }

    // MARK: - Rows

    private var optionalResolutionRow: some View {
        overrideRow("Resolution", isOverridden: Binding(
            get: { overrides.width != nil },
            set: { enabled in
                if enabled {
                    overrides.width = globalSettings.width == 0 ? 1920 : globalSettings.width
                    overrides.height = globalSettings.height == 0 ? 1080 : globalSettings.height
                } else {
                    overrides.width = nil
                    overrides.height = nil
                }
            }
        ), inheritedText: inheritanceLabelForResolution) {
            Picker("", selection: Binding(
                get: { "\(overrides.width ?? 0)x\(overrides.height ?? 0)" },
                set: { value in
                    let parts = value.split(separator: "x").compactMap { Int($0) }
                    guard parts.count == 2 else { return }
                    overrides.width = parts[0]
                    overrides.height = parts[1]
                }
            )) {
                ForEach(resolutions, id: \.name) { res in
                    Text(res.name).tag("\(res.width)x\(res.height)")
                }
            }
            .labelsHidden()
            .frame(width: 160)
        }
    }

    private var optionalFPSRow: some View {
        overrideRow("Frame Rate", isOverridden: Binding(
            get: { overrides.fps != nil },
            set: { enabled in overrides.fps = enabled ? globalSettings.fps : nil }
        ), inheritedText: "\(globalSettings.fps) FPS") {
            Picker("", selection: Binding(
                get: { overrides.fps ?? globalSettings.fps },
                set: { overrides.fps = $0 }
            )) {
                ForEach(framerates, id: \.self) { fps in
                    Text("\(fps) FPS").tag(fps)
                }
            }
            .labelsHidden()
            .frame(width: 140)
        }
    }

    private var optionalWindowModeRow: some View {
        overrideRow("Display Mode", isOverridden: Binding(
            get: { overrides.windowMode != nil },
            set: { enabled in overrides.windowMode = enabled ? globalSettings.windowMode : nil }
        ), inheritedText: globalSettings.windowMode.rawValue) {
            Picker("", selection: Binding(
                get: { overrides.windowMode ?? globalSettings.windowMode },
                set: { overrides.windowMode = $0 }
            )) {
                ForEach(WindowMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .labelsHidden()
            .frame(width: 200)
        }
    }

    private var optionalBitrateRow: some View {
        overrideRow("Bitrate", isOverridden: Binding(
            get: { overrides.bitrateMbps != nil },
            set: { enabled in overrides.bitrateMbps = enabled ? globalSettings.bitrateMbps : nil }
        ), inheritedText: "\(globalSettings.bitrateMbps) Mbps") {
            HStack(spacing: 6) {
                Slider(value: Binding(
                    get: { Double(overrides.bitrateMbps ?? globalSettings.bitrateMbps) },
                    set: { overrides.bitrateMbps = Int($0) }
                ), in: 5...150, step: 1)
                .frame(width: 120)
                Text("\(overrides.bitrateMbps ?? globalSettings.bitrateMbps) Mbps")
                    .monospacedDigit()
                    .font(.caption)
                    .frame(width: 70, alignment: .trailing)
            }
        }
    }

    private var optionalCodecRow: some View {
        overrideRow("Codec", isOverridden: Binding(
            get: { overrides.codec != nil },
            set: { enabled in overrides.codec = enabled ? globalSettings.codec : nil }
        ), inheritedText: globalSettings.codec.rawValue) {
            Picker("", selection: Binding(
                get: { overrides.codec ?? globalSettings.codec },
                set: { overrides.codec = $0 }
            )) {
                ForEach(VideoCodec.allCases, id: \.self) { codec in
                    if codec != .av1 || VideoCodec.isAV1DecodingSupported {
                        Text(codec.rawValue).tag(codec)
                    }
                }
            }
            .labelsHidden()
            .frame(width: 160)
        }
    }

    private var optionalAudioModeRow: some View {
        overrideRow("Audio Layout", isOverridden: Binding(
            get: { overrides.audioMode != nil },
            set: { enabled in overrides.audioMode = enabled ? globalSettings.audioMode : nil }
        ), inheritedText: globalSettings.audioMode.rawValue) {
            Picker("", selection: Binding(
                get: { overrides.audioMode ?? globalSettings.audioMode },
                set: { overrides.audioMode = $0 }
            )) {
                ForEach(AudioConfigurationMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .labelsHidden()
            .frame(width: 160)
        }
    }

    // MARK: - Building blocks

    @ViewBuilder
    private func overrideGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func optionalToggle(_ title: String, value: Binding<Bool?>, inherited: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(title, isOn: Binding(
                get: { value.wrappedValue ?? inherited },
                set: { value.wrappedValue = $0 }
            ))
            HStack(spacing: 6) {
                Text("Using global: \(inherited ? "On" : "Off")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if value.wrappedValue != nil {
                    Button("Inherit") { value.wrappedValue = nil }
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
                Text(title)
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

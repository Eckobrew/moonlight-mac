import SwiftUI

struct ControllerSettings: View {
    @Binding var features: ClientFeatures
    var body: some View {
        GroupBox(AppLocalization.text("Game Controllers")) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(AppLocalization.text("Swap A/B and X/Y buttons"), isOn: $features.swapFaceButtons)
                Toggle(AppLocalization.text("Controller mouse control"), isOn: $features.gamepadMouse)
                if features.gamepadMouse {
                    Text(
                        AppLocalization.text(
                            "Hold Start for ¾ second to switch. Left stick moves, A/B click, right stick scrolls."
                        )
                    ).font(.caption).foregroundStyle(.secondary)
                }
                Toggle(
                    AppLocalization.text("Allow controller input in the background"),
                    isOn: $features.backgroundGamepad)
                Toggle(
                    AppLocalization.text("Keep one virtual controller connected"),
                    isOn: $features.persistentGamepad)
                if features.persistentGamepad {
                    Text(
                        AppLocalization.text(
                            "Merges attached controllers into player one and announces a controller before the game starts."
                        )
                    ).font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Text(
                    AppLocalization.text(
                        "Connect controllers before or during streaming. Rumble, motion, touch and lighting depend on the controller and host."
                    )
                ).font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }
    }
}

struct VideoCompatibilitySettings: View {
    @Binding var features: ClientFeatures
    var codec: VideoCodec
    var body: some View {
        DisclosureGroup(AppLocalization.text("Advanced video options")) {
            VStack(alignment: .leading, spacing: 12) {
                Picker(AppLocalization.text("Video decoder"), selection: $features.decoder) {
                    ForEach(DecoderPreference.allCases, id: \.self) {
                        Text(AppLocalization.text($0.rawValue)).tag($0)
                    }
                }
                Toggle(AppLocalization.text("Use 4:4:4 chroma for H.264 / HEVC"), isOn: $features.yuv444)
                    .disabled(codec == .av1)
                if features.yuv444 || codec == .av1 {
                    Text(
                        AppLocalization.text(
                            "Sharper desktop text. Requires a compatible host and decoder. AV1 uses 4:2:0.")
                    ).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.top, 8)
        }
    }
}

struct ApplicationSettings: View {
    @Binding var features: ClientFeatures
    var body: some View {
        GroupBox(AppLocalization.text("Application")) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(
                    AppLocalization.text("Discover hosts automatically with Bonjour"),
                    isOn: $features.enableMdns)
                Picker(AppLocalization.text("Language"), selection: $features.language) {
                    Text(AppLocalization.text("System Default")).tag("system")
                    Text("English").tag("en")
                    Text("Deutsch").tag("de")
                    Text("Français").tag("fr")
                    Text("Español").tag("es")
                }
                Text(AppLocalization.text("Language changes apply when the application is reopened.")).font(
                    .caption
                ).foregroundStyle(.secondary)
            }.padding(8)
        }
        GroupBox("Discord") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(
                    AppLocalization.text("Share the streamed game in Discord"),
                    isOn: $features.discordPresence)
                if features.discordPresence {
                    Text(AppLocalization.text("Shows the streamed game and host in the Discord desktop app."))
                        .font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup(AppLocalization.text("Advanced Discord options")) {
                        TextField(
                            AppLocalization.text("Discord application ID"), text: $features.discordApplicationID
                        )
                        .padding(.top, 8)
                    }
                }
            }.padding(8)
        }
    }
}

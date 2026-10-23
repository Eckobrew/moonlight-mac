import SwiftUI

/// Presets and custom values share one control in both global and per-game settings.
struct FrameRatePicker: View {
    static let presets = [30, 60, 90, 120, 144, 240]
    @Binding var value: Int
    var title: String
    @State private var custom: Bool

    init(value: Binding<Int>, title: String = "Frame Rate:") {
        _value = value
        self.title = title
        _custom = State(initialValue: !Self.presets.contains(value.wrappedValue))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(
                AppLocalization.text(title),
                selection: Binding(
                    get: { custom ? 0 : value },
                    set: { selection in
                        custom = selection == 0
                        if selection != 0 { value = selection }
                    }
                )
            ) {
                ForEach(Self.presets, id: \.self) { Text("\($0) FPS").tag($0) }
                Text(AppLocalization.text("Custom…")).tag(0)
            }
            if custom {
                HStack {
                    Text(AppLocalization.text("Custom FPS:"))
                    TextField(
                        AppLocalization.text("Custom FPS:"), value: $value, format: .number.grouping(.never)
                    )
                    .labelsHidden()
                    .frame(width: 80)
                    Text(AppLocalization.text("FPS")).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct ResolutionPicker: View {
    private static let presets = [
        (1280, 720, "720p"), (1920, 1080, "1080p"), (2560, 1440, "1440p"), (3840, 2160, "4K"),
    ]
    @Binding var width: Int
    @Binding var height: Int
    var title: String
    var nativeLabel: String
    @State private var custom: Bool

    init(
        width: Binding<Int>, height: Binding<Int>, title: String = "Resolution:",
        nativeLabel: String = "Native"
    ) {
        _width = width
        _height = height
        self.title = title
        self.nativeLabel = nativeLabel
        let w = width.wrappedValue
        let h = height.wrappedValue
        _custom = State(
            initialValue: !(w == 0 && h == 0) && !Self.presets.contains { $0.0 == w && $0.1 == h })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(
                AppLocalization.text(title),
                selection: Binding(
                    get: { custom ? "Custom" : "\(width)x\(height)" },
                    set: { selection in
                        custom = selection == "Custom"
                        if custom {
                            if width == 0 || height == 0 {
                                width = 1920
                                height = 1080
                            }
                        } else {
                            let dimensions = selection.split(separator: "x").compactMap { Int($0) }
                            guard dimensions.count == 2 else { return }
                            width = dimensions[0]
                            height = dimensions[1]
                        }
                    }
                )
            ) {
                Text(AppLocalization.text(nativeLabel)).tag("0x0")
                ForEach(Self.presets, id: \.0) { preset in
                    Text("\(preset.2) (\(preset.0)×\(preset.1))").tag("\(preset.0)x\(preset.1)")
                }
                Text(AppLocalization.text("Custom…")).tag("Custom")
            }
            if custom {
                HStack {
                    Text(AppLocalization.text("Custom resolution:"))
                    TextField(AppLocalization.text("Width"), value: $width, format: .number.grouping(.never))
                        .frame(width: 80)
                    Text("×")
                    TextField(
                        AppLocalization.text("Height"), value: $height, format: .number.grouping(.never)
                    ).frame(width: 80)
                }
            }
        }
    }
}

import Foundation

/// How the host should interpret keyboard events.
///
/// Mac virtual key codes are *positions*, and Windows virtual-key codes are *characters*. Sending
/// VK codes directly means the host types US characters regardless of the host's actual layout, so
/// a UK/German/AZERTY host produces the wrong punctuation.
///
/// moonlight-qt solves this by encoding the physical key as a scancode (`keyCode |= 0x8000`) and —
/// for layouts the host must not re-map — passing `SS_KBE_FLAG_NON_NORMALIZED` so GFE/Sunshine
/// resolves the character using the host's own active layout. This type exposes that as a user
/// choice.
public enum KeyboardLayout: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Send Windows virtual-key codes for a US layout (legacy behavior).
    case us = "US (virtual keys)"

    /// Send physical scancodes and let the host resolve them with its own layout.
    /// This is what moonlight-qt does and is correct for any non-US host layout.
    case matchHost = "Match host layout"

    public var id: String { rawValue }

    public var explanation: String {
        switch self {
        case .us:
            return "Sends US virtual keys. Punctuation is wrong if your PC uses a non-US layout."
        case .matchHost:
            return "Sends physical key positions so the PC applies its own layout (UK, German, AZERTY, ...)."
        }
    }

    /// Whether key codes should be tagged as scancodes instead of virtual keys.
    var sendsScancodes: Bool { self == .matchHost }
}

import Foundation

/// Legacy persisted preference. Both values now use GameStream's normalized
/// position-based VK mapping, matching moonlight-qt. The old blanket
/// NON_NORMALIZED flag prevented Sunshine from applying its host layout.
public enum KeyboardLayout: String, Codable, CaseIterable, Sendable, Identifiable {
    case us = "US (virtual keys)"
    case matchHost = "Match host layout"

    public var id: String { rawValue }

    public var explanation: String {
        "Keys follow their physical positions. The PC applies its active keyboard layout; paste text to preserve exact characters."
    }
}

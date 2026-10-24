import Foundation

public enum DecoderPreference: String, Codable, CaseIterable, Sendable {
    case automatic = "Automatic", hardware = "Hardware", software = "Software"
}

/// New preferences are grouped to keep old saved settings compatible.
public struct ClientFeatures: Codable, Equatable, Sendable {
    public var desktopMouse = false
    public var swapMouseButtons = false
    public var reverseScroll = false
    public var swapFaceButtons = false
    public var gamepadMouse = true
    public var backgroundGamepad = false
    public var persistentGamepad = false
    public var decoder: DecoderPreference = .automatic
    public var yuv444 = false
    public var enableMdns = true
    public var language = "system"
    public var discordPresence = false
    public var discordApplicationID = "1563323903949021204"
    public init() {}
    private enum CodingKeys: String, CodingKey { case desktopMouse, swapMouseButtons, reverseScroll, swapFaceButtons, gamepadMouse, backgroundGamepad, persistentGamepad, decoder, yuv444, enableMdns, language, discordPresence, discordApplicationID }
    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        desktopMouse = try values.decodeIfPresent(Bool.self, forKey: .desktopMouse) ?? desktopMouse
        swapMouseButtons = try values.decodeIfPresent(Bool.self, forKey: .swapMouseButtons) ?? swapMouseButtons
        reverseScroll = try values.decodeIfPresent(Bool.self, forKey: .reverseScroll) ?? reverseScroll
        swapFaceButtons = try values.decodeIfPresent(Bool.self, forKey: .swapFaceButtons) ?? swapFaceButtons
        gamepadMouse = try values.decodeIfPresent(Bool.self, forKey: .gamepadMouse) ?? gamepadMouse
        backgroundGamepad = try values.decodeIfPresent(Bool.self, forKey: .backgroundGamepad) ?? backgroundGamepad
        persistentGamepad = try values.decodeIfPresent(Bool.self, forKey: .persistentGamepad) ?? persistentGamepad
        self.decoder = try values.decodeIfPresent(DecoderPreference.self, forKey: .decoder) ?? self.decoder
        yuv444 = try values.decodeIfPresent(Bool.self, forKey: .yuv444) ?? yuv444
        enableMdns = try values.decodeIfPresent(Bool.self, forKey: .enableMdns) ?? enableMdns
        language = try values.decodeIfPresent(String.self, forKey: .language) ?? language
        discordPresence = try values.decodeIfPresent(Bool.self, forKey: .discordPresence) ?? discordPresence
        discordApplicationID = try values.decodeIfPresent(String.self, forKey: .discordApplicationID) ?? discordApplicationID
    }
}

public extension StreamSettings {
    /// Zero selects 25% of the normal bitrate. Calculate in Kbps to retain fractional Mbps.
    func streamBitrateKbps(isRemote: Bool) -> Int {
        let normal = bitrateMbps * 1000
        guard isRemote && enableRemoteBitrate else { return normal }
        return remoteBitrateMbps == 0 ? normal / 4 : remoteBitrateMbps * 1000
    }

    var validationMessage: String? {
        if !(width == 0 && height == 0) && (!(256...8192).contains(width) || !(256...8192).contains(height) || width % 2 != 0 || height % 2 != 0) {
            return "Resolution must use even dimensions between 256 and 8192, or Native."
        }
        if !(1...500).contains(fps) { return "Frame rate must be between 1 and 500 FPS." }
        if !(1...500).contains(bitrateMbps) || !(0...500).contains(remoteBitrateMbps) { return "Bitrate must be between 1 and 500 Mbps; remote bitrate can also be 0 (automatic)." }
        if !(256...1408).contains(packetSize) || packetSize % 16 != 0 { return "Packet size must be a multiple of 16 between 256 and 1408." }
        return nil
    }
}

import Foundation
import MoonlightCommonC

enum ConnectionDiagnostics {
    static func ports(_ flags: UInt32) -> String {
        guard flags != 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: 256)
        LiStringifyPortFlags(flags, ", ", &buffer, Int32(buffer.count))
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    static func stageFailure(stage: Int32, code: Int32) -> String {
        let name = LiGetStageName(stage).map { String(cString: $0) } ?? "Connection"
        let ports = ports(LiGetPortFlagsFromStage(stage))
        return "\(name) failed (\(code))." + (ports.isEmpty ? " Check that the host is reachable and paired." : " Check firewall or forwarding for \(ports).")
    }
    static func termination(_ code: Int32) -> String? {
        switch code {
        case 0: return nil
        case ML_ERROR_NO_VIDEO_TRAFFIC: return "No video arrived. Check the host firewall and UDP video port forwarding."
        case ML_ERROR_NO_VIDEO_FRAME: return "Video packets arrived but no complete frame could be received. Lower the bitrate or improve the network connection."
        case ML_ERROR_PROTECTED_CONTENT, ML_ERROR_UNEXPECTED_EARLY_TERMINATION: return "The host stopped capture. Close DRM-protected content and try again."
        case ML_ERROR_FRAME_CONVERSION: return "The host could not convert video. Check HDR and display resolution settings."
        default: return "Connection ended (\(code)). Check the host and network."
        }
    }
}

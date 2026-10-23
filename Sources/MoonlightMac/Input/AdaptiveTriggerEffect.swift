import Foundation
import GameController

/// Decode the public DualSense feedback/weapon/vibration wire modes into native
/// GameController effects. Unknown firmware modes are cleared rather than latched.
enum AdaptiveTriggerEffect: Equatable {
    case off
    case feedback([Float])
    case weapon(start: Float, end: Float, strength: Float)
    case vibration([Float], frequency: Float)

    static func decode(type: UInt8, bytes: [UInt8]) -> Self {
        guard bytes.count == 10 else { return .off }
        let zones = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
        var packed: UInt64 = 0
        for (index, byte) in bytes[2..<6].enumerated() { packed |= UInt64(byte) << (index * 8) }
        var strengths = [Float](repeating: 0, count: 10)
        for index in 0..<10 where zones & (UInt16(1) << index) != 0 {
            let encoded = (packed >> (index * 3)) & UInt64(7)
            strengths[index] = Float(encoded + 1) / 8
        }
        switch type {
        case 0x21: return .feedback(strengths)
        case 0x25:
            let positions = (0..<10).filter { zones & (1 << $0) != 0 }
            guard let first = positions.first, let last = positions.last, last > first else {
                return .off
            }
            return .weapon(
                start: Float(first) / 9, end: Float(last) / 9,
                strength: Float(min(8, Int(bytes[2]) + 1)) / 8)
        case 0x26: return .vibration(strengths, frequency: Float(bytes[8]) / 255)
        case 0x01:
            return .feedback((0..<10).map { $0 >= Int(bytes[0]) * 10 / 256 ? Float(bytes[1]) / 255 : 0 })
        case 0x05, 0x00: return .off
        default: return .off
        }
    }

    func apply(to trigger: GCDualSenseAdaptiveTrigger) {
        switch self {
        case .off: trigger.setModeOff()
        case .feedback(let values):
            var strengths = GCDualSenseAdaptiveTrigger.PositionalResistiveStrengths()
            _ = withUnsafeMutableBytes(of: &strengths.values) { raw in
                raw.bindMemory(to: Float.self).update(from: values)
            }
            trigger.setModeFeedback(resistiveStrengths: strengths)
        case .weapon(let start, let end, let strength):
            trigger.setModeWeaponWithStartPosition(start, endPosition: end, resistiveStrength: strength)
        case .vibration(let values, let frequency):
            var amplitudes = GCDualSenseAdaptiveTrigger.PositionalAmplitudes()
            _ = withUnsafeMutableBytes(of: &amplitudes.values) { raw in
                raw.bindMemory(to: Float.self).update(from: values)
            }
            trigger.setModeVibration(amplitudes: amplitudes, frequency: frequency)
        }
    }
}

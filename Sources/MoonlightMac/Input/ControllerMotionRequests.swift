import Foundation

/// Per-controller, per-sensor host requests. Access under the controller manager lock.
struct ControllerMotionRequests {
    private struct Request {
        var interval: TimeInterval
        var lastSent: TimeInterval = -.infinity
        var lastValue: SIMD3<Float>?
    }
    private var requests: [Int: [UInt8: Request]] = [:]

    mutating func update(slot: Int, category: UInt8, hz: UInt16) {
        guard (0..<16).contains(slot), category == 1 || category == 2 else { return }
        if hz == 0 { requests[slot]?[category] = nil }
        else { requests[slot, default: [:]][category] = Request(interval: 1 / Double(hz)) }
    }

    func isEnabled(slot: Int) -> Bool { requests[slot]?.isEmpty == false }

    mutating func reset() { requests.removeAll() }

    mutating func shouldSend(slot: Int, category: UInt8, now: TimeInterval, value: SIMD3<Float>) -> Bool {
        guard var request = requests[slot]?[category], now - request.lastSent >= request.interval,
              request.lastValue != value else { return false }
        request.lastSent = now
        request.lastValue = value
        requests[slot]?[category] = request
        return true
    }
}

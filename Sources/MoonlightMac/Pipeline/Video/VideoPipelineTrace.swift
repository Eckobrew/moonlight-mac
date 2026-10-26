import Foundation
import os.signpost

/// Opt-in Instruments intervals. Disabled runs emit no per-frame logs/events and
/// retain no frames. Wall-time spans include framework waits; use Time Profiler
/// alongside them to distinguish CPU work from blocked time.
enum VideoPipelineTrace {
    private static let enabled = ProcessInfo.processInfo.environment["MOONLIGHT_PIPELINE_PROFILE"] == "1"
    private static let log = OSLog(subsystem: "com.moonlight.mac", category: .pointsOfInterest)

    static func begin(_ name: StaticString) -> OSSignpostID? {
        guard enabled else { return nil }
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        return id
    }

    static func end(_ name: StaticString, _ id: OSSignpostID?) {
        guard let id else { return }
        os_signpost(.end, log: log, name: name, signpostID: id)
    }
}

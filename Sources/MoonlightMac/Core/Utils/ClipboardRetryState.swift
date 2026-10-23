import Foundation

struct ClipboardRetryState {
    private(set) var failures = 0
    private(set) var retryAt: TimeInterval = 0
    private(set) var unsupported = false

    func canAttempt(at now: TimeInterval) -> Bool { !unsupported && now >= retryAt }

    mutating func succeeded() { self = Self() }

    mutating func failed(_ error: any Error, at now: TimeInterval) {
        let error = error as NSError
        // Only an explicit endpoint/method-not-supported response is permanent.
        unsupported = error.domain == "SunshineHTTPClient" && [404, 405, 501].contains(error.code)
        failures = min(failures + 1, 6)
        retryAt = now + min(30, pow(2, Double(failures - 1)))
    }
}

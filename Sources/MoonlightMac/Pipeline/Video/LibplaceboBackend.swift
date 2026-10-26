import CPlaceboBridge
import CoreVideo
import Foundation
import QuartzCore

/// Methods are confined to the renderer's serial queue. Acquisition is separate
/// from rendering so the mailbox can be sampled after compositor/GPU waits.
protocol LibplaceboBackend: AnyObject {
    func create(layer: CAMetalLayer, vsync: Bool) throws
    func beginFrame(width: Int32, height: Int32) throws -> Bool
    func render(_ buffer: CVPixelBuffer, width: Int32, height: Int32) throws -> Bool
    func discardFrame()
    func destroy()
}

final class NativeLibplaceboBackend: LibplaceboBackend {
    private var context: OpaquePointer?
    private var reportedFallback = false
    private let diagnostics = ProcessInfo.processInfo.environment["MOONLIGHT_STREAM_DIAGNOSTICS"] == "1"

    private struct BridgeError: Error, CustomStringConvertible {
        let description: String
    }

    private func message(_ error: [CChar]) -> String {
        String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    func create(layer: CAMetalLayer, vsync: Bool) throws {
        var error = [CChar](repeating: 0, count: 512)
        context = MLPlaceboCreate(Unmanaged.passUnretained(layer).toOpaque(), vsync, &error, error.count)
        guard context != nil else { throw BridgeError(description: message(error)) }
        reportedFallback = false
    }

    func beginFrame(width: Int32, height: Int32) throws -> Bool {
        var error = [CChar](repeating: 0, count: 512)
        let status = MLPlaceboBeginFrame(context, width, height, &error, error.count)
        guard status >= 0 else { throw BridgeError(description: message(error)) }
        return status == 1
    }

    func render(_ buffer: CVPixelBuffer, width: Int32, height: Int32) throws -> Bool {
        var error = [CChar](repeating: 0, count: 512)
        let status = MLPlaceboRender(context, buffer, width, height, &error, error.count)
        guard status >= 0 else { throw BridgeError(description: message(error)) }
        let stats = MLPlaceboGetStats(context)
        if diagnostics && stats.presentedFrames > 0 && stats.presentedFrames % 300 == 0 {
            let frames = Double(stats.presentedFrames)
            let acquisitionFrames = Double(max(1, stats.earlyAcquireFrames))
            AppLogger.shared.info(String(format:
                "[Libplacebo] CPU wall time averages: acquire=%.3f ms render=%.3f ms submit=%.3f ms; imports=%llu uploads=%llu",
                stats.acquireTimeMs / acquisitionFrames, stats.renderTimeMs / frames, stats.submitTimeMs / frames,
                stats.importedFrames, stats.uploadedFrames))
        }
        if stats.presentedFrames == 1 {
            AppLogger.shared.info("[Libplacebo] Input path: \(stats.importedFrames > 0 ? "direct Metal texture import" : "CPU upload fallback")")
        }
        if stats.uploadedFrames > 0 && !reportedFallback {
            reportedFallback = true
            AppLogger.shared.warning("[Libplacebo] A frame required CPU upload fallback; direct imports=\(stats.importedFrames), uploads=\(stats.uploadedFrames)")
        }
        return status == 1
    }

    func discardFrame() { MLPlaceboDiscardFrame(context) }

    func destroy() {
        MLPlaceboDestroy(context)
        context = nil
    }
}

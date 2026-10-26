import Combine
import Foundation

@MainActor final class RuntimeServiceStatus: ObservableObject {
    static let shared = RuntimeServiceStatus()
    @Published var audio: String?
    @Published var discord: String?
    @Published var renderer: String?
    nonisolated static func reportAudio(_ message: String?) {
        Task { @MainActor in if shared.audio != message { shared.audio = message } }
    }
    nonisolated static func reportDiscord(_ message: String?) {
        Task { @MainActor in if shared.discord != message { shared.discord = message } }
    }
}

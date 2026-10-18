import Foundation

public struct StreamApp: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: Int
    public var title: String
    public var isAppCollectorGame: Bool
    public var boxArtUrl: URL?

    public init(id: Int, title: String, isAppCollectorGame: Bool = false, boxArtUrl: URL? = nil) {
        self.id = id
        self.title = title
        self.isAppCollectorGame = isAppCollectorGame
        self.boxArtUrl = boxArtUrl
    }
}

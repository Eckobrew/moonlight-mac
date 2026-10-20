import AppKit
import Foundation

public enum ArtworkCategory: String, CaseIterable, Identifiable {
    case all = "All"
    case covers = "Covers"
    case logos = "Logos & Icons"
    case banners = "Banners"

    public var id: String { rawValue }
}

public struct GameArtworkCandidate: Identifiable, Hashable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let category: ArtworkCategory
    public let sourceDescription: String
    public let previewUrl: URL?
    public let fullUrl: URL?
    public let staticImage: NSImage?

    public init(
        id: String,
        title: String,
        subtitle: String,
        category: ArtworkCategory,
        sourceDescription: String,
        previewUrl: URL? = nil,
        fullUrl: URL? = nil,
        staticImage: NSImage? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.category = category
        self.sourceDescription = sourceDescription
        self.previewUrl = previewUrl
        self.fullUrl = fullUrl
        self.staticImage = staticImage
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: GameArtworkCandidate, rhs: GameArtworkCandidate) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
public final class GameArtworkSearchService: ObservableObject {
    public static let shared = GameArtworkSearchService()

    @Published public private(set) var candidates: [GameArtworkCandidate] = []
    @Published public private(set) var isSearching = false
    @Published public private(set) var errorMessage: String?

    private let memoryCache = NSCache<NSURL, NSImage>()
    private var currentSearchTask: Task<Void, Never>?

    private init() {
        memoryCache.countLimit = 150
    }

    /// Searches Steam Store and (if configured) SteamGridDB for artwork matching the query.
    public func search(query: String, hostBoxArt: NSImage? = nil, hostAppName: String? = nil) {
        currentSearchTask?.cancel()

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            self.candidates = makeDefaultCandidates(hostBoxArt: hostBoxArt, appName: hostAppName ?? "Game")
            self.isSearching = false
            return
        }

        isSearching = true
        errorMessage = nil

        currentSearchTask = Task {
            var results: [GameArtworkCandidate] = []

            // 1. Always include host box art if present
            if let hostBoxArt = hostBoxArt {
                results.append(GameArtworkCandidate(
                    id: "host_box_art",
                    title: hostAppName ?? "Current Game",
                    subtitle: "Host Box Art (Sunshine / GFE)",
                    category: .covers,
                    sourceDescription: "Host",
                    staticImage: hostBoxArt
                ))
            }

            // 2. Fetch from Steam Store Search API
            let steamItems = await searchSteamStore(query: trimmedQuery)
            for item in steamItems {
                // Vertical Cover
                let coverFull = URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(item.id)/library_600x900_2x.jpg")!
                let coverThumb = URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(item.id)/library_600x900.jpg")!
                results.append(GameArtworkCandidate(
                    id: "steam_\(item.id)_cover",
                    title: item.name,
                    subtitle: "Steam Cover (600x900)",
                    category: .covers,
                    sourceDescription: "Steam",
                    previewUrl: coverThumb,
                    fullUrl: coverFull
                ))

                // Header / Banner
                let headerUrl = URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(item.id)/header.jpg")!
                results.append(GameArtworkCandidate(
                    id: "steam_\(item.id)_header",
                    title: item.name,
                    subtitle: "Steam Banner",
                    category: .banners,
                    sourceDescription: "Steam",
                    previewUrl: headerUrl,
                    fullUrl: headerUrl
                ))

                // Logo
                let logoUrl = URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(item.id)/logo.png")!
                results.append(GameArtworkCandidate(
                    id: "steam_\(item.id)_logo",
                    title: item.name,
                    subtitle: "Steam Logo (Transparent)",
                    category: .logos,
                    sourceDescription: "Steam",
                    previewUrl: logoUrl,
                    fullUrl: logoUrl
                ))

                // Hero Banner
                let heroUrl = URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(item.id)/library_hero.jpg")!
                results.append(GameArtworkCandidate(
                    id: "steam_\(item.id)_hero",
                    title: item.name,
                    subtitle: "Steam Hero Artwork",
                    category: .banners,
                    sourceDescription: "Steam",
                    previewUrl: heroUrl,
                    fullUrl: heroUrl
                ))
            }

            // 3. If SteamGridDB API key is provided, query SteamGridDB
            let sgdbKey = UserDefaults.standard.string(forKey: "steamgriddb_api_key")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !sgdbKey.isEmpty {
                let sgdbCandidates = await searchSteamGridDB(query: trimmedQuery, apiKey: sgdbKey)
                results.append(contentsOf: sgdbCandidates)
            }

            if Task.isCancelled { return }

            self.candidates = results
            self.isSearching = false
        }
    }

    private func makeDefaultCandidates(hostBoxArt: NSImage?, appName: String) -> [GameArtworkCandidate] {
        var list: [GameArtworkCandidate] = []
        if let hostBoxArt = hostBoxArt {
            list.append(GameArtworkCandidate(
                id: "host_box_art",
                title: appName,
                subtitle: "Host Box Art (Sunshine / GFE)",
                category: .covers,
                sourceDescription: "Host",
                staticImage: hostBoxArt
            ))
        }
        return list
    }

    // MARK: - Steam Store Search API
    private struct SteamStoreResponse: Decodable {
        let total: Int
        let items: [SteamStoreItem]?
    }

    private struct SteamStoreItem: Decodable {
        let id: Int
        let name: String
    }

    private func searchSteamStore(query: String) async -> [SteamStoreItem] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://store.steampowered.com/api/storesearch/?term=\(encoded)&l=english&cc=US") else {
            return []
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return []
            }
            let decoded = try JSONDecoder().decode(SteamStoreResponse.self, from: data)
            return Array((decoded.items ?? []).prefix(6))
        } catch {
            return []
        }
    }

    // MARK: - SteamGridDB API (Optional)
    private struct SGDBAutocompleteResponse: Decodable {
        let success: Bool
        let data: [SGDBGameItem]?
    }

    private struct SGDBGameItem: Decodable {
        let id: Int
        let name: String
    }

    private struct SGDBMediaResponse: Decodable {
        let success: Bool
        let data: [SGDBMediaItem]?
    }

    private struct SGDBMediaItem: Decodable {
        let id: Int
        let url: String
        let thumb: String?
    }

    private func searchSteamGridDB(query: String, apiKey: String) async -> [GameArtworkCandidate] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchUrl = URL(string: "https://www.steamgriddb.com/api/v2/search/autocomplete/\(encoded)") else {
            return []
        }

        var searchReq = URLRequest(url: searchUrl)
        searchReq.timeoutInterval = 10
        searchReq.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var foundCandidates: [GameArtworkCandidate] = []

        do {
            let (data, resp) = try await URLSession.shared.data(for: searchReq)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                return []
            }
            let decoded = try JSONDecoder().decode(SGDBAutocompleteResponse.self, from: data)
            guard let games = decoded.data, let firstGame = games.first else {
                return []
            }

            // Fetch square icons
            if let iconsUrl = URL(string: "https://www.steamgriddb.com/api/v2/icons/game/\(firstGame.id)") {
                var iconReq = URLRequest(url: iconsUrl)
                iconReq.timeoutInterval = 10
                iconReq.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                if let (iconData, iconResp) = try? await URLSession.shared.data(for: iconReq),
                   let iconHttp = iconResp as? HTTPURLResponse, iconHttp.statusCode == 200,
                   let iconMedia = try? JSONDecoder().decode(SGDBMediaResponse.self, from: iconData),
                   let items = iconMedia.data {
                    for item in items.prefix(8) {
                        if let full = URL(string: item.url) {
                            let thumb = item.thumb != nil ? URL(string: item.thumb!) : full
                            foundCandidates.append(GameArtworkCandidate(
                                id: "sgdb_icon_\(item.id)",
                                title: firstGame.name,
                                subtitle: "SteamGridDB Square Icon",
                                category: .logos,
                                sourceDescription: "SteamGridDB",
                                previewUrl: thumb,
                                fullUrl: full
                            ))
                        }
                    }
                }
            }

            // Fetch grids (covers)
            if let gridsUrl = URL(string: "https://www.steamgriddb.com/api/v2/grids/game/\(firstGame.id)?dimensions=600x900") {
                var gridReq = URLRequest(url: gridsUrl)
                gridReq.timeoutInterval = 10
                gridReq.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                if let (gridData, gridResp) = try? await URLSession.shared.data(for: gridReq),
                   let gridHttp = gridResp as? HTTPURLResponse, gridHttp.statusCode == 200,
                   let gridMedia = try? JSONDecoder().decode(SGDBMediaResponse.self, from: gridData),
                   let items = gridMedia.data {
                    for item in items.prefix(6) {
                        if let full = URL(string: item.url) {
                            let thumb = item.thumb != nil ? URL(string: item.thumb!) : full
                            foundCandidates.append(GameArtworkCandidate(
                                id: "sgdb_grid_\(item.id)",
                                title: firstGame.name,
                                subtitle: "SteamGridDB Cover",
                                category: .covers,
                                sourceDescription: "SteamGridDB",
                                previewUrl: thumb,
                                fullUrl: full
                            ))
                        }
                    }
                }
            }
        } catch {
            // Ignore error
        }

        return foundCandidates
    }

    // MARK: - Image Downloading & Caching
    public func fetchImage(from url: URL) async -> NSImage? {
        let nsUrl = url as NSURL
        if let cached = memoryCache.object(forKey: nsUrl) {
            return cached
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let image = NSImage(data: data) else {
                return nil
            }
            memoryCache.setObject(image, forKey: nsUrl)
            return image
        } catch {
            return nil
        }
    }
}

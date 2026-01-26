import Foundation

/// Art Institute of Chicago provider using their public API
/// Uses proper search endpoint with artwork type filtering
final class AICProvider: MuseumProvider {

    let providerID: String = "aic"
    let sourceName: String = "Art Institute of Chicago"

    private let apiBase = "https://api.artic.edu/api/v1"
    private let imageBase = "https://www.artic.edu/iiif/2"

    private let maxIDsPerLoad = 500

    // Shared URL session
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    // MARK: - Fetch Artwork IDs

    func fetchArtworkIDs(
        query: String,
        medium: String?,
        geo: String?,
        period: PeriodPreset
    ) async throws -> [String] {
        
        DebugLogger.logProviderStart("AIC", query: query)
        
        print("🟡 [AIC] === FETCH REQUEST ===")
        print("🟡 [AIC] Medium filter: \(medium ?? "all")")
        print("🟡 [AIC] Using /search endpoint with type filtering")
        
        // Map medium filter to artwork types
        let typesToFetch = artworkTypesForMedium(medium)
        print("🟡 [AIC] Fetching types: \(typesToFetch)")
        
        // Fetch selected types in parallel
        var results: [(String, [Int])] = []
        
        await withTaskGroup(of: (String, [Int]).self) { group in
            for artType in typesToFetch {
                group.addTask {
                    let ids = await self.fetchIDsForType(artType, pages: 5)
                    return (artType, ids)
                }
            }
            
            for await (artType, ids) in group {
                print("🟡 [AIC] \(artType): \(ids.count) IDs")
                results.append((artType, ids))
            }
        }
        
        // Check if we got any results
        let hasResults = results.contains { !$0.1.isEmpty }
        guard hasResults else {
            print("🟡 [AIC] ⚠️ Type filters returned 0 results, using all public domain")
            let fallbackIDs = await fetchAllPublicDomain(pages: 20)
            guard !fallbackIDs.isEmpty else {
                throw URLError(.cannotLoadFromNetwork)
            }
            
            let finalIDs = Array(fallbackIDs).shuffled().prefix(maxIDsPerLoad).map { "\(providerID):\($0)" }
            print("🟡 [AIC] Fallback: \(finalIDs.count) IDs")
            DebugLogger.logProviderSuccess("AIC", idCount: finalIDs.count)
            return finalIDs
        }
        
        print("🟡 [AIC] === TYPE DISTRIBUTION ===")
        for (artType, ids) in results {
            print("🟡 [AIC] \(artType): \(ids.count)")
        }
        
        // Build balanced mix - equal amounts from each type
        let targetPerType = maxIDsPerLoad / max(1, typesToFetch.count)
        
        var balancedIDs: [Int] = []
        for (artType, typeIDs) in results {
            let shuffled = typeIDs.shuffled()
            let selected = Array(shuffled.prefix(targetPerType))
            balancedIDs.append(contentsOf: selected)
            print("🟡 [AIC] Selected \(selected.count) \(artType)")
        }
        
        // Final shuffle to interleave types
        let finalIDs = balancedIDs.shuffled().map { "\(providerID):\($0)" }
        
        print("🟡 [AIC] Total unique: \(Set(balancedIDs).count)")
        print("🟡 [AIC] Final selection: \(finalIDs.count) IDs")
        
        if finalIDs.count >= 10 {
            let sample = finalIDs.prefix(10).map { $0.replacingOccurrences(of: "aic:", with: "") }
            print("🟡 [AIC] Sample IDs: \(sample.joined(separator: ", "))")
        }
        
        DebugLogger.logProviderSuccess("AIC", idCount: finalIDs.count)
        
        return finalIDs
    }
    
    /// Maps user-facing medium filter to AIC artwork_type_title values
    private func artworkTypesForMedium(_ medium: String?) -> [String] {
        guard let medium = medium?.lowercased() else {
            // No filter = all types
            return ["Painting", "Print", "Drawing and Watercolor", "Photograph"]
        }
        
        switch medium {
        case "paintings":
            return ["Painting"]
        case "drawings":
            return ["Drawing and Watercolor"]
        case "prints":
            return ["Print"]
        case "photographs":
            return ["Photograph"]
        default:
            return ["Painting", "Print", "Drawing and Watercolor", "Photograph"]
        }
    }
    
    /// Fetch IDs for a specific artwork type using the /search endpoint
    /// Uses artwork_type_title.keyword for exact text matching per Elasticsearch conventions
    private func fetchIDsForType(_ artworkType: String, pages: Int) async -> [Int] {
        print("🟡 [AIC] Fetching type: \(artworkType)")
        
        // Build Elasticsearch query for this type
        // IMPORTANT: Use .keyword suffix for exact text field matching
        let searchQuery: [String: Any] = [
            "query": [
                "bool": [
                    "must": [
                        ["term": ["is_public_domain": true]],
                        ["term": ["artwork_type_title.keyword": artworkType]]
                    ]
                ]
            ]
        ]
        
        guard let queryData = try? JSONSerialization.data(withJSONObject: searchQuery),
              let queryString = String(data: queryData, encoding: .utf8),
              let encodedQuery = queryString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            print("🟡 [AIC] \(artworkType): failed to encode query")
            return []
        }
        
        // First, get total count
        let countURL = "\(apiBase)/artworks/search?limit=1&fields=id&params=\(encodedQuery)"
        guard let url = URL(string: countURL) else { return [] }
        
        let totalCount: Int
        do {
            let response: AICSearchResponse = try await fetchJSON(url: url)
            totalCount = response.pagination.total
            print("🟡 [AIC] \(artworkType): \(totalCount) total items")
        } catch {
            print("🟡 [AIC] \(artworkType): error getting count - \(error)")
            return []
        }
        
        guard totalCount > 0 else {
            print("🟡 [AIC] \(artworkType): 0 items, skipping")
            return []
        }
        
        // Calculate total pages and select random ones
        // IMPORTANT: AIC API returns server errors for pages > 10 with filtered queries
        // Limiting to first 10 pages (1000 items) for reliability
        let itemsPerPage = 100
        let maxReliablePage = 10  // Pages 11+ return HTTP errors
        let totalPages = (totalCount + itemsPerPage - 1) / itemsPerPage
        let accessiblePages = min(totalPages, maxReliablePage)
        let pagesToFetch = min(pages, accessiblePages)
        let randomPages = (1...accessiblePages).shuffled().prefix(pagesToFetch)
        
        print("🟡 [AIC] \(artworkType): fetching \(pagesToFetch) random pages from \(accessiblePages) accessible (\(totalPages) total)")
        
        var allIDs: [Int] = []
        
        // Fetch pages in parallel
        await withTaskGroup(of: [Int].self) { group in
            for page in randomPages {
                group.addTask {
                    await self.fetchPageWithQuery(page: page, query: encodedQuery, type: artworkType)
                }
            }
            
            for await pageIDs in group {
                allIDs.append(contentsOf: pageIDs)
            }
        }
        
        print("🟡 [AIC] \(artworkType): collected \(allIDs.count) IDs")
        return allIDs
    }
    
    /// Fetch a single page with a specific query
    private func fetchPageWithQuery(page: Int, query: String, type: String) async -> [Int] {
        let urlString = "\(apiBase)/artworks/search?page=\(page)&limit=100&fields=id&params=\(query)"
        guard let url = URL(string: urlString) else {
            print("🟡 [AIC] \(type) p\(page): ❌ Invalid URL")
            return []
        }
        
        do {
            let response: AICSearchResponse = try await fetchJSON(url: url)
            if !response.data.isEmpty {
                print("🟡 [AIC] \(type) p\(page): \(response.data.count) items")
            } else {
                print("🟡 [AIC] \(type) p\(page): 0 items (empty response)")
            }
            return response.data.map { $0.id }
        } catch {
            print("🟡 [AIC] \(type) p\(page): ❌ Error - \(error.localizedDescription)")
            return []
        }
    }
    
    /// Fallback: fetch all public domain artworks
    private func fetchAllPublicDomain(pages: Int) async -> [Int] {
        print("🟡 [AIC] Fetching \(pages) random pages of all public domain")
        
        let searchQuery: [String: Any] = [
            "query": [
                "term": ["is_public_domain": true]
            ]
        ]
        
        guard let queryData = try? JSONSerialization.data(withJSONObject: searchQuery),
              let queryString = String(data: queryData, encoding: .utf8),
              let encodedQuery = queryString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return []
        }
        
        var allIDs: [Int] = []
        let randomPages = (1...100).shuffled().prefix(pages)
        
        await withTaskGroup(of: [Int].self) { group in
            for page in randomPages {
                group.addTask {
                    await self.fetchPageWithQuery(page: page, query: encodedQuery, type: "all")
                }
            }
            
            for await pageIDs in group {
                allIDs.append(contentsOf: pageIDs)
            }
        }
        
        print("🟡 [AIC] All public domain: collected \(allIDs.count) IDs")
        return allIDs
    }

    // MARK: - Fetch Single Artwork

    func fetchArtwork(id: String) async throws -> Artwork {
        let numericID = id.replacingOccurrences(of: "\(providerID):", with: "")
        guard let artworkID = Int(numericID) else { throw URLError(.badURL) }

        let fields = "id,title,artist_display,date_display,medium_display,image_id,artwork_type_title"
        guard let url = URL(string: "\(apiBase)/artworks/\(artworkID)?fields=\(fields)") else {
            throw URLError(.badURL)
        }

        let response: AICArtworkResponse = try await fetchJSON(url: url)
        let artwork = response.data

        // Validate image availability
        guard let imageID = artwork.image_id, !imageID.isEmpty else {
            throw URLError(.resourceUnavailable)
        }

        // Construct IIIF image URL (full quality)
        let imageURL = URL(string: "\(imageBase)/\(imageID)/full/843,/0/default.jpg")!

        let title = artwork.title ?? "Untitled"
        let artist = artwork.artist_display ?? "Unknown Artist"
        let date = artwork.date_display
        let medium = artwork.medium_display
        let contentType = classifyContentType(artworkType: artwork.artwork_type_title)

        print("🟡 [AIC] ✅ Loaded ID \(artworkID): [\(contentType)] type=\(artwork.artwork_type_title ?? "?"), artist=\(artist)")

        return Artwork(
            id: id,
            title: title,
            artist: artist,
            date: date,
            medium: medium,
            imageURL: imageURL,
            source: sourceName,
            sourceURL: URL(string: "https://www.artic.edu/artworks/\(artworkID)")!
        )
    }

    /// Classify artwork into content type for tracking
    private func classifyContentType(artworkType: String?) -> String {
        guard let type = artworkType?.lowercased() else { return "OTHER" }
        
        if type.contains("painting") {
            return "PAINTING"
        } else if type.contains("print") {
            return "PRINT"
        } else if type.contains("drawing") || type.contains("watercolor") {
            return "DRAWING"
        } else if type.contains("photograph") {
            return "PHOTO"
        }
        
        return "OTHER"
    }

    // MARK: - Network Helpers

    private func fetchJSON<T: Decodable>(url: URL) async throws -> T {
        let (data, response) = try await session.data(from: url)
        
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - API Models

private struct AICSearchResponse: Codable {
    let data: [AICSearchHit]
    let pagination: AICPagination
    let config: AICConfig?
}

private struct AICSearchHit: Codable {
    let id: Int
}

private struct AICPagination: Codable {
    let total: Int
    let limit: Int
    let offset: Int
    let current_page: Int
    let total_pages: Int
    let next_url: String?
    let prev_url: String?
}

private struct AICConfig: Codable {
    let iiif_url: String?
    let website_url: String?
}

private struct AICArtworkResponse: Codable {
    let data: AICArtwork
    let config: AICConfig?
}

private struct AICArtwork: Codable {
    let id: Int
    let title: String?
    let artist_display: String?
    let date_display: String?
    let medium_display: String?
    let image_id: String?
    let is_public_domain: Bool?
    let artwork_type_title: String?
}

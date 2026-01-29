import Foundation

final class CMAProvider: MuseumProvider {

    let providerID: String = "cma"
    let sourceName: String = "Cleveland Museum of Art"

    private let base = "https://openaccess-api.clevelandart.org/api"
    private let maxIDsPerLoad = 600

    private struct CMASearchResponse: Codable {
        let data: [CMASearchItem]
    }

    private struct CMASearchItem: Codable { let id: Int }

    private struct CMAArtworkResponse: Codable {
        let data: CMAArtwork
    }

    private struct CMAArtwork: Codable {
        let id: Int
        let title: String?
        let creators: [CMACreator]?
        let creation_date: String?
        let technique: String?

        let type: String?
        let department: String?
        let culture: [String]?
        let country: String?

        let share_license_status: String?

        let inseparable_parts: Bool?
        let part_visible: Bool?

        let url: String?
        let images: CMAImages?
    }

    private struct CMACreator: Codable { let description: String? }

    private struct CMAImages: Codable {
        let web: CMAImage?
        let print: CMAImage?
        let full: CMAImage?
    }

    private struct CMAImage: Codable { let url: String? }

    // MARK: - Provider

    func fetchArtworkIDs(query: String, medium: String?, geo: String?, period: PeriodPreset) async throws -> [String] {
        DebugLogger.logProviderStart("CMA", query: query)
        
        // Get all collections we want to query
        let collections = buildAllCollections(medium: medium, geo: geo)
        
        DebugLogger.log(.info, "CMA: Will query \(collections.count) collections in parallel")
        
        let limitPerCollection = max(100, 1000 / collections.count)
        
        // Query ALL collections IN PARALLEL for speed
        let allIDs = await withTaskGroup(of: [Int].self) { group in
            // Add a task for each collection
            for collection in collections {
                group.addTask {
                    do {
                        let ids = try await self.fetchFromCollection(
                            collection: collection,
                            query: query,
                            limit: limitPerCollection
                        )
                        if ids.isEmpty {
                            DebugLogger.log(.warning, "CMA: '\(collection)' returned 0 results")
                        } else {
                            DebugLogger.log(.success, "CMA: '\(collection)' returned \(ids.count) IDs")
                        }
                        return ids
                    } catch {
                        DebugLogger.log(.warning, "CMA: '\(collection)' failed - \(error.localizedDescription)")
                        return []
                    }
                }
            }
            
            // Collect all results
            var combined: [Int] = []
            for await result in group {
                combined.append(contentsOf: result)
            }
            return combined
        }
        
        guard !allIDs.isEmpty else {
            DebugLogger.logProviderError("CMA", error: URLError(.cannotLoadFromNetwork))
            throw URLError(.cannotLoadFromNetwork)
        }
        
        // Shuffle to mix all collections together
        var shuffledIDs = allIDs
        shuffledIDs.shuffle()
        
        let finalIDs = Array(shuffledIDs.prefix(maxIDsPerLoad)).map { "\(providerID):\($0)" }
        DebugLogger.logProviderSuccess("CMA", idCount: finalIDs.count)
        
        return finalIDs
    }
    
    /// Fetch from a specific collection
    private func fetchFromCollection(collection: String, query: String, limit: Int) async throws -> [Int] {
        // Use collection-appropriate skip to avoid overshooting smaller collections
        let maxSkip = estimateMaxSkip(for: collection)
        let skip = Int.random(in: 0...maxSkip)
        
        var ids = try await fetchCollectionPage(collection: collection, query: query, limit: limit, skip: skip)
        
        // If we got 0 results and we skipped, retry from the beginning
        if ids.isEmpty && skip > 0 {
            DebugLogger.log(.info, "CMA: '\(collection)' empty at skip=\(skip), retrying from 0")
            ids = try await fetchCollectionPage(collection: collection, query: query, limit: limit, skip: 0)
        }
        
        return ids
    }
    
    /// Execute the actual API request for a collection page
    private func fetchCollectionPage(collection: String, query: String, limit: Int, skip: Int) async throws -> [Int] {
        var comps = URLComponents(string: "\(base)/artworks/")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "cc0", value: ""),
            URLQueryItem(name: "has_image", value: "1"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "skip", value: String(skip)),
            URLQueryItem(name: "collection", value: collection)
        ]
        
        // Don't add generic "painting" query when using collection filters
        if !query.isEmpty && query.lowercased() != "painting" {
            items.append(URLQueryItem(name: "q", value: query))
        }
        
        comps.queryItems = items
        guard let url = comps.url else { throw URLError(.badURL) }
        
        DebugLogger.logNetworkRequest(url: url)
        let resp: CMASearchResponse = try await fetchJSON(url: url)
        return resp.data.map { $0.id }
    }
    
    /// Estimate safe max skip based on known collection sizes
    /// These are conservative estimates to avoid overshooting
    /// Most painting collections are quite small (under 50 items with CC0)
    private func estimateMaxSkip(for collection: String) -> Int {
        switch collection {
        // Large collections (500+ items) - can skip more
        case "DR - Italian", "DR - French", "DR - American 19th Century",
             "PR - Etching", "PR - Lithograph", "PR - Woodcut":
            return 400
            
        // Medium-large collections (200-500 items)
        case "Mod Euro - Painting 1800-1960",
             "American - Painting", "DR - German", "DR - American 20th Century":
            return 150
            
        // Medium collections (100-200 items)
        case "Drawings", "Prints",
             "P - Italian 16th & 17th Century":
            return 50
            
        // Small painting collections (under 100 CC0 items) - very conservative
        case "P - Italian 15th Century and earlier",
             "P - Italian 18th Century",
             "P - Netherlandish-Dutch",
             "P - Netherlandish-Flemish",
             "P - French & Austria 16th C. and earlier",
             "P - French 17th Century",
             "P - French 18th Century",
             "P - Spanish before 1800",
             "P - British before 1800",
             "P - German before 1800",
             "P - Miscellaneous":
            return 10
            
        // Photography - unknown size, be conservative
        case "Photography":
            return 30
            
        // Default conservative
        default:
            return 20
        }
    }
    
    /// Build list of collections based on medium filter
    /// Maps user-facing medium names to CMA collection codes
    private func buildAllCollections(medium: String?, geo: String?) -> [String] {
        let mediumLower = (medium ?? "").lowercased()
        
        // Handle specific medium filters
        if mediumLower == "paintings" {
            return buildPaintingCollections(geo: geo)
        }
        
        if mediumLower == "drawings" {
            return [
                "DR - American 19th Century",
                "DR - American 20th Century",
                "DR - French",
                "DR - Italian",
                "DR - German",
                "Drawings"
            ]
        }
        
        if mediumLower == "prints" {
            return [
                "Prints",
                "PR - Etching",
                "PR - Lithograph",
                "PR - Woodcut"
            ]
        }
        
        if mediumLower == "photographs" {
            return ["Photography"]
        }
        
        // No filter = all types
        var collections = buildPaintingCollections(geo: geo)
        
        // Add drawings
        collections.append(contentsOf: [
            "DR - American 19th Century",
            "DR - American 20th Century",
            "DR - French",
            "DR - Italian",
            "DR - German",
            "Drawings"
        ])
        
        // Add prints
        collections.append(contentsOf: [
            "Prints",
            "PR - Etching",
            "PR - Lithograph",
            "PR - Woodcut"
        ])
        
        return collections
    }
    
    /// Build painting collections, optionally filtered by geography
    /// Collection names must match CMA's actual department/collection values
    private func buildPaintingCollections(geo: String?) -> [String] {
        // Check for geography filter
        if let geo = geo?.lowercased() {
            if geo.contains("united states") || geo.contains("america") {
                return ["American - Painting"]
            } else if geo.contains("france") {
                return [
                    "P - French & Austria 16th C. and earlier",
                    "P - French 17th Century",
                    "P - French 18th Century",
                    "Mod Euro - Painting 1800-1960"
                ]
            } else if geo.contains("spain") {
                return ["P - Spanish before 1800", "Mod Euro - Painting 1800-1960"]
            } else if geo.contains("italy") {
                return [
                    "P - Italian 15th Century and earlier",
                    "P - Italian 16th & 17th Century",
                    "P - Italian 18th Century"
                ]
            } else if geo.contains("netherlands") || geo.contains("dutch") {
                return ["P - Netherlandish-Dutch"]
            } else if geo.contains("flemish") || geo.contains("belgium") {
                return ["P - Netherlandish-Flemish"]
            } else if geo.contains("england") || geo.contains("british") {
                return ["P - British before 1800", "Mod Euro - Painting 1800-1960"]
            } else if geo.contains("german") {
                return ["P - German before 1800", "Mod Euro - Painting 1800-1960"]
            }
        }
        
        // All painting collections - using CMA's actual collection names
        return [
            "American - Painting",
            "P - Italian 15th Century and earlier",
            "P - Italian 16th & 17th Century",
            "P - Italian 18th Century",
            "P - Netherlandish-Dutch",
            "P - Netherlandish-Flemish",
            "P - French & Austria 16th C. and earlier",
            "P - French 17th Century",
            "P - French 18th Century",
            "P - Spanish before 1800",
            "P - British before 1800",
            "P - German before 1800",
            "P - Miscellaneous",
            "Mod Euro - Painting 1800-1960"
        ]
    }
    

    func fetchArtwork(id: String) async throws -> Artwork {
        DebugLogger.logArtworkFetch(id: id)
        
        let raw = id.replacingOccurrences(of: "\(providerID):", with: "")
        guard let intID = Int(raw) else { throw URLError(.badURL) }

        guard let url = URL(string: "\(base)/artworks/\(intID)") else { throw URLError(.badURL) }

        let resp: CMAArtworkResponse = try await fetchJSON(url: url)
        let a = resp.data

        if let status = a.share_license_status?.uppercased(), status != "CC0" {
            DebugLogger.log(.warning, "CMA: Blocked \(id) - license status: \(status)")
            throw URLError(.resourceUnavailable)
        }

        let imageURLString =
            a.images?.web?.url ??
            a.images?.print?.url ??
            a.images?.full?.url

        guard let imageURLString, let imageURL = URL(string: imageURLString) else {
            DebugLogger.log(.warning, "CMA: Blocked \(id) - no image available")
            throw URLError(.resourceUnavailable)
        }

        let title = (a.title ?? "").nilIfEmpty ?? "Untitled"
        let artist = a.creators?.first?.description?.nilIfEmpty ?? "Unknown artist"
        let date = (a.creation_date ?? "").nilIfEmpty
        let medium = (a.technique ?? "").nilIfEmpty

        let sourceURL = (a.url.flatMap(URL.init)) ?? URL(string: "https://www.clevelandart.org/art/\(a.id)")

        var debug: [String: String] = [:]
        debug["provider"] = providerID
        debug["cma_id"] = "\(a.id)"
        if let t = a.type { debug["type"] = t }
        if let d = a.department { debug["department"] = d }
        if let tech = a.technique { debug["technique"] = tech }
        if let culture = a.culture?.first { debug["culture"] = culture }
        if let status = a.share_license_status { debug["share_license_status"] = status }
        if let ip = a.inseparable_parts { debug["inseparable_parts"] = ip ? "true" : "false" }
        if let pv = a.part_visible { debug["part_visible"] = pv ? "true" : "false" }

        if isBlockedCleveland(title: title, technique: a.technique, type: a.type, department: a.department) {
            DebugLogger.log(.warning, "CMA: Blocked \(id) '\(title)' - type: \(a.type ?? "nil"), dept: \(a.department ?? "nil"), technique: \(a.technique ?? "nil")")
            throw URLError(.resourceUnavailable)
        }

        DebugLogger.logArtworkSuccess(id: id, title: title)
        
        return Artwork(
            id: id,
            title: title,
            artist: artist,
            date: date,
            medium: medium,
            imageURL: imageURL,
            source: sourceName,
            sourceURL: sourceURL,
            debugFields: debug
        )
    }

    // MARK: - Filtering Rules (Cleveland-only)

    private func isBlockedCleveland(title: String, technique: String?, type: String?, department: String?) -> Bool {
        let t = title.lowercased()
        let tech = (technique ?? "").lowercased()
        let ty = (type ?? "").lowercased()
        let dept = (department ?? "").lowercased()

        // Since we're using precise collection filters, we mainly need to block
        // book/manuscript objects that might slip through

        // Block specific problematic series
        let seriesTitleBlocks = [
            "tuti-nama", "tutinama"
        ]
        if seriesTitleBlocks.contains(where: { t.contains($0) }) {
            return true
        }

        // Block bound volumes and manuscripts
        if ty.contains("bound volume") {
            return true
        }

        // Block manuscript techniques
        let techniqueBlocks = [
            "palm leaves", "palm leaf", "on palm",
            "vellum", "parchment",
            "handscroll", "scroll", "album", "codex", "manuscript",
            "sutra", "prayerbook", "prayer book"
        ]
        if techniqueBlocks.contains(where: { tech.contains($0) }) {
            return true
        }

        // Block folio/page titles
        let titleBlocks = [
            "text,", "folio", "fol.", "leaf", "page",
            "manuscript", "sutra", "prajnaparamita",
            "hours of", "book of hours",
            "prayerbook", "prayer book",
            "song of songs",
            "illustrated tale"
        ]
        if titleBlocks.contains(where: { t.contains($0) }) {
            return true
        }

        // Block manuscript departments
        let departmentBlocks = [
            "manuscript", "rare book", "library", "archives"
        ]
        if departmentBlocks.contains(where: { dept.contains($0) }) {
            return true
        }

        return false
    }

    // MARK: - Networking

    private func fetchJSON<T: Decodable>(url: URL) async throws -> T {
        var req = URLRequest(url: url)
        req.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: req)
        
        guard let http = response as? HTTPURLResponse else {
            DebugLogger.log(.error, "CMA: Invalid response type")
            throw URLError(.badServerResponse)
        }
        
        DebugLogger.logNetworkResponse(url: url, statusCode: http.statusCode, dataSize: data.count)
        
        guard (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            DebugLogger.log(.error, "CMA: JSON decode error - \(error.localizedDescription)")
            if let jsonString = String(data: data, encoding: .utf8) {
                DebugLogger.log(.error, "CMA: Response preview - \(String(jsonString.prefix(200)))")
            }
            throw error
        }
    }
}

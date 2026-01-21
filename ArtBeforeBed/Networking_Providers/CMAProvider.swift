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
        var comps = URLComponents(string: "\(base)/artworks/")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "cc0", value: ""),
            URLQueryItem(name: "has_image", value: "1"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "skip", value: String(Int.random(in: 0...200))),
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
    
    /// Build list of ALL collections to query based on filters
    /// By default (medium=nil), returns paintings + drawings + prints
    private func buildAllCollections(medium: String?, geo: String?) -> [String] {
        var collections: [String] = []
        
        let mediumLower = (medium ?? "").lowercased()
        
        // If user selected specific medium, only get that type
        if mediumLower.contains("drawing") {
            // Drawings only
            return [
                "DR - American 19th Century",
                "DR - American 20th Century",
                "DR - French",
                "DR - Italian",
                "DR - German",
                "Drawings"
            ]
        }
        
        if mediumLower.contains("print") {
            // Prints only
            return [
                "Prints",
                "PR - Etching",
                "PR - Lithograph",
                "PR - Woodcut"
            ]
        }
        
        if mediumLower.contains("photograph") {
            // Photographs only
            return ["Photography"]
        }
        
        // Default: Get paintings + drawings + prints (everything!)
        
        // PAINTINGS - American and European only
        if medium == nil || mediumLower.contains("painting") {
            // American paintings
            collections.append("American - Painting")
            
            // European paintings
            collections.append("P - Italian 14th-15th Century")
            collections.append("P - Italian 16th & 17th Century")
            collections.append("P - Northern European 15th & 16th Century")
            collections.append("P - Dutch & Flemish 17th Century")
            collections.append("P - French & Spanish 17th & 18th Century")
            collections.append("P - British 18th & 19th Century")
            collections.append("Mod Euro - Painting 1800-1960")
            
            // If specific geography requested, filter paintings further
            if let geo = geo?.lowercased() {
                if geo.contains("united states") || geo.contains("america") {
                    collections = ["American - Painting"]
                } else if geo.contains("france") || geo.contains("spain") {
                    collections = ["P - French & Spanish 17th & 18th Century", "Mod Euro - Painting 1800-1960"]
                } else if geo.contains("italy") {
                    collections = ["P - Italian 14th-15th Century", "P - Italian 16th & 17th Century"]
                } else if geo.contains("netherlands") || geo.contains("flemish") {
                    collections = ["P - Dutch & Flemish 17th Century"]
                } else if geo.contains("england") || geo.contains("british") {
                    collections = ["P - British 18th & 19th Century"]
                }
            }
        }
        
        // Add drawings and prints when medium is "Any" (not when user specifically selected "Paintings")
        if medium == nil {
            // DRAWINGS - Worldwide
            collections.append("DR - American 19th Century")
            collections.append("DR - American 20th Century")
            collections.append("DR - French")
            collections.append("DR - Italian")
            collections.append("DR - German")
            collections.append("Drawings")
            
            // PRINTS - Worldwide
            collections.append("Prints")
            collections.append("PR - Etching")
            collections.append("PR - Lithograph")
            collections.append("PR - Woodcut")
        }
        
        return collections
    }
    
    // MARK: - Collection Filtering
    
    /// Returns allowed collection values based on medium and geography
    /// Paintings: American and European only
    /// Drawings/Prints: Worldwide
    private func buildCollectionFilter(medium: String?, geo: String?) -> [String]? {
        // If no medium specified, return default mix of paintings
        guard let medium = medium else {
            return [
                "American - Painting",
                "Mod Euro - Painting 1800-1960",
                "P - Dutch & Flemish 17th Century",
                "P - Italian 16th & 17th Century"
            ]
        }
        
        let mediumLower = medium.lowercased()
        
        // PAINTINGS - American and European only
        if mediumLower.contains("painting") {
            var paintingCollections: [String] = []
            
            // American paintings
            paintingCollections.append("American - Painting")
            
            // European paintings
            paintingCollections.append("P - Italian 14th-15th Century")
            paintingCollections.append("P - Italian 16th & 17th Century")
            paintingCollections.append("P - Northern European 15th & 16th Century")
            paintingCollections.append("P - Dutch & Flemish 17th Century")
            paintingCollections.append("P - French & Spanish 17th & 18th Century")
            paintingCollections.append("P - British 18th & 19th Century")
            paintingCollections.append("Mod Euro - Painting 1800-1960")
            
            // If specific geography is requested, filter further
            if let geo = geo?.lowercased() {
                if geo.contains("united states") || geo.contains("america") {
                    return ["American - Painting"]
                } else if geo.contains("france") || geo.contains("spain") {
                    return ["P - French & Spanish 17th & 18th Century", "Mod Euro - Painting 1800-1960"]
                } else if geo.contains("italy") {
                    return ["P - Italian 14th-15th Century", "P - Italian 16th & 17th Century"]
                } else if geo.contains("netherlands") || geo.contains("flemish") {
                    return ["P - Dutch & Flemish 17th Century"]
                } else if geo.contains("england") || geo.contains("british") {
                    return ["P - British 18th & 19th Century"]
                }
            }
            
            return paintingCollections
        }
        
        // DRAWINGS - Worldwide
        if mediumLower.contains("drawing") {
            return [
                "DR - American 19th Century",
                "DR - American 20th Century",
                "DR - French",
                "DR - Italian",
                "DR - German",
                "Drawings"
            ]
        }
        
        // PRINTS - Worldwide
        if mediumLower.contains("print") {
            return [
                "Prints",
                "PR - Etching",
                "PR - Lithograph",
                "PR - Woodcut"
            ]
        }
        
        // PHOTOGRAPHS - Worldwide
        if mediumLower.contains("photograph") {
            return ["Photography"]
        }
        
        // If medium doesn't match any category, return default paintings
        return [
            "American - Painting",
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

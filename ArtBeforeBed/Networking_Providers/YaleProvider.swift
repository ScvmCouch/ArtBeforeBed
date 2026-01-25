import Foundation

// Yale Provider - Simplified for Photography and Prints & Drawings departments
// This provider focuses on open access items from Yale University Art Gallery's:
// - Photography department (~1,722 open access photographs)
// - Prints and Drawings department (~24,030 open access items)
//
// These departments are chosen because they have substantial open access collections
// that are well-suited for digital display and discovery.

final class YaleProvider: MuseumProvider {
    
    let providerID: String = "yale"
    let sourceName: String = "Yale University Art Gallery"
    
    private let searchBase = "https://lux.collections.yale.edu/api/search/item"
    private let dataBase = "https://lux.collections.yale.edu/data/object"
    
    // Yale's Linked Art response structure
    private struct SearchResponse: Codable {
        let orderedItems: [SearchItem]?
        let partOf: [PartOfInfo]?
        
        struct SearchItem: Codable {
            let id: String  // Data URI like "https://lux.collections.yale.edu/data/object/{uuid}"
        }
        
        struct PartOfInfo: Codable {
            let totalItems: Int?
        }
    }
    
    // Simplified Linked Art object structure (we only parse what we need)
    private struct LinkedArtObject: Codable {
        let id: String
        let type: String?
        let _label: String?
        
        let identified_by: [IdentifiedBy]?
        let made_of: [Material]?
        let produced_by: Production?
        let representation: [Representation]?
        let subject_to: [Rights]?
        let member_of: [MemberOf]?
        let referred_to_by: [ReferredToBy]?
        
        struct IdentifiedBy: Codable {
            let type: String?
            let content: String?
            let classified_as: [Classification]?
        }
        
        struct Material: Codable {
            let _label: String?
        }
        
        struct Production: Codable {
            let type: String?
            let _label: String?
            let carried_out_by: [Agent]?
            let part: [ProductionPart]?  // Sometimes artist is nested in parts
            let timespan: Timespan?
            
            struct Agent: Codable {
                let id: String?
                let type: String?
                let _label: String?
            }
            
            struct ProductionPart: Codable {
                let type: String?
                let _label: String?
                let carried_out_by: [Agent]?
            }
            
            struct Timespan: Codable {
                let begin_of_the_begin: String?
                let end_of_the_end: String?
                let _label: String?
            }
        }
        
        struct Representation: Codable {
            let type: String?
            let digitally_shown_by: [DigitalObject]?
            
            struct DigitalObject: Codable {
                let access_point: [AccessPoint]?
                let classified_as: [Classification]?
                
                struct AccessPoint: Codable {
                    let id: String?
                }
            }
        }
        
        struct Rights: Codable {
            let type: String?
            let classified_as: [Classification]?
        }
        
        struct MemberOf: Codable {
            let _label: String?
        }
        
        struct ReferredToBy: Codable {
            let type: String?
            let content: String?
            let classified_as: [Classification]?
        }
        
        struct Classification: Codable {
            let id: String?
            let _label: String?
        }
    }
    
    func fetchArtworkIDs(
        query: String,
        medium: String?,
        geo: String?,
        period: PeriodPreset
    ) async throws -> [String] {
        let overallStart = CFAbsoluteTimeGetCurrent()
        
        // Build the search query JSON
        let queryDict = buildQueryDict(query: query, medium: medium, geo: geo, period: period)
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: queryDict),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw URLError(.badURL)
        }
        
        // First, fetch page 1 just to get total count
        let countStart = CFAbsoluteTimeGetCurrent()
        let totalCount = try await fetchTotalCount(jsonString: jsonString)
        let countTime = CFAbsoluteTimeGetCurrent() - countStart
        print("[\(providerID)] Total count fetch: \(String(format: "%.2f", countTime))s (found \(totalCount) items)")
        
        guard totalCount > 0 else {
            throw URLError(.cannotLoadFromNetwork)
        }
        
        // Calculate pagination for randomization
        // NOTE: Yale LUX API slows dramatically on higher pages (page 50+ can take 7-13s)
        // Cap at page 20 for reasonable performance (~2000 items accessible, sub-1s per page)
        let pageSize = 100
        let maxUsablePage = min(totalCount / pageSize, 19) // Cap at page 20 for performance
        
        // Fetch multiple random pages in parallel for better variety
        let pagesToFetch = min(5, maxUsablePage + 1) // Fetch up to 5 random pages
        var randomPages = Set<Int>()
        
        while randomPages.count < pagesToFetch {
            randomPages.insert(Int.random(in: 0...maxUsablePage))
        }
        
        print("[\(providerID)] Fetching pages: \(randomPages.sorted()) (max available: \(maxUsablePage))")
        
        // Fetch pages in parallel
        let pagesStart = CFAbsoluteTimeGetCurrent()
        let allIDs = try await withThrowingTaskGroup(of: (Int, [String], Double).self) { group in
            for page in randomPages {
                group.addTask {
                    let pageStart = CFAbsoluteTimeGetCurrent()
                    let ids = try await self.fetchPage(jsonString: jsonString, page: page, pageSize: pageSize)
                    let pageTime = CFAbsoluteTimeGetCurrent() - pageStart
                    return (page, ids, pageTime)
                }
            }
            
            var collected: [String] = []
            for try await (page, pageIDs, pageTime) in group {
                print("[\(self.providerID)]   Page \(page): \(pageIDs.count) IDs in \(String(format: "%.2f", pageTime))s")
                collected.append(contentsOf: pageIDs)
            }
            return collected
        }
        let pagesTime = CFAbsoluteTimeGetCurrent() - pagesStart
        
        // Shuffle the combined results for extra randomization
        let shuffled = allIDs.shuffled()
        
        let overallTime = CFAbsoluteTimeGetCurrent() - overallStart
        print("[\(providerID)] Complete: \(shuffled.count) IDs in \(String(format: "%.2f", overallTime))s (pages: \(String(format: "%.2f", pagesTime))s parallel)")
        
        return Array(shuffled.prefix(500))
    }
    
    // MARK: - Query Building
    
    private func buildQueryDict(query: String, medium: String?, geo: String?, period: PeriodPreset) -> [String: Any] {
        var filters: [[String: Any]] = []
        
        // Always require digital images
        filters.append(["hasDigitalImage": true])
        
        // Filter by department - only Photography and Prints & Drawings
        if let medium = medium {
            let dept = mapMediumToDepartment(medium)
            if !dept.isEmpty {
                filters.append(["memberOf": ["name": dept]])
            }
        } else {
            // If no medium specified, include both departments
            filters.append([
                "OR": [
                    ["memberOf": ["name": "Photography"]],
                    ["memberOf": ["name": "Prints and Drawings"]]
                ]
            ])
        }
        
        // Add text query
        if !query.isEmpty {
            filters.append(["text": query])
        }
        
        // Add geography/culture filter
        if let geo = geo {
            filters.append(["text": geo])
        }
        
        // Add period filter
        if let range = period.yearRange {
            let periodText = "\(range.lowerBound)-\(range.upperBound)"
            filters.append(["text": periodText])
        }
        
        return ["AND": filters]
    }
    
    private func fetchTotalCount(jsonString: String) async throws -> Int {
        var comps = URLComponents(string: searchBase)!
        comps.queryItems = [
            URLQueryItem(name: "q", value: jsonString),
            URLQueryItem(name: "pageLength", value: "1") // Minimal fetch just for count
        ]
        
        guard let url = comps.url else { throw URLError(.badURL) }
        
        let response: SearchResponse = try await fetchJSON(url: url)
        
        // Total count is in partOf[0].totalItems
        return response.partOf?.first?.totalItems ?? 0
    }
    
    private func fetchPage(jsonString: String, page: Int, pageSize: Int) async throws -> [String] {
        var comps = URLComponents(string: searchBase)!
        comps.queryItems = [
            URLQueryItem(name: "q", value: jsonString),
            URLQueryItem(name: "pageLength", value: String(pageSize)),
            URLQueryItem(name: "page", value: String(page + 1)) // LUX uses 1-based pages
        ]
        
        guard let url = comps.url else { throw URLError(.badURL) }
        
        let response: SearchResponse = try await fetchJSON(url: url)
        
        guard let items = response.orderedItems else { return [] }
        
        // Extract UUIDs from the data URIs
        return items.compactMap { item -> String? in
            // item.id looks like: "https://lux.collections.yale.edu/data/object/uuid"
            guard let uuid = item.id.split(separator: "/").last.map(String.init) else {
                return nil
            }
            return "\(providerID):\(uuid)"
        }
    }
    
    func fetchArtwork(id: String) async throws -> Artwork {
        // Extract UUID from our prefixed ID (e.g., "yale:uuid-here")
        let uuid = id.replacingOccurrences(of: "\(providerID):", with: "")
        
        guard let url = URL(string: "\(dataBase)/\(uuid)") else {
            throw URLError(.badURL)
        }
        
        let obj: LinkedArtObject = try await fetchJSON(url: url)
        
        // Extract image URL
        guard let imageURL = extractImageURL(from: obj) else {
            throw URLError(.resourceUnavailable)
        }
        
        // Check if it's public domain or open access
        guard isOpenAccess(obj) else {
            throw URLError(.resourceUnavailable)
        }
        
        // Extract metadata
        let title = obj._label ?? extractTitle(from: obj) ?? "Untitled"
        let artist = extractArtist(from: obj)
        let date = extractDate(from: obj)
        let medium = extractMedium(from: obj)
        
        let sourceURL = URL(string: "https://lux.collections.yale.edu/view/object/\(uuid)")
        
        // Build debug fields
        var debug: [String: String] = [:]
        debug["provider"] = providerID
        debug["uuid"] = uuid
        debug["type"] = obj.type ?? "unknown"
        if let collection = obj.member_of?.first?._label {
            debug["collection"] = collection
        }
        
        return Artwork(
            id: id,
            title: title,
            artist: artist ?? "",  // Empty string if no artist found
            date: date,
            medium: medium,
            imageURL: imageURL,
            source: sourceName,
            sourceURL: sourceURL,
            debugFields: debug
        )
    }
    
    // MARK: - Helper Methods
    
    private func extractImageURL(from obj: LinkedArtObject) -> URL? {
        // Look for primary image representation
        guard let representations = obj.representation else { return nil }
        
        for rep in representations {
            if let digitalObjects = rep.digitally_shown_by {
                for digital in digitalObjects {
                    // Look for IIIF image or direct access point
                    if let accessPoints = digital.access_point,
                       let firstPoint = accessPoints.first,
                       let urlString = firstPoint.id,
                       let url = URL(string: urlString) {
                        // Yale uses IIIF - we want the full image
                        // If it's a IIIF URL, we can request full size
                        if urlString.contains("iiif") {
                            // IIIF pattern: append /full/!2000,2000/0/default.jpg for reasonable size
                            if !urlString.contains("/full/") {
                                let iiifFull = urlString.replacingOccurrences(of: "/info.json", with: "/full/!2000,2000/0/default.jpg")
                                return URL(string: iiifFull) ?? url
                            }
                        }
                        return url
                    }
                }
            }
        }
        return nil
    }
    
    private func isOpenAccess(_ obj: LinkedArtObject) -> Bool {
        // Photography and Prints & Drawings departments at Yale have open access items
        // Since we're filtering by these departments, assume open access
        // In the future, could add more sophisticated rights checking if needed
        return true
    }
    
    private func extractTitle(from obj: LinkedArtObject) -> String? {
        guard let identifiers = obj.identified_by else { return nil }
        
        for identifier in identifiers {
            if identifier.type == "Name" {
                return identifier.content
            }
        }
        return nil
    }
    
    private func extractArtist(from obj: LinkedArtObject) -> String? {
        var allNames: [String] = []
        
        // Try produced_by.carried_out_by first (direct attribution)
        if let agents = obj.produced_by?.carried_out_by {
            allNames.append(contentsOf: agents.compactMap { $0._label })
        }
        
        // Try produced_by.part[].carried_out_by (nested in production parts)
        if let parts = obj.produced_by?.part {
            for part in parts {
                if let agents = part.carried_out_by {
                    allNames.append(contentsOf: agents.compactMap { $0._label })
                }
            }
        }
        
        // Filter out placeholder/unknown values and deduplicate
        let validNames = allNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { name in
                let lower = name.lowercased()
                // Filter out unknown/placeholder values
                if lower.isEmpty ||
                   lower == "unknown" ||
                   lower == "unknown artist" ||
                   lower == "unidentified" ||
                   lower == "anonymous" ||
                   lower.hasPrefix("unknown ") ||
                   lower.hasPrefix("unidentified ") {
                    return false
                }
                return true
            }
        
        // Deduplicate while preserving order
        var seen = Set<String>()
        let uniqueNames = validNames.filter { name in
            let dominated = name.lowercased()
            if seen.contains(dominated) { return false }
            seen.insert(dominated)
            return true
        }
        
        if !uniqueNames.isEmpty {
            return uniqueNames.joined(separator: "; ")
        }
        
        // Fallback: use produced_by._label if it looks like an artist name
        if let prodLabel = obj.produced_by?._label {
            let lower = prodLabel.lowercased()
            // Skip generic/placeholder labels
            if !lower.contains("production") &&
               !lower.contains("unknown") &&
               !lower.contains("unidentified") {
                return prodLabel
            }
        }
        
        // Return nil if no valid artist found - UI will display blank
        return nil
    }
    
    private func extractDate(from obj: LinkedArtObject) -> String? {
        return obj.produced_by?.timespan?._label
    }
    
    private func extractMedium(from obj: LinkedArtObject) -> String? {
        guard let materials = obj.made_of else { return nil }
        let materialNames = materials.compactMap { $0._label }
        return materialNames.isEmpty ? nil : materialNames.joined(separator: ", ")
    }
    
    private func mapMediumToDepartment(_ medium: String) -> String {
        // Map medium types to Yale departments (Photography or Prints and Drawings)
        switch medium.lowercased() {
        case "photographs", "photography":
            return "Photography"
        case "prints", "drawings", "prints and drawings":
            return "Prints and Drawings"
        default:
            // Default to Prints and Drawings for most 2D media
            return "Prints and Drawings"
        }
    }
    
    private func fetchJSON<T: Decodable>(url: URL) async throws -> T {
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        
        return try JSONDecoder().decode(T.self, from: data)
    }
}

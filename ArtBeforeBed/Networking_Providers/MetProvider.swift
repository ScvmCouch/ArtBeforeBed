import Foundation

/// Simple throttle actor to prevent overwhelming the Met API
private actor MetRequestThrottle {
    private var lastRequestTime: Date = .distantPast
    private let minInterval: TimeInterval = 0.15  // 150ms between requests (~6-7 req/sec max)
    
    func throttle() async {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRequestTime)
        if elapsed < minInterval {
            let waitTime = minInterval - elapsed
            try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
        }
        lastRequestTime = Date()
    }
}

final class MetProvider: MuseumProvider {

    let providerID: String = "met"
    let sourceName: String = "The Met"

    private let base = "https://collectionapi.metmuseum.org/public/collection/v1"
    
    /// Request throttle to prevent 403 blocks from Met API
    private let throttle = MetRequestThrottle()
    
    /// Curated department IDs for art-focused content
    /// 9 = Drawings and Prints
    /// 11 = European Paintings
    /// 19 = Photographs
    /// 21 = Modern Art
    /// 1 = American Decorative Arts (filtered via search to paintings/watercolors)
    private let curatedDepartmentIDs = [9, 11, 19, 21, 1]
    
    /// Cutoff year for public domain safety
    private let publicDomainCutoffYear = 1926

    private struct MetSearchResponse: Codable {
        let total: Int
        let objectIDs: [Int]?
    }

    private struct MetObject: Codable {
        let objectID: Int
        let title: String?
        let artistDisplayName: String?
        let objectDate: String?
        let primaryImage: String?
        let primaryImageSmall: String?
        let isPublicDomain: Bool
        let creditLine: String?
        let medium: String?
        let objectName: String?  // The type of object (Painting, Drawing, etc.)
        let country: String?
        let culture: String?
        let objectBeginDate: Int?
        let objectEndDate: Int?
        let objectURL: String?
        let department: String?

        var bestImageURL: URL? {
            let s = (primaryImageSmall?.nilIfEmpty) ?? (primaryImage?.nilIfEmpty)
            guard let s else { return nil }
            return URL(string: s)
        }

        var bestYear: Int? {
            if let b = objectBeginDate, b != 0 { return b }
            if let e = objectEndDate, e != 0 { return e }
            return nil
        }
    }

    func fetchArtworkIDs(query: String, medium: String?, geo: String?, period: PeriodPreset) async throws -> [String] {
        DebugLogger.logProviderStart("Met", query: query)
        
        print("🔵 [MET] === FETCH REQUEST ===")
        print("🔵 [MET] Query: '\(query.isEmpty ? "*" : query)' (ignoring - using department-based curation)")
        print("🔵 [MET] Medium filter: \(medium ?? "none") (ignoring - departments define content)")
        print("🔵 [MET] Geo filter: \(geo ?? "none")")
        print("🔵 [MET] Period: \(period)")
        
        // Strategy: Query each department with wildcard to get maximum variety
        // Departments naturally provide different content types:
        // - Dept 9: Prints & Drawings
        // - Dept 11: Paintings (European)
        // - Dept 19: Photographs
        // - Dept 21: Paintings (Modern)
        // - Dept 15: Paintings & Drawings (Lehman)
        
        // Fetch IDs from each curated department in parallel
        // Use "*" wildcard to get full collection from each department
        async let dept9IDs = fetchIDsForDepartment(9, query: "*", medium: nil, geo: geo, period: period)   // Drawings and Prints
        async let dept11IDs = fetchIDsForDepartment(11, query: "*", medium: nil, geo: geo, period: period) // European Paintings
        async let dept19IDs = fetchIDsForDepartment(19, query: "*", medium: nil, geo: geo, period: period) // Photographs
        async let dept21IDs = fetchIDsForDepartment(21, query: "*", medium: nil, geo: geo, period: period) // Modern Art
        async let dept1IDs = fetchIDsForDepartment(1, query: "*", medium: nil, geo: geo, period: period)   // American Decorative Arts (filtered)
        
        let results = await [dept9IDs, dept11IDs, dept19IDs, dept21IDs, dept1IDs]
        
        // Combine all IDs
        var allIDs: [String] = []
        for ids in results {
            allIDs.append(contentsOf: ids)
        }
        
        guard !allIDs.isEmpty else {
            throw URLError(.cannotLoadFromNetwork)
        }
        
        // Log department distribution before shuffling
        print("🔵 [MET] === DEPARTMENT DISTRIBUTION ===")
        print("🔵 [MET] Drawings & Prints (9): \(results[0].count)")
        print("🔵 [MET] European Paintings (11): \(results[1].count)")
        print("🔵 [MET] Photographs (19): \(results[2].count)")
        print("🔵 [MET] Modern Art (21): \(results[3].count)")
        print("🔵 [MET] American Decorative Arts (1): \(results[4].count) (filtered to paintings/drawings/paper/graphite)")
        print("🔵 [MET] Total before shuffle: \(allIDs.count)")
        
        // Shuffle and limit
        let finalIDs = Array(allIDs.shuffled().prefix(2000))
        
        print("🔵 [MET] === FINAL SELECTION ===")
        print("🔵 [MET] Final count after shuffle/limit: \(finalIDs.count)")
        
        // Calculate rough distribution in final selection
        let dept9Count = finalIDs.filter { $0.contains(":") && results[0].contains($0) }.count
        let dept11Count = finalIDs.filter { $0.contains(":") && results[1].contains($0) }.count
        let dept19Count = finalIDs.filter { $0.contains(":") && results[2].contains($0) }.count
        let dept21Count = finalIDs.filter { $0.contains(":") && results[3].contains($0) }.count
        let dept1Count = finalIDs.filter { $0.contains(":") && results[4].contains($0) }.count
        
        print("🔵 [MET] Estimated final distribution:")
        print("🔵 [MET]   Drawings & Prints: ~\(dept9Count) (\(Int(Double(dept9Count)/Double(finalIDs.count)*100))%)")
        print("🔵 [MET]   European Paintings: ~\(dept11Count) (\(Int(Double(dept11Count)/Double(finalIDs.count)*100))%)")
        print("🔵 [MET]   Photographs: ~\(dept19Count) (\(Int(Double(dept19Count)/Double(finalIDs.count)*100))%)")
        print("🔵 [MET]   Modern Art: ~\(dept21Count) (\(Int(Double(dept21Count)/Double(finalIDs.count)*100))%)")
        print("🔵 [MET]   American Decorative Arts: ~\(dept1Count) (\(Int(Double(dept1Count)/Double(finalIDs.count)*100))%)")
        
        // Sample some IDs to verify randomization
        if finalIDs.count >= 10 {
            let sample = finalIDs.prefix(10).map { $0.replacingOccurrences(of: "met:", with: "") }
            print("🔵 [MET] Sample IDs (first 10): \(sample.joined(separator: ", "))")
        }
        
        DebugLogger.logProviderSuccess("Met", idCount: finalIDs.count)
        
        return finalIDs
    }
    
    /// Fetches IDs for a specific department
    private func fetchIDsForDepartment(_ departmentId: Int, query: String, medium: String?, geo: String?, period: PeriodPreset) async -> [String] {
        var comps = URLComponents(string: "\(base)/search")!
        var items: [URLQueryItem] = [
            .init(name: "hasImages", value: "true"),
            .init(name: "departmentId", value: String(departmentId)),
            .init(name: "q", value: query.isEmpty ? "*" : query)
        ]

        if let medium, !medium.isEmpty {
            items.append(.init(name: "medium", value: medium))
        }

        if let geo, !geo.isEmpty {
            items.append(.init(name: "geoLocation", value: geo))
        }

        // Only apply user's period filter if they specified one
        // Don't enforce publicDomainCutoffYear here - let isPublicDomain flag handle it
        if let r = period.yearRange {
            items.append(.init(name: "dateBegin", value: String(r.lowerBound)))
            items.append(.init(name: "dateEnd", value: String(r.upperBound)))
        }
        // If no period specified, don't add date filters - get everything
        // The isPublicDomain flag in fetchArtwork will filter out non-PD items

        comps.queryItems = items
        guard let url = comps.url else { return [] }

        do {
            let resp: MetSearchResponse = try await fetchJSON(url: url)
            guard let ids = resp.objectIDs, !ids.isEmpty else {
                print("🔵 [MET] \(departmentName(for: departmentId)) (\(departmentId)): NO RESULTS")
                return []
            }
            
            // BALANCED SAMPLING STRATEGY:
            // - Photographs (19): Smaller collection, take more to ensure representation
            // - Drawings & Prints (9): Huge collection, sample broadly
            // - European Paintings (11): Medium size, standard sampling
            // - Modern Art (21): Large collection, standard sampling
            // - American Decorative Arts (1): Filter to paintings/drawings/paper/graphite only
            
            let maxPerDepartment: Int
            switch departmentId {
            case 19:  // Photographs - boost to ensure good representation
                maxPerDepartment = 600
            case 1:   // American Decorative Arts - needs filtering, start with more
                maxPerDepartment = 600
            case 9:   // Drawings & Prints - huge collection, keep standard
                maxPerDepartment = 500
            case 11:  // European Paintings
                maxPerDepartment = 500
            case 21:  // Modern Art
                maxPerDepartment = 500
            default:
                maxPerDepartment = 500
            }
            
            // For American Decorative Arts, use search queries to filter instead of fetching objects
            if departmentId == 1 {
                return await fetchAmericanDecorativeArtsWithSearch(geo: geo, period: period)
            }
            
            // Take a random sample from this department
            let sampledIDs = ids.shuffled().prefix(maxPerDepartment)
            
            let deptName = departmentName(for: departmentId)
            print("🔵 [MET] \(deptName) (\(departmentId)): found \(resp.total) total, available \(ids.count) IDs, sampling \(sampledIDs.count)")
            
            // Show ID range to verify randomization
            if let min = ids.min(), let max = ids.max() {
                print("🔵 [MET]   → ID range: \(min) to \(max) (span: \(max - min))")
            }
            
            return sampledIDs.map { "\(providerID):\($0)" }
        } catch {
            print("🔵 [MET] \(departmentName(for: departmentId)) (\(departmentId)) error: \(error)")
            return []
        }
    }
    
    /// Helper to get friendly department names
    private func departmentName(for id: Int) -> String {
        switch id {
        case 1: return "American Decorative Arts"
        case 9: return "Drawings & Prints"
        case 11: return "European Paintings"
        case 19: return "Photographs"
        case 21: return "Modern Art"
        default: return "Unknown"
        }
    }
    
    /// Fetches American Decorative Arts using search queries for paintings/drawings (fast approach)
    private func fetchAmericanDecorativeArtsWithSearch(geo: String?, period: PeriodPreset) async -> [String] {
        print("🔵 [MET] American Decorative Arts (1): Using search-based filtering...")
        
        // Search for specific terms within the department
        let searchTerms = ["painting", "watercolor", "pastel", "oil on canvas"]
        
        var allIDs: Set<Int> = []
        
        for term in searchTerms {
            var comps = URLComponents(string: "\(base)/search")!
            var items: [URLQueryItem] = [
                .init(name: "hasImages", value: "true"),
                .init(name: "departmentId", value: "1"),
                .init(name: "q", value: term)
            ]
            
            if let geo, !geo.isEmpty {
                items.append(.init(name: "geoLocation", value: geo))
            }
            
            if let r = period.yearRange {
                items.append(.init(name: "dateBegin", value: String(r.lowerBound)))
                items.append(.init(name: "dateEnd", value: String(r.upperBound)))
            }
            
            comps.queryItems = items
            guard let url = comps.url else { continue }
            
            do {
                let resp: MetSearchResponse = try await fetchJSON(url: url)
                if let ids = resp.objectIDs {
                    print("🔵 [MET]   → '\(term)': found \(ids.count) results")
                    allIDs.formUnion(ids)
                }
            } catch {
                print("🔵 [MET]   → '\(term)': error - \(error.localizedDescription)")
            }
        }
        
        let maxCount = 500
        let sampledIDs = Array(allIDs).shuffled().prefix(maxCount)
        
        print("🔵 [MET] American Decorative Arts (1): Total unique IDs: \(allIDs.count), sampling \(sampledIDs.count)")
        
        return sampledIDs.map { "\(providerID):\($0)" }
    }

    func fetchArtwork(id: String) async throws -> Artwork {
        let raw = id.replacingOccurrences(of: "\(providerID):", with: "")
        guard let intID = Int(raw) else { throw URLError(.badURL) }

        guard let url = URL(string: "\(base)/objects/\(intID)") else { throw URLError(.badURL) }
        let obj: MetObject = try await fetchJSON(url: url)

        guard obj.isPublicDomain, let img = obj.bestImageURL else {
            print("🔵 [MET] ❌ Rejected ID \(intID): publicDomain=\(obj.isPublicDomain), hasImage=\(obj.bestImageURL != nil)")
            throw URLError(.resourceUnavailable)
        }
        
        // Validate year for public domain safety
        if let year = obj.bestYear, year >= publicDomainCutoffYear {
            print("🔵 [MET] ❌ Rejected ID \(intID) from \(year) (must be before \(publicDomainCutoffYear))")
            throw URLError(.resourceUnavailable)
        }

        let artist = (obj.artistDisplayName?.nilIfEmpty) ?? "Unknown artist"
        let title = (obj.title?.nilIfEmpty) ?? "Untitled"
        let date = obj.objectDate?.nilIfEmpty
        let med = obj.medium?.nilIfEmpty

        let sourceURL = obj.objectURL.flatMap(URL.init)

        var debug: [String: String] = [:]
        debug["provider"] = providerID
        debug["met_objectID"] = "\(obj.objectID)"
        debug["isPublicDomain"] = obj.isPublicDomain ? "true" : "false"
        debug["department"] = obj.department ?? "unknown"
        if let credit = obj.creditLine?.nilIfEmpty { debug["creditLine"] = credit }
        if let m = obj.medium?.nilIfEmpty { debug["medium_raw"] = m }
        if let c = obj.country?.nilIfEmpty { debug["country"] = c }
        if let cul = obj.culture?.nilIfEmpty { debug["culture"] = cul }
        if let y = obj.bestYear { debug["year"] = "\(y)" }

        // Determine content type for tracking
        let contentType = classifyContentType(medium: med, department: obj.department)
        debug["content_type"] = contentType

        // Log what we're actually loading with content type
        print("🔵 [MET] ✅ Loaded ID \(intID): [\(contentType)] dept=\(obj.department ?? "?"), medium=\(med ?? "?"), year=\(obj.bestYear?.description ?? "?")")

        return Artwork(
            id: id,
            title: title,
            artist: artist,
            date: date,
            medium: med,
            imageURL: img,
            source: sourceName,
            sourceURL: sourceURL,
            debugFields: debug
        )
    }
    
    /// Classify artwork into content type for tracking
    private func classifyContentType(medium: String?, department: String?) -> String {
        let mediumLower = medium?.lowercased() ?? ""
        let deptLower = department?.lowercased() ?? ""
        
        // Photographs
        if deptLower.contains("photograph") ||
           mediumLower.contains("photograph") ||
           mediumLower.contains("gelatin silver") ||
           mediumLower.contains("albumen") {
            return "PHOTO"
        }
        
        // Prints
        if mediumLower.contains("print") ||
           mediumLower.contains("etching") ||
           mediumLower.contains("lithograph") ||
           mediumLower.contains("woodcut") ||
           mediumLower.contains("engraving") {
            return "PRINT"
        }
        
        // Drawings
        if mediumLower.contains("drawing") ||
           mediumLower.contains("chalk") ||
           mediumLower.contains("charcoal") ||
           mediumLower.contains("pencil") ||
           mediumLower.contains("ink") && !mediumLower.contains("oil") {
            return "DRAWING"
        }
        
        // Paintings
        if mediumLower.contains("oil") ||
           mediumLower.contains("canvas") ||
           mediumLower.contains("tempera") ||
           mediumLower.contains("panel") ||
           mediumLower.contains("painting") ||
           deptLower.contains("painting") {
            return "PAINTING"
        }
        
        return "OTHER"
    }

    private func fetchJSON<T: Decodable>(url: URL) async throws -> T {
        // Throttle requests to prevent 403 blocks
        await throttle.throttle()
        
        var req = URLRequest(url: url)
        req.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            print("🔵 [MET] ⚠️ Non-HTTP response for \(url.lastPathComponent)")
            throw URLError(.badServerResponse)
        }
        
        guard (200...299).contains(http.statusCode) else {
            // Log the actual error for debugging
            if http.statusCode == 429 {
                print("🔵 [MET] 🚫 RATE LIMITED (429) for \(url.lastPathComponent)")
            } else if http.statusCode == 403 {
                print("🔵 [MET] 🚫 FORBIDDEN (403) for \(url.lastPathComponent)")
            } else if http.statusCode == 404 {
                // Don't log 404s - these are expected for removed/unavailable objects
                ()
            } else {
                print("🔵 [MET] ⚠️ HTTP \(http.statusCode) for \(url.lastPathComponent)")
            }
            throw URLError(.badServerResponse)
        }

        return try JSONDecoder().decode(T.self, from: data)
    }
}

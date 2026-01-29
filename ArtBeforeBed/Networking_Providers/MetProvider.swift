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
    
    // MARK: - Validated ID Cache
    
    /// Cache of IDs that have been validated as public domain with images
    /// This prevents re-fetching metadata for IDs we've already confirmed are good
    private actor ValidatedIDCache {
        private var validIDs: Set<String> = []
        private var invalidIDs: Set<String> = []
        
        func isKnownValid(_ id: String) -> Bool {
            validIDs.contains(id)
        }
        
        func isKnownInvalid(_ id: String) -> Bool {
            invalidIDs.contains(id)
        }
        
        func markValid(_ id: String) {
            validIDs.insert(id)
            invalidIDs.remove(id)
        }
        
        func markInvalid(_ id: String) {
            invalidIDs.insert(id)
            validIDs.remove(id)
        }
        
        var validCount: Int { validIDs.count }
        var invalidCount: Int { invalidIDs.count }
    }
    
    private let validationCache = ValidatedIDCache()
    
    // MARK: - Department Collections (World Art)
    
    /// Met department IDs for world art collections
    /// These are separate from the curated "main" departments
    enum WorldArtDepartment: Int, CaseIterable {
        case islamicArt = 14
        case artsOfAfricaOceaniaAmericas = 5
        case asianArt = 6
        case ancientNearEasternArt = 3
        case egyptianArt = 10
        case greekAndRomanArt = 13
        
        var title: String {
            switch self {
            case .islamicArt: return "Islamic Art"
            case .artsOfAfricaOceaniaAmericas: return "Arts of Africa, Oceania, and the Americas"
            case .asianArt: return "Asian Art"
            case .ancientNearEasternArt: return "Ancient Near Eastern Art"
            case .egyptianArt: return "Egyptian Art"
            case .greekAndRomanArt: return "Greek and Roman Art"
            }
        }
    }
    
    /// Material filters for specific department collections
    /// These use search queries since Met API medium param requires exact matches
    struct DepartmentMaterialFilter {
        let department: WorldArtDepartment
        let searchTerms: [String]  // Search terms to query (e.g., "earthenware", "linen")
        let maxIDsPerTerm: Int     // Max IDs to fetch per search term
        
        var maxTotalIDs: Int {
            searchTerms.count * maxIDsPerTerm
        }
    }
    
    /// Enabled world art collections with their material filters
    /// Islamic Art with earthenware and linen as "lower implemented contributor"
    private let enabledWorldArtCollections: [DepartmentMaterialFilter] = [
        DepartmentMaterialFilter(
            department: .islamicArt,
            searchTerms: ["earthenware", "linen"],
            maxIDsPerTerm: 150  // ~300 total for Islamic Art
        )
    ]
    
    /// Curated department IDs for art-focused content
    /// 9 = Drawings and Prints
    /// 11 = European Paintings
    /// 19 = Photographs
    /// 21 = Modern Art
    /// 1 = American Decorative Arts (filtered via search to paintings/watercolors)
    private let curatedDepartmentIDs = [9, 11, 19, 21, 1]
    
    /// Cutoff year for public domain safety
    private let publicDomainCutoffYear = 1926
    
    /// Oversample factor to compensate for Met API's unreliable isPublicDomain search filter
    /// The search API returns ~30-40% invalid IDs even with isPublicDomain=true
    private let oversampleFactor = 2.5

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
        print("🔵 [MET] Medium filter: \(medium ?? "all")")
        print("🔵 [MET] Geo filter: \(geo ?? "none")")
        print("🔵 [MET] Period: \(period)")
        print("🔵 [MET] World art collections: \(enabledWorldArtCollections.map { $0.department.title })")
        print("🔵 [MET] Oversample factor: \(oversampleFactor)x (compensating for unreliable search filter)")
        
        // Map medium filter to departments
        let departments = departmentsForMedium(medium)
        print("🔵 [MET] Querying departments: \(departments)")
        
        // Fetch IDs from selected departments in parallel
        var results: [[String]] = []
        
        await withTaskGroup(of: (Int, [String]).self) { group in
            for dept in departments {
                group.addTask {
                    let ids = await self.fetchIDsForDepartment(dept, query: "*", medium: nil, geo: geo, period: period)
                    return (dept, ids)
                }
            }
            
            for await (dept, ids) in group {
                print("🔵 [MET] Department \(dept): \(ids.count) IDs")
                results.append(ids)
            }
        }
        
        // Fetch world art collections in parallel
        var worldArtResults: [(DepartmentMaterialFilter, [String])] = []
        
        if !enabledWorldArtCollections.isEmpty {
            await withTaskGroup(of: (DepartmentMaterialFilter, [String]).self) { group in
                for collection in enabledWorldArtCollections {
                    group.addTask {
                        let ids = await self.fetchIDsForWorldArtCollection(collection, geo: geo, period: period)
                        return (collection, ids)
                    }
                }
                
                for await (collection, ids) in group {
                    print("🔵 [MET] 🌍 \(collection.department.title) (\(collection.searchTerms.joined(separator: ", "))): \(ids.count) IDs")
                    worldArtResults.append((collection, ids))
                }
            }
        }
        
        // Combine all IDs
        var allIDs: [String] = []
        for ids in results {
            allIDs.append(contentsOf: ids)
        }
        
        // Add world art collection IDs
        for (collection, ids) in worldArtResults {
            allIDs.append(contentsOf: ids)
            print("🔵 [MET] 🌍 Added \(ids.count) from \(collection.department.title)")
        }
        
        guard !allIDs.isEmpty else {
            throw URLError(.cannotLoadFromNetwork)
        }
        
        print("🔵 [MET] Total before shuffle: \(allIDs.count)")
        
        // Shuffle and limit - oversample to compensate for invalid IDs
        let targetCount = 2000
        let oversampledCount = Int(Double(targetCount) * oversampleFactor)
        let finalIDs = Array(allIDs.shuffled().prefix(oversampledCount))
        
        print("🔵 [MET] Final count after shuffle/limit: \(finalIDs.count) (oversampled \(oversampleFactor)x)")
        
        if finalIDs.count >= 10 {
            let sample = finalIDs.prefix(10).map { $0.replacingOccurrences(of: "met:", with: "") }
            print("🔵 [MET] Sample IDs (first 10): \(sample.joined(separator: ", "))")
        }
        
        DebugLogger.logProviderSuccess("Met", idCount: finalIDs.count)
        
        return finalIDs
    }
    
    /// Maps user-facing medium filter to Met department IDs
    private func departmentsForMedium(_ medium: String?) -> [Int] {
        guard let medium = medium?.lowercased() else {
            // No filter = all curated departments
            return [9, 11, 19, 21, 1]
        }
        
        switch medium {
        case "paintings":
            // Dept 11: European Paintings, Dept 21: Modern Art, Dept 1: American (paintings)
            return [11, 21, 1]
        case "drawings":
            // Dept 9: Drawings and Prints (includes drawings)
            return [9]
        case "prints":
            // Dept 9: Drawings and Prints (includes prints)
            return [9]
        case "photographs":
            // Dept 19: Photographs
            return [19]
        default:
            return [9, 11, 19, 21, 1]
        }
    }
    
    // MARK: - World Art Collection Fetching
    
    /// Fetches IDs for a world art collection with material filters
    /// Uses search queries within the department to find specific materials
    private func fetchIDsForWorldArtCollection(_ collection: DepartmentMaterialFilter, geo: String?, period: PeriodPreset) async -> [String] {
        print("🔵 [MET] 🌍 Fetching \(collection.department.title) with terms: \(collection.searchTerms.joined(separator: ", "))")
        
        var allIDs: Set<Int> = []
        
        // Search for each material term within the department
        for term in collection.searchTerms {
            var comps = URLComponents(string: "\(base)/search")!
            var items: [URLQueryItem] = [
                .init(name: "hasImages", value: "true"),
                .init(name: "isPublicDomain", value: "true"),
                .init(name: "departmentId", value: String(collection.department.rawValue)),
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
            guard let url = comps.url else {
                print("🔵 [MET] 🌍   → '\(term)': Failed to build URL")
                continue
            }
            
            do {
                let resp: MetSearchResponse = try await fetchJSON(url: url)
                if let ids = resp.objectIDs, !ids.isEmpty {
                    // Oversample from this term's results
                    let oversampledMax = Int(Double(collection.maxIDsPerTerm) * oversampleFactor)
                    let sampled = ids.shuffled().prefix(oversampledMax)
                    print("🔵 [MET] 🌍   → '\(term)': found \(resp.total) total, sampling \(sampled.count) (oversampled)")
                    allIDs.formUnion(sampled)
                } else {
                    print("🔵 [MET] 🌍   → '\(term)': no results")
                }
            } catch {
                print("🔵 [MET] 🌍   → '\(term)': error - \(error.localizedDescription)")
            }
        }
        
        print("🔵 [MET] 🌍 \(collection.department.title): collected \(allIDs.count) unique IDs")
        
        // Show ID range to verify variety
        if let min = allIDs.min(), let max = allIDs.max() {
            print("🔵 [MET] 🌍   → ID range: \(min) to \(max) (span: \(max - min))")
        }
        
        return allIDs.map { "\(providerID):\($0)" }
    }
    
    /// Fetches IDs for a specific department
    private func fetchIDsForDepartment(_ departmentId: Int, query: String, medium: String?, geo: String?, period: PeriodPreset) async -> [String] {
        var comps = URLComponents(string: "\(base)/search")!
        var items: [URLQueryItem] = [
            .init(name: "hasImages", value: "true"),
            .init(name: "isPublicDomain", value: "true"),
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
        if let r = period.yearRange {
            items.append(.init(name: "dateBegin", value: String(r.lowerBound)))
            items.append(.init(name: "dateEnd", value: String(r.upperBound)))
        }

        comps.queryItems = items
        guard let url = comps.url else { return [] }

        do {
            let resp: MetSearchResponse = try await fetchJSON(url: url)
            guard let ids = resp.objectIDs, !ids.isEmpty else {
                print("🔵 [MET] \(departmentName(for: departmentId)) (\(departmentId)): NO RESULTS")
                return []
            }
            
            // BALANCED SAMPLING STRATEGY with oversample compensation:
            let baseMax: Int
            switch departmentId {
            case 19:  // Photographs - boost to ensure good representation
                baseMax = 600
            case 1:   // American Decorative Arts - needs filtering, start with more
                baseMax = 600
            case 9:   // Drawings & Prints - huge collection, keep standard
                baseMax = 500
            case 11:  // European Paintings
                baseMax = 500
            case 21:  // Modern Art
                baseMax = 500
            default:
                baseMax = 500
            }
            
            // Apply oversample factor
            let maxPerDepartment = Int(Double(baseMax) * oversampleFactor)
            
            // For American Decorative Arts, use search queries to filter instead of fetching objects
            if departmentId == 1 {
                return await fetchAmericanDecorativeArtsWithSearch(geo: geo, period: period)
            }
            
            // Take a random sample from this department
            let sampledIDs = ids.shuffled().prefix(maxPerDepartment)
            
            let deptName = departmentName(for: departmentId)
            print("🔵 [MET] \(deptName) (\(departmentId)): found \(resp.total) total, available \(ids.count) IDs, sampling \(sampledIDs.count) (oversampled)")
            
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
        // Check world art departments first
        if let worldArt = WorldArtDepartment(rawValue: id) {
            return worldArt.title
        }
        
        // Then check curated departments
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
                .init(name: "isPublicDomain", value: "true"),
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
        
        // Oversample to compensate for invalid IDs
        let baseMaxCount = 500
        let maxCount = Int(Double(baseMaxCount) * oversampleFactor)
        let sampledIDs = Array(allIDs).shuffled().prefix(maxCount)
        
        print("🔵 [MET] American Decorative Arts (1): Total unique IDs: \(allIDs.count), sampling \(sampledIDs.count) (oversampled)")
        
        return sampledIDs.map { "\(providerID):\($0)" }
    }

    func fetchArtwork(id: String) async throws -> Artwork {
        let raw = id.replacingOccurrences(of: "\(providerID):", with: "")
        guard let intID = Int(raw) else { throw URLError(.badURL) }
        
        // Check validation cache first
        if await validationCache.isKnownInvalid(id) {
            print("🔵 [MET] ⏭️ Skipping known-invalid ID \(intID)")
            throw URLError(.resourceUnavailable)
        }

        guard let url = URL(string: "\(base)/objects/\(intID)") else { throw URLError(.badURL) }
        let obj: MetObject = try await fetchJSON(url: url)

        guard obj.isPublicDomain, let img = obj.bestImageURL else {
            print("🔵 [MET] ❌ Rejected ID \(intID): publicDomain=\(obj.isPublicDomain), hasImage=\(obj.bestImageURL != nil)")
            await validationCache.markInvalid(id)
            throw URLError(.resourceUnavailable)
        }
        
        // Validate year for public domain safety
        if let year = obj.bestYear, year >= publicDomainCutoffYear {
            print("🔵 [MET] ❌ Rejected ID \(intID) from \(year) (must be before \(publicDomainCutoffYear))")
            await validationCache.markInvalid(id)
            throw URLError(.resourceUnavailable)
        }
        
        // Mark as valid for future reference
        await validationCache.markValid(id)

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
        
        // World Art / Decorative Arts - ceramics, textiles, etc.
        if mediumLower.contains("earthenware") ||
           mediumLower.contains("ceramic") ||
           mediumLower.contains("pottery") ||
           mediumLower.contains("terracotta") ||
           mediumLower.contains("stonepaste") ||
           mediumLower.contains("stoneware") {
            return "CERAMIC"
        }
        
        if mediumLower.contains("linen") ||
           mediumLower.contains("textile") ||
           mediumLower.contains("silk") ||
           mediumLower.contains("cotton") ||
           mediumLower.contains("wool") ||
           mediumLower.contains("tapestry") {
            return "TEXTILE"
        }
        
        // Islamic Art department catch-all
        if deptLower.contains("islamic") {
            return "ISLAMIC"
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

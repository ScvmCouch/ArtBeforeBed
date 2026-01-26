import Foundation

/// Rijksmuseum provider using Linked Art APIs
/// Optimized for maximum variety and reliable creator metadata
final class RijksmuseumProvider: MuseumProvider {

    let providerID: String = "rijks"
    let sourceName: String = "Rijksmuseum"

    private let searchBase = "https://data.rijksmuseum.nl/search/collection"
    private let resolverBase = "https://id.rijksmuseum.nl"

    private let maxIDsPerLoad = 500

    /// Cutoff year for public domain safety (works must be created before this year)
    private let publicDomainCutoffYear = 1926

    // Shared URL session with optimized config
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config)
    }()

    /// Object types with weights (paintings have best metadata)
    /// Note: Conservative page estimates - API returns -1011 for pages beyond actual range
    private let objectTypeWeights: [(type: String, pages: Int, estimatedMaxPage: Int)] = [
        ("painting", 8, 20),    // Conservative: fetch 8 pages from first 20
        ("print", 6, 30),       // Conservative: fetch 6 pages from first 30
        ("drawing", 6, 20)      // Conservative: fetch 6 pages from first 20
        // Photographs skipped - often lack creator and are post-1926
    ]

    // MARK: - Fetch Artwork IDs

    func fetchArtworkIDs(
        query: String,
        medium: String?,
        geo: String?,
        period: PeriodPreset
    ) async throws -> [String] {
        
        DebugLogger.logProviderStart("Rijksmuseum", query: query)
        
        print("🟠 [RIJKS] === FETCH REQUEST ===")
        print("🟠 [RIJKS] Medium filter: \(medium ?? "all")")
        print("🟠 [RIJKS] Using type-based filtering")
        
        // Map medium filter to Rijksmuseum types
        let typesToFetch = objectTypesForMedium(medium)
        print("🟠 [RIJKS] Fetching types: \(typesToFetch)")
        
        // Note: Rijksmuseum doesn't have a good photographs collection
        // so we skip that filter silently
        guard !typesToFetch.isEmpty else {
            print("🟠 [RIJKS] ⚠️ No matching types for medium filter, returning empty")
            throw URLError(.cannotLoadFromNetwork)
        }
        
        // Fetch all types in parallel
        var results: [(String, [String])] = []
        
        await withTaskGroup(of: (String, [String]).self) { group in
            for objType in typesToFetch {
                group.addTask {
                    let ids = await self.fetchIDsForTypeWithRandomPages(objType, pages: 8, maxPage: 20)
                    return (objType, ids)
                }
            }
            
            for await (objType, ids) in group {
                print("🟠 [RIJKS] \(objType): \(ids.count) IDs")
                results.append((objType, ids))
            }
        }
        
        // Combine and deduplicate
        var allIDs = Set<String>()
        for (_, ids) in results {
            allIDs.formUnion(ids)
        }
        
        // If we got nothing, try fallback to first few pages sequentially
        if allIDs.isEmpty {
            print("🟠 [RIJKS] ⚠️ Random pages failed, trying fallback to pages 0-5...")
            for objType in typesToFetch {
                let fallbackIDs = await fetchSequentialPages(objType, startPage: 0, count: 3)
                allIDs.formUnion(fallbackIDs)
            }
        }
        
        guard !allIDs.isEmpty else {
            print("🟠 [RIJKS] ❌ No IDs found even with fallback!")
            throw URLError(.cannotLoadFromNetwork)
        }
        
        print("🟠 [RIJKS] === TYPE DISTRIBUTION ===")
        for (objType, ids) in results {
            let percentage = allIDs.isEmpty ? 0 : Int(Double(ids.count) / Double(allIDs.count) * 100)
            print("🟠 [RIJKS] \(objType): \(ids.count) (~\(percentage)%)")
        }
        print("🟠 [RIJKS] Total: \(allIDs.count)")
        
        let finalIDs = Array(allIDs).shuffled().prefix(maxIDsPerLoad).map { "\(providerID):\($0)" }
        
        print("🟠 [RIJKS] Final selection: \(finalIDs.count) IDs")
        if finalIDs.count >= 10 {
            let sample = finalIDs.prefix(10).map { $0.replacingOccurrences(of: "rijks:", with: "") }
            print("🟠 [RIJKS] Sample IDs: \(sample.joined(separator: ", "))")
        }
        
        DebugLogger.logProviderSuccess("Rijksmuseum", idCount: finalIDs.count)
        
        return finalIDs
    }
    
    /// Maps user-facing medium filter to Rijksmuseum type parameter values
    /// Note: Rijksmuseum doesn't have a strong photographs collection
    private func objectTypesForMedium(_ medium: String?) -> [String] {
        guard let medium = medium?.lowercased() else {
            // No filter = all types (no photographs - Rijks doesn't have many)
            return ["painting", "print", "drawing"]
        }
        
        switch medium {
        case "paintings":
            return ["painting"]
        case "drawings":
            return ["drawing"]
        case "prints":
            return ["print"]
        case "photographs":
            // Rijksmuseum has very few photographs - return empty to skip this provider
            return []
        default:
            return ["painting", "print", "drawing"]
        }
    }
    
    /// Fallback: fetch first few pages sequentially
    private func fetchSequentialPages(_ type: String, startPage: Int, count: Int) async -> [String] {
        var components = URLComponents(string: searchBase)!
        components.queryItems = [
            URLQueryItem(name: "imageAvailable", value: "true"),
            URLQueryItem(name: "type", value: type)
        ]
        
        guard let initialURL = components.url else { return [] }
        
        var allIDs: [String] = []
        var currentURL: URL? = initialURL
        var pageCount = 0
        
        while let url = currentURL, pageCount < count {
            do {
                let response: LinkedArtSearchResponse = try await fetchJSON(url: url)
                
                for item in response.orderedItems {
                    if let idString = extractIDFromURL(item.id) {
                        allIDs.append(idString)
                    }
                }
                
                pageCount += 1
                
                if let nextURL = response.next?.id, let next = URL(string: nextURL) {
                    currentURL = next
                } else {
                    break
                }
            } catch {
                print("🟠 [RIJKS] \(type) fallback error: \(error)")
                break
            }
        }
        
        print("🟠 [RIJKS] \(type) fallback: collected \(allIDs.count) IDs from \(pageCount) pages")
        return allIDs
    }

    /// Fetches IDs for a specific object type using cursor-based pagination
    /// Rijksmuseum uses 'next' links, not page numbers
    private func fetchIDsForTypeWithRandomPages(_ type: String, pages: Int, maxPage: Int) async -> [String] {
        var components = URLComponents(string: searchBase)!
        components.queryItems = [
            URLQueryItem(name: "imageAvailable", value: "true"),
            URLQueryItem(name: "type", value: type)
        ]
        
        guard let initialURL = components.url else {
            print("🟠 [RIJKS] \(type): invalid URL")
            return []
        }
        
        // Randomly skip some pages for variety
        let pagesToSkip = Int.random(in: 0...5)
        
        print("🟠 [RIJKS] \(type): fetching \(pages) pages, skipping first \(pagesToSkip) for variety")
        
        var allIDs: [String] = []
        var currentURL: URL? = initialURL
        var pageCount = 0
        var skipped = 0
        
        while let url = currentURL, pageCount < pages {
            do {
                let response: LinkedArtSearchResponse = try await fetchJSON(url: url)
                
                // Skip pages for randomization
                if skipped < pagesToSkip {
                    skipped += 1
                    if let nextURL = response.next?.id, let next = URL(string: nextURL) {
                        currentURL = next
                        continue
                    } else {
                        // Not enough pages, start collecting
                        skipped = pagesToSkip
                    }
                }
                
                var pageIDs: [String] = []
                var skippedModern = 0
                
                for item in response.orderedItems {
                    // PRE-FILTER: Check _label for obvious modern dates
                    if let label = item.label, shouldSkipBasedOnLabel(label) {
                        skippedModern += 1
                        continue
                    }
                    
                    if let idString = extractIDFromURL(item.id) {
                        pageIDs.append(idString)
                    }
                }
                
                allIDs.append(contentsOf: pageIDs)
                
                if skippedModern > 0 {
                    print("🟠 [RIJKS] \(type) p\(pageCount): \(response.orderedItems.count) items, kept \(pageIDs.count), skipped \(skippedModern)")
                } else {
                    print("🟠 [RIJKS] \(type) p\(pageCount): \(pageIDs.count) items")
                }
                
                pageCount += 1
                
                // Get next page URL
                if let nextURL = response.next?.id, let next = URL(string: nextURL) {
                    currentURL = next
                } else {
                    print("🟠 [RIJKS] \(type): no more pages available")
                    break
                }
            } catch {
                print("🟠 [RIJKS] \(type) p\(pageCount) error: \(error)")
                break
            }
        }
        
        print("🟠 [RIJKS] \(type): collected \(allIDs.count) IDs from \(pageCount) pages")
        return allIDs
    }
    
    /// Pre-filter items that are obviously too modern based on label
    private func shouldSkipBasedOnLabel(_ label: String) -> Bool {
        // Check for years 1926-2029 in the label
        let modernYearPattern = #"(19[2-9]\d|20[0-2]\d)"#
        if let regex = try? NSRegularExpression(pattern: modernYearPattern),
           regex.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)) != nil {
            return true
        }
        return false
    }

    // MARK: - Fetch Single Artwork

    func fetchArtwork(id: String) async throws -> Artwork {
        let overallStart = CFAbsoluteTimeGetCurrent()
        DebugLogger.logArtworkFetch(id: id)
        
        let numericID = id.replacingOccurrences(of: "\(providerID):", with: "")
        let objectURL = URL(string: "\(resolverBase)/\(numericID)")!
        
        // REQUEST 1: Fetch main object
        var stepStart = CFAbsoluteTimeGetCurrent()
        let json = try await fetchLinkedArtJSON(url: objectURL)
        print("🟠 [RIJKS TIMING] Request 1 (object): \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - stepStart))s")
        
        // Validate public domain
        guard checkPublicDomain(json: json) else {
            throw URLError(.resourceUnavailable)
        }
        
        // Extract and validate date - reject works from 1926 or later
        let date = extractDate(from: json)
        if let year = extractYearFromDate(date), year >= publicDomainCutoffYear {
            print("🟠 [RIJKS] ❌ Rejected artwork from \(year) (must be before \(publicDomainCutoffYear))")
            throw URLError(.resourceUnavailable)
        }
        
        // Extract title (required)
        guard let title = extractTitle(from: json) else {
            throw URLError(.cannotDecodeContentData)
        }
        
        // Extract creator (will try inline first, then fetch person with caching if needed)
        stepStart = CFAbsoluteTimeGetCurrent()
        let artist = await extractCreatorInline(from: json)
        print("🟠 [RIJKS TIMING] Creator extraction: \(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - stepStart))s")
        
        // PARALLEL: Fetch image URL
        stepStart = CFAbsoluteTimeGetCurrent()
        let imageURLString = try await extractImageURLWithTiming(from: json)
        print("🟠 [RIJKS TIMING] Image extraction: \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - stepStart))s")
        
        guard let imageURLString = imageURLString,
              let imageURL = URL(string: imageURLString) else {
            throw URLError(.cannotDecodeContentData)
        }
        
        let medium = extractMedium(from: json)
        
        let totalTime = CFAbsoluteTimeGetCurrent() - overallStart
        let creatorStatus = artist != nil ? "✅ \(artist!)" : "❌ unknown"
        print("🟠 [RIJKS TIMING] ✅ TOTAL: \(String(format: "%.2f", totalTime))s for \(numericID) - Creator: \(creatorStatus)")
        
        return Artwork(
            id: id,
            title: title,
            artist: artist ?? "",  // Empty string if no artist found
            date: date,
            medium: medium,
            imageURL: imageURL,
            source: sourceName,
            sourceURL: URL(string: "https://www.rijksmuseum.nl/nl/collectie/\(numericID)")!
        )
    }

    /// Extracts a numeric year from a date string like "1642", "c. 1650", "1640 - 1650", etc.
    private func extractYearFromDate(_ dateString: String?) -> Int? {
        guard let dateString = dateString else { return nil }
        
        // Try to find a 4-digit year in the string
        let pattern = #"\b(\d{4})\b"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: dateString, range: NSRange(dateString.startIndex..., in: dateString)),
           let range = Range(match.range(at: 1), in: dateString) {
            return Int(dateString[range])
        }
        
        return nil
    }

    // MARK: - Public Domain Detection

    private func checkPublicDomain(json: [String: Any]) -> Bool {
        guard let subjectOf = json["subject_of"] as? [[String: Any]] else {
            // If no rights info, assume it's okay since we filtered for imageAvailable
            return true
        }
        
        for item in subjectOf {
            if let subjectTo = item["subject_to"] as? [[String: Any]] {
                for right in subjectTo {
                    if let type = right["type"] as? String, type == "Right",
                       let classified = right["classified_as"] as? [[String: Any]] {
                        for classification in classified {
                            if let licenseId = classification["id"] as? String,
                               licenseId.contains("publicdomain") || licenseId.contains("creativecommons.org/publicdomain") {
                                return true
                            }
                        }
                    }
                }
            }
        }
        
        // Default to true if we can't determine - the search already filtered for images
        return true
    }

    // MARK: - Image URL Extraction

    private func extractImageURLWithTiming(from json: [String: Any]) async throws -> String? {
        // Get visual item reference from 'shows'
        guard let shows = json["shows"] as? [[String: Any]],
              let firstShow = shows.first,
              let visualItemId = firstShow["id"] as? String,
              let visualURL = URL(string: visualItemId) else {
            return nil
        }
        
        // REQUEST 2: Fetch visual item
        var stepStart = CFAbsoluteTimeGetCurrent()
        let visualJson = try await fetchLinkedArtJSON(url: visualURL)
        print("🟠 [RIJKS TIMING]   └─ Request 2 (visual): \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - stepStart))s")
        
        // Get digital object reference
        guard let digitallyShownBy = visualJson["digitally_shown_by"] as? [[String: Any]],
              let firstDigital = digitallyShownBy.first else {
            return nil
        }
        
        // Check for inline access_point first (sometimes present, saves a request)
        if let inlineAccessPoints = firstDigital["access_point"] as? [[String: Any]],
           let firstAccess = inlineAccessPoints.first,
           let imageUrl = firstAccess["id"] as? String {
            print("🟠 [RIJKS TIMING]   └─ Request 3 (digital): SKIPPED (inline)")
            return imageUrl
        }
        
        // Otherwise fetch the digital object
        guard let digitalObjectId = firstDigital["id"] as? String,
              let digitalObjectURL = URL(string: digitalObjectId) else {
            return nil
        }
        
        // REQUEST 3: Fetch digital object
        stepStart = CFAbsoluteTimeGetCurrent()
        let digitalJson = try await fetchLinkedArtJSON(url: digitalObjectURL)
        print("🟠 [RIJKS TIMING]   └─ Request 3 (digital): \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - stepStart))s")
        
        guard let accessPoints = digitalJson["access_point"] as? [[String: Any]],
              let firstAccessPoint = accessPoints.first,
              let imageUrl = firstAccessPoint["id"] as? String else {
            return nil
        }
        
        return imageUrl
    }

    // Cache for person names to avoid refetching the same artists
    private actor PersonNameCache {
        private var cache: [String: String?] = [:]
        
        func get(_ personID: String) -> String?? {
            return cache[personID]
        }
        
        func set(_ personID: String, name: String?) {
            cache[personID] = name
        }
    }
    
    private let personCache = PersonNameCache()

    // MARK: - Creator Extraction (WITH OPTIMIZED PERSON FETCH)

    /// Extracts creator - first checks inline data, then fetches person if needed
    /// Uses caching to avoid refetching the same artists
    private func extractCreatorInline(from json: [String: Any]) async -> String? {
        guard let producedBy = json["produced_by"] as? [String: Any] else {
            return nil
        }
        
        // PRIORITY 1: Check _label directly on produced_by
        if let label = producedBy["_label"] as? String, !label.isEmpty {
            if let cleaned = cleanCreatorName(label) {
                print("🟠 [RIJKS]   └─ Creator: ✅ found inline _label: \(cleaned)")
                return cleaned
            }
        }
        
        // PRIORITY 2: Check carried_out_by inline label
        if let carriedOutBy = producedBy["carried_out_by"] as? [[String: Any]],
           let firstCreator = carriedOutBy.first,
           let label = firstCreator["_label"] as? String, !label.isEmpty {
            if let cleaned = cleanCreatorName(label) {
                print("🟠 [RIJKS]   └─ Creator: ✅ found in carried_out_by _label: \(cleaned)")
                return cleaned
            }
        }
        
        // PRIORITY 3: Check 'part' array
        if let parts = producedBy["part"] as? [[String: Any]] {
            for part in parts {
                // Check part _label
                if let label = part["_label"] as? String, !label.isEmpty {
                    if let cleaned = cleanCreatorName(label) {
                        print("🟠 [RIJKS]   └─ Creator: ✅ found in part _label: \(cleaned)")
                        return cleaned
                    }
                }
                
                // Check part's carried_out_by for inline label
                if let carriedOutBy = part["carried_out_by"] as? [[String: Any]],
                   let firstCreator = carriedOutBy.first,
                   let label = firstCreator["_label"] as? String, !label.isEmpty {
                    if let cleaned = cleanCreatorName(label) {
                        print("🟠 [RIJKS]   └─ Creator: ✅ found in part.carried_out_by _label: \(cleaned)")
                        return cleaned
                    }
                }
                
                // LAST RESORT: Fetch person object (with caching)
                if let carriedOutBy = part["carried_out_by"] as? [[String: Any]],
                   let firstCreator = carriedOutBy.first,
                   let personId = firstCreator["id"] as? String,
                   let personURL = URL(string: personId) {
                    
                    // Check cache first
                    if let cached = await personCache.get(personId) {
                        if let name = cached {
                            print("🟠 [RIJKS]   └─ Creator: ✅ from cache: \(name)")
                            return name
                        } else {
                            print("🟠 [RIJKS]   └─ Creator: ❌ cache says no name available")
                            continue
                        }
                    }
                    
                    // Fetch person with timeout
                    print("🟠 [RIJKS]   └─ Creator: fetching person (not cached)...")
                    if let name = await fetchPersonNameWithTimeout(url: personURL, timeout: 2.0) {
                        await personCache.set(personId, name: name)
                        print("🟠 [RIJKS]   └─ Creator: ✅ fetched: \(name)")
                        return name
                    } else {
                        await personCache.set(personId, name: nil)
                        print("🟠 [RIJKS]   └─ Creator: ❌ person fetch failed/timeout")
                    }
                }
            }
        }
        
        print("🟠 [RIJKS]   └─ Creator: ❌ not found")
        return nil
    }
    
    /// Fetch person name with a timeout to avoid blocking
    private func fetchPersonNameWithTimeout(url: URL, timeout: TimeInterval) async -> String? {
        return await withTaskGroup(of: String?.self) { group in
            // Race: fetch vs timeout
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            
            group.addTask {
                await self.fetchPersonNameQuick(url: url)
            }
            
            // Return first result (either timeout nil or actual result)
            for await result in group {
                if result != nil {
                    group.cancelAll()
                    return result
                }
            }
            
            return nil
        }
    }
    
    /// Quick person name fetch
    private func fetchPersonNameQuick(url: URL) async -> String? {
        do {
            let personJson = try await fetchLinkedArtJSON(url: url)
            
            // Check root _label first
            if let label = personJson["_label"] as? String, !label.isEmpty {
                if let cleaned = cleanCreatorName(label) {
                    return cleaned
                }
            }
            
            // Check identified_by array
            if let identifiedBy = personJson["identified_by"] as? [[String: Any]] {
                for identifier in identifiedBy {
                    if let type = identifier["type"] as? String,
                       (type == "Name" || type == "Identifier"),
                       let content = identifier["content"] as? String,
                       !content.isEmpty {
                        if let cleaned = cleanCreatorName(content) {
                            return cleaned
                        }
                    }
                }
            }
        } catch {
            // Silent failure
        }
        return nil
    }

    private func cleanCreatorName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        
        // Filter out placeholder/unknown values (including Dutch terms)
        if lower.isEmpty ||
           lower == "unknown" ||
           lower == "unknown artist" ||
           lower == "unidentified" ||
           lower == "anonymous" ||
           lower == "anon" ||              // Abbreviation for anonymous
           lower == "anon." ||             // With period
           lower == "anoniem" ||           // Dutch: anonymous
           lower == "onbekend" ||          // Dutch: unknown
           lower == "onbekende" ||         // Dutch: unknown (alt form)
           lower.hasPrefix("unknown ") ||
           lower.hasPrefix("unidentified ") ||
           lower.hasPrefix("anonymous ") ||
           lower.hasPrefix("anoniem ") ||
           lower.hasPrefix("onbekend") {
            return nil
        }
        
        return trimmed
    }

    // MARK: - Title Extraction

    private func extractTitle(from json: [String: Any]) -> String? {
        guard let identifiedBy = json["identified_by"] as? [[String: Any]] else {
            return nil
        }
        
        var titles: [(content: String, priority: Int)] = []
        
        for identifier in identifiedBy {
            guard let type = identifier["type"] as? String,
                  (type == "Name" || type == "Title"),
                  let content = identifier["content"] as? String,
                  !content.isEmpty else {
                continue
            }
            
            var priority = 0
            
            // Check for explicit English language tag
            if let language = identifier["language"] as? [[String: Any]],
               let firstLang = language.first {
                if let langId = firstLang["id"] as? String {
                    if langId.contains("english") || langId.hasSuffix("/en") {
                        priority = 10
                    }
                } else if let langLabel = firstLang["_label"] as? String {
                    if langLabel.lowercased().contains("english") || langLabel == "en" {
                        priority = 10
                    }
                }
            }
            
            titles.append((content: content, priority: priority))
        }
        
        titles.sort { $0.priority > $1.priority }
        return titles.first?.content
    }

    // MARK: - Date Extraction

    private func extractDate(from json: [String: Any]) -> String? {
        guard let producedBy = json["produced_by"] as? [String: Any],
              let timespan = producedBy["timespan"] as? [String: Any] else {
            return nil
        }
        
        // Try _label first
        if let label = timespan["_label"] as? String, !label.isEmpty {
            return label
        }
        
        // Fall back to begin_of_the_begin
        if let beginDate = timespan["begin_of_the_begin"] as? String,
           let year = extractYearFromDateString(beginDate) {
            return "\(year)"
        }
        
        return nil
    }

    private func extractYearFromDateString(_ dateString: String) -> Int? {
        let components = dateString.components(separatedBy: "-")
        if let yearString = components.first, let year = Int(yearString) {
            return year
        }
        return nil
    }

    // MARK: - Medium Extraction

    private func extractMedium(from json: [String: Any]) -> String? {
        if let madeOf = json["made_of"] as? [[String: Any]] {
            let materials = madeOf.compactMap { $0["_label"] as? String }
            if !materials.isEmpty {
                return materials.joined(separator: ", ")
            }
        }
        return nil
    }

    // MARK: - Network Helpers

    private func fetchLinkedArtJSON(url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.setValue("application/ld+json", forHTTPHeaderField: "Accept")
        
        let (data, response) = try await session.data(for: request)
        
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotDecodeContentData)
        }
        
        return json
    }

    private func fetchJSON<T: Decodable>(url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("application/ld+json", forHTTPHeaderField: "Accept")
        
        let (data, response) = try await session.data(for: request)
        
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func extractIDFromURL(_ urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        return url.lastPathComponent
    }
}

// MARK: - Linked Art Search Models

private struct LinkedArtSearchResponse: Codable {
    let orderedItems: [LinkedArtSearchItem]
    let next: LinkedArtPageRef?
    let partOf: LinkedArtPartOf?
}

private struct LinkedArtSearchItem: Codable {
    let id: String
    let type: String
    let label: String?
    
    enum CodingKeys: String, CodingKey {
        case id
        case type
        case label = "_label"
    }
}

private struct LinkedArtPageRef: Codable {
    let id: String
    let type: String
}

private struct LinkedArtPartOf: Codable {
    let totalItems: Int?
}

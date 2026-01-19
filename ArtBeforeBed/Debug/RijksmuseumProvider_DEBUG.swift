import Foundation

/// Rijksmuseum provider with public domain filtering
final class RijksmuseumProvider: MuseumProvider {
    
    let providerID: String = "rijks"
    let sourceName: String = "Rijksmuseum"
    
    private let searchBase = "https://data.rijksmuseum.nl/search/collection"
    private let resolverBase = "https://id.rijksmuseum.nl"
    
    private let maxIDsPerLoad = 500
    
    func fetchArtworkIDs(
        query: String,
        medium: String?,
        geo: String?,
        period: PeriodPreset
    ) async throws -> [String] {
        
        DebugLogger.logProviderStart("Rijksmuseum", query: query)
        
        var components = URLComponents(string: searchBase)!
        var queryItems: [URLQueryItem] = []
        
        queryItems.append(URLQueryItem(name: "type", value: "painting"))
        queryItems.append(URLQueryItem(name: "imageAvailable", value: "true"))
        
        components.queryItems = queryItems
        guard let searchURL = components.url else {
            throw URLError(.badURL)
        }
        
        var allIDs: Set<String> = []
        var currentURL: URL? = searchURL
        var pageCount = 0
        let maxPages = 5
        
        while let url = currentURL, pageCount < maxPages, allIDs.count < maxIDsPerLoad {
            let response: LinkedArtSearchResponse = try await fetchJSON(url: url)
            
            for item in response.orderedItems {
                if let idString = extractIDFromURL(item.id) {
                    allIDs.insert(idString)
                }
            }
            
            if let nextURL = response.next?.id,
               let url = URL(string: nextURL) {
                currentURL = url
                pageCount += 1
            } else {
                break
            }
        }
        
        guard !allIDs.isEmpty else {
            throw URLError(.cannotLoadFromNetwork)
        }
        
        let finalIDs = Array(allIDs).shuffled().prefix(maxIDsPerLoad).map { "\(providerID):\($0)" }
        DebugLogger.logProviderSuccess("Rijksmuseum", idCount: finalIDs.count)
        
        return finalIDs
    }
    
    func fetchArtwork(id: String) async throws -> Artwork {
        DebugLogger.logArtworkFetch(id: id)
        
        let numericID = id.replacingOccurrences(of: "\(providerID):", with: "")
        let objectURL = URL(string: "\(resolverBase)/\(numericID)")!
        
        var request = URLRequest(url: objectURL)
        request.timeoutInterval = 30
        request.setValue("application/ld+json", forHTTPHeaderField: "Accept")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotDecodeContentData)
        }
        
        // Check if this is a public domain work
        guard checkPublicDomain(json: json) else {
            throw URLError(.resourceUnavailable)
        }
        
        // Extract artwork information
        guard let title = extractTitle(from: json) else {
            throw URLError(.cannotDecodeContentData)
        }
        
        // Get the visual item to extract image URL
        guard let imageURLString = try await extractImageURL(from: json),
              let imageURL = URL(string: imageURLString) else {
            throw URLError(.cannotDecodeContentData)
        }
        
        let artist = await extractCreator(from: json) ?? "Unknown Artist"
        let date = extractYear(from: json).map { "\($0)" }
        
        return Artwork(
            id: id,
            title: title,
            artist: artist,
            date: date,
            medium: nil,
            imageURL: imageURL,
            source: sourceName,
            sourceURL: URL(string: "https://www.rijksmuseum.nl/nl/collectie/\(numericID)")!
        )
    }
    
    // MARK: - Public Domain Detection
    
    /// Checks if artwork is in public domain based on Linked Art structure
    /// The public domain info is in subject_of -> subject_to -> classified_as
    private func checkPublicDomain(json: [String: Any]) -> Bool {
        guard let subjectOf = json["subject_of"] as? [[String: Any]] else {
            return false
        }
        
        for item in subjectOf {
            // Look for 'subject_to' field which contains rights information
            if let subjectTo = item["subject_to"] as? [[String: Any]] {
                for right in subjectTo {
                    // Check if this is a Right type
                    if let type = right["type"] as? String, type == "Right" {
                        // Check classified_as for the license URL
                        if let classified = right["classified_as"] as? [[String: Any]] {
                            for classification in classified {
                                if let licenseId = classification["id"] as? String {
                                    // Check for public domain licenses
                                    if licenseId.contains("creativecommons.org/publicdomain/zero") ||
                                       licenseId.contains("creativecommons.org/publicdomain/mark") ||
                                       licenseId.contains("publicdomain") {
                                        return true
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        
        return false
    }
    
    // MARK: - Data Extraction Methods
    
    /// Extracts the high-resolution image URL from the visual item
    private func extractImageURL(from json: [String: Any]) async throws -> String? {
        // Get the visual item ID from 'shows'
        guard let shows = json["shows"] as? [[String: Any]],
              let firstShow = shows.first,
              let visualItemId = firstShow["id"] as? String,
              let visualURL = URL(string: visualItemId) else {
            return nil
        }
        
        // Fetch the visual item to get the digital object reference
        var request = URLRequest(url: visualURL)
        request.timeoutInterval = 30
        request.setValue("application/ld+json", forHTTPHeaderField: "Accept")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return nil
        }
        
        guard let visualJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        
        // Get the digital object ID from digitally_shown_by
        guard let digitallyShownBy = visualJson["digitally_shown_by"] as? [[String: Any]],
              let firstDigital = digitallyShownBy.first,
              let digitalObjectId = firstDigital["id"] as? String,
              let digitalObjectURL = URL(string: digitalObjectId) else {
            return nil
        }
        
        // Fetch the digital object to get the access point
        var digitalRequest = URLRequest(url: digitalObjectURL)
        digitalRequest.timeoutInterval = 30
        digitalRequest.setValue("application/ld+json", forHTTPHeaderField: "Accept")
        
        let (digitalData, digitalResponse) = try await URLSession.shared.data(for: digitalRequest)
        
        guard let digitalHttp = digitalResponse as? HTTPURLResponse, (200...299).contains(digitalHttp.statusCode) else {
            return nil
        }
        
        guard let digitalJson = try? JSONSerialization.jsonObject(with: digitalData) as? [String: Any] else {
            return nil
        }
        
        // Extract the image URL from access_point
        guard let accessPoints = digitalJson["access_point"] as? [[String: Any]],
              let firstAccessPoint = accessPoints.first,
              let imageUrl = firstAccessPoint["id"] as? String else {
            return nil
        }
        
        return imageUrl
    }
    
    /// Extracts title from Linked Art JSON
    private func extractTitle(from json: [String: Any]) -> String? {
        guard let identifiedBy = json["identified_by"] as? [[String: Any]] else {
            return nil
        }
        
        var titles: [(content: String, isEnglish: Bool)] = []
        
        for identifier in identifiedBy {
            if let type = identifier["type"] as? String,
               (type == "Name" || type == "Title"),
               let content = identifier["content"] as? String {
                
                // Try to determine if it's English
                var isEnglish = false
                
                // Check explicit language field
                if let language = identifier["language"] as? [[String: Any]],
                   let firstLang = language.first,
                   let langLabel = firstLang["_label"] as? String {
                    isEnglish = langLabel.lowercased().contains("english") || langLabel == "en"
                } else {
                    // Heuristic: check for English keywords
                    let lowerContent = content.lowercased()
                    
                    // English indicators
                    let englishWords = ["portrait of", "landscape", "view of", "still life",
                                       "the ", "with the", "and the", "scene", "allegory"]
                    // Dutch indicators
                    let dutchWords = ["van de", "van een", "met de", "het ", "de ",
                                     "stilleven", "portret van", "gezicht"]
                    
                    let hasEnglish = englishWords.contains { lowerContent.contains($0) }
                    let hasDutch = dutchWords.contains { lowerContent.contains($0) }
                    
                    // If has English keywords but not Dutch, likely English
                    isEnglish = hasEnglish && !hasDutch
                }
                
                titles.append((content: content, isEnglish: isEnglish))
            }
        }
        
        // Prefer English titles
        if let englishTitle = titles.first(where: { $0.isEnglish }) {
            return englishTitle.content
        }
        
        // Fallback to any title
        return titles.first?.content
    }
    
    /// Extracts creator from Linked Art JSON
    private func extractCreator(from json: [String: Any]) async -> String? {
        guard let producedBy = json["produced_by"] as? [String: Any] else {
            return nil
        }
        
        // First try carried_out_by at top level (standard location)
        if let carriedOutBy = producedBy["carried_out_by"] as? [[String: Any]] {
            if let firstCreator = carriedOutBy.first {
                // If we have a _label, use it directly
                if let label = firstCreator["_label"] as? String {
                    return label
                }
                // Otherwise fetch the person object
                if let personId = firstCreator["id"] as? String {
                    return await fetchPersonName(personId: personId)
                }
            }
        }
        
        // Try the 'part' array (Rijksmuseum structure)
        if let parts = producedBy["part"] as? [[String: Any]] {
            for part in parts {
                if let carriedOutBy = part["carried_out_by"] as? [[String: Any]],
                   let firstCreator = carriedOutBy.first {
                    // If we have a _label, use it directly
                    if let label = firstCreator["_label"] as? String {
                        return label
                    }
                    // Otherwise fetch the person object
                    if let personId = firstCreator["id"] as? String {
                        return await fetchPersonName(personId: personId)
                    }
                }
            }
        }
        
        return nil
    }
    
    /// Fetches the person's name from their Person object
    private func fetchPersonName(personId: String) async -> String? {
        guard let personURL = URL(string: personId) else {
            return nil
        }
        
        var request = URLRequest(url: personURL)
        request.timeoutInterval = 30
        request.setValue("application/ld+json", forHTTPHeaderField: "Accept")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            
            guard let personJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            
            // Look for the person's name in identified_by
            if let identifiedBy = personJson["identified_by"] as? [[String: Any]] {
                for identifier in identifiedBy {
                    if let type = identifier["type"] as? String,
                       (type == "Name" || type == "Title"),
                       let content = identifier["content"] as? String {
                        // Found a name
                        return content
                    }
                }
            }
            
            // Fallback: check for _label at root
            if let label = personJson["_label"] as? String {
                return label
            }
            
        } catch {
            return nil
        }
        
        return nil
    }
    
    /// Extracts year from production timespan
    private func extractYear(from json: [String: Any]) -> Int? {
        guard let producedBy = json["produced_by"] as? [String: Any],
              let timespan = producedBy["timespan"] as? [String: Any] else {
            return nil
        }
        
        // Try to get begin_of_the_begin or end_of_the_end
        if let beginDate = timespan["begin_of_the_begin"] as? String {
            return extractYearFromDateString(beginDate)
        }
        if let endDate = timespan["end_of_the_end"] as? String {
            return extractYearFromDateString(endDate)
        }
        
        return nil
    }
    
    /// Extracts year from ISO date string
    private func extractYearFromDateString(_ dateString: String) -> Int? {
        // Date format is typically "YYYY-MM-DD" or just "YYYY"
        let components = dateString.components(separatedBy: "-")
        if let yearString = components.first,
           let year = Int(yearString) {
            return year
        }
        return nil
    }
    
    // MARK: - Helpers
    
    private func extractIDFromURL(_ urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        return url.lastPathComponent
    }
    
    private func fetchJSON<T: Decodable>(url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/ld+json", forHTTPHeaderField: "Accept")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Linked Art Search Models

private struct LinkedArtSearchResponse: Codable {
    let orderedItems: [LinkedArtSearchItem]
    let next: LinkedArtPageRef?
}

private struct LinkedArtSearchItem: Codable {
    let id: String
    let type: String
}

private struct LinkedArtPageRef: Codable {
    let id: String
    let type: String
}

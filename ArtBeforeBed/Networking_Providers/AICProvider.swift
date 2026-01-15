import Foundation

/// Art Institute of Chicago (AIC) provider
/// Public domain enforcement:
/// - Search filter: query[term][is_public_domain]=true
/// - Detail check: is_public_domain == true
final class AICProvider: MuseumProvider {

    let providerID: String = "aic"
    let sourceName: String = "Art Institute of Chicago"

    private let base = "https://api.artic.edu/api/v1"
    private let maxIDsPerLoad = 400

    // Courtesy header recommended by AIC: "AIC-User-Agent"
    private let userAgentValue = "ArtBeforeBed (contact: markobrien)"

    func fetchArtworkIDs(
        query: String,
        medium: String?,
        geo: String?,
        period: PeriodPreset
    ) async throws -> [String] {

        let q = buildQueryString(base: query, medium: medium, geo: geo, period: period)

        // 1) Always do a safe first request on page 1 to learn total_pages.
        let firstURL = try makeSearchURL(q: q, page: 1, limit: 100)
        let firstResp: AICSearchResponse = try await fetchJSON(url: firstURL)

        let totalPages = max(1, firstResp.pagination?.total_pages ?? 1)

        // Choose a random *valid* start page (cap randomness so we don't go deep)
        let maxRandomPage = min(totalPages, 25)
        var page = Int.random(in: 1...maxRandomPage)

        var all: [Int] = []
        var seenPages = 0

        // We'll keep walking forward from that valid page.
        // If we hit end, we stop.
        while all.count < maxIDsPerLoad {
            let url = try makeSearchURL(q: q, page: page, limit: 100)

            let resp: AICSearchResponse
            do {
                resp = try await fetchJSON(url: url)
            } catch {
                // If random page somehow fails, fall back to page 1 once.
                if page != 1 && seenPages == 0 {
                    page = 1
                    continue
                }
                throw error
            }

            let ids = resp.data.map { $0.id }
            if ids.isEmpty { break }

            all.append(contentsOf: ids)

            seenPages += 1
            page += 1

            // Stop at end
            if let tp = resp.pagination?.total_pages,
               let cp = resp.pagination?.current_page,
               cp >= tp {
                break
            }

            // Safety stop to avoid looping too long
            if seenPages >= 8 { break } // 8 pages * 100 = 800 IDs max gathered before dedupe
        }

        let unique = Array(Set(all)).shuffled()
        return unique.prefix(maxIDsPerLoad).map { "\(providerID):\($0)" }
    }

    func fetchArtwork(id: String) async throws -> Artwork {
        let raw = id.replacingOccurrences(of: "\(providerID):", with: "")
        guard let artworkID = Int(raw) else {
            throw URLError(.badURL)
        }

        let fields = [
            "id",
            "title",
            "artist_display",
            "date_display",
            "medium_display",
            "image_id",
            "is_public_domain"
        ].joined(separator: ",")

        guard var comps = URLComponents(string: "\(base)/artworks/\(artworkID)") else {
            throw URLError(.badURL)
        }
        comps.queryItems = [
            URLQueryItem(name: "fields", value: fields)
        ]
        guard let url = comps.url else {
            throw URLError(.badURL)
        }

        let resp: AICArtworkResponse = try await fetchJSON(url: url)
        let a = resp.data

        // Strict enforcement: public domain only
        guard a.is_public_domain == true else {
            throw URLError(.cannotDecodeContentData)
        }

        guard let imageID = a.image_id, !imageID.isEmpty else {
            throw URLError(.resourceUnavailable)
        }

        // IIIF base from config, with a safe fallback.
        let iiifBase = resp.config?.iiif_url ?? "https://www.artic.edu/iiif/2"
        let imageURLString = "\(iiifBase)/\(imageID)/full/843,/0/default.jpg"
        guard let imageURL = URL(string: imageURLString) else {
            throw URLError(.badURL)
        }

        let sourceURL = URL(string: "https://www.artic.edu/artworks/\(artworkID)")

        return Artwork(
            id: id,
            title: (a.title ?? "").nilIfEmpty ?? "Untitled",
            artist: (a.artist_display ?? "").nilIfEmpty ?? "Unknown artist",
            date: (a.date_display ?? "").nilIfEmpty,
            medium: (a.medium_display ?? "").nilIfEmpty,
            imageURL: imageURL,
            source: sourceName,
            sourceURL: sourceURL
        )
    }

    // MARK: - Helpers

    private func buildQueryString(base: String, medium: String?, geo: String?, period: PeriodPreset) -> String {
        var parts: [String] = [base]
        if let medium, !medium.isEmpty { parts.append(medium) }
        if let geo, !geo.isEmpty { parts.append(geo) }
        _ = period
        return parts.joined(separator: " ")
    }

    private func makeSearchURL(q: String, page: Int, limit: Int) throws -> URL {
        guard var comps = URLComponents(string: "\(base)/artworks/search") else {
            throw URLError(.badURL)
        }

        comps.queryItems = [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "query[term][is_public_domain]", value: "true"),
            URLQueryItem(name: "fields", value: "id"),
            URLQueryItem(name: "page", value: String(max(1, page))),
            URLQueryItem(name: "limit", value: String(min(limit, 100)))
        ]

        guard let url = comps.url else {
            throw URLError(.badURL)
        }
        return url
    }

    private func fetchJSON<T: Decodable>(url: URL) async throws -> T {
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue(userAgentValue, forHTTPHeaderField: "AIC-User-Agent")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            // This will surface as -1011; caller/repository now handles it gracefully.
            throw URLError(.badServerResponse)
        }

        return try JSONDecoder().decode(T.self, from: data)
    }
}

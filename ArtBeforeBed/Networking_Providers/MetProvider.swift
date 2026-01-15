import Foundation

final class MetProvider: MuseumProvider {

    let providerID: String = "met"
    let sourceName: String = "The Met"

    private let base = "https://collectionapi.metmuseum.org/public/collection/v1"

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
        let country: String?
        let culture: String?
        let objectBeginDate: Int?
        let objectEndDate: Int?
        let objectURL: String?

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
        var comps = URLComponents(string: "\(base)/search")!
        var items: [URLQueryItem] = [
            .init(name: "q", value: query.isEmpty ? "painting" : query),
            .init(name: "hasImages", value: "true")
        ]

        if let medium, !medium.isEmpty {
            items.append(.init(name: "medium", value: medium))
        }

        if let geo, !geo.isEmpty {
            items.append(.init(name: "geoLocation", value: geo))
        }

        if let r = period.yearRange {
            items.append(.init(name: "dateBegin", value: String(r.lowerBound)))
            items.append(.init(name: "dateEnd", value: String(r.upperBound)))
        }

        comps.queryItems = items
        guard let url = comps.url else { throw URLError(.badURL) }

        let resp: MetSearchResponse = try await fetchJSON(url: url)
        guard let ids = resp.objectIDs, !ids.isEmpty else { throw URLError(.cannotLoadFromNetwork) }

        return ids.prefix(2000).map { "\(providerID):\($0)" }
    }

    func fetchArtwork(id: String) async throws -> Artwork {
        let raw = id.replacingOccurrences(of: "\(providerID):", with: "")
        guard let intID = Int(raw) else { throw URLError(.badURL) }

        guard let url = URL(string: "\(base)/objects/\(intID)") else { throw URLError(.badURL) }
        let obj: MetObject = try await fetchJSON(url: url)

        guard obj.isPublicDomain, let img = obj.bestImageURL else {
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
        if let credit = obj.creditLine?.nilIfEmpty { debug["creditLine"] = credit }
        if let m = obj.medium?.nilIfEmpty { debug["medium_raw"] = m }
        if let c = obj.country?.nilIfEmpty { debug["country"] = c }
        if let cul = obj.culture?.nilIfEmpty { debug["culture"] = cul }
        if let y = obj.bestYear { debug["year"] = "\(y)" }

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

    private func fetchJSON<T: Decodable>(url: URL) async throws -> T {
        var req = URLRequest(url: url)
        req.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        return try JSONDecoder().decode(T.self, from: data)
    }
}

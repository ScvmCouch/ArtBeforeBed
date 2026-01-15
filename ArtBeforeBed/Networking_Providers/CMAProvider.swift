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
        var comps = URLComponents(string: "\(base)/artworks/")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "cc0", value: ""),
            URLQueryItem(name: "has_image", value: "1"),
            URLQueryItem(name: "limit", value: "1000"),
            URLQueryItem(name: "skip", value: String(Int.random(in: 0...8000)))
        ]

        var qParts: [String] = []
        if !query.isEmpty { qParts.append(query) }
        if let medium, !medium.isEmpty { qParts.append(medium) }
        if let geo, !geo.isEmpty { qParts.append(geo) }
        _ = period

        if !qParts.isEmpty {
            items.append(URLQueryItem(name: "q", value: qParts.joined(separator: " ")))
        }

        comps.queryItems = items
        guard let url = comps.url else { throw URLError(.badURL) }

        let resp: CMASearchResponse = try await fetchJSON(url: url)
        let ids = resp.data.map { $0.id }
        guard !ids.isEmpty else { throw URLError(.cannotLoadFromNetwork) }

        return Array(ids.prefix(maxIDsPerLoad)).map { "\(providerID):\($0)" }
    }

    func fetchArtwork(id: String) async throws -> Artwork {
        let raw = id.replacingOccurrences(of: "\(providerID):", with: "")
        guard let intID = Int(raw) else { throw URLError(.badURL) }

        guard let url = URL(string: "\(base)/artworks/\(intID)") else { throw URLError(.badURL) }

        let resp: CMAArtworkResponse = try await fetchJSON(url: url)
        let a = resp.data

        if let status = a.share_license_status?.uppercased(), status != "CC0" {
            throw URLError(.resourceUnavailable)
        }

        let imageURLString =
            a.images?.web?.url ??
            a.images?.print?.url ??
            a.images?.full?.url

        guard let imageURLString, let imageURL = URL(string: imageURLString) else {
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
            throw URLError(.resourceUnavailable)
        }

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

        // 0) Specific series that flood results (surgical)
        // Add to this list only when you see repeats dominating.
        let seriesTitleBlocks = [
            "tuti-nama",      // Tales of a Parrot (your example)
            "tutinama"
        ]
        if seriesTitleBlocks.contains(where: { t.contains($0) }) {
            return true
        }

        // 1) Type-based "book object" block
        if ty.contains("bound volume") {
            return true
        }

        // 2) Technique/material markers for pages/books/scrolls
        let techniqueBlocks = [
            "palm leaves", "palm leaf", "on palm",
            "vellum", "parchment",
            "handscroll", "scroll", "album", "codex", "manuscript",
            "sutra", "prayerbook", "prayer book"
        ]
        if techniqueBlocks.contains(where: { tech.contains($0) }) {
            return true
        }

        // 3) Title markers for folios/pages/manuscripts
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

        // 4) Department blocks (only explicit archival-style depts)
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
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        return try JSONDecoder().decode(T.self, from: data)
    }
}

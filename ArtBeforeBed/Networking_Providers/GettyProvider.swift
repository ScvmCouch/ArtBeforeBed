import Foundation

final class GettyProvider: MuseumProvider {

    let providerID: String = "getty"
    let sourceName: String = "J. Paul Getty Museum"

    // Getty SPARQL endpoint (for discovering object UUIDs)
    private let sparqlEndpoint = URL(string: "https://data.getty.edu/museum/collection/sparql")!

    // IIIF manifests live here:
    // https://data.getty.edu/museum/api/iiif/<uuid>/manifest.json
    private let iiifBase = "https://data.getty.edu/museum/api/iiif"

    // Tune these for speed vs pool size
    private let desiredIDsPerBuild = 220
    private let sparqlBatchSize = 120
    private let maxSparqlRounds = 10

    func fetchArtworkIDs(
        query: String,
        medium: String?,
        geo: String?,
        period: PeriodPreset
    ) async throws -> [String] {

        // Getty: we are not applying query/medium/geo/period yet.
        // The goal here is: return a solid CC0 image pool.
        _ = query
        _ = medium
        _ = geo
        _ = period

        var good: [String] = []
        good.reserveCapacity(desiredIDsPerBuild)

        for _ in 0..<maxSparqlRounds {
            if good.count >= desiredIDsPerBuild { break }

            let candidates = try await fetchRandomObjectUUIDs(limit: sparqlBatchSize)
            if candidates.isEmpty { continue }

            let valid = try await validateUUIDsHaveCC0Images(candidates)
            if !valid.isEmpty {
                good.append(contentsOf: valid)
                good = Array(Set(good)) // de-dupe
            }
        }

        guard !good.isEmpty else {
            throw URLError(.cannotLoadFromNetwork)
        }

        return good.shuffled().prefix(desiredIDsPerBuild).map { "\(providerID):\($0)" }
    }

    func fetchArtwork(id: String) async throws -> Artwork {
        let uuid = id.replacingOccurrences(of: "\(providerID):", with: "")
        let manifestURL = URL(string: "\(iiifBase)/\(uuid)/manifest.json")!

        let manifestNode = try await fetchAnyJSON(url: manifestURL)

        // Must be CC0 / Public Domain
        guard isCC0orPublicDomain(manifestNode) else {
            throw URLError(.resourceUnavailable)
        }

        guard let imageURL = extractIIIFImageURL(manifestNode) else {
            throw URLError(.resourceUnavailable)
        }

        let title =
            JSONAny.firstString(at: ["label"], in: manifestNode)
            ?? JSONAny.firstString(at: ["label", "none", 0], in: manifestNode)
            ?? JSONAny.firstString(at: ["label", "en", 0], in: manifestNode)
            ?? "Untitled"

        let artist =
            metadataValue(manifestNode, keys: ["Artist", "Creator", "Maker"])
            ?? "Unknown artist"

        let date = metadataValue(manifestNode, keys: ["Date", "Creation Date"])
        let medium = metadataValue(manifestNode, keys: ["Medium", "Materials", "Technique"])

        // Prefer homepage if present (IIIF v3), else leave nil
        let homepageURL =
            JSONAny.firstString(at: ["homepage", 0, "id"], in: manifestNode).flatMap(URL.init)
            ?? JSONAny.firstString(at: ["homepage", 0, "@id"], in: manifestNode).flatMap(URL.init)

        var debug: [String: String] = [:]
        debug["provider"] = providerID
        debug["getty_uuid"] = uuid
        debug["iiif_manifest"] = manifestURL.absoluteString

        if let rights = JSONAny.firstString(at: ["rights"], in: manifestNode) {
            debug["rights"] = rights
        } else if let rights2 = JSONAny.findFirstString(where: { $0.lowercased().contains("public domain") || $0.lowercased().contains("cc0") }, in: manifestNode) {
            debug["rights_hint"] = rights2
        }

        return Artwork(
            id: id,
            title: title.nilIfEmpty ?? "Untitled",
            artist: artist.nilIfEmpty ?? "Unknown artist",
            date: date?.nilIfEmpty,
            medium: medium?.nilIfEmpty,
            imageURL: imageURL,
            source: sourceName,
            sourceURL: homepageURL,
            debugFields: debug
        )
    }

    // MARK: - SPARQL discovery

    private func fetchRandomObjectUUIDs(limit: Int) async throws -> [String] {
        // Return object URIs, then strip to UUID. Many UUIDs won't have IIIF or CC0; we validate after.
        let query = """
        PREFIX crm: <http://www.cidoc-crm.org/cidoc-crm/>
        SELECT ?obj WHERE {
          ?obj a crm:E22_Human-Made_Object .
        }
        ORDER BY RAND()
        LIMIT \(limit)
        """

        var comps = URLComponents(url: sparqlEndpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "query", value: query)]

        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        req.timeoutInterval = 30
        req.setValue("application/sparql-results+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let decoded = try JSONDecoder().decode(SPARQLResults.self, from: data)

        let uris = decoded.results.bindings.compactMap { $0.obj.value }
        let uuids = uris.compactMap { uri -> String? in
            // Usually: https://data.getty.edu/museum/collection/object/<uuid>
            if let range = uri.range(of: "/collection/object/") {
                return String(uri[range.upperBound...])
            }
            // Fallback: last path component
            return URL(string: uri)?.lastPathComponent
        }

        return Array(Set(uuids))
    }

    // MARK: - Validation pass (the "make sure" filter)

    private func validateUUIDsHaveCC0Images(_ uuids: [String]) async throws -> [String] {
        return try await withThrowingTaskGroup(of: String?.self) { group in
            for uuid in uuids {
                group.addTask {
                    let url = URL(string: "\(self.iiifBase)/\(uuid)/manifest.json")!
                    do {
                        let node = try await self.fetchAnyJSON(url: url)
                        guard self.isCC0orPublicDomain(node),
                              self.extractIIIFImageURL(node) != nil else {
                            return nil
                        }
                        return uuid
                    } catch {
                        return nil
                    }
                }
            }

            var good: [String] = []
            for try await res in group {
                if let uuid = res {
                    good.append(uuid)
                }
            }
            return good
        }
    }

    // MARK: - IIIF parsing (supports v2 + v3)

    private func isCC0orPublicDomain(_ node: JSONAny.Node) -> Bool {
        let needles = [
            "creativecommons.org/publicdomain/zero",
            "cc0",
            "public domain"
        ]
        return JSONAny.containsString(in: node) { s in
            let l = s.lowercased()
            return needles.contains(where: { l.contains($0) })
        }
    }

    private func extractIIIFImageURL(_ manifest: JSONAny.Node) -> URL? {
        // IIIF v2 direct image:
        if let direct = JSONAny.firstString(at: ["sequences", 0, "canvases", 0, "images", 0, "resource", "@id"], in: manifest),
           let url = URL(string: direct) {
            return url
        }

        // IIIF v2 service:
        if let service = JSONAny.firstString(at: ["sequences", 0, "canvases", 0, "images", 0, "resource", "service", "@id"], in: manifest) {
            return URL(string: "\(service)/full/!1600,1600/0/default.jpg")
        }

        // IIIF v3 direct image:
        if let directV3 = JSONAny.firstString(at: ["items", 0, "items", 0, "items", 0, "body", "id"], in: manifest),
           let url = URL(string: directV3) {
            return url
        }

        // IIIF v3 service:
        if let serviceV3 = JSONAny.firstString(at: ["items", 0, "items", 0, "items", 0, "body", "service", 0, "id"], in: manifest) {
            return URL(string: "\(serviceV3)/full/!1600,1600/0/default.jpg")
        }

        // Fallback: find any image-ish string
        if let anyJpg = JSONAny.findFirstString(where: { s in
            let l = s.lowercased()
            return l.contains("default.jpg") || l.hasSuffix(".jpg") || l.hasSuffix(".jpeg")
        }, in: manifest),
           let url = URL(string: anyJpg) {
            return url
        }

        return nil
    }

    private func metadataValue(_ manifest: JSONAny.Node, keys: [String]) -> String? {
        guard case let .array(items) = JSONAny.node(at: ["metadata"], in: manifest) else { return nil }
        let lowered = Set(keys.map { $0.lowercased() })

        for item in items {
            let label =
                JSONAny.firstString(at: ["label"], in: item)
                ?? JSONAny.firstString(at: ["label", "en", 0], in: item)
                ?? JSONAny.firstString(at: ["label", "none", 0], in: item)

            guard let labelLower = label?.lowercased(),
                  lowered.contains(labelLower) else { continue }

            let value =
                JSONAny.firstString(at: ["value"], in: item)
                ?? JSONAny.firstString(at: ["value", "en", 0], in: item)
                ?? JSONAny.firstString(at: ["value", "none", 0], in: item)

            return value
        }

        return nil
    }

    // MARK: - Networking

    private func fetchAnyJSON(url: URL) async throws -> JSONAny.Node {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let any = try JSONSerialization.jsonObject(with: data, options: [])
        return JSONAny.wrap(any)
    }
}

// MARK: - SPARQL Models

private struct SPARQLResults: Decodable {
    let results: Results
    struct Results: Decodable { let bindings: [Binding] }
    struct Binding: Decodable { let obj: Value }
    struct Value: Decodable { let value: String? }
}

// MARK: - JSONAny

private enum JSONAny {
    indirect enum Node {
        case dict([String: Node])
        case array([Node])
        case string(String)
        case number(Double)
        case bool(Bool)
        case null
        case unknown
    }

    static func wrap(_ any: Any) -> Node {
        if let d = any as? [String: Any] {
            var out: [String: Node] = [:]
            for (k, v) in d { out[k] = wrap(v) }
            return .dict(out)
        }
        if let a = any as? [Any] { return .array(a.map(wrap)) }
        if let s = any as? String { return .string(s) }
        if let n = any as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.doubleValue)
        }
        if any is NSNull { return .null }
        return .unknown
    }

    static func node(at path: [Any], in root: Node) -> Node {
        var cur = root
        for p in path {
            switch (p, cur) {
            case let (k as String, .dict(d)):
                cur = d[k] ?? .null
            case let (i as Int, .array(a)):
                cur = (0 <= i && i < a.count) ? a[i] : .null
            default:
                return .null
            }
        }
        return cur
    }

    static func firstString(at path: [Any], in root: Node) -> String? {
        findFirstString(where: { _ in true }, in: node(at: path, in: root))
    }

    static func findFirstString(where predicate: (String) -> Bool, in node: Node) -> String? {
        switch node {
        case .string(let s): return predicate(s) ? s : nil
        case .array(let a):
            for n in a { if let s = findFirstString(where: predicate, in: n) { return s } }
            return nil
        case .dict(let d):
            for (_, v) in d { if let s = findFirstString(where: predicate, in: v) { return s } }
            return nil
        default:
            return nil
        }
    }

    static func containsString(in node: Node, where predicate: (String) -> Bool) -> Bool {
        return findFirstString(where: predicate, in: node) != nil
    }
}

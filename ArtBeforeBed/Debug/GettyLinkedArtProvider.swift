import Foundation
import CoreFoundation

/// Getty Provider - IMPROVED VERSION
/// Uses your proven working approach:
/// 1. SPARQL to discover UUIDs
/// 2. Linked Art object for metadata
/// 3. IIIF manifest for images
final class GettyProvider: MuseumProvider {

    let providerID: String = "getty"
    let sourceName: String = "J. Paul Getty Museum"

    private let sparqlEndpoint = URL(string: "https://data.getty.edu/museum/collection/sparql")!
    private let linkedArtObjectBase = "https://data.getty.edu/museum/collection/object"

    private let desiredIDsPerBuild = 160
    private let sparqlBatchSize = 280
    private let maxSparqlRounds = 2

    // MARK: - MuseumProvider

    func fetchArtworkIDs(
        query: String,
        medium: String?,
        geo: String?,
        period: PeriodPreset
    ) async throws -> [String] {

        _ = query; _ = medium; _ = geo; _ = period

        DebugLogger.logProviderStart("Getty", query: "SPARQL discovery")

        var uuids: Set<String> = []

        for round in 0..<maxSparqlRounds {
            DebugLogger.log(.info, "Getty: SPARQL round \(round + 1)/\(maxSparqlRounds)")
            
            let batch = try await fetchRandomObjectUUIDs(limit: sparqlBatchSize)
            batch.forEach { uuids.insert($0) }

            DebugLogger.log(.success, "Getty: Round \(round + 1) got \(batch.count) candidates, unique total: \(uuids.count)")

            if uuids.count >= desiredIDsPerBuild { break }
        }

        guard !uuids.isEmpty else {
            DebugLogger.log(.error, "Getty: No UUIDs discovered from SPARQL")
            throw URLError(.cannotLoadFromNetwork)
        }

        let ids = uuids.shuffled().prefix(desiredIDsPerBuild).map { "\(providerID):\($0)" }

        DebugLogger.logProviderSuccess("Getty", idCount: ids.count)
        DebugLogger.log(.info, "Getty: Sample IDs: \(ids.prefix(3).joined(separator: ", "))")

        return ids
    }

    func fetchArtwork(id: String) async throws -> Artwork {
        DebugLogger.logArtworkFetch(id: id)
        
        let uuid = id.replacingOccurrences(of: "\(providerID):", with: "")
        let objectURL = URL(string: "\(linkedArtObjectBase)/\(uuid)")!

        // STEP 1: Fetch Linked Art object JSON
        DebugLogger.log(.info, "Getty: Fetching Linked Art object for \(uuid)")
        let objectJSON = try await fetchJSON(url: objectURL, accept: "application/ld+json, application/json")

        // STEP 2: CC0/Public domain check
        guard isCC0orPublicDomain(objectJSON) else {
            DebugLogger.log(.warning, "Getty: \(uuid) not CC0/Public Domain")
            throw URLError(.resourceUnavailable)
        }
        DebugLogger.log(.success, "Getty: \(uuid) is CC0/Public Domain")

        // STEP 3: Extract IIIF manifest URL from object JSON
        // This is the KEY step - Getty stores images in separate IIIF manifests!
        guard let manifestURLString = JSONAny.findFirstString(
            where: { $0.contains("media.getty.edu/iiif/manifest/") },
            in: objectJSON
        ),
        let manifestURL = URL(string: manifestURLString)
        else {
            DebugLogger.log(.error, "Getty: No IIIF manifest URL found in object for \(uuid)")
            throw URLError(.resourceUnavailable)
        }
        DebugLogger.log(.success, "Getty: Found manifest: \(manifestURL.absoluteString)")

        // STEP 4: Fetch IIIF manifest JSON (v2 or v3)
        DebugLogger.log(.info, "Getty: Fetching IIIF manifest")
        let manifestJSON = try await fetchJSON(url: manifestURL, accept: "application/json")

        // STEP 5: Extract image URL from manifest
        guard let imageURL = extractImageURL(fromManifest: manifestJSON) else {
            DebugLogger.log(.error, "Getty: Could not extract image URL from manifest")
            throw URLError(.resourceUnavailable)
        }
        DebugLogger.log(.success, "Getty: Image URL: \(imageURL.absoluteString)")

        // STEP 6: Extract basic metadata
        let title =
            JSONAny.firstString(at: ["label"], in: objectJSON)
            ?? JSONAny.firstString(at: ["_label"], in: objectJSON)
            ?? "Untitled"

        let artist =
            JSONAny.firstString(at: ["produced_by", "carried_out_by", 0, "_label"], in: objectJSON)
            ?? JSONAny.firstString(at: ["produced_by", "carried_out_by", 0, "label"], in: objectJSON)
            ?? "Unknown artist"

        let date =
            JSONAny.firstString(at: ["produced_by", "timespan", "_label"], in: objectJSON)
            ?? JSONAny.firstString(at: ["produced_by", "timespan", "label"], in: objectJSON)

        let medium =
            JSONAny.firstString(at: ["classified_as", 0, "_label"], in: objectJSON)
            ?? JSONAny.firstString(at: ["classified_as", 0, "label"], in: objectJSON)

        DebugLogger.log(.info, "Getty: Title: \(title), Artist: \(artist)")

        var debug: [String: String] = [:]
        debug["provider"] = providerID
        debug["getty_uuid"] = uuid
        debug["linkedart_object"] = objectURL.absoluteString
        debug["manifest"] = manifestURL.absoluteString
        debug["image_url"] = imageURL.absoluteString

        DebugLogger.logArtworkSuccess(id: id, title: title)

        return Artwork(
            id: id,
            title: title.nilIfEmpty ?? "Untitled",
            artist: artist.nilIfEmpty ?? "Unknown artist",
            date: date?.nilIfEmpty,
            medium: medium?.nilIfEmpty,
            imageURL: imageURL,
            source: sourceName,
            sourceURL: URL(string: "https://www.getty.edu"),
            debugFields: debug
        )
    }

    // MARK: - Manifest parsing (robust IIIF v2 + v3)

    private func extractImageURL(fromManifest manifest: JSONAny.Node) -> URL? {

        // 0) If the manifest already contains a direct media.getty.edu iiif image URL, grab it.
        if let direct = JSONAny.findFirstString(
            where: { s in
                let l = s.lowercased()
                return l.contains("media.getty.edu/iiif/image/")
                    && (l.contains("/default.jpg") || l.contains("/default.jpeg") || l.contains(".jpg") || l.contains(".jpeg"))
            },
            in: manifest
        ),
        let u = URL(string: direct) {
            if direct.contains("/full/") {
                return u
            }
            if direct.contains("media.getty.edu/iiif/image/") && !direct.contains("/full/") {
                return URL(string: "\(direct)/full/!1600,1600/0/default.jpg") ?? u
            }
            return u
        }

        // Helper to read "id" or "@id" at the same path
        func firstID(at path: [Any], in root: JSONAny.Node) -> String? {
            JSONAny.firstString(at: path + ["id"], in: root)
            ?? JSONAny.firstString(at: path + ["@id"], in: root)
        }

        // 1) Thumbnail (IIIF v3)
        if let t = JSONAny.firstString(at: ["thumbnail", "id"], in: manifest) ?? JSONAny.firstString(at: ["thumbnail", "@id"], in: manifest),
           let u = URL(string: t) { return u }
        if let t = JSONAny.firstString(at: ["thumbnail", 0, "id"], in: manifest) ?? JSONAny.firstString(at: ["thumbnail", 0, "@id"], in: manifest),
           let u = URL(string: t) { return u }

        // 2) IIIF v3: items[0].items[0].body.id / service.id
        if let body = firstID(at: ["items", 0, "items", 0, "body"], in: manifest),
           let u = URL(string: body) { return u }

        if let service =
            JSONAny.firstString(at: ["items", 0, "items", 0, "body", "service", 0, "id"], in: manifest)
            ?? JSONAny.firstString(at: ["items", 0, "items", 0, "body", "service", 0, "@id"], in: manifest)
            ?? JSONAny.firstString(at: ["items", 0, "items", 0, "body", "service", "id"], in: manifest)
            ?? JSONAny.firstString(at: ["items", 0, "items", 0, "body", "service", "@id"], in: manifest)
        {
            return URL(string: "\(service)/full/!1600,1600/0/default.jpg")
        }

        // 3) IIIF v2: sequences[0].canvases[0].images[0].resource.@id
        if let resource =
            JSONAny.firstString(at: ["sequences", 0, "canvases", 0, "images", 0, "resource", "@id"], in: manifest)
            ?? JSONAny.firstString(at: ["sequences", 0, "canvases", 0, "images", 0, "resource", "id"], in: manifest),
           let u = URL(string: resource) {
            return u
        }

        // 4) IIIF v2: sequences[0].canvases[0].images[0].resource.service.@id
        if let service =
            JSONAny.firstString(at: ["sequences", 0, "canvases", 0, "images", 0, "resource", "service", "@id"], in: manifest)
            ?? JSONAny.firstString(at: ["sequences", 0, "canvases", 0, "images", 0, "resource", "service", "id"], in: manifest)
            ?? JSONAny.firstString(at: ["sequences", 0, "canvases", 0, "images", 0, "resource", "service", 0, "@id"], in: manifest)
            ?? JSONAny.firstString(at: ["sequences", 0, "canvases", 0, "images", 0, "resource", "service", 0, "id"], in: manifest)
        {
            return URL(string: "\(service)/full/!1600,1600/0/default.jpg")
        }

        // 5) IIIF v2: sequences[0].canvases[0].thumbnail.@id
        if let thumb =
            JSONAny.firstString(at: ["sequences", 0, "canvases", 0, "thumbnail", "@id"], in: manifest)
            ?? JSONAny.firstString(at: ["sequences", 0, "canvases", 0, "thumbnail", "id"], in: manifest),
           let u = URL(string: thumb) {
            return u
        }

        return nil
    }

    // MARK: - Rights check

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

    // MARK: - SPARQL discovery

    private func fetchRandomObjectUUIDs(limit: Int) async throws -> [String] {
        let query = """
        PREFIX crm: <http://www.cidoc-crm.org/cidoc-crm/>
        SELECT ?obj WHERE { ?obj a crm:E22_Human-Made_Object . }
        ORDER BY RAND()
        LIMIT \(limit)
        """

        var comps = URLComponents(url: sparqlEndpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "query", value: query)]
        guard let url = comps.url else { throw URLError(.badURL) }

        DebugLogger.logNetworkRequest(url: url, method: "GET (SPARQL)")

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 30
        req.setValue("application/sparql-results+json", forHTTPHeaderField: "Accept")
        req.setValue("ArtBeforeBed/1.0 (iOS)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        DebugLogger.logNetworkResponse(url: url, statusCode: http.statusCode, dataSize: data.count)

        guard (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let decoded = try JSONDecoder().decode(SPARQLResults.self, from: data)
        let uris = decoded.results.bindings.compactMap { $0.obj.value }

        return uris.compactMap { uri in
            if let u = URL(string: uri) {
                return u.lastPathComponent.nilIfEmpty
            }
            return nil
        }
    }

    // MARK: - Networking

    private func fetchJSON(url: URL, accept: String) async throws -> JSONAny.Node {
        DebugLogger.logNetworkRequest(url: url)
        
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 30
        req.setValue(accept, forHTTPHeaderField: "Accept")
        req.setValue("ArtBeforeBed/1.0 (iOS)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        DebugLogger.logNetworkResponse(url: url, statusCode: http.statusCode, dataSize: data.count)

        guard (200...299).contains(http.statusCode) else {
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

// MARK: - JSONAny (self-contained)

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

    nonisolated static func wrap(_ any: Any) -> Node {
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

    nonisolated static func node(at path: [Any], in root: Node) -> Node {
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

    nonisolated static func firstString(at path: [Any], in root: Node) -> String? {
        findFirstString(where: { _ in true }, in: node(at: path, in: root))
    }

    nonisolated static func findFirstString(where predicate: (String) -> Bool, in node: Node) -> String? {
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

    nonisolated static func containsString(in node: Node, where predicate: (String) -> Bool) -> Bool {
        return findFirstString(where: predicate, in: node) != nil
    }
}

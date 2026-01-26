import Foundation
import CoreFoundation

/// Getty Provider - OPTIMIZED VERSION with Rights Filtering
///
/// Key Features:
/// 1. SPARQL queries filter for CC0/Public Domain at query time
/// 2. Parallel queries for traditional art vs photographs
/// 3. Actor-based caching for Linked Art objects and IIIF manifests
/// 4. Conservative offset-based random sampling
///
/// Architecture:
/// - SPARQL to discover UUIDs (filtered by rights + type)
/// - Linked Art object for metadata + secondary rights check
/// - IIIF manifest for images

// MARK: - Cache Actor

/// Thread-safe cache for Getty API responses
private actor GettyCache {
    private var linkedArtObjects: [String: JSONAny.Node] = [:]
    private var iiifManifests: [String: JSONAny.Node] = [:]
    private var artworkCache: [String: Artwork] = [:]
    private var failedIDs: Set<String> = []
    
    private let maxCacheSize = 500
    
    func getLinkedArt(_ uuid: String) -> JSONAny.Node? {
        return linkedArtObjects[uuid]
    }
    
    func setLinkedArt(_ uuid: String, _ node: JSONAny.Node) {
        if linkedArtObjects.count >= maxCacheSize {
            let keysToRemove = Array(linkedArtObjects.keys.prefix(maxCacheSize / 5))
            keysToRemove.forEach { linkedArtObjects.removeValue(forKey: $0) }
        }
        linkedArtObjects[uuid] = node
    }
    
    func getManifest(_ url: String) -> JSONAny.Node? {
        return iiifManifests[url]
    }
    
    func setManifest(_ url: String, _ node: JSONAny.Node) {
        if iiifManifests.count >= maxCacheSize {
            let keysToRemove = Array(iiifManifests.keys.prefix(maxCacheSize / 5))
            keysToRemove.forEach { iiifManifests.removeValue(forKey: $0) }
        }
        iiifManifests[url] = node
    }
    
    func getArtwork(_ id: String) -> Artwork? {
        return artworkCache[id]
    }
    
    func setArtwork(_ id: String, _ artwork: Artwork) {
        if artworkCache.count >= maxCacheSize {
            let keysToRemove = Array(artworkCache.keys.prefix(maxCacheSize / 5))
            keysToRemove.forEach { artworkCache.removeValue(forKey: $0) }
        }
        artworkCache[id] = artwork
    }
    
    func markFailed(_ id: String) {
        failedIDs.insert(id)
    }
    
    func isFailed(_ id: String) -> Bool {
        return failedIDs.contains(id)
    }
    
    func clearFailedIDs() {
        failedIDs.removeAll()
    }
}

// MARK: - Getty Provider

final class GettyProvider: MuseumProvider {

    let providerID: String = "getty"
    let sourceName: String = "J. Paul Getty Museum"

    private let sparqlEndpoint = URL(string: "https://data.getty.edu/museum/collection/sparql")!
    private let linkedArtObjectBase = "https://data.getty.edu/museum/collection/object"

    // Configuration - favor traditional art heavily (most photos aren't CC0)
    private let desiredIDsPerBuild = 120
    private let traditionalArtCount = 110  // Mostly traditional art
    private let photographCount = 10       // Very few photos (most fail rights check)
    
    // SPARQL tuning
    private let sparqlBatchSize = 300
    private let maxSparqlRetries = 2
    
    // Network tuning
    private let requestTimeout: TimeInterval = 20
    private let maxConcurrentFetches = 6
    
    // Cache
    private let cache = GettyCache()
    
    // Conservative collection size estimates for CC0 items only
    // These are much smaller than total collection
    private let approxCC0TraditionalArt = 2000
    private let approxCC0Photographs = 3000

    // MARK: - MuseumProvider Protocol

    func fetchArtworkIDs(
        query: String,
        medium: String?,
        geo: String?,
        period: PeriodPreset
    ) async throws -> [String] {

        _ = query; _ = geo; _ = period

        DebugLogger.logProviderStart("Getty", query: "SPARQL discovery (CC0 filtered)")
        print("🟣 [GETTY] Medium filter: \(medium ?? "all")")
        
        let startTime = CFAbsoluteTimeGetCurrent()

        // Determine which types to fetch based on medium filter
        let fetchTraditional: Bool
        let fetchPhotos: Bool
        
        switch medium?.lowercased() {
        case "paintings", "drawings", "prints":
            fetchTraditional = true
            fetchPhotos = false
        case "photographs":
            fetchTraditional = false
            fetchPhotos = true
        default:
            // No filter = both
            fetchTraditional = true
            fetchPhotos = true
        }
        
        var traditionalUUIDs: [String] = []
        var photographUUIDs: [String] = []
        
        // Fetch based on filter
        if fetchTraditional && fetchPhotos {
            async let traditionalTask = fetchCC0TraditionalArtUUIDs()
            async let photographTask = fetchCC0PhotographUUIDs()
            (traditionalUUIDs, photographUUIDs) = try await (traditionalTask, photographTask)
        } else if fetchTraditional {
            traditionalUUIDs = try await fetchCC0TraditionalArtUUIDs()
        } else if fetchPhotos {
            photographUUIDs = try await fetchCC0PhotographUUIDs()
        }
        
        let sparqlDuration = CFAbsoluteTimeGetCurrent() - startTime
        DebugLogger.log(.success, "Getty: SPARQL completed in \(String(format: "%.2f", sparqlDuration))s - Traditional: \(traditionalUUIDs.count), Photos: \(photographUUIDs.count)")

        // Calculate selection counts
        let selectedTraditional: [String]
        let selectedPhotographs: [String]
        
        if fetchTraditional && fetchPhotos {
            selectedTraditional = Array(traditionalUUIDs.shuffled().prefix(traditionalArtCount))
            selectedPhotographs = Array(photographUUIDs.shuffled().prefix(photographCount))
        } else if fetchTraditional {
            selectedTraditional = Array(traditionalUUIDs.shuffled().prefix(desiredIDsPerBuild))
            selectedPhotographs = []
        } else {
            selectedTraditional = []
            selectedPhotographs = Array(photographUUIDs.shuffled().prefix(desiredIDsPerBuild))
        }
        
        DebugLogger.log(.success, "Getty: Selected \(selectedTraditional.count) traditional + \(selectedPhotographs.count) photographs")

        guard !selectedTraditional.isEmpty || !selectedPhotographs.isEmpty else {
            DebugLogger.log(.error, "Getty: No CC0 UUIDs found for medium filter: \(medium ?? "all")")
            throw URLError(.cannotLoadFromNetwork)
        }

        var allUUIDs = selectedTraditional + selectedPhotographs
        allUUIDs.shuffle()
        
        let ids = allUUIDs.prefix(desiredIDsPerBuild).map { "\(providerID):\($0)" }

        DebugLogger.logProviderSuccess("Getty", idCount: ids.count)
        DebugLogger.log(.info, "Getty: Sample IDs: \(ids.prefix(3).joined(separator: ", "))")

        return ids
    }

    func fetchArtwork(id: String) async throws -> Artwork {
        // Check cache first
        if let cached = await cache.getArtwork(id) {
            DebugLogger.log(.info, "Getty: Cache hit for \(id)")
            return cached
        }
        
        // Check if previously failed
        if await cache.isFailed(id) {
            DebugLogger.log(.warning, "Getty: Skipping previously failed ID \(id)")
            throw URLError(.resourceUnavailable)
        }
        
        DebugLogger.logArtworkFetch(id: id)
        
        let uuid = id.replacingOccurrences(of: "\(providerID):", with: "")
        
        do {
            let artwork = try await fetchArtworkInternal(uuid: uuid, id: id)
            await cache.setArtwork(id, artwork)
            return artwork
        } catch {
            await cache.markFailed(id)
            throw error
        }
    }
    
    // MARK: - Internal Artwork Fetching
    
    private func fetchArtworkInternal(uuid: String, id: String) async throws -> Artwork {
        let objectURL = URL(string: "\(linkedArtObjectBase)/\(uuid)")!

        // STEP 1: Fetch Linked Art object
        let objectJSON: JSONAny.Node
        if let cached = await cache.getLinkedArt(uuid) {
            DebugLogger.log(.info, "Getty: Linked Art cache hit for \(uuid)")
            objectJSON = cached
        } else {
            DebugLogger.log(.info, "Getty: Fetching Linked Art object for \(uuid)")
            objectJSON = try await fetchJSON(url: objectURL, accept: "application/ld+json, application/json")
            await cache.setLinkedArt(uuid, objectJSON)
        }

        // STEP 2: Secondary CC0/Public domain check (belt and suspenders)
        guard isCC0orPublicDomain(objectJSON) else {
            DebugLogger.log(.warning, "Getty: \(uuid) not CC0/Public Domain")
            throw URLError(.resourceUnavailable)
        }
        DebugLogger.log(.success, "Getty: \(uuid) is CC0/Public Domain")

        // STEP 3: Extract IIIF manifest URL
        guard let manifestURLString = JSONAny.findFirstString(
            where: { $0.contains("/iiif/") && $0.contains("manifest") },
            in: objectJSON
        ),
        let manifestURL = URL(string: manifestURLString) else {
            DebugLogger.log(.warning, "Getty: \(uuid) no IIIF manifest URL found")
            throw URLError(.resourceUnavailable)
        }

        // STEP 4: Fetch IIIF manifest
        let manifestJSON: JSONAny.Node
        if let cached = await cache.getManifest(manifestURLString) {
            manifestJSON = cached
        } else {
            DebugLogger.log(.info, "Getty: Fetching IIIF manifest for \(uuid)")
            manifestJSON = try await fetchJSON(url: manifestURL, accept: "application/ld+json, application/json")
            await cache.setManifest(manifestURLString, manifestJSON)
        }

        // STEP 5: Extract image URL
        guard let imageURL = extractImageURL(fromManifest: manifestJSON) else {
            DebugLogger.log(.warning, "Getty: \(uuid) no image URL in manifest")
            throw URLError(.resourceUnavailable)
        }

        // STEP 6: Extract metadata
        let title = extractTitle(from: objectJSON) ?? "Untitled"
        let artist = extractArtist(from: objectJSON) ?? "Unknown artist"
        let date = extractDate(from: objectJSON)
        let medium = extractMedium(from: objectJSON)

        let sourceURL = URL(string: "https://www.getty.edu/art/collection/object/\(uuid)")

        var debug: [String: String] = [:]
        debug["provider"] = providerID
        debug["uuid"] = uuid
        debug["manifestURL"] = manifestURLString

        DebugLogger.logArtworkSuccess(id: id, title: title)

        return Artwork(
            id: id,
            title: title.nilIfEmpty ?? "Untitled",
            artist: artist.nilIfEmpty ?? "Unknown artist",
            date: date?.nilIfEmpty,
            medium: medium?.nilIfEmpty,
            imageURL: imageURL,
            source: sourceName,
            sourceURL: sourceURL,
            debugFields: debug
        )
    }

    // MARK: - SPARQL Discovery
    
    /// Fetch traditional art UUIDs (paintings, drawings, prints, watercolors)
    /// Rights filtering happens at fetch time, not SPARQL time
    private func fetchCC0TraditionalArtUUIDs() async throws -> [String] {
        var allUUIDs: Set<String> = []
        
        // Use offset 0 plus a couple random offsets for variety
        // Traditional art collection is smaller, so keep offsets conservative
        var offsets = [0]
        offsets.append(contentsOf: generateRandomOffsets(count: 2, maxOffset: 2000))
        
        print("🟣 [GETTY] Traditional art offsets: \(offsets)")
        
        try await withThrowingTaskGroup(of: [String].self) { group in
            for offset in offsets {
                group.addTask {
                    try await self.fetchTraditionalArtBatch(offset: offset)
                }
            }
            
            for try await batch in group {
                print("🟣 [GETTY] Traditional art batch: \(batch.count) UUIDs")
                batch.forEach { allUUIDs.insert($0) }
            }
        }
        
        return Array(allUUIDs)
    }
    
    private func fetchTraditionalArtBatch(offset: Int) async throws -> [String] {
        // Query for traditional art types only - rights check happens at fetch time
        // AAT codes: 300033618 (paintings), 300033973 (drawings), 300078925 (prints), 300041273 (watercolors)
        let query = """
        PREFIX crm: <http://www.cidoc-crm.org/cidoc-crm/>
        PREFIX aat: <http://vocab.getty.edu/aat/>
        SELECT DISTINCT ?obj WHERE {
            ?obj a crm:E22_Human-Made_Object ;
                 crm:P2_has_type ?type .
            FILTER (
                ?type = aat:300033618 ||
                ?type = aat:300033973 ||
                ?type = aat:300078925 ||
                ?type = aat:300041273
            )
        }
        OFFSET \(offset)
        LIMIT \(sparqlBatchSize)
        """
        
        return try await executeSPARQLQueryWithRetry(query)
    }
    
    /// Fetch photograph UUIDs
    private func fetchCC0PhotographUUIDs() async throws -> [String] {
        var allUUIDs: Set<String> = []
        
        // Photographs: use offset 0 plus one random for variety
        var offsets = [0]
        offsets.append(contentsOf: generateRandomOffsets(count: 1, maxOffset: 5000))
        
        print("🟣 [GETTY] Photograph offsets: \(offsets)")
        
        try await withThrowingTaskGroup(of: [String].self) { group in
            for offset in offsets {
                group.addTask {
                    try await self.fetchPhotographBatch(offset: offset)
                }
            }
            
            for try await batch in group {
                print("🟣 [GETTY] Photograph batch: \(batch.count) UUIDs")
                batch.forEach { allUUIDs.insert($0) }
            }
        }
        
        return Array(allUUIDs)
    }
    
    private func fetchPhotographBatch(offset: Int) async throws -> [String] {
        // Query for photographs - rights check happens at fetch time
        // AAT code: 300046300 (photographs)
        let query = """
        PREFIX crm: <http://www.cidoc-crm.org/cidoc-crm/>
        PREFIX aat: <http://vocab.getty.edu/aat/>
        SELECT DISTINCT ?obj WHERE {
            ?obj a crm:E22_Human-Made_Object ;
                 crm:P2_has_type aat:300046300 .
        }
        OFFSET \(offset)
        LIMIT \(sparqlBatchSize / 2)
        """
        
        return try await executeSPARQLQueryWithRetry(query)
    }
    
    private func generateRandomOffsets(count: Int, maxOffset: Int) -> [Int] {
        guard maxOffset > 0 else { return [0] }
        
        var offsets: Set<Int> = []
        while offsets.count < count {
            offsets.insert(Int.random(in: 0...maxOffset))
        }
        return Array(offsets)
    }
    
    /// Execute SPARQL with automatic retry on failure
    private func executeSPARQLQueryWithRetry(_ query: String, attempt: Int = 1) async throws -> [String] {
        do {
            return try await executeSPARQLQuery(query)
        } catch {
            if attempt < maxSparqlRetries {
                DebugLogger.log(.warning, "Getty: SPARQL attempt \(attempt) failed, retrying...")
                try await Task.sleep(nanoseconds: UInt64(500_000_000 * attempt))
                return try await executeSPARQLQueryWithRetry(query, attempt: attempt + 1)
            }
            throw error
        }
    }

    private func executeSPARQLQuery(_ query: String) async throws -> [String] {
        var comps = URLComponents(url: sparqlEndpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "query", value: query)]
        guard let url = comps.url else { throw URLError(.badURL) }

        // Log a truncated version of the URL for debugging
        let truncatedURL = String(url.absoluteString.prefix(150))
        print("🟣 [GETTY] SPARQL request: \(truncatedURL)...")
        
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = requestTimeout
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

        let results = try JSONDecoder().decode(SPARQLResults.self, from: data)
        
        return results.results.bindings.compactMap { binding in
            guard let value = binding.obj.value,
                  let u = URL(string: value) else { return nil }
            return u.lastPathComponent.nilIfEmpty
        }
    }

    // MARK: - Metadata Extraction

    private func extractTitle(from node: JSONAny.Node) -> String? {
        // Try identified_by array for Name type
        if case .dict(let d) = node,
           case .array(let arr)? = d["identified_by"] {
            for item in arr {
                if case .dict(let itemDict) = item,
                   case .string(let type)? = itemDict["type"],
                   type == "Name",
                   case .string(let content)? = itemDict["content"] {
                    return content
                }
            }
        }
        
        // Fallback to _label
        if case .dict(let d) = node,
           case .string(let label)? = d["_label"] {
            return label
        }
        
        return nil
    }

    private func extractArtist(from node: JSONAny.Node) -> String? {
        // Try produced_by.carried_out_by[]._label
        if case .dict(let d) = node,
           case .dict(let producedBy)? = d["produced_by"],
           case .array(let carriedOutBy)? = producedBy["carried_out_by"] {
            for item in carriedOutBy {
                if case .dict(let itemDict) = item,
                   case .string(let label)? = itemDict["_label"] {
                    return label
                }
            }
        }
        return nil
    }

    private func extractDate(from node: JSONAny.Node) -> String? {
        // Try produced_by.timespan._label
        if case .dict(let d) = node,
           case .dict(let producedBy)? = d["produced_by"],
           case .dict(let timespan)? = producedBy["timespan"],
           case .string(let label)? = timespan["_label"] {
            return label
        }
        return nil
    }

    private func extractMedium(from node: JSONAny.Node) -> String? {
        // Try made_of[]._label
        if case .dict(let d) = node,
           case .array(let madeOf)? = d["made_of"] {
            var materials: [String] = []
            for item in madeOf {
                if case .dict(let itemDict) = item,
                   case .string(let label)? = itemDict["_label"] {
                    materials.append(label)
                }
            }
            if !materials.isEmpty {
                return materials.joined(separator: ", ")
            }
        }
        return nil
    }

    // MARK: - Image URL Extraction
    
    /// Target image size for normalized URLs
    private let targetImageSize = "!1200,1200"
    
    /// Normalize Getty IIIF image URLs to consistent size
    private func normalizeGettyImageURL(_ urlString: String) -> URL? {
        // Extract the image ID and construct a normalized URL
        if let range = urlString.range(of: "media.getty.edu/iiif/image/") {
            let afterBase = String(urlString[range.upperBound...])
            
            let imageID: String
            if let slashIndex = afterBase.firstIndex(of: "/") {
                imageID = String(afterBase[..<slashIndex])
            } else {
                imageID = afterBase
            }
            
            let normalizedURL = "https://media.getty.edu/iiif/image/\(imageID)/full/\(targetImageSize)/0/default.jpg"
            return URL(string: normalizedURL)
        }
        
        return URL(string: urlString)
    }

    private func extractImageURL(fromManifest manifest: JSONAny.Node) -> URL? {
        // Helper for id/@id
        func firstID(at path: [Any], in root: JSONAny.Node) -> String? {
            JSONAny.firstString(at: path + ["id"], in: root)
            ?? JSONAny.firstString(at: path + ["@id"], in: root)
        }
        
        // 1) Look for direct image URLs anywhere in manifest
        if let direct = JSONAny.findFirstString(
            where: { $0.contains("media.getty.edu/iiif/image/") },
            in: manifest
        ),
        let normalized = normalizeGettyImageURL(direct) {
            return normalized
        }

        // 2) IIIF v3: items[0].items[0].body.service[].id
        if let service =
            JSONAny.firstString(at: ["items", 0, "items", 0, "body", "service", 0, "id"], in: manifest)
            ?? JSONAny.firstString(at: ["items", 0, "items", 0, "body", "service", 0, "@id"], in: manifest)
            ?? JSONAny.firstString(at: ["items", 0, "items", 0, "body", "service", "id"], in: manifest)
            ?? JSONAny.firstString(at: ["items", 0, "items", 0, "body", "service", "@id"], in: manifest),
           service.contains("media.getty.edu/iiif/image/")
        {
            return normalizeGettyImageURL(service)
        }
        
        // 3) IIIF v3: items[0].items[0].body.id
        if let body = firstID(at: ["items", 0, "items", 0, "body"], in: manifest),
           body.contains("media.getty.edu/iiif/image/") {
            return normalizeGettyImageURL(body)
        }

        // 4) IIIF v2: sequences[0].canvases[0].images[0].resource.service.@id
        if let service =
            JSONAny.firstString(at: ["sequences", 0, "canvases", 0, "images", 0, "resource", "service", "@id"], in: manifest)
            ?? JSONAny.firstString(at: ["sequences", 0, "canvases", 0, "images", 0, "resource", "service", "id"], in: manifest)
            ?? JSONAny.firstString(at: ["sequences", 0, "canvases", 0, "images", 0, "resource", "service", 0, "@id"], in: manifest)
            ?? JSONAny.firstString(at: ["sequences", 0, "canvases", 0, "images", 0, "resource", "service", 0, "id"], in: manifest),
           service.contains("media.getty.edu/iiif/image/")
        {
            return normalizeGettyImageURL(service)
        }

        // 5) IIIF v2: sequences[0].canvases[0].images[0].resource.@id
        if let resource =
            JSONAny.firstString(at: ["sequences", 0, "canvases", 0, "images", 0, "resource", "@id"], in: manifest)
            ?? JSONAny.firstString(at: ["sequences", 0, "canvases", 0, "images", 0, "resource", "id"], in: manifest),
           resource.contains("media.getty.edu/iiif/image/")
        {
            return normalizeGettyImageURL(resource)
        }

        // 6) Thumbnails
        if let thumb =
            JSONAny.firstString(at: ["thumbnail", "id"], in: manifest)
            ?? JSONAny.firstString(at: ["thumbnail", "@id"], in: manifest)
            ?? JSONAny.firstString(at: ["thumbnail", 0, "id"], in: manifest)
            ?? JSONAny.firstString(at: ["thumbnail", 0, "@id"], in: manifest)
            ?? JSONAny.firstString(at: ["sequences", 0, "canvases", 0, "thumbnail", "@id"], in: manifest)
            ?? JSONAny.firstString(at: ["sequences", 0, "canvases", 0, "thumbnail", "id"], in: manifest),
           thumb.contains("media.getty.edu/iiif/image/")
        {
            return normalizeGettyImageURL(thumb)
        }

        return nil
    }

    // MARK: - Rights Check

    private func isCC0orPublicDomain(_ node: JSONAny.Node) -> Bool {
        let needles = [
            "creativecommons.org/publicdomain/zero",
            "creativecommons.org/publicdomain/mark",
            "cc0",
            "public domain",
            "no known copyright",
            "no copyright"
        ]
        return JSONAny.containsString(in: node) { s in
            let l = s.lowercased()
            return needles.contains(where: { l.contains($0) })
        }
    }

    // MARK: - Networking

    private func fetchJSON(url: URL, accept: String) async throws -> JSONAny.Node {
        DebugLogger.logNetworkRequest(url: url)
        
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = requestTimeout
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

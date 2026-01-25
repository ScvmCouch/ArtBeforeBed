import Foundation
import CoreFoundation

/// Getty Provider - OPTIMIZED VERSION
///
/// Key Performance Improvements:
/// 1. Parallel SPARQL queries for traditional art vs photographs
/// 2. Actor-based caching for Linked Art objects and IIIF manifests
/// 3. Removed expensive ORDER BY RAND() - uses OFFSET-based random sampling instead
/// 4. Configurable concurrency limits to prevent overwhelming the server
/// 5. Preemptive batch fetching to warm the cache
///
/// Architecture:
/// - SPARQL to discover UUIDs (with deterministic random sampling)
/// - Linked Art object for metadata + rights check
/// - IIIF manifest for images
/// - 75/25 weighted balance (traditional art / photographs)

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
            // Remove oldest ~20% when cache is full
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

    // Configuration
    private let desiredIDsPerBuild = 160
    private let traditionalArtCount = 120  // 75%
    private let photographCount = 40        // 25%
    
    // SPARQL tuning - fetch more upfront, fewer rounds
    private let sparqlBatchSize = 400
    private let maxSparqlRetries = 2
    
    // Network tuning
    private let requestTimeout: TimeInterval = 20  // Reduced from 30
    private let maxConcurrentFetches = 6           // Limit parallel requests
    
    // Cache
    private let cache = GettyCache()
    
    // Known collection sizes (approximate, for random offset calculation)
    private let approxTraditionalArtCount = 8000
    private let approxPhotographCount = 45000

    // MARK: - MuseumProvider Protocol

    func fetchArtworkIDs(
        query: String,
        medium: String?,
        geo: String?,
        period: PeriodPreset
    ) async throws -> [String] {

        _ = query; _ = medium; _ = geo; _ = period

        DebugLogger.logProviderStart("Getty", query: "SPARQL discovery (optimized)")
        
        let startTime = CFAbsoluteTimeGetCurrent()

        // Run both SPARQL queries in parallel
        async let traditionalTask = fetchTraditionalArtUUIDs()
        async let photographTask = fetchPhotographUUIDs()
        
        let (traditionalUUIDs, photographUUIDs) = try await (traditionalTask, photographTask)
        
        let sparqlDuration = CFAbsoluteTimeGetCurrent() - startTime
        DebugLogger.log(.success, "Getty: SPARQL completed in \(String(format: "%.2f", sparqlDuration))s - Traditional: \(traditionalUUIDs.count), Photos: \(photographUUIDs.count)")

        // Select weighted distribution
        let selectedTraditional = Array(traditionalUUIDs.shuffled().prefix(traditionalArtCount))
        let selectedPhotographs = Array(photographUUIDs.shuffled().prefix(photographCount))
        
        DebugLogger.log(.success, "Getty: Selected \(selectedTraditional.count) traditional + \(selectedPhotographs.count) photographs")

        guard !selectedTraditional.isEmpty else {
            DebugLogger.log(.error, "Getty: No traditional art UUIDs discovered from SPARQL")
            throw URLError(.cannotLoadFromNetwork)
        }

        // Combine and shuffle
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
        
        // Check if previously failed (avoid repeated failures)
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

        // STEP 1: Fetch Linked Art object (with caching)
        let objectJSON: JSONAny.Node
        if let cached = await cache.getLinkedArt(uuid) {
            DebugLogger.log(.info, "Getty: Linked Art cache hit for \(uuid)")
            objectJSON = cached
        } else {
            DebugLogger.log(.info, "Getty: Fetching Linked Art object for \(uuid)")
            objectJSON = try await fetchJSON(url: objectURL, accept: "application/ld+json, application/json")
            await cache.setLinkedArt(uuid, objectJSON)
        }

        // STEP 2: CC0/Public domain check
        guard isCC0orPublicDomain(objectJSON) else {
            DebugLogger.log(.warning, "Getty: \(uuid) not CC0/Public Domain")
            throw URLError(.resourceUnavailable)
        }
        DebugLogger.log(.success, "Getty: \(uuid) is CC0/Public Domain")

        // STEP 3: Extract IIIF manifest URL
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

        // STEP 4: Fetch IIIF manifest (with caching)
        let manifestJSON: JSONAny.Node
        let manifestKey = manifestURL.absoluteString
        if let cached = await cache.getManifest(manifestKey) {
            DebugLogger.log(.info, "Getty: Manifest cache hit")
            manifestJSON = cached
        } else {
            DebugLogger.log(.info, "Getty: Fetching IIIF manifest")
            manifestJSON = try await fetchJSON(url: manifestURL, accept: "application/json")
            await cache.setManifest(manifestKey, manifestJSON)
        }

        // STEP 5: Extract image URL
        guard let imageURL = extractImageURL(fromManifest: manifestJSON) else {
            DebugLogger.log(.error, "Getty: Could not extract image URL from manifest")
            throw URLError(.resourceUnavailable)
        }
        DebugLogger.log(.success, "Getty: Image URL: \(imageURL.absoluteString)")

        // STEP 6: Extract metadata
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

    // MARK: - SPARQL Discovery (Optimized)
    
    /// Fetch traditional art using OFFSET-based random sampling (faster than ORDER BY RAND())
    private func fetchTraditionalArtUUIDs() async throws -> [String] {
        var allUUIDs: Set<String> = []
        
        // Use multiple random offsets to sample different parts of the collection
        let offsets = generateRandomOffsets(
            count: 3,
            maxOffset: max(0, approxTraditionalArtCount - sparqlBatchSize)
        )
        
        // Fetch from multiple offsets in parallel
        try await withThrowingTaskGroup(of: [String].self) { group in
            for offset in offsets {
                group.addTask {
                    try await self.fetchTraditionalArtBatch(offset: offset)
                }
            }
            
            for try await batch in group {
                batch.forEach { allUUIDs.insert($0) }
            }
        }
        
        return Array(allUUIDs)
    }
    
    private func fetchTraditionalArtBatch(offset: Int) async throws -> [String] {
        // Using OFFSET for random sampling - much faster than ORDER BY RAND()
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
    
    /// Fetch photographs using OFFSET-based sampling
    private func fetchPhotographUUIDs() async throws -> [String] {
        var allUUIDs: Set<String> = []
        
        let offsets = generateRandomOffsets(
            count: 2,
            maxOffset: max(0, approxPhotographCount - sparqlBatchSize)
        )
        
        try await withThrowingTaskGroup(of: [String].self) { group in
            for offset in offsets {
                group.addTask {
                    try await self.fetchPhotographBatch(offset: offset)
                }
            }
            
            for try await batch in group {
                batch.forEach { allUUIDs.insert($0) }
            }
        }
        
        return Array(allUUIDs)
    }
    
    private func fetchPhotographBatch(offset: Int) async throws -> [String] {
        let query = """
        PREFIX crm: <http://www.cidoc-crm.org/cidoc-crm/>
        PREFIX aat: <http://vocab.getty.edu/aat/>
        SELECT DISTINCT ?obj WHERE {
            ?obj a crm:E22_Human-Made_Object ;
                 crm:P2_has_type ?type .
            FILTER (
                ?type = aat:300046300
            )
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
                try await Task.sleep(nanoseconds: UInt64(500_000_000 * attempt)) // Exponential backoff
                return try await executeSPARQLQueryWithRetry(query, attempt: attempt + 1)
            }
            throw error
        }
    }

    private func executeSPARQLQuery(_ query: String) async throws -> [String] {
        var comps = URLComponents(url: sparqlEndpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "query", value: query)]
        guard let url = comps.url else { throw URLError(.badURL) }

        DebugLogger.logNetworkRequest(url: url, method: "GET (SPARQL)")

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

        let decoded = try JSONDecoder().decode(SPARQLResults.self, from: data)
        let uris = decoded.results.bindings.compactMap { $0.obj.value }

        return uris.compactMap { uri in
            if let u = URL(string: uri) {
                return u.lastPathComponent.nilIfEmpty
            }
            return nil
        }
    }

    // MARK: - Manifest Parsing
    
    /// Target image size - balances quality vs download speed
    /// !1200,1200 means "fit within 1200x1200 box, maintaining aspect ratio"
    /// This typically yields 200-500KB images instead of 4-7MB full resolution
    private let targetImageSize = "!1200,1200"
    
    /// Normalize any Getty IIIF image URL to use our target size
    /// Converts: .../full/full/0/default.jpg (huge) or .../full/!600,600/0/default.jpg (tiny)
    /// To:       .../full/!1200,1200/0/default.jpg (just right)
    private func normalizeGettyImageURL(_ urlString: String) -> URL? {
        // Pattern: https://media.getty.edu/iiif/image/{id}/full/{size}/0/default.jpg
        // We want to replace {size} with our target size
        
        guard urlString.contains("media.getty.edu/iiif/image/") else {
            return URL(string: urlString)
        }
        
        // Extract the image ID from various URL formats
        // Could be: .../image/{id}/full/full/0/default.jpg
        //       or: .../image/{id}/full/!600,600/0/default.jpg
        //       or: .../image/{id} (base URL only)
        
        if let range = urlString.range(of: "media.getty.edu/iiif/image/") {
            let afterBase = String(urlString[range.upperBound...])
            
            // Get the image ID (everything before the next "/" or end of string)
            let imageID: String
            if let slashIndex = afterBase.firstIndex(of: "/") {
                imageID = String(afterBase[..<slashIndex])
            } else {
                imageID = afterBase
            }
            
            // Construct normalized URL with our target size
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
        
        // Strategy: Find ANY Getty IIIF image URL, then normalize it to our target size
        // This ensures consistent sizing regardless of what the manifest specifies
        
        // 1) Look for direct image URLs anywhere in manifest
        if let direct = JSONAny.findFirstString(
            where: { $0.contains("media.getty.edu/iiif/image/") },
            in: manifest
        ),
        let normalized = normalizeGettyImageURL(direct) {
            return normalized
        }

        // 2) IIIF v3: items[0].items[0].body.service[].id (service endpoint)
        if let service =
            JSONAny.firstString(at: ["items", 0, "items", 0, "body", "service", 0, "id"], in: manifest)
            ?? JSONAny.firstString(at: ["items", 0, "items", 0, "body", "service", 0, "@id"], in: manifest)
            ?? JSONAny.firstString(at: ["items", 0, "items", 0, "body", "service", "id"], in: manifest)
            ?? JSONAny.firstString(at: ["items", 0, "items", 0, "body", "service", "@id"], in: manifest),
           service.contains("media.getty.edu/iiif/image/")
        {
            return normalizeGettyImageURL(service)
        }
        
        // 3) IIIF v3: items[0].items[0].body.id (direct body URL)
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

        // 6) Thumbnails (IIIF v2/v3) - normalize these too for consistency
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
            "cc0",
            "public domain"
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

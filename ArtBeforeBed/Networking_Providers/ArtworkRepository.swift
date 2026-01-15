import Foundation

final class ArtworkRepository {

    private let providers: [MuseumProvider]

    /// Caps each provider pool to keep museum mix balanced
    private let perProviderCap = 350

    init(providers: [MuseumProvider]) {
        self.providers = providers
    }

    /// Loads provider-scoped IDs (e.g. "met:123", "cma:456", "getty:789")
    /// Optionally restricts which providers participate via allowedProviderIDs.
    func loadIDs(
        query: String,
        medium: String?,
        geo: String?,
        period: PeriodPreset,
        allowedProviderIDs: Set<String>? = nil
    ) async throws -> [String] {

        var lists: [[String]] = []
        var anySucceeded = false
        var lastError: Error?

        for p in providers {
            if let allowed = allowedProviderIDs, !allowed.contains(p.providerID) {
                continue
            }

            do {
                var ids = try await p.fetchArtworkIDs(
                    query: query,
                    medium: medium,
                    geo: geo,
                    period: period
                )

                // Balance: cap and shuffle each provider so one museum doesn't dominate
                if ids.count > perProviderCap {
                    ids.shuffle()
                    ids = Array(ids.prefix(perProviderCap))
                }

                if !ids.isEmpty {
                    ids.shuffle()
                    lists.append(ids)
                    anySucceeded = true
                }
            } catch {
                lastError = error
                continue
            }
        }

        guard anySucceeded, !lists.isEmpty else {
            throw lastError ?? URLError(.cannotLoadFromNetwork)
        }

        // Interleave each provider list to keep variety
        return roundRobinMerge(lists)
    }

    func loadArtwork(id: String) async throws -> Artwork {
        let prefix = id.split(separator: ":").first.map(String.init) ?? ""

        guard let provider = providers.first(where: { $0.providerID == prefix }) else {
            throw URLError(.badURL)
        }

        return try await provider.fetchArtwork(id: id)
    }

    private func roundRobinMerge(_ lists: [[String]]) -> [String] {
        var indices = Array(repeating: 0, count: lists.count)
        var result: [String] = []
        result.reserveCapacity(lists.reduce(0) { $0 + $1.count })

        var didAppend = true
        while didAppend {
            didAppend = false
            for i in lists.indices {
                let idx = indices[i]
                if idx < lists[i].count {
                    result.append(lists[i][idx])
                    indices[i] += 1
                    didAppend = true
                }
            }
        }
        return result
    }
}

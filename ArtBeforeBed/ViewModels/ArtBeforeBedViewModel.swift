import Foundation
import Combine
import UIKit

@MainActor
final class ArtBeforeBedViewModel: ObservableObject {

    @Published var current: Artwork?
    @Published var nextArt: Artwork?
    @Published var prevArt: Artwork?

    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    @Published var isAdvancing: Bool = false

    // Filters
    @Published var selectedMedium: String? = nil
    @Published var selectedGeo: String? = nil
    @Published var selectedPeriod: PeriodPreset = .any

    // NEW: museum picker
    @Published var selectedMuseum: MuseumSelection = .mixed

    let mediumOptions: [String] = [
        "Paintings",
        "Photographs",
        "Prints",
        "Drawings",
        "Sculpture",
        "Ceramics",
        "Textiles",
        "Furniture",
        "Arms and Armor"
    ]

    let geoOptions: [String] = [
        "United States",
        "France",
        "Italy",
        "Netherlands",
        "Spain",
        "England",
        "Germany",
        "Japan",
        "China",
        "India",
        "Mexico",
        "Greece",
        "Egypt"
    ]

    private let repository = ArtworkRepository(providers: [
        MetProvider(),
        AICProvider(),
        CMAProvider(),
        GettyProvider()
    ])


    private var ids: [String] = []
    private var used: Set<String> = []

    private let maxHistoryCount = 20
    private var history: [Artwork] = []
    private var historyIndex: Int = -1

    private let prefetcher = ImagePrefetcher()

    private let maxAutoRetries = 1
    private let retryDelayNs: UInt64 = 600_000_000

    func start() async {
        await loadWithRetry { [self] in
            try await self.reloadIDs()
            self.clearHistory()
            try await self.loadNextArtworkAndPushToHistory()
            await self.prefetchNeighbors()
        }
    }

    func applyFilters(medium: String?, geo: String?, period: PeriodPreset, museum: MuseumSelection) async {
        selectedMedium = medium
        selectedGeo = geo
        selectedPeriod = period
        selectedMuseum = museum

        await start()
    }

    func swipeNext() async {
        guard !isAdvancing else { return }
        isAdvancing = true
        defer { isAdvancing = false }

        errorMessage = nil

        do {
            if canGoForwardInHistory {
                historyIndex += 1
                current = history[historyIndex]
            } else {
                let consumedNext = nextArt
                nextArt = nil

                if let prefetched = consumedNext {
                    pushToHistory(prefetched)
                } else {
                    try await loadNextArtworkAndPushToHistory()
                }
            }

            await prefetchNeighbors()
        } catch {
            errorMessage = "Failed to load next artwork."
        }
    }

    func swipePrevious() async {
        guard !isAdvancing else { return }
        guard canGoBackInHistory else { return }

        isAdvancing = true
        defer { isAdvancing = false }

        historyIndex -= 1
        current = history[historyIndex]
        await prefetchNeighbors()
    }

    var canGoBackInHistory: Bool { historyIndex > 0 }

    private var canGoForwardInHistory: Bool {
        historyIndex >= 0 && historyIndex < (history.count - 1)
    }

    private func loadWithRetry(_ block: @escaping () async throws -> Void) async {
        isLoading = true
        errorMessage = nil
        isAdvancing = false

        var attempt = 0
        while true {
            do {
                try await block()
                break
            } catch {
                if attempt < maxAutoRetries {
                    attempt += 1
                    try? await Task.sleep(nanoseconds: retryDelayNs)
                    continue
                } else {
                    errorMessage = "Failed to load artwork. Please try again."
                    break
                }
            }
        }

        isLoading = false
    }

    private func clearHistory() {
        history.removeAll()
        historyIndex = -1
        current = nil
        nextArt = nil
        prevArt = nil
    }

    private func reloadIDs() async throws {
        ids = try await repository.loadIDs(
            query: "painting",
            medium: selectedMedium,
            geo: selectedGeo,
            period: selectedPeriod,
            allowedProviderIDs: selectedMuseum.allowedProviderIDs
        )

        used.removeAll()
        ids.shuffle()
    }

    private func pushToHistory(_ obj: Artwork) {
        if canGoForwardInHistory {
            history = Array(history.prefix(historyIndex + 1))
        }

        if history.count == maxHistoryCount {
            history.removeFirst()
            historyIndex = max(0, historyIndex - 1)
        }

        history.append(obj)
        historyIndex = history.count - 1
        current = obj
    }

    private func loadNextArtworkAndPushToHistory() async throws {
        let obj = try await loadNextArtworkAvoidingDuplicates()
        pushToHistory(obj)
    }

    private func loadNextArtworkAvoidingDuplicates() async throws -> Artwork {
        guard !ids.isEmpty else { throw URLError(.badURL) }

        let currentID = current?.id
        let avoidIDs: Set<String> = Set([currentID].compactMap { $0 })

        let currentURL = current?.imageURL.absoluteString

        for _ in 0..<200 {
            guard let candidateID = ids.randomElement() else { break }

            if avoidIDs.contains(candidateID) { continue }
            if used.contains(candidateID) { continue }
            used.insert(candidateID)

            do {
                let art = try await repository.loadArtwork(id: candidateID)

                if let cur = currentURL, art.imageURL.absoluteString == cur {
                    continue
                }

                return art
            } catch {
                continue
            }
        }

        throw URLError(.cannotLoadFromNetwork)
    }

    private func prefetchNeighbors() async {
        if canGoBackInHistory {
            prevArt = history[historyIndex - 1]
        } else {
            prevArt = nil
        }

        if canGoForwardInHistory {
            nextArt = history[historyIndex + 1]
        } else {
            do {
                let candidate = try await loadNextArtworkAvoidingDuplicates()
                nextArt = candidate
            } catch {
                nextArt = nil
            }
        }

        var urls: [URL] = []
        if let u = current?.imageURL { urls.append(u) }
        if let u = nextArt?.imageURL { urls.append(u) }
        if let u = prevArt?.imageURL { urls.append(u) }
        prefetcher.prefetch(urls)
    }
}

final class ImagePrefetcher {
    func prefetch(_ urls: [URL]) {
        for url in urls {
            let req = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 30)
            URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()
        }
    }
}

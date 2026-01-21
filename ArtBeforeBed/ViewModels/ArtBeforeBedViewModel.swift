import Foundation
import Combine
import UIKit

@MainActor
final class ArtBeforeBedViewModel: ObservableObject {
    
    // MARK: - Published State
    
    @Published var current: Artwork?
    @Published var nextArt: Artwork?
    @Published var prevArt: Artwork?
    
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var isAdvancing: Bool = false
    
    // Published images for the carousel - these drive the UI
    @Published var currentImage: UIImage?
    @Published var nextImage: UIImage?
    @Published var prevImage: UIImage?
    
    // Filters
    @Published var selectedMedium: String? = nil
    @Published var selectedGeo: String? = nil
    @Published var selectedPeriod: PeriodPreset = .any
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
    
    // MARK: - Private State
    
    private let repository = ArtworkRepository(providers: [
        MetProvider(),
        AICProvider(),
        CMAProvider(),
        GettyProvider(),
        RijksmuseumProvider(),
        YaleProvider()
    ])
    
    private var ids: [String] = []
    private var used: Set<String> = []
    
    private let maxHistoryCount = 20
    private var history: [Artwork] = []
    private var historyIndex: Int = -1
    
    private let maxAutoRetries = 1
    private let retryDelayNs: UInt64 = 600_000_000
    
    // MARK: - Public Methods
    
    func start() async {
        await loadWithRetry { [self] in
            try await self.reloadIDs()
            self.clearHistory()
            try await self.loadNextArtworkAndPushToHistory()
            
            // Load the current image before showing
            if let current = self.current {
                self.currentImage = await ImageCache.shared.loadImage(for: current.imageURL)
            }
            
            await self.prefetchNeighbors()
        }
    }
    
    func applyFilters(medium: String?, geo: String?, period: PeriodPreset, museum: MuseumSelection) async {
        selectedMedium = medium
        selectedGeo = geo
        selectedPeriod = period
        selectedMuseum = museum
        
        // Clear cached images when filters change
        await ImageCache.shared.clear()
        currentImage = nil
        nextImage = nil
        prevImage = nil
        
        await start()
    }
    
    /// Swipe to next artwork. Returns true if the next image is ready for immediate display.
    func swipeNext() async -> Bool {
        guard !isAdvancing else { return false }
        isAdvancing = true
        defer { isAdvancing = false }
        
        errorMessage = nil
        
        do {
            if canGoForwardInHistory {
                // Moving forward in history
                historyIndex += 1
                current = history[historyIndex]
                
                // Use cached next image if available
                if let current {
                    if let cached = await ImageCache.shared.image(for: current.imageURL) {
                        currentImage = cached
                    } else {
                        currentImage = await ImageCache.shared.loadImage(for: current.imageURL)
                    }
                }
            } else {
                // Need to load new artwork
                let consumedNext = nextArt
                let consumedNextImage = nextImage
                nextArt = nil
                nextImage = nil
                
                if let prefetched = consumedNext {
                    pushToHistory(prefetched)
                    // Use the prefetched image if available
                    if let img = consumedNextImage {
                        currentImage = img
                    } else {
                        currentImage = await ImageCache.shared.loadImage(for: prefetched.imageURL)
                    }
                } else {
                    try await loadNextArtworkAndPushToHistory()
                    if let current {
                        currentImage = await ImageCache.shared.loadImage(for: current.imageURL)
                    }
                }
            }
            
            await prefetchNeighbors()
            return true
        } catch {
            errorMessage = "Failed to load next artwork."
            return false
        }
    }
    
    /// Swipe to previous artwork. Returns true if successful.
    func swipePrevious() async -> Bool {
        guard !isAdvancing else { return false }
        guard canGoBackInHistory else { return false }
        
        isAdvancing = true
        defer { isAdvancing = false }
        
        historyIndex -= 1
        current = history[historyIndex]
        
        // Use cached prev image if available
        if let current {
            if let cached = await ImageCache.shared.image(for: current.imageURL) {
                currentImage = cached
            } else {
                currentImage = await ImageCache.shared.loadImage(for: current.imageURL)
            }
        }
        
        await prefetchNeighbors()
        return true
    }
    
    var canGoBackInHistory: Bool { historyIndex > 0 }
    
    /// Check if next image is ready for smooth transition
    func isNextImageReady() async -> Bool {
        guard let nextArt else { return false }
        return await ImageCache.shared.isCached(nextArt.imageURL)
    }
    
    /// Check if previous image is ready
    func isPrevImageReady() async -> Bool {
        guard let prevArt else { return false }
        return await ImageCache.shared.isCached(prevArt.imageURL)
    }
    
    // MARK: - Private Methods
    
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
        currentImage = nil
        nextImage = nil
        prevImage = nil
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
        // Set up prev artwork reference
        if canGoBackInHistory {
            prevArt = history[historyIndex - 1]
        } else {
            prevArt = nil
        }
        
        // Set up next artwork reference
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
        
        // Prefetch images using the cache
        var urlsToPrefetch: [URL] = []
        
        // Prioritize next image
        if let nextArt {
            urlsToPrefetch.append(nextArt.imageURL)
        }
        
        // Then prev image
        if let prevArt {
            urlsToPrefetch.append(prevArt.imageURL)
        }
        
        // Start prefetching
        await ImageCache.shared.prefetch(urlsToPrefetch)
        
        // Update published images for the carousel
        // Do this after prefetch starts so images load in parallel
        if let nextArt {
            nextImage = await ImageCache.shared.loadImage(for: nextArt.imageURL)
        } else {
            nextImage = nil
        }
        
        if let prevArt {
            prevImage = await ImageCache.shared.loadImage(for: prevArt.imageURL)
        } else {
            prevImage = nil
        }
    }
}

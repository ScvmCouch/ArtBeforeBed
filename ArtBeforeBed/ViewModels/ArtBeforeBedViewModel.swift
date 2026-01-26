import Foundation
import Combine
import UIKit

@MainActor
final class ArtBeforeBedViewModel: ObservableObject {
    
    // MARK: - Published State
    
    @Published var current: Artwork?
    @Published var nextArt: Artwork?
    
    /// Whether there's a next artwork ready (even if image isn't loaded yet)
    var hasNextArtwork: Bool { nextArt != nil }
    
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
    
    /// Medium types supported across all museum providers
    /// Each provider maps these to their specific filtering mechanism
    let mediumOptions: [String] = [
        "Paintings",
        "Drawings",
        "Prints",
        "Photographs"
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
    
    // MARK: - Prefetch Queue
    // Keep a buffer of pre-fetched artworks ready to go
    private var prefetchedArtworks: [Artwork] = []
    private let prefetchBufferSize = 3
    private var isPrefetching = false
    
    // Track artworks whose images failed to load - don't reuse them
    private var failedImageURLs: Set<URL> = []
    
    // MARK: - Public Methods
    
    func start() async {
        await loadWithRetry { [self] in
            try await self.reloadIDs()
            self.clearHistory()
            self.prefetchedArtworks.removeAll()
            
            try await self.loadNextArtworkAndPushToHistory()
            
            // Load the current image before showing
            if let current = self.current {
                self.currentImage = await ImageCache.shared.loadImage(for: current.imageURL)
            }
            
            // Start aggressive prefetching in background
            await self.prefetchNeighbors()
            self.startBackgroundPrefetch()
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
        prefetchedArtworks.removeAll()
        failedImageURLs.removeAll()
        
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
                
                if let current {
                    if let cached = await ImageCache.shared.image(for: current.imageURL) {
                        currentImage = cached
                    } else {
                        currentImage = await ImageCache.shared.loadImage(for: current.imageURL)
                    }
                }
            } else if let next = nextArt {
                // Use the pre-assigned nextArt
                pushToHistory(next)
                nextArt = nil  // Clear it so prefetchNeighbors will assign a new one
                
                if let img = nextImage {
                    currentImage = img
                    nextImage = nil
                } else {
                    // Try to load the image
                    let loadedImage = await ImageCache.shared.loadImage(for: next.imageURL)
                    if let loadedImage {
                        currentImage = loadedImage
                    } else {
                        // Image failed to load - mark it and try to get another artwork
                        print("🔴 [SWIPE] Image failed to load for \(next.id), skipping...")
                        failedImageURLs.insert(next.imageURL)
                        
                        // Try to load another artwork
                        await prefetchNeighbors()
                        if let fallbackNext = nextArt {
                            pushToHistory(fallbackNext)
                            nextArt = nil
                            currentImage = await ImageCache.shared.loadImage(for: fallbackNext.imageURL)
                        }
                    }
                }
            } else {
                // Fallback: load on demand (shouldn't normally happen)
                print("🟡 [SWIPE] No nextArt available, loading on-demand")
                try await loadNextArtworkAndPushToHistory()
                if let current {
                    currentImage = await ImageCache.shared.loadImage(for: current.imageURL)
                }
            }
            
            await prefetchNeighbors()
            startBackgroundPrefetch()
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
        // This is called during swipe - nextArt should already be set
        // Just load fresh from IDs as fallback
        return try await loadNextArtworkFromIDs()
    }
    
    /// Load a new artwork from the ID pool (not from prefetch buffer)
    private func loadNextArtworkFromIDs() async throws -> Artwork {
        guard !ids.isEmpty else { throw URLError(.badURL) }
        
        let currentID = current?.id
        var avoidIDs: Set<String> = Set([currentID].compactMap { $0 })
        
        // Also avoid anything already in prefetch buffer or history
        avoidIDs.formUnion(prefetchedArtworks.map { $0.id })
        avoidIDs.formUnion(history.map { $0.id })
        if let next = nextArt {
            avoidIDs.insert(next.id)
        }
        
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
                
                // Skip if this image URL has failed before
                if failedImageURLs.contains(art.imageURL) {
                    print("🔴 [LOAD] Skipping \(candidateID) - image URL previously failed")
                    continue
                }
                
                return art
            } catch {
                continue
            }
        }
        
        throw URLError(.cannotLoadFromNetwork)
    }
    
    // MARK: - Background Prefetch System
    
    /// Starts background prefetching of artwork metadata
    /// This runs independently and keeps a buffer of ready-to-use artworks
    private func startBackgroundPrefetch() {
        guard !isPrefetching else { return }
        
        Task { [weak self] in
            await self?.fillPrefetchBuffer()
        }
    }
    
    private func fillPrefetchBuffer() async {
        guard !isPrefetching else { return }
        isPrefetching = true
        defer { isPrefetching = false }
        
        while prefetchedArtworks.count < prefetchBufferSize {
            guard !ids.isEmpty else { break }
            
            // Get IDs to avoid (current, history, already prefetched)
            var avoidIDs = Set(history.map { $0.id })
            avoidIDs.formUnion(prefetchedArtworks.map { $0.id })
            if let currentID = current?.id {
                avoidIDs.insert(currentID)
            }
            
            // Find a candidate
            var candidateID: String?
            for _ in 0..<50 {
                guard let id = ids.randomElement() else { break }
                if !avoidIDs.contains(id) && !used.contains(id) {
                    candidateID = id
                    break
                }
            }
            
            guard let id = candidateID else { break }
            used.insert(id)
            
            print("🔄 [PREFETCH] Loading metadata for: \(id)")
            
            do {
                let art = try await repository.loadArtwork(id: id)
                
                // Also start prefetching the image immediately
                Task {
                    await ImageCache.shared.prefetch([art.imageURL])
                }
                
                prefetchedArtworks.append(art)
                print("🟢 [PREFETCH] Buffer now has \(prefetchedArtworks.count) artworks ready")
                
            } catch {
                print("🔴 [PREFETCH] Failed to load \(id): \(error)")
                continue
            }
        }
    }
    
    // MARK: - Neighbor Prefetch (for prev/next UI)
    
    private func prefetchNeighbors() async {
        // Set up prev artwork reference
        if canGoBackInHistory {
            prevArt = history[historyIndex - 1]
        } else {
            prevArt = nil
        }
        
        // Set up next artwork reference
        if canGoForwardInHistory {
            // We're in history - use the history item
            // Clear any stale nextArt that might have been prefetched before we went back
            let historyNext = history[historyIndex + 1]
            if nextArt?.id != historyNext.id {
                // nextArt is stale (from before we navigated back), clear it
                nextArt = nil
            }
            nextArt = historyNext
        } else if nextArt == nil || history.contains(where: { $0.id == nextArt?.id }) || failedImageURLs.contains(nextArt?.imageURL ?? URL(fileURLWithPath: "")) {
            // We need a new nextArt - either we don't have one,
            // or the current one is already in history (would be duplicate),
            // or its image failed to load
            nextArt = nil
            
            // Remove any artworks with failed images from the buffer
            prefetchedArtworks.removeAll { failedImageURLs.contains($0.imageURL) }
            
            // Use from prefetch buffer if available, otherwise load
            if !prefetchedArtworks.isEmpty {
                let prefetched = prefetchedArtworks.removeFirst()
                nextArt = prefetched
                print("🟢 [PREFETCH] Assigned from buffer: \(prefetched.id)")
            } else {
                do {
                    print("🟡 [PREFETCH] Buffer empty, loading on-demand...")
                    let candidate = try await loadNextArtworkFromIDs()
                    nextArt = candidate
                } catch {
                    nextArt = nil
                }
            }
        }
        // else: nextArt is already set and valid, keep it
        
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
        
        // Also prefetch images for anything in the buffer
        for art in prefetchedArtworks {
            if !urlsToPrefetch.contains(art.imageURL) {
                urlsToPrefetch.append(art.imageURL)
            }
        }
        
        // Start prefetching all images
        await ImageCache.shared.prefetch(urlsToPrefetch)
        
        // Update published images for the carousel
        // Load next image first (higher priority)
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

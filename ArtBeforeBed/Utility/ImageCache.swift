import UIKit

/// Thread-safe image cache using Swift actor for concurrent access
actor ImageCache {
    static let shared = ImageCache()
    
    private var cache: [URL: UIImage] = [:]
    private var inFlightTasks: [URL: Task<UIImage?, Never>] = [:]
    
    /// Maximum number of images to keep in cache
    private let maxCacheSize = 20
    private var accessOrder: [URL] = []
    
    /// Get cached image synchronously (returns nil if not cached)
    func image(for url: URL) -> UIImage? {
        if let image = cache[url] {
            // Update access order for LRU
            if let index = accessOrder.firstIndex(of: url) {
                accessOrder.remove(at: index)
            }
            accessOrder.append(url)
            return image
        }
        return nil
    }
    
    /// Load image, using cache if available
    func loadImage(for url: URL) async -> UIImage? {
        // Return cached immediately
        if let cached = cache[url] {
            // Update access order
            if let index = accessOrder.firstIndex(of: url) {
                accessOrder.remove(at: index)
            }
            accessOrder.append(url)
            return cached
        }
        
        // Join existing task if already loading this URL
        if let existing = inFlightTasks[url] {
            return await existing.value
        }
        
        // Start new load task
        let task = Task<UIImage?, Never> {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                
                // Validate response
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    return nil
                }
                
                // Create image
                guard let image = UIImage(data: data) else {
                    return nil
                }
                
                return image
            } catch {
                print("ImageCache: Failed to load \(url): \(error.localizedDescription)")
                return nil
            }
        }
        
        inFlightTasks[url] = task
        let image = await task.value
        inFlightTasks[url] = nil
        
        // Cache the result
        if let image {
            addToCache(url: url, image: image)
        }
        
        return image
    }
    
    /// Prefetch multiple URLs in the background
    func prefetch(_ urls: [URL]) {
        for url in urls {
            // Skip if already cached or loading
            guard cache[url] == nil, inFlightTasks[url] == nil else { continue }
            
            Task {
                _ = await loadImage(for: url)
            }
        }
    }
    
    /// Check if an image is cached
    func isCached(_ url: URL) -> Bool {
        cache[url] != nil
    }
    
    /// Clear the entire cache
    func clear() {
        cache.removeAll()
        inFlightTasks.values.forEach { $0.cancel() }
        inFlightTasks.removeAll()
        accessOrder.removeAll()
    }
    
    /// Remove a specific URL from cache
    func remove(_ url: URL) {
        cache[url] = nil
        if let index = accessOrder.firstIndex(of: url) {
            accessOrder.remove(at: index)
        }
    }
    
    // MARK: - Private
    
    private func addToCache(url: URL, image: UIImage) {
        // Evict oldest if at capacity
        while cache.count >= maxCacheSize, let oldest = accessOrder.first {
            cache[oldest] = nil
            accessOrder.removeFirst()
        }
        
        cache[url] = image
        accessOrder.append(url)
    }
}

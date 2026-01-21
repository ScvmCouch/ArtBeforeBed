import SwiftUI
import Combine

// Image loader that caches UIImages
@MainActor
class ImageLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var isLoading = false
    
    private static var cache: [URL: UIImage] = [:]
    private static var inProgressLoads: [URL: AnyCancellable] = [:]
    private var cancellable: AnyCancellable?
    private var currentURL: URL?
    
    func load(url: URL) {
        currentURL = url
        
        // Check cache first - SYNCHRONOUSLY
        if let cached = Self.cache[url] {
            self.image = cached
            self.isLoading = false
            return
        }
        
        // Check if already loading
        if let existingLoad = Self.inProgressLoads[url] {
            // Already loading, just wait for it
            isLoading = true
            return
        }
        
        isLoading = true
        
        let task = URLSession.shared.dataTaskPublisher(for: url)
            .map { UIImage(data: $0.data) }
            .replaceError(with: nil)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] downloadedImage in
                guard let self = self else { return }
                
                // Only update if we're still loading this URL
                if self.currentURL == url {
                    self.image = downloadedImage
                    self.isLoading = false
                }
                
                // Cache it
                if let img = downloadedImage {
                    Self.cache[url] = img
                }
                
                // Remove from in-progress
                Self.inProgressLoads.removeValue(forKey: url)
            }
        
        Self.inProgressLoads[url] = task
        cancellable = task
    }
    
    func cancel() {
        cancellable?.cancel()
    }
    
    static func clearCache() {
        cache.removeAll()
        inProgressLoads.removeAll()
    }
    
    static func preload(url: URL) {
        // Start loading in background if not cached
        guard cache[url] == nil, inProgressLoads[url] == nil else { return }
        
        let task = URLSession.shared.dataTaskPublisher(for: url)
            .map { UIImage(data: $0.data) }
            .replaceError(with: nil)
            .receive(on: DispatchQueue.main)
            .sink { downloadedImage in
                if let img = downloadedImage {
                    cache[url] = img
                }
                inProgressLoads.removeValue(forKey: url)
            }
        
        inProgressLoads[url] = task
    }
}

// Cached async image view
struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL
    let content: (Image) -> Content
    let placeholder: () -> Placeholder
    
    @StateObject private var loader = ImageLoader()
    
    init(
        url: URL,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.content = content
        self.placeholder = placeholder
    }
    
    var body: some View {
        Group {
            if let uiImage = loader.image {
                content(Image(uiImage: uiImage))
            } else {
                placeholder()
            }
        }
        .onAppear {
            loader.load(url: url)
        }
    }
}

import SwiftUI
import UIKit

/// UIKit-based paging carousel wrapped for SwiftUI
/// Provides smooth paging transitions and zoom/pan on the current image
struct CarouselView: UIViewControllerRepresentable {
    @ObservedObject var vm: ArtBeforeBedViewModel
    
    let onTap: () -> Void
    
    func makeUIViewController(context: Context) -> CarouselViewController {
        let vc = CarouselViewController()
        vc.delegate = context.coordinator
        context.coordinator.viewController = vc
        return vc
    }
    
    func updateUIViewController(_ vc: CarouselViewController, context: Context) {
        vc.updatePages(
            prev: vm.prevImage,
            current: vm.currentImage,
            next: vm.nextImage
        )
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, CarouselViewControllerDelegate {
        let parent: CarouselView
        weak var viewController: CarouselViewController?
        
        init(_ parent: CarouselView) {
            self.parent = parent
        }
        
        func carouselDidSwipeNext() {
            Task { @MainActor in
                _ = await parent.vm.swipeNext()
            }
        }
        
        func carouselDidSwipePrevious() {
            Task { @MainActor in
                _ = await parent.vm.swipePrevious()
            }
        }
        
        func carouselDidTap() {
            parent.onTap()
        }
        
        func carouselCanSwipePrevious() -> Bool {
            parent.vm.canGoBackInHistory
        }
        
        func carouselCanSwipeNext() -> Bool {
            // Allow swipe if we have either the image ready OR the artwork ready to load
            parent.vm.nextImage != nil || parent.vm.hasNextArtwork
        }
        
        func carouselGetCurrentImage() -> UIImage? {
            parent.vm.currentImage
        }
        
        func carouselGetNextImage() -> UIImage? {
            parent.vm.nextImage
        }
        
        func carouselGetPrevImage() -> UIImage? {
            parent.vm.prevImage
        }
    }
}

// MARK: - Delegate Protocol

protocol CarouselViewControllerDelegate: AnyObject {
    func carouselDidSwipeNext()
    func carouselDidSwipePrevious()
    func carouselDidTap()
    func carouselCanSwipePrevious() -> Bool
    func carouselCanSwipeNext() -> Bool
    func carouselGetCurrentImage() -> UIImage?
    func carouselGetNextImage() -> UIImage?
    func carouselGetPrevImage() -> UIImage?
}

// MARK: - Carousel View Controller

class CarouselViewController: UIViewController, UIScrollViewDelegate {
    
    weak var delegate: CarouselViewControllerDelegate?
    
    // Main paging scroll view
    private let pagingScrollView = UIScrollView()
    
    // Three zoomable image views for prev/current/next
    private let prevZoomView = ZoomableImageView()
    private let currentZoomView = ZoomableImageView()
    private let nextZoomView = ZoomableImageView()
    
    private var isSettingUp = true
    private var isResetting = false
    
    // Pending navigation tracking
    enum PendingNavigation: Equatable {
        case none
        case next(expectedImage: UIImage?)
        case previous(expectedImage: UIImage?)
        
        static func == (lhs: PendingNavigation, rhs: PendingNavigation) -> Bool {
            switch (lhs, rhs) {
            case (.none, .none): return true
            case (.next(let a), .next(let b)): return a === b
            case (.previous(let a), .previous(let b)): return a === b
            default: return false
            }
        }
        
        var isNone: Bool {
            if case .none = self { return true }
            return false
        }
    }
    private var pendingNavigation: PendingNavigation = .none
    private var pendingTimeoutWork: DispatchWorkItem?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupPagingScrollView()
        setupZoomViews()
        setupGestures()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPages()
    }
    
    // MARK: - Setup
    
    private func setupPagingScrollView() {
        pagingScrollView.isPagingEnabled = true
        pagingScrollView.showsHorizontalScrollIndicator = false
        pagingScrollView.showsVerticalScrollIndicator = false
        pagingScrollView.bounces = true
        pagingScrollView.delegate = self
        pagingScrollView.backgroundColor = .black
        
        view.addSubview(pagingScrollView)
        pagingScrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pagingScrollView.topAnchor.constraint(equalTo: view.topAnchor),
            pagingScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            pagingScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pagingScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }
    
    private func setupZoomViews() {
        for zoomView in [prevZoomView, currentZoomView, nextZoomView] {
            pagingScrollView.addSubview(zoomView)
        }
        
        // Only the current view handles zoom - disable on prev/next to avoid conflicts
        prevZoomView.isUserInteractionEnabled = false
        nextZoomView.isUserInteractionEnabled = false
        
        // Set up callback for when zoom changes
        currentZoomView.onZoomChanged = { [weak self] isZoomed in
            self?.updatePagingEnabled()
        }
    }
    
    private func setupGestures() {
        // Single tap is handled by the ZoomableImageView and forwarded to us
        // This avoids conflicts with the zoom scroll view
        currentZoomView.onSingleTap = { [weak self] in
            self?.delegate?.carouselDidTap()
        }
    }
    
    // MARK: - Layout
    
    private func layoutPages() {
        let pageWidth = view.bounds.width
        let pageHeight = view.bounds.height
        
        pagingScrollView.contentSize = CGSize(width: pageWidth * 3, height: pageHeight)
        
        prevZoomView.frame = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        currentZoomView.frame = CGRect(x: pageWidth, y: 0, width: pageWidth, height: pageHeight)
        nextZoomView.frame = CGRect(x: pageWidth * 2, y: 0, width: pageWidth, height: pageHeight)
        
        // Center on current page initially
        if isSettingUp {
            isSettingUp = false
            pagingScrollView.contentOffset = CGPoint(x: pageWidth, y: 0)
        }
    }
    
    private func updatePagingEnabled() {
        // Disable paging when zoomed in
        let isZoomed = currentZoomView.zoomScale > 1.01
        pagingScrollView.isScrollEnabled = !isZoomed
    }
    
    // MARK: - Public Methods
    
    func updatePages(prev: UIImage?, current: UIImage?, next: UIImage?) {
        pendingTimeoutWork?.cancel()
        pendingTimeoutWork = nil
        
        // Check if this satisfies a pending navigation
        switch pendingNavigation {
        case .next(let expectedImage):
            if expectedImage == nil || current === expectedImage {
                applyImages(prev: prev, current: current, next: next)
                recenter()
                pendingNavigation = .none
                return
            }
            
        case .previous(let expectedImage):
            if expectedImage == nil || current === expectedImage {
                applyImages(prev: prev, current: current, next: next)
                recenter()
                pendingNavigation = .none
                return
            }
            
        case .none:
            break
        }
        
        // Normal update - only if centered and no pending
        let pageWidth = view.bounds.width
        let currentPage = pageWidth > 0 ? Int(round(pagingScrollView.contentOffset.x / pageWidth)) : 1
        
        if currentPage == 1 && pendingNavigation.isNone {
            applyImages(prev: prev, current: current, next: next)
        }
    }
    
    private func applyImages(prev: UIImage?, current: UIImage?, next: UIImage?) {
        prevZoomView.setImage(prev)
        currentZoomView.setImage(current)
        nextZoomView.setImage(next)
    }
    
    private func recenter() {
        let pageWidth = view.bounds.width
        guard pageWidth > 0 else { return }
        
        isResetting = true
        pagingScrollView.setContentOffset(CGPoint(x: pageWidth, y: 0), animated: false)
        isResetting = false
        
        // Reset zoom on the current image when we navigate
        currentZoomView.resetZoom()
        updatePagingEnabled()
    }
    
    // MARK: - UIScrollViewDelegate (for paging)
    
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView == pagingScrollView, !isResetting else { return }
        
        let pageWidth = view.bounds.width
        guard pageWidth > 0 else { return }
        
        let offset = scrollView.contentOffset.x
        
        // Resistance at edges
        if offset < pageWidth && !(delegate?.carouselCanSwipePrevious() ?? false) {
            let resistance: CGFloat = 0.3
            scrollView.contentOffset.x = pageWidth - (pageWidth - offset) * resistance
        }
        
        if offset > pageWidth && !(delegate?.carouselCanSwipeNext() ?? false) {
            let resistance: CGFloat = 0.3
            scrollView.contentOffset.x = pageWidth + (offset - pageWidth) * resistance
        }
    }
    
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard scrollView == pagingScrollView else { return }
        
        // Force complete any pending navigation when user starts new drag
        if !pendingNavigation.isNone {
            pendingTimeoutWork?.cancel()
            pendingTimeoutWork = nil
            
            let prev = delegate?.carouselGetPrevImage()
            let current = delegate?.carouselGetCurrentImage()
            let next = delegate?.carouselGetNextImage()
            
            applyImages(prev: prev, current: current, next: next)
            recenter()
            pendingNavigation = .none
        }
    }
    
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView == pagingScrollView else { return }
        handlePageChange()
    }
    
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollView == pagingScrollView, !decelerate else { return }
        handlePageChange()
    }
    
    private func handlePageChange() {
        let pageWidth = view.bounds.width
        guard pageWidth > 0 else { return }
        
        let page = Int(round(pagingScrollView.contentOffset.x / pageWidth))
        
        if page == 0 && (delegate?.carouselCanSwipePrevious() ?? false) {
            let expectedImage = delegate?.carouselGetPrevImage()
            pendingNavigation = .previous(expectedImage: expectedImage)
            delegate?.carouselDidSwipePrevious()
            startPendingTimeout()
            
        } else if page == 2 && (delegate?.carouselCanSwipeNext() ?? false) {
            let expectedImage = delegate?.carouselGetNextImage()
            pendingNavigation = .next(expectedImage: expectedImage)
            delegate?.carouselDidSwipeNext()
            startPendingTimeout()
            
        } else if page != 1 {
            recenter()
        }
    }
    
    private func startPendingTimeout() {
        pendingTimeoutWork?.cancel()
        
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, !self.pendingNavigation.isNone else { return }
            
            let prev = self.delegate?.carouselGetPrevImage()
            let current = self.delegate?.carouselGetCurrentImage()
            let next = self.delegate?.carouselGetNextImage()
            
            self.applyImages(prev: prev, current: current, next: next)
            self.recenter()
            self.pendingNavigation = .none
        }
        pendingTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}

// MARK: - Zoomable Image View

class ZoomableImageView: UIScrollView, UIScrollViewDelegate {
    
    private let imageView = UIImageView()
    
    var onZoomChanged: ((Bool) -> Void)?
    var onSingleTap: (() -> Void)?
    
    private let maxZoomScale: CGFloat = 5.0
    private let doubleTapZoomScale: CGFloat = 2.5
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }
    
    private func setup() {
        delegate = self
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        backgroundColor = .black
        minimumZoomScale = 1.0
        maximumZoomScale = maxZoomScale
        bouncesZoom = true
        
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .black
        imageView.isUserInteractionEnabled = true
        addSubview(imageView)
        
        // Single tap gesture - for info toggle, doesn't affect zoom
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.numberOfTapsRequired = 1
        imageView.addGestureRecognizer(singleTap)
        
        // Double tap gesture - for zoom
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        imageView.addGestureRecognizer(doubleTap)
        
        // Single tap requires double tap to fail first
        singleTap.require(toFail: doubleTap)
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        centerImageIfNeeded()
    }
    
    // MARK: - Public Methods
    
    func setImage(_ image: UIImage?) {
        imageView.image = image
        
        if let image = image {
            // Size imageView to the image's aspect ratio within our bounds
            let imageSize = image.size
            let boundsSize = bounds.size
            
            guard imageSize.width > 0 && imageSize.height > 0 else {
                imageView.frame = bounds
                return
            }
            
            let widthRatio = boundsSize.width / imageSize.width
            let heightRatio = boundsSize.height / imageSize.height
            let scale = min(widthRatio, heightRatio)
            
            let scaledWidth = imageSize.width * scale
            let scaledHeight = imageSize.height * scale
            
            imageView.frame = CGRect(
                x: (boundsSize.width - scaledWidth) / 2,
                y: (boundsSize.height - scaledHeight) / 2,
                width: scaledWidth,
                height: scaledHeight
            )
            
            contentSize = bounds.size
            resetZoom()
        } else {
            imageView.frame = bounds
            resetZoom()
        }
    }
    
    func resetZoom() {
        setZoomScale(1.0, animated: false)
        contentOffset = .zero
        centerImageIfNeeded()
        onZoomChanged?(false)
    }
    
    // MARK: - Gesture Handlers
    
    @objc private func handleSingleTap() {
        // Just forward to callback - don't affect zoom at all
        onSingleTap?()
    }
    
    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > 1.01 {
            // Zoom out
            setZoomScale(1.0, animated: true)
        } else {
            // Zoom in to tap location
            let location = gesture.location(in: imageView)
            let zoomRect = zoomRectForScale(doubleTapZoomScale, center: location)
            zoom(to: zoomRect, animated: true)
        }
    }
    
    private func zoomRectForScale(_ scale: CGFloat, center: CGPoint) -> CGRect {
        let width = bounds.width / scale
        let height = bounds.height / scale
        let x = center.x - (width / 2)
        let y = center.y - (height / 2)
        return CGRect(x: x, y: y, width: width, height: height)
    }
    
    // MARK: - UIScrollViewDelegate
    
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        return imageView
    }
    
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImageIfNeeded()
        onZoomChanged?(zoomScale > 1.01)
    }
    
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        // Snap to 1.0 if very close
        if scale < 1.05 && scale > 0.95 {
            setZoomScale(1.0, animated: true)
        }
        onZoomChanged?(zoomScale > 1.01)
    }
    
    // MARK: - Centering
    
    private func centerImageIfNeeded() {
        guard let image = imageView.image else { return }
        
        let boundsSize = bounds.size
        var frameToCenter = imageView.frame
        
        // Center horizontally
        if frameToCenter.width < boundsSize.width {
            frameToCenter.origin.x = (boundsSize.width - frameToCenter.width) / 2
        } else {
            frameToCenter.origin.x = 0
        }
        
        // Center vertically
        if frameToCenter.height < boundsSize.height {
            frameToCenter.origin.y = (boundsSize.height - frameToCenter.height) / 2
        } else {
            frameToCenter.origin.y = 0
        }
        
        imageView.frame = frameToCenter
    }
}

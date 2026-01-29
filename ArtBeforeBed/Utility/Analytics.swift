import Foundation
import TelemetryClient

/// Analytics wrapper for TelemetryDeck
/// Tracks anonymous usage patterns and errors
final class Analytics {
    static let shared = Analytics()
    
    private var isInitialized = false
    
    private init() {}
    
    // MARK: - Setup
    
    /// Initialize TelemetryDeck with your app ID
    /// Call this in your App's init or AppDelegate
    func initialize() {
        let config = TelemetryManagerConfiguration(
            appID: "1E3726A3-9954-4FE4-9455-E657187FBF3F"  // Replace with your TelemetryDeck App ID
        )
        TelemetryManager.initialize(with: config)
        isInitialized = true
        
        // Track app launch
        track("app_launched")
    }
    
    // MARK: - Event Tracking
    
    /// Track a simple event
    func track(_ event: String) {
        guard isInitialized else { return }
        TelemetryManager.send(event)
    }
    
    /// Track an event with parameters
    func track(_ event: String, with parameters: [String: String]) {
        guard isInitialized else { return }
        TelemetryManager.send(event, with: parameters)
    }
    
    // MARK: - Predefined Events
    
    /// Track artwork viewed
    func trackArtworkViewed(provider: String, artworkId: String) {
        track("artwork_viewed", with: [
            "provider": provider,
            "artwork_id": artworkId
        ])
    }
    
    /// Track swipe action
    func trackSwipe(direction: String) {
        track("swipe", with: ["direction": direction])
    }
    
    /// Track filter applied
    func trackFilterApplied(museum: String?, medium: String?) {
        var params: [String: String] = [:]
        if let museum = museum {
            params["museum"] = museum
        }
        if let medium = medium {
            params["medium"] = medium
        }
        track("filter_applied", with: params)
    }
    
    /// Track error occurred
    func trackError(type: String, message: String, provider: String? = nil) {
        var params: [String: String] = [
            "error_type": type,
            "message": message
        ]
        if let provider = provider {
            params["provider"] = provider
        }
        track("error", with: params)
    }
    
    /// Track session duration when app backgrounds
    func trackSessionEnd(artworksViewed: Int, duration: TimeInterval) {
        track("session_end", with: [
            "artworks_viewed": String(artworksViewed),
            "duration_seconds": String(Int(duration))
        ])
    }
    
    /// Track info panel shown
    func trackInfoPanelShown() {
        track("info_panel_shown")
    }
    
    /// Track share action
    func trackShare(provider: String) {
        track("share", with: ["provider": provider])
    }
    
    /// Track offline state
    func trackOffline() {
        track("went_offline")
    }
    
    /// Track reconnection
    func trackReconnected() {
        track("reconnected")
    }
}

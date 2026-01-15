import Foundation

// MARK: - AIC Search

struct AICSearchResponse: Codable {
    let data: [AICSearchHit]
    let pagination: AICPagination?
    let config: AICConfig?
}

struct AICSearchHit: Codable {
    let id: Int
}

struct AICPagination: Codable {
    let total: Int?
    let limit: Int?
    let offset: Int?
    let current_page: Int?
    let total_pages: Int?
    let next_url: String?
    let prev_url: String?
}

struct AICConfig: Codable {
    let iiif_url: String?
    let website_url: String?
}

// MARK: - AIC Artwork Detail

struct AICArtworkResponse: Codable {
    let data: AICArtwork
    let config: AICConfig?
}

struct AICArtwork: Codable {
    let id: Int
    let title: String?
    let artist_display: String?
    let date_display: String?
    let medium_display: String?
    let image_id: String?
    let is_public_domain: Bool?
}

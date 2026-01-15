import Foundation

// MARK: - Cleveland Museum of Art Search

struct CMASearchResponse: Codable {
    let data: [CMASearchItem]
}

struct CMASearchItem: Codable {
    let id: Int
}

// MARK: - Cleveland Museum of Art Artwork Detail

struct CMAArtworkResponse: Codable {
    let data: CMAArtwork
}

struct CMAArtwork: Codable {
    let id: Int
    let title: String?
    let creators: [CMACreator]?
    let creation_date: String?
    let technique: String?
    let images: CMAImages?
    let url: String?
}

struct CMACreator: Codable {
    let description: String?
}

struct CMAImages: Codable {
    let web: CMAImage?
}

struct CMAImage: Codable {
    let url: String?
}

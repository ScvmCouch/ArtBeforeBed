import Foundation

protocol MuseumProvider {
    var providerID: String { get }
    var sourceName: String { get }

    func fetchArtworkIDs(
        query: String,
        medium: String?,
        geo: String?,
        period: PeriodPreset
    ) async throws -> [String]

    func fetchArtwork(id: String) async throws -> Artwork
}

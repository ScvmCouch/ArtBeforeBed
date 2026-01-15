import Foundation

/// App-wide unified artwork model.
/// UI/ViewModel only deal with this type (never MetObject / YaleObject / etc.)
struct Artwork: Identifiable, Hashable {
    let id: String               // e.g. "met:12345"
    let title: String
    let artist: String
    let date: String?
    let medium: String?
    let imageURL: URL
    let source: String           // e.g. "The Met"
    let sourceURL: URL?

    /// Extra metadata for tuning filters (provider-specific key/value pairs)
    let debugFields: [String: String]

    /// Human-readable debug dump for copy/share
    var debugText: String {
        var lines: [String] = []
        lines.append("id: \(id)")
        lines.append("source: \(source)")
        if let sourceURL { lines.append("sourceURL: \(sourceURL.absoluteString)") }
        lines.append("title: \(title)")
        lines.append("artist: \(artist)")
        if let date { lines.append("date: \(date)") }
        if let medium { lines.append("medium: \(medium)") }
        lines.append("imageURL: \(imageURL.absoluteString)")

        let keys = debugFields.keys.sorted()
        if !keys.isEmpty {
            lines.append("")
            lines.append("---- debugFields ----")
            for k in keys {
                lines.append("\(k): \(debugFields[k] ?? "")")
            }
        }
        return lines.joined(separator: "\n")
    }

    // Convenience initializer so existing providers can pass debugFields optionally
    init(
        id: String,
        title: String,
        artist: String,
        date: String?,
        medium: String?,
        imageURL: URL,
        source: String,
        sourceURL: URL?,
        debugFields: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.date = date
        self.medium = medium
        self.imageURL = imageURL
        self.source = source
        self.sourceURL = sourceURL
        self.debugFields = debugFields
    }
}

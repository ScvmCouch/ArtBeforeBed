import Foundation

/// Shared utilities for parsing Linked Art JSON-LD format
/// Used by Getty and Rijksmuseum providers
enum LinkedArtParser {
    
    // MARK: - Rights/License Checking
    
    /// Check if an object is CC0 or Public Domain
    static func isPublicDomain(_ json: [String: Any]) -> Bool {
        // Check for CC0 or public domain in rights statements
        if let rights = extractArray(at: ["subject_of"], from: json) {
            for right in rights {
                if let rightDict = right as? [String: Any],
                   let classified = extractArray(at: ["classified_as"], from: rightDict) {
                    for classification in classified {
                        if let classDict = classification as? [String: Any],
                           let label = extractString(at: ["_label"], from: classDict) {
                            let lower = label.lowercased()
                            if lower.contains("public domain") || lower.contains("cc0") {
                                return true
                            }
                        }
                    }
                }
            }
        }
        
        // Also check direct rights field
        if let rightsURL = extractString(at: ["rights"], from: json) {
            let lower = rightsURL.lowercased()
            if lower.contains("publicdomain") || lower.contains("cc0") {
                return true
            }
        }
        
        return false
    }
    
    // MARK: - Type/Classification Checking
    
    /// Check if object type matches desired types (painting, drawing, etching, print)
    static func isDesiredArtworkType(_ json: [String: Any]) -> Bool {
        guard let classifications = extractArray(at: ["classified_as"], from: json) else {
            return false
        }
        
        let desiredTypes = [
            "painting", "paintings",
            "drawing", "drawings",
            "etching", "etchings",
            "print", "prints",
            "watercolor", "watercolors",
            "gouache",
            "pastel", "pastels"
        ]
        
        for classification in classifications {
            if let classDict = classification as? [String: Any],
               let label = extractString(at: ["_label"], from: classDict) {
                let lower = label.lowercased()
                if desiredTypes.contains(where: { lower.contains($0) }) {
                    return true
                }
            }
        }
        
        return false
    }
    
    /// Check if object should be blocked (manuscripts, books, etc.)
    static func isBlockedType(_ json: [String: Any]) -> Bool {
        guard let classifications = extractArray(at: ["classified_as"], from: json) else {
            return false
        }
        
        let blockedTypes = [
            "manuscript", "manuscripts",
            "book", "books",
            "folio", "folios",
            "page", "pages",
            "leaf", "leaves",
            "album", "albums",
            "scroll", "scrolls",
            "bound volume",
            "codex"
        ]
        
        for classification in classifications {
            if let classDict = classification as? [String: Any],
               let label = extractString(at: ["_label"], from: classDict) {
                let lower = label.lowercased()
                if blockedTypes.contains(where: { lower.contains($0) }) {
                    return true
                }
            }
        }
        
        // Also check title
        if let title = extractTitle(from: json) {
            let lower = title.lowercased()
            if blockedTypes.contains(where: { lower.contains($0) }) {
                return true
            }
        }
        
        return false
    }
    
    // MARK: - Data Extraction
    
    /// Extract the primary title from a Linked Art object
    static func extractTitle(from json: [String: Any]) -> String? {
        guard let identifiedBy = extractArray(at: ["identified_by"], from: json) else {
            return nil
        }
        
        // Look for primary name/title
        for item in identifiedBy {
            if let itemDict = item as? [String: Any],
               let type = extractString(at: ["type"], from: itemDict),
               (type == "Name" || type == "Title") {
                
                // Check if it's classified as primary
                if let classified = extractArray(at: ["classified_as"], from: itemDict) {
                    for classification in classified {
                        if let classDict = classification as? [String: Any],
                           let label = extractString(at: ["_label"], from: classDict),
                           label.lowercased().contains("primary") {
                            if let content = extractString(at: ["content"], from: itemDict) {
                                return content
                            }
                        }
                    }
                }
                
                // Fallback: first name/title we find
                if let content = extractString(at: ["content"], from: itemDict) {
                    return content
                }
            }
        }
        
        return nil
    }
    
    /// Extract artist/creator name
    static func extractArtist(from json: [String: Any]) -> String? {
        // Try produced_by -> carried_out_by
        if let producedBy = extractDict(at: ["produced_by"], from: json),
           let carriedOutBy = extractArray(at: ["carried_out_by"], from: producedBy) {
            for item in carriedOutBy {
                if let itemDict = item as? [String: Any],
                   let label = extractString(at: ["_label"], from: itemDict) {
                    return label
                }
            }
        }
        
        // Fallback: attributed_to
        if let attributedTo = extractArray(at: ["attributed_to"], from: json) {
            for item in attributedTo {
                if let itemDict = item as? [String: Any],
                   let label = extractString(at: ["_label"], from: itemDict) {
                    return label
                }
            }
        }
        
        return nil
    }
    
    /// Extract creation date/timespan
    static func extractDate(from json: [String: Any]) -> String? {
        if let producedBy = extractDict(at: ["produced_by"], from: json),
           let timespan = extractDict(at: ["timespan"], from: producedBy) {
            
            // Try begin_of_the_begin and end_of_the_end
            if let begin = extractString(at: ["begin_of_the_begin"], from: timespan),
               let end = extractString(at: ["end_of_the_end"], from: timespan) {
                // Extract just the year from ISO dates
                let beginYear = begin.prefix(4)
                let endYear = end.prefix(4)
                if beginYear == endYear {
                    return String(beginYear)
                } else {
                    return "\(beginYear)–\(endYear)"
                }
            }
            
            // Fallback to _label
            if let label = extractString(at: ["_label"], from: timespan) {
                return label
            }
        }
        
        return nil
    }
    
    /// Extract medium/technique
    static func extractMedium(from json: [String: Any]) -> String? {
        // Try produced_by -> technique
        if let producedBy = extractDict(at: ["produced_by"], from: json),
           let techniques = extractArray(at: ["technique"], from: producedBy) {
            var parts: [String] = []
            for item in techniques {
                if let itemDict = item as? [String: Any],
                   let label = extractString(at: ["_label"], from: itemDict) {
                    parts.append(label)
                }
            }
            if !parts.isEmpty {
                return parts.joined(separator: ", ")
            }
        }
        
        // Also try made_of (materials)
        if let madeOf = extractArray(at: ["made_of"], from: json) {
            var parts: [String] = []
            for item in madeOf {
                if let itemDict = item as? [String: Any],
                   let label = extractString(at: ["_label"], from: itemDict) {
                    parts.append(label)
                }
            }
            if !parts.isEmpty {
                return parts.joined(separator: ", ")
            }
        }
        
        return nil
    }
    
    /// Extract image URL (IIIF or direct)
    static func extractImageURL(from json: [String: Any]) -> URL? {
        // Look for representation (visual items)
        guard let representations = extractArray(at: ["representation"], from: json) else {
            return nil
        }
        
        for rep in representations {
            if let repDict = rep as? [String: Any] {
                // Try IIIF service
                if let digitally = extractArray(at: ["digitally_shown_by"], from: repDict) {
                    for item in digitally {
                        if let itemDict = item as? [String: Any] {
                            // Try access_point (IIIF service)
                            if let accessPoints = extractArray(at: ["access_point"], from: itemDict) {
                                for ap in accessPoints {
                                    if let apDict = ap as? [String: Any],
                                       let id = extractString(at: ["id"], from: apDict) {
                                        // IIIF image service - append size params
                                        if id.contains("/iiif/") {
                                            return URL(string: "\(id)/full/!1600,1600/0/default.jpg")
                                        } else if id.hasSuffix(".jpg") || id.hasSuffix(".jpeg") || id.hasSuffix(".png") {
                                            return URL(string: id)
                                        }
                                    }
                                }
                            }
                            
                            // Fallback: direct id
                            if let id = extractString(at: ["id"], from: itemDict) {
                                if id.contains("/iiif/") {
                                    return URL(string: "\(id)/full/!1600,1600/0/default.jpg")
                                } else if id.hasSuffix(".jpg") || id.hasSuffix(".jpeg") || id.hasSuffix(".png") {
                                    return URL(string: id)
                                }
                            }
                        }
                    }
                }
            }
        }
        
        return nil
    }
    
    /// Extract web page URL for the object
    static func extractWebPageURL(from json: [String: Any]) -> URL? {
        if let subjectOf = extractArray(at: ["subject_of"], from: json) {
            for item in subjectOf {
                if let itemDict = item as? [String: Any],
                   let type = extractString(at: ["type"], from: itemDict),
                   type == "DigitalObject" {
                    
                    // Check if it's classified as a web page
                    if let classified = extractArray(at: ["classified_as"], from: itemDict) {
                        for classification in classified {
                            if let classDict = classification as? [String: Any],
                               let id = extractString(at: ["id"], from: classDict),
                               id.contains("300264578") { // AAT ID for "web page"
                                if let urlString = extractString(at: ["id"], from: itemDict),
                                   let url = URL(string: urlString) {
                                    return url
                                }
                            }
                        }
                    }
                }
            }
        }
        
        return nil
    }
    
    // MARK: - JSON Traversal Helpers
    
    private static func extractString(at path: [String], from dict: [String: Any]) -> String? {
        var current: Any = dict
        for key in path {
            guard let dict = current as? [String: Any],
                  let next = dict[key] else {
                return nil
            }
            current = next
        }
        return current as? String
    }
    
    private static func extractDict(at path: [String], from dict: [String: Any]) -> [String: Any]? {
        var current: Any = dict
        for key in path {
            guard let dict = current as? [String: Any],
                  let next = dict[key] else {
                return nil
            }
            current = next
        }
        return current as? [String: Any]
    }
    
    private static func extractArray(at path: [String], from dict: [String: Any]) -> [Any]? {
        var current: Any = dict
        for key in path {
            guard let dict = current as? [String: Any],
                  let next = dict[key] else {
                return nil
            }
            current = next
        }
        return current as? [Any]
    }
}

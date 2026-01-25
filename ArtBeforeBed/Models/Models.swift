import Foundation

// MARK: - Museum Selection

enum MuseumSelection: String, CaseIterable, Identifiable {
    case mixed = "Mixed"
    case met = "Met"
    case aic = "Chicago"
    case cma = "Cleveland"
    case getty = "Getty"
    case rijks = "Rijksmuseum"
    case yale = "Yale"

    var id: String { rawValue }

    /// Provider ID prefixes used in IDs: "met:123", "aic:456", "cma:789", "getty:uuid", "rijks:123", "yale:uuid"
    var allowedProviderIDs: Set<String>? {
        switch self {
        case .mixed:
            // nil means "allow all providers"
            return nil
        case .met:
            return ["met"]
        case .aic:
            return ["aic"]
        case .cma:
            return ["cma"]
        case .getty:
            return ["getty"]
        case .rijks:
            return ["rijks"]
        case .yale:
            return ["yale"]
        }
    }
}

// MARK: - Period Presets

enum PeriodPreset: String, CaseIterable, Identifiable, Codable {
    case any = "Any"
    case medieval = "Medieval (500–1400)"
    case renaissance = "Renaissance (1400–1600)"
    case baroque = "Baroque (1600–1750)"
    case modern = "Modern (1750–1950)"
    case contemporary = "Contemporary (1950–Now)"

    var id: String { rawValue }

    var yearRange: ClosedRange<Int>? {
        switch self {
        case .any: return nil
        case .medieval: return 500...1400
        case .renaissance: return 1400...1600
        case .baroque: return 1600...1750
        case .modern: return 1750...1950
        case .contemporary: return 1950...9999
        }
    }
}

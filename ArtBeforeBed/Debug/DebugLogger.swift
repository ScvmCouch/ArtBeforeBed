import Foundation

/// Debug logging utility for tracking API calls and failures
enum DebugLogger {
    
    static var isEnabled = true
    
    enum LogLevel: String {
        case info = "ℹ️"
        case success = "✅"
        case warning = "⚠️"
        case error = "❌"
        case network = "🌐"
    }
    
    static func log(_ level: LogLevel, _ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        guard isEnabled else { return }
        
        let fileName = (file as NSString).lastPathComponent
        let timestamp = DateFormatter.logFormatter.string(from: Date())
        
        print("\(level.rawValue) [\(timestamp)] [\(fileName):\(line)] \(message)")
    }
    
    static func logNetworkRequest(url: URL, method: String = "GET") {
        log(.network, "REQUEST: \(method) \(url.absoluteString)")
    }
    
    static func logNetworkResponse(url: URL, statusCode: Int, dataSize: Int) {
        let emoji: LogLevel = (200...299).contains(statusCode) ? .success : .error
        log(emoji, "RESPONSE: \(statusCode) | \(url.absoluteString) | \(dataSize) bytes")
    }
    
    static func logNetworkError(url: URL, error: Error) {
        log(.error, "NETWORK ERROR: \(url.absoluteString) | \(error.localizedDescription)")
    }
    
    static func logJSON(_ json: Any, prefix: String = "JSON") {
        guard isEnabled else { return }
        if let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
           let string = String(data: data, encoding: .utf8) {
            print("\n📄 \(prefix):\n\(string)\n")
        }
    }
    
    static func logProviderStart(_ providerName: String, query: String) {
        log(.info, "🎨 \(providerName) starting search for: '\(query)'")
    }
    
    static func logProviderSuccess(_ providerName: String, idCount: Int) {
        log(.success, "🎨 \(providerName) found \(idCount) IDs")
    }
    
    static func logProviderError(_ providerName: String, error: Error) {
        log(.error, "🎨 \(providerName) failed: \(error.localizedDescription)")
    }
    
    static func logArtworkFetch(id: String) {
        log(.info, "🖼 Fetching artwork: \(id)")
    }
    
    static func logArtworkSuccess(id: String, title: String) {
        log(.success, "🖼 Loaded: \(title) (\(id))")
    }
    
    static func logArtworkError(id: String, error: Error) {
        log(.error, "🖼 Failed to load \(id): \(error.localizedDescription)")
    }
}

private extension DateFormatter {
    static let logFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

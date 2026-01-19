import SwiftUI

/// Enhanced debug view with API testing capabilities
struct EnhancedDebugView: View {
    let artwork: Artwork
    @State private var testResults: [String] = []
    @State private var isTesting = false
    
    var body: some View {
        NavigationStack {
            List {
                Section("Artwork Info") {
                    LabeledRow(label: "ID", value: artwork.id)
                    LabeledRow(label: "Title", value: artwork.title)
                    LabeledRow(label: "Artist", value: artwork.artist)
                    LabeledRow(label: "Source", value: artwork.source)
                    if let date = artwork.date {
                        LabeledRow(label: "Date", value: date)
                    }
                    if let medium = artwork.medium {
                        LabeledRow(label: "Medium", value: medium)
                    }
                }
                
                Section("Image") {
                    LabeledRow(label: "Image URL", value: artwork.imageURL.absoluteString)
                    
                    Button("Test Image URL") {
                        testImageURL()
                    }
                }
                
                Section("Debug Fields") {
                    ForEach(artwork.debugFields.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        LabeledRow(label: key, value: value)
                    }
                }
                
                if !testResults.isEmpty {
                    Section("Test Results") {
                        ForEach(testResults, id: \.self) { result in
                            Text(result)
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                }
                
                Section("Actions") {
                    Button("Copy Debug Info") {
                        UIPasteboard.general.string = artwork.debugText
                    }
                    
                    Button("Test API Endpoint") {
                        Task {
                            await testAPIEndpoint()
                        }
                    }
                    .disabled(isTesting)
                    
                    if isTesting {
                        ProgressView()
                    }
                }
            }
            .navigationTitle("Enhanced Debug")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    private func testImageURL() {
        testResults.append("🌐 Testing: \(artwork.imageURL.absoluteString)")
        
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(from: artwork.imageURL)
                
                if let http = response as? HTTPURLResponse {
                    testResults.append("✅ HTTP \(http.statusCode) | Size: \(data.count) bytes")
                    
                    // Check if it's actually an image
                    if let _ = UIImage(data: data) {
                        testResults.append("✅ Valid image data")
                    } else {
                        testResults.append("❌ Data is not a valid image")
                    }
                } else {
                    testResults.append("⚠️ Response is not HTTP")
                }
            } catch {
                testResults.append("❌ Error: \(error.localizedDescription)")
            }
        }
    }
    
    private func testAPIEndpoint() async {
        isTesting = true
        testResults.removeAll()
        
        // Determine which museum and construct API test
        if artwork.id.hasPrefix("rijks:") {
            await testRijksmuseum()
        } else if artwork.id.hasPrefix("getty:") {
            await testGetty()
        } else {
            testResults.append("ℹ️ API testing only available for Getty/Rijksmuseum")
        }
        
        isTesting = false
    }
    
    private func testRijksmuseum() async {
        let numericID = artwork.id.replacingOccurrences(of: "rijks:", with: "")
        let url = URL(string: "https://id.rijksmuseum.nl/\(numericID)")!
        
        testResults.append("🔍 Testing Rijksmuseum API...")
        testResults.append("URL: \(url.absoluteString)")
        
        var request = URLRequest(url: url)
        request.setValue("application/ld+json", forHTTPHeaderField: "Accept")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let http = response as? HTTPURLResponse {
                testResults.append("✅ HTTP \(http.statusCode)")
                testResults.append("📦 Response size: \(data.count) bytes")
                
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    testResults.append("✅ Valid JSON received")
                    
                    // Check for key fields
                    if json["@context"] != nil {
                        testResults.append("✅ Has @context (Linked Art)")
                    }
                    if json["representation"] != nil {
                        testResults.append("✅ Has representation field")
                    } else {
                        testResults.append("❌ Missing representation field")
                    }
                } else {
                    testResults.append("❌ Failed to parse JSON")
                }
            }
        } catch {
            testResults.append("❌ Network error: \(error.localizedDescription)")
        }
    }
    
    private func testGetty() async {
        let objectID = artwork.id.replacingOccurrences(of: "getty:", with: "")
        let url = URL(string: "https://data.getty.edu/museum/collection/object/\(objectID)")!
        
        testResults.append("🔍 Testing Getty API...")
        testResults.append("URL: \(url.absoluteString)")
        
        var request = URLRequest(url: url)
        request.setValue("application/ld+json", forHTTPHeaderField: "Accept")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let http = response as? HTTPURLResponse {
                testResults.append("✅ HTTP \(http.statusCode)")
                testResults.append("📦 Response size: \(data.count) bytes")
                
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    testResults.append("✅ Valid JSON received")
                    
                    if json["@context"] != nil {
                        testResults.append("✅ Has @context (Linked Art)")
                    }
                    if json["representation"] != nil {
                        testResults.append("✅ Has representation field")
                    } else {
                        testResults.append("❌ Missing representation field")
                    }
                } else {
                    testResults.append("❌ Failed to parse JSON")
                    if let preview = String(data: data, encoding: .utf8) {
                        testResults.append("Preview: \(preview.prefix(200))")
                    }
                }
            }
        } catch {
            testResults.append("❌ Network error: \(error.localizedDescription)")
        }
    }
}

private struct LabeledRow: View {
    let label: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}

// Replace your existing ArtworkDebugView with this, or use alongside it

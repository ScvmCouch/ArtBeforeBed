import SwiftUI

@main
struct ArtBeforeBedApp: App {
    
    init() {
        Analytics.shared.initialize()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

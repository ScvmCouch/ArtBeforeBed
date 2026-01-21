import SwiftUI

struct SplashView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 4) {
                Text("Art")
                Text("Before")
                Text("Bed")
            }
            .font(.system(size: 32, weight: .light))
            .foregroundStyle(.white)
        }
    }
}

#Preview {
    SplashView()
}

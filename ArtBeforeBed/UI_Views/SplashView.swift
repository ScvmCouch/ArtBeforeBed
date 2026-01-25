import SwiftUI

struct SplashView: View {
    @State private var fadeIn = false

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
            .opacity(fadeIn ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 8.0)) {
                    fadeIn = true
                }
            }
        }
    }
}

#Preview {
    SplashView()
}

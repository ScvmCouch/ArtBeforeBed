import SwiftUI

struct SplashView: View {
    @State private var fadeIn = false

    // Loading behavior
    @State private var showLoading = false
    @State private var pulse = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 10) {

                // --- Your original title block (unchanged) ---
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

                    // Fade in "Loading" after the title finishes (8s), then pulse
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
                        withAnimation(.easeIn(duration: 1.5)) {
                            showLoading = true
                        }

                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.75) {
                            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                                pulse = true
                            }
                        }
                    }
                }

                // --- Loading underneath (smaller) ---
                Text("Loading")
                    .font(.system(size: 14, weight: .light))
                    .foregroundStyle(.white.opacity(0.75))
                    .opacity(showLoading ? (pulse ? 0.35 : 1.0) : 0.0)
                    .offset(y: 90)  
            }
        }
    }
}

#Preview {
    SplashView()
}

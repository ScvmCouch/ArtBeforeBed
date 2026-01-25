import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var vm = ArtBeforeBedViewModel()
    
    @State private var showFilters = false
    @State private var isInfoVisible = false
    @State private var showDebug = false
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if vm.isLoading && vm.currentImage == nil {
                // Show splash while loading
                SplashView()
            } else if vm.currentImage != nil {
                // UIKit carousel with built-in zoom/pan support
                CarouselView(
                    vm: vm,
                    onTap: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isInfoVisible.toggle()
                        }
                    }
                )
                .ignoresSafeArea()
                
                // SwiftUI overlays
                VStack {
                    topBar
                    Spacer()
                    
                    if isInfoVisible, let art = vm.current {
                        infoPanel(for: art)
                            .padding(.bottom, 16)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: isInfoVisible)
                
            } else if let err = vm.errorMessage {
                errorView(error: err)
            }
        }
        .task {
            await vm.start()
        }
        .sheet(isPresented: $showFilters) {
            FiltersSheet(vm: vm)
        }
        .sheet(isPresented: $showDebug) {
            if let art = vm.current {
                ArtworkDebugView(artwork: art)
            }
        }
    }
    
    // MARK: - UI Components
    
    private func errorView(error: String) -> some View {
        VStack(spacing: 12) {
            Text("Failed to load")
                .foregroundStyle(.white)
                .font(.title2.weight(.semibold))
            
            Text(error)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            
            Button("Try Again") {
                Task { await vm.start() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
    
    private var topBar: some View {
        HStack {
            Button {
                showFilters = true
            } label: {
                // Three horizontal lines (hamburger menu)
                VStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1)
                            .frame(width: 20, height: 2)
                    }
                }
                .padding(10)
            }
            
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .foregroundStyle(Color(red: 0.35, green: 0.15, blue: 0.12))
    }
    
    private func infoPanel(for art: Artwork) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(art.title)
                .foregroundStyle(.white)
                .font(.headline)
            
            Text(art.artist)
                .foregroundStyle(.white.opacity(0.85))
                .font(.subheadline)
            
            HStack(spacing: 10) {
                Text(art.source)
                if let date = art.date, !date.isEmpty {
                    Text("• \(date)")
                }
            }
            .foregroundStyle(.white.opacity(0.75))
            .font(.caption)
            
            if let m = art.medium, !m.isEmpty {
                Text(m)
                    .foregroundStyle(.white.opacity(0.7))
                    .font(.caption2)
            }
            
            Button {
                showDebug = true
            } label: {
                Label("Debug / Share metadata", systemImage: "square.and.arrow.up")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .tint(.white.opacity(0.15))
        }
        .padding(14)
        .background(.black.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 14)
    }
}

// MARK: - Filters Sheet

private struct FiltersSheet: View {
    @ObservedObject var vm: ArtBeforeBedViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var museum: MuseumSelection
    
    private let accentColor = Color(red: 0.85, green: 0.75, blue: 0.65)
    
    init(vm: ArtBeforeBedViewModel) {
        self.vm = vm
        _museum = State(initialValue: vm.selectedMuseum)
    }
    
    var body: some View {
        ZStack {
            // Dark gradient background
            LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.06, blue: 0.05),
                    Color(red: 0.05, green: 0.03, blue: 0.02)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                header
                
                Spacer()
                
                // Content at bottom
                VStack(spacing: 24) {
                    filterSection(title: "Collection", icon: "building.columns") {
                        ForEach(MuseumSelection.allCases) { m in
                            filterChip(
                                label: m.rawValue,
                                isSelected: museum == m
                            ) {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    museum = m
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                
                // Apply button at bottom
                applyButton
            }
        }
        .presentationDetents([.fraction(0.4)])
        .presentationBackground(.clear)
        .presentationDragIndicator(.visible)
    }
    
    private var header: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 32, height: 32)
                    .background(.white.opacity(0.08))
                    .clipShape(Circle())
            }
            
            Spacer()
            
            Text("Filters")
                .font(.system(size: 18, weight: .semibold, design: .serif))
                .foregroundStyle(.white.opacity(0.9))
            
            Spacer()
            
            // Invisible spacer for balance
            Color.clear
                .frame(width: 32, height: 32)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }
    
    private var applyButton: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [.clear, Color(red: 0.05, green: 0.03, blue: 0.02)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 20)
            
            Button {
                dismiss()
                Task {
                    await vm.applyFilters(
                        medium: nil,
                        geo: nil,
                        period: .any,
                        museum: museum
                    )
                }
            } label: {
                Text("Apply Filters")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(red: 0.1, green: 0.08, blue: 0.06))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 30)
            .background(Color(red: 0.05, green: 0.03, blue: 0.02))
        }
    }
    
    private func filterSection<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(accentColor.opacity(0.8))
                
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.leading, 4)
            
            FlowLayout(spacing: 8) {
                content()
            }
        }
    }
    
    private func filterChip(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color(red: 0.1, green: 0.08, blue: 0.06) : .white.opacity(0.7))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    isSelected
                        ? accentColor
                        : Color.white.opacity(0.06)
                )
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(
                            isSelected ? Color.clear : Color.white.opacity(0.1),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Flow Layout for Chips

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
        return CGSize(width: proposal.width ?? 0, height: result.height)
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            let point = result.positions[index]
            subview.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }
    
    struct FlowResult {
        var positions: [CGPoint] = []
        var height: CGFloat = 0
        
        init(in width: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var rowHeight: CGFloat = 0
            
            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                
                if x + size.width > width && x > 0 {
                    x = 0
                    y += rowHeight + spacing
                    rowHeight = 0
                }
                
                positions.append(CGPoint(x: x, y: y))
                rowHeight = max(rowHeight, size.height)
                x += size.width + spacing
            }
            
            height = y + rowHeight
        }
    }
}

#Preview {
    ContentView()
}

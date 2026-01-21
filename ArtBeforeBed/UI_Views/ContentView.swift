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
            Spacer()
            
            Button {
                showFilters = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .semibold))
            }
            
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .foregroundStyle(Color(red: 0.45, green: 0.25, blue: 0.2))
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
    
    @State private var medium: String?
    @State private var geo: String?
    @State private var period: PeriodPreset
    @State private var museum: MuseumSelection
    
    init(vm: ArtBeforeBedViewModel) {
        self.vm = vm
        _medium = State(initialValue: vm.selectedMedium)
        _geo = State(initialValue: vm.selectedGeo)
        _period = State(initialValue: vm.selectedPeriod)
        _museum = State(initialValue: vm.selectedMuseum)
    }
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                HStack {
                    Button("Close") {
                        dismiss()
                    }
                    .foregroundStyle(.white.opacity(0.7))
                    
                    Spacer()
                    
                    Text("Filters")
                        .font(.headline)
                        .foregroundStyle(.white)
                    
                    Spacer()
                    
                    Button("Apply") {
                        dismiss()
                        Task {
                            await vm.applyFilters(medium: medium, geo: geo, period: period, museum: museum)
                        }
                    }
                    .foregroundStyle(.white)
                    .fontWeight(.semibold)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                
                ScrollView {
                    VStack(spacing: 12) {
                        filterSection(title: "Museum") {
                            ForEach(MuseumSelection.allCases) { m in
                                filterOption(
                                    label: m.rawValue,
                                    isSelected: museum == m
                                ) {
                                    museum = m
                                }
                            }
                        }
                        
                        filterSection(title: "Medium") {
                            filterOption(label: "Any", isSelected: medium == nil) {
                                medium = nil
                            }
                            ForEach(vm.mediumOptions, id: \.self) { m in
                                filterOption(
                                    label: m,
                                    isSelected: medium == m
                                ) {
                                    medium = m
                                }
                            }
                        }
                        
                        filterSection(title: "Geography") {
                            filterOption(label: "Any", isSelected: geo == nil) {
                                geo = nil
                            }
                            ForEach(vm.geoOptions, id: \.self) { g in
                                filterOption(
                                    label: g,
                                    isSelected: geo == g
                                ) {
                                    geo = g
                                }
                            }
                        }
                        
                        filterSection(title: "Period") {
                            ForEach(PeriodPreset.allCases, id: \.self) { p in
                                filterOption(
                                    label: String(describing: p),
                                    isSelected: period == p
                                ) {
                                    period = p
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 20)
                }
            }
        }
        .presentationBackground(.black)
    }
    
    private func filterSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
                .textCase(.uppercase)
                .padding(.leading, 4)
            
            VStack(spacing: 2) {
                content()
            }
            .background(.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
    
    private func filterOption(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label)
                    .foregroundStyle(.white.opacity(0.85))
                    .font(.subheadline)
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.white)
                        .font(.subheadline.weight(.semibold))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ContentView()
}

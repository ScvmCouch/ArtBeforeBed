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

            if vm.isLoading && vm.current == nil {
                ProgressView()
                    .tint(.white)
            } else if let art = vm.current {
                mainArtworkView(art)
            } else if let err = vm.errorMessage {
                VStack(spacing: 12) {
                    Text("Failed to load")
                        .foregroundStyle(.white)
                        .font(.title2.weight(.semibold))

                    Text(err)
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
        }
        .task { await vm.start() }
        .sheet(isPresented: $showFilters) {
            FiltersSheet(vm: vm)
        }
        .sheet(isPresented: $showDebug) {
            if let art = vm.current {
                ArtworkDebugView(artwork: art)
            }
        }
    }

    private func mainArtworkView(_ art: Artwork) -> some View {
        ZStack {
            AsyncImage(url: art.imageURL) { phase in
                switch phase {
                case .empty:
                    ProgressView().tint(.white)
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failure:
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 28))
                        Text("Image failed to load")
                            .font(.subheadline)
                    }
                    .foregroundStyle(.white.opacity(0.85))
                @unknown default:
                    EmptyView()
                }
            }

            VStack {
                topBar
                Spacer()

                if isInfoVisible {
                    infoPanel(for: art)
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    if value.translation.width < -90 {
                        Task { await vm.swipeNext() }
                    } else if value.translation.width > 90 {
                        Task { await vm.swipePrevious() }
                    }
                }
        )
        .animation(.easeInOut(duration: 0.2), value: isInfoVisible)
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Button {
                showFilters = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .semibold))
            }

            Button {
                showDebug = true
            } label: {
                Image(systemName: "ladybug")
                    .font(.system(size: 18, weight: .semibold))
            }

            Spacer()

            Button {
                withAnimation { isInfoVisible.toggle() }
            } label: {
                Image(systemName: isInfoVisible ? "info.circle.fill" : "info.circle")
                    .font(.system(size: 18, weight: .semibold))
            }

            Button {
                Task { await vm.swipeNext() }
            } label: {
                Image(systemName: "arrow.right")
                    .font(.system(size: 18, weight: .semibold))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .foregroundStyle(.white)
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
        NavigationStack {
            Form {
                Section("Museum") {
                    Picker("Museum", selection: $museum) {
                        ForEach(MuseumSelection.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                }

                Section("Medium") {
                    Picker("Medium", selection: Binding(
                        get: { medium ?? "Any" },
                        set: { medium = ($0 == "Any") ? nil : $0 }
                    )) {
                        Text("Any").tag("Any")
                        ForEach(vm.mediumOptions, id: \.self) { Text($0).tag($0) }
                    }
                }

                Section("Geography") {
                    Picker("Geography", selection: Binding(
                        get: { geo ?? "Any" },
                        set: { geo = ($0 == "Any") ? nil : $0 }
                    )) {
                        Text("Any").tag("Any")
                        ForEach(vm.geoOptions, id: \.self) { Text($0).tag($0) }
                    }
                }

                Section("Period") {
                    Picker("Period", selection: $period) {
                        ForEach(PeriodPreset.allCases, id: \.self) { p in
                            Text(String(describing: p)).tag(p)
                        }
                    }
                }

                Section {
                    Button("Apply") {
                        dismiss()
                        Task { await vm.applyFilters(medium: medium, geo: geo, period: period, museum: museum) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("Filters")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

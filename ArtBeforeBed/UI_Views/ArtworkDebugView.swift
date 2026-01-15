import SwiftUI
import UIKit

struct ArtworkDebugView: View {
    let artwork: Artwork

    @Environment(\.dismiss) private var dismiss
    @State private var showShare = false
    @State private var copied = false

    private var debugText: String {
        artwork.debugText
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                ScrollView {
                    Text(debugText)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }

                HStack(spacing: 12) {
                    Button {
                        UIPasteboard.general.string = debugText
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            copied = false
                        }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        showShare = true
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .navigationTitle("Artwork Debug")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(isPresented: $showShare) {
                ShareSheet(items: [debugText])
            }
        }
    }
}

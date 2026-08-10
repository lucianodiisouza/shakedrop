//
//  DropZoneView.swift
//  ShakeDrop
//
//  Receives file drops and wires the shake detector to the held file.
//

import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    /// Called on the main thread when the user shakes the mouse
    /// while a file URL is loaded.
    let onShake: (URL) -> Void

    @State private var loadedURL: URL?
    @State private var isTargeted: Bool = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.5),
                    style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                )
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(isTargeted
                              ? Color.accentColor.opacity(0.08)
                              : Color.secondary.opacity(0.05))
                )

            VStack(spacing: 12) {
                Image(systemName: loadedURL == nil
                      ? "tray.and.arrow.down"
                      : "doc.fill")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.secondary)

                if let url = loadedURL {
                    Text(url.lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Shake your mouse to AirDrop")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Drop a file here")
                        .font(.headline)
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
        }
        // The shake detector needs a backing NSView so it can install
        // an NSTrackingArea and a local event monitor.
        .background(ShakeDetectorHost { shake in
            if shake, let url = loadedURL {
                onShake(url)
            }
        })
        .onChange(of: loadedURL) { _ in
            // Reset detector when a new file is dropped.
            ShakeDetectorHost.reset()
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier,
                          options: nil) { item, _ in
            var resolved: URL?
            if let data = item as? Data,
               let url = URL(dataRepresentation: data, relativeTo: nil) {
                resolved = url
            } else if let url = item as? URL {
                resolved = url
            }
            if let url = resolved {
                DispatchQueue.main.async {
                    self.loadedURL = url
                }
            }
        }
        return true
    }
}

// MARK: - ShakeDetectorHost

/// NSViewRepresentable that hosts a single `ShakeDetectorView`.
struct ShakeDetectorHost: NSViewRepresentable {
    static var shared: ShakeDetectorView?

    let onShake: (Bool) -> Void

    func makeNSView(context: Context) -> ShakeDetectorView {
        let view = ShakeDetectorView()
        view.onShake = onShake
        Self.shared = view
        return view
    }

    func updateNSView(_ nsView: ShakeDetectorView, context: Context) {
        nsView.onShake = onShake
    }

    static func reset() {
        shared?.reset()
    }
}

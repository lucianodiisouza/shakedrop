//
//  ContentView.swift
//  ShakeDrop
//
//  Hosts the drop zone + status text.
//

import SwiftUI

struct ContentView: View {
    @State private var status: String = "Drag a file in, then shake your mouse to AirDrop it."

    var body: some View {
        VStack(spacing: 16) {
            DropZoneView(onShake: { url in
                status = "Shake detected — opening AirDrop for \(url.lastPathComponent)…"
                AirDropSender.send(url: url) { success in
                    status = success
                        ? "Sent \(url.lastPathComponent) via AirDrop."
                        : "AirDrop was cancelled or failed."
                }
            })
            .padding(20)

            Text(status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
        }
        .padding(20)
    }
}

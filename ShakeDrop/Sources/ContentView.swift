//
//  ContentView.swift
//  ShakeDrop
//
//  Hosts the drop zone + status text. Sized for a menu-bar
//  popover (compact), not a regular window.
//

import SwiftUI

struct ContentView: View {
    @State private var status: String = "Drop a file, then shake to AirDrop."

    var body: some View {
        VStack(spacing: 12) {
            DropZoneView(onShake: { url in
                status = "Shake detected — opening AirDrop for \(url.lastPathComponent)…"
                AirDropSender.send(url: url) { success in
                    status = success
                        ? "Sent \(url.lastPathComponent) via AirDrop."
                        : "AirDrop was cancelled or failed."
                }
            })

            Text(status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 12)
        }
        .padding(12)
    }
}

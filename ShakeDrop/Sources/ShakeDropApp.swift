//
//  ShakeDropApp.swift
//  ShakeDrop
//
//  Menu-bar-only app. The drop-zone UI lives inside a popover
//  attached to the status bar item; there is no dock icon, no
//  main window. The status bar icon is the SF Symbol `hand.draw`
//  (closed hand with extended index finger inside a circle).
//

import SwiftUI

@main
struct ShakeDropApp: App {
    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .frame(width: 360, height: 280)

            Divider()

            Button("About ShakeDrop") {
                NSApplication.shared.orderFrontStandardAboutPanel(nil)
            }

            Button("Quit ShakeDrop") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            // SF Symbol: hand.draw — closed hand with index finger
            // extended, inside a circle. Requires macOS 13+.
            Image(systemName: "hand.draw")
        }
        .menuBarExtraStyle(.window)
    }
}

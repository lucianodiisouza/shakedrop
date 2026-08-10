//
//  ShakeDropApp.swift
//  ShakeDrop
//
//  Status-bar-only app (LSUIElement). The status bar icon is
//  the SF Symbol `hand.draw`; the menu has just About and Quit.
//  The drop UI is a small floating window that appears near the
//  cursor when the user shakes the mouse while holding a file.
//

import SwiftUI
import AppKit

@main
struct ShakeDropApp: App {

    init() {
        NSLog("[ShakeDrop] App.init — bootstrapping coordinator")
        _ = AppCoordinator.shared.bootstrap()
    }

    var body: some Scene {
        MenuBarExtra {
            Button("About ShakeDrop") {
                NSApplication.shared.orderFrontStandardAboutPanel(nil)
            }
            Divider()
            Button("Quit ShakeDrop") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Image(systemName: "hand.draw")
        }
        .menuBarExtraStyle(.menu)
    }
}

//
//  ShakeDropApp.swift
//  ShakeDrop
//
//  Menu-bar-only app. The drop UI is a small floating window
//  that appears near the cursor when the user shakes the mouse
//  while holding a file (system-wide).
//
//  The status bar icon is the SF Symbol `hand.draw`.
//

import SwiftUI

@main
struct ShakeDropApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            // Clicking the status bar icon is the trigger for
            // requesting Input Monitoring permission. The actual
            // shake detection runs in the background after the
            // permission has been granted.
            Button("Open ShakeDrop") {
                appDelegate.coordinator.menuBarClicked()
            }
            Divider()
            Button("About ShakeDrop") {
                NSApplication.shared.orderFrontStandardAboutPanel(nil)
            }
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.applicationDidFinishLaunching()
    }
}

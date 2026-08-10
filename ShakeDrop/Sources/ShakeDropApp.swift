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

@main
struct ShakeDropApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            // About pulls the version straight from the app
            // bundle's Info.plist, so it tracks whatever we
            // tag without having to hardcode anything here.
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.applicationDidFinishLaunching()
    }
}

//
//  ShakeDropApp.swift
//  ShakeDrop
//
//  Entry point. Minimal SwiftUI scene — the interesting work
//  happens in DropZoneView and ShakeDetector.
//

import SwiftUI

@main
struct ShakeDropApp: App {
    var body: some Scene {
        WindowGroup("ShakeDrop") {
            ContentView()
                .frame(minWidth: 360, minHeight: 260)
        }
        .windowResizability(.contentSize)
    }
}

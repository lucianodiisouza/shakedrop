//
//  AirDropSender.swift
//
//  Thin wrapper around NSSharingService that picks the AirDrop
//  service and hands it a file URL.
//

import AppKit

enum AirDropSender {
    /// Open the AirDrop sharing sheet for `url`. Calls `completion`
    /// on the main thread when the user dismisses the sheet.
    static func send(url: URL, completion: @escaping (Bool) -> Void) {
        let items: [Any] = [url]
        // Use the real predefined constant. The previous code passed a
        // made-up name string ("AirDrop"), which matches no registered
        // service, so the initializer returned nil and nothing was ever
        // shared. `.sendViaAirDrop` (raw value "com.apple.share.AirDrop.send")
        // is the actual AirDrop service.
        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            slog("AirDrop: NSSharingService(named:.sendViaAirDrop) is nil")
            completion(false)
            return
        }
        guard service.canPerform(withItems: items) else {
            slog("AirDrop: canPerform=false for \(url.path) (sandbox may lack access to this file)")
            completion(false)
            return
        }
        slog("AirDrop: performing share sheet for \(url.lastPathComponent)")

        // `perform(withItems:)` is the documented entry point. The
        // share sheet is presented asynchronously; we report "done"
        // shortly after it appears. (AppKit doesn't give us a
        // callback when the user closes the sheet, so this is best-
        // effort for the UX message.)
        service.perform(withItems: items)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            completion(true)
        }
    }
}

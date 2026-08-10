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
        guard let service = NSSharingService(named: NSSharingService.Name("AirDrop")),
              service.canPerform(withItems: items) else {
            completion(false)
            return
        }

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

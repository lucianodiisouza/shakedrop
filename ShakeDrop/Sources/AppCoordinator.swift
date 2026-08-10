//
//  AppCoordinator.swift
//  ShakeDrop
//
//  Wires together the global ShakeMonitor, the floating
//  DropTargetWindow, and the AirDropSender.
//
//  Lifecycle:
//   - `bootstrap()` is called from AppDelegate.init (before
//     SwiftUI has realized any scene). It starts the monitor
//     if Input Monitoring is already granted, or shows the
//     one-time prompt and starts polling.
//   - `applicationDidFinishLaunching()` is a no-op today but
//     is the right place for any work that needs the full
//     app to be running.
//   - `applicationWillTerminate()` stops the monitor and the
//     permission poll.
//
//  Logging uses NSLog so messages show up in Console.app
//  without needing any filter — `os.Logger` is more elegant
//  but its messages can be hidden by macOS' default Console
//  verbosity, and we've been burned by "no logs" before.
//

import AppKit

// MARK: - File logger
//
// NSLog is effectively invisible on recent macOS (messages are
// redacted / not surfaced by `log` for third-party apps), which
// makes this app impossible to debug. So we ALSO append to a plain
// text file inside the app's sandbox container, which can be read
// from a normal shell:
//
//   ~/Library/Containers/com.shakedrop.app/Data/Library/Caches/shakedrop.log
//
// `slog` is a top-level function so every file in the target can
// call it without ceremony.
private let _slogURL: URL? = {
    let fm = FileManager.default
    guard let dir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
    else { return nil }
    return dir.appendingPathComponent("shakedrop.log")
}()

private let _slogFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

func slog(_ message: String) {
    NSLog("[ShakeDrop] \(message)")
    guard let url = _slogURL else { return }
    let line = "\(_slogFormatter.string(from: Date()))  \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    } else {
        try? data.write(to: url, options: .atomic)
    }
}

@MainActor
final class AppCoordinator {

    /// Singleton. SwiftUI's `App.init` needs to bootstrap
    /// the coordinator before any scene is realized, and
    /// `App.body` is recomputed — a held property on `App`
    /// would be re-created on each recompute. A singleton
    /// guarantees a single instance for the process lifetime.
    static let shared = AppCoordinator()

    private let monitor = ShakeMonitor()
    private let dropWindow = DropTargetWindow()
    private var didShowInitialPermissionPrompt = false
    private var permissionPollTask: Task<Void, Never>?
    private var didBootstrap = false

    private init() {
        monitor.onShake = { [weak self] location in
            self?.handleShake(at: location)
        }
        monitor.onDragEnded = { [weak self] in
            self?.handleDragEnded()
        }
        dropWindow.onFileDropped = { [weak self] url in
            self?.handleFileDropped(url)
        }
    }

    // MARK: Lifecycle

    /// Earliest hook. Called from `App.init` so we run before
    /// SwiftUI has a chance to defer anything. Idempotent —
    /// calling it multiple times is a no-op after the first.
    @discardableResult
    func bootstrap() -> Bool {
        NSLog("[ShakeDrop] bootstrap; Input Monitoring authorized = \(ShakeMonitor.isInputMonitoringAuthorized())")
        if didBootstrap { return true }
        didBootstrap = true
        attemptStart()
        return didBootstrap
    }

    /// Try to start the monitor. If permission isn't granted,
    /// shows a one-shot prompt and starts a 1Hz poll that
    /// starts the monitor the moment the user grants access.
    private func attemptStart() {
        if monitor.start() {
            NSLog("[ShakeDrop] monitor started")
            // If we were polling, stop.
            permissionPollTask?.cancel()
            permissionPollTask = nil
            return
        }
        NSLog("[ShakeDrop] monitor not started; permission likely missing")
        showPermissionPromptIfNeeded()
        startPermissionPoll()
    }

    // MARK: Permission prompt

    private func showPermissionPromptIfNeeded() {
        guard !didShowInitialPermissionPrompt else { return }
        didShowInitialPermissionPrompt = true

        let alert = NSAlert()
        alert.messageText = "ShakeDrop needs Input Monitoring"
        alert.informativeText = """
        To detect the mouse-shake gesture from anywhere on your Mac, \
        ShakeDrop watches mouse events globally.

        macOS will ask you to approve ShakeDrop under \
        System Settings ▸ Privacy & Security ▸ Input Monitoring.

        After you flip the toggle, ShakeDrop will start working \
        automatically — no need to relaunch.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not now")

        if alert.runModal() == .alertFirstButtonReturn {
            ShakeMonitor.openInputMonitoringSettings()
        }
    }

    private func startPermissionPoll() {
        permissionPollTask?.cancel()
        permissionPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                NSLog("[ShakeDrop] poll: checking Input Monitoring…")
                if ShakeMonitor.isInputMonitoringAuthorized() {
                    NSLog("[ShakeDrop] poll: permission now granted")
                    if self.monitor.start() {
                        NSLog("[ShakeDrop] poll: monitor started")
                        self.permissionPollTask?.cancel()
                        self.permissionPollTask = nil
                        return
                    }
                }
            }
        }
    }

    // MARK: Shake / drop handling

    private func handleShake(at location: NSPoint) {
        NSLog("[ShakeDrop] shake at (\(location.x), \(location.y))")
        // Once the drop target is on screen, further shakes must not
        // reposition or re-trigger it — otherwise continuing to move
        // the held file makes the window jump around under the cursor.
        guard !dropWindow.isPresented else { return }
        dropWindow.present(near: location)
    }

    /// The drag session ended (mouse released). Dismiss the drop
    /// window so a stale target doesn't linger for the next file. A
    /// short delay lets an on-target drop's `performDragOperation`
    /// run first (it dismisses on its own); this just cleans up the
    /// "released outside the target" case. `dismiss()` is idempotent.
    private func handleDragEnded() {
        NSLog("[ShakeDrop] drag ended; dismissing drop window if open")
        dropWindow.dismiss()
    }

    private func handleFileDropped(_ url: URL) {
        AirDropSender.send(url: url) { _ in
            // Best-effort; NSSharingService doesn't expose
            // success/cancel granularly through this API.
        }
    }
}

//
//  AppCoordinator.swift
//  ShakeDrop
//
//  Wires together the global ShakeMonitor, the floating
//  DropTargetWindow, and the AirDropSender.
//
//  Behaviour:
//   - On launch, tries to start the global mouse monitor
//     immediately. If Input Monitoring is already granted,
//     the shake gesture is live within milliseconds.
//   - If the permission isn't granted yet, shows a one-time
//     alert explaining how to grant it, and polls once a
//     second until the user does — at which point the
//     monitor starts automatically. No user action required
//     after they flip the toggle in System Settings.
//   - On shake: presents the drop window near the cursor.
//   - On drop: dismisses the window and opens AirDrop.
//

import AppKit
import os.log

private let log = Logger(subsystem: "com.shakedrop.app", category: "AppCoordinator")

@MainActor
final class AppCoordinator {

    private let monitor = ShakeMonitor()
    private let dropWindow = DropTargetWindow()
    private var didShowInitialPermissionPrompt = false
    private var permissionPollTask: Task<Void, Never>?

    init() {
        monitor.onShake = { [weak self] location in
            self?.handleShake(at: location)
        }
        dropWindow.onFileDropped = { [weak self] url in
            self?.handleFileDropped(url)
        }
    }

    // MARK: Lifecycle

    /// Called from `applicationDidFinishLaunching` in AppDelegate.
    func applicationDidFinishLaunching() {
        log.info("launched; current Input Monitoring state: \(ShakeMonitor.isInputMonitoringAuthorized())")
        if monitor.start() {
            return
        }
        // Permission not granted yet. Show the prompt and
        // start a background poll that starts the monitor
        // the moment the user grants access.
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

    /// Poll the Input Monitoring permission once per second.
    /// When the user grants it, start the monitor and stop
    /// polling. Cheap, runs on the main actor, and self-
    /// terminates on success.
    private func startPermissionPoll() {
        permissionPollTask?.cancel()
        permissionPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                if ShakeMonitor.isInputMonitoringAuthorized() {
                    log.info("permission granted; starting monitor")
                    if self.monitor.start() {
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
        log.info("presenting drop window at (\(location.x), \(location.y))")
        dropWindow.present(near: location)
    }

    private func handleFileDropped(_ url: URL) {
        log.info("file dropped: \(url.lastPathComponent)")
        AirDropSender.send(url: url) { _ in
            // Best-effort; NSSharingService doesn't expose
            // success/cancel granularly through this API.
        }
    }
}

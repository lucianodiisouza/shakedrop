//
//  AppCoordinator.swift
//  ShakeDrop
//
//  Wires together the global ShakeMonitor, the floating
//  DropTargetWindow, and the AirDropSender. Owns permission
//  state for Input Monitoring — if access isn't granted yet,
//  shows a single-shot prompt the first time the user clicks
//  the menu bar icon, and then attempts to start the monitor.
//
//  On shake, the coordinator presents the drop window near the
//  cursor. On drop, it opens the AirDrop share sheet.
//

import AppKit
import UserNotifications

@MainActor
final class AppCoordinator {

    private let monitor = ShakeMonitor()
    private let dropWindow = DropTargetWindow()
    private var didShowInitialPermissionPrompt = false

    init() {
        monitor.onShake = { [weak self] location in
            self?.handleShake(at: location)
        }
        dropWindow.onFileDropped = { [weak self] url in
            self?.handleFileDropped(url)
        }
    }

    // MARK: Lifecycle

    /// Called from the App scene. If permission is already
    /// granted, starts the monitor immediately. If not, the
    /// monitor will be started from `menuBarClicked` once the
    /// user grants access.
    func applicationDidFinishLaunching() {
        if ShakeMonitor.isInputMonitoringAuthorized() {
            monitor.start()
        } else {
            // We could also try-request here — the system will
            // show a native dialog the first time. Doing it on
            // demand (when the user clicks the icon) is less
            // aggressive, so we just wait.
        }
    }

    /// Hooked into the MenuBarExtra button. If the monitor
    /// isn't running, this is where we prompt for permission.
    func menuBarClicked() {
        if monitor.isStarted { return }

        guard ShakeMonitor.isInputMonitoringAuthorized() else {
            showPermissionPromptIfNeeded()
            return
        }
        monitor.start()
    }

    // MARK: Permission prompt

    private func showPermissionPromptIfNeeded() {
        guard !didShowInitialPermissionPrompt else { return }
        didShowInitialPermissionPrompt = true

        let alert = NSAlert()
        alert.messageText = "ShakeDrop needs Input Monitoring"
        alert.informativeText = """
        To detect the mouse-shake gesture from anywhere on your Mac \
        (not just while ShakeDrop is in front), ShakeDrop watches \
        mouse events globally.

        macOS will ask you to approve ShakeDrop under \
        System Settings ▸ Privacy & Security ▸ Input Monitoring.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not now")

        if alert.runModal() == .alertFirstButtonReturn {
            ShakeMonitor.openInputMonitoringSettings()
        }
    }

    // MARK: Shake / drop handling

    private func handleShake(at location: NSPoint) {
        dropWindow.present(near: location)
    }

    private func handleFileDropped(_ url: URL) {
        AirDropSender.send(url: url) { _ in
            // Best-effort UX message; the share sheet runs
            // independently.
        }
    }
}

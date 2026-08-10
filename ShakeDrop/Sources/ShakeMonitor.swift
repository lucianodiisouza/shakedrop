//
//  ShakeMonitor.swift
//  ShakeDrop
//
//  Global mouse-shake detector. Watches mouseMoved events across
//  the whole system (not just our window) using a CGEventTap, so
//  the user can shake the mouse while holding a file in Finder
//  and the gesture fires regardless of which app is in front.
//
//  Requires the Input Monitoring entitlement and user approval in
//  System Settings > Privacy & Security > Input Monitoring.
//
//  Heuristic (tuned for both mouse and trackpad):
//   - Count sign-flips of (dx + dy) over a sliding window.
//   - Fire when >= minReversals (3) flips within maxWindow (0.6s)
//     AND total travel >= minTotalTravel (150pt).
//   - Re-arm after the window goes quiet.
//

import AppKit
import CoreGraphics
import ApplicationServices
import Foundation

// NSLog so messages show in Console.app without any filter.

@MainActor
final class ShakeMonitor {

    /// Fires on the main thread when a shake is detected.
    /// Argument is the screen-space location of the mouse at the
    /// moment the gesture fired.
    var onShake: ((NSPoint) -> Void)?

    // MARK: Tunables

    private let minReversals: Int = 3
    private let maxWindow: TimeInterval = 0.6
    private let minTotalTravel: CGFloat = 150
    private let minDelta: CGFloat = 6

    // MARK: State

    private struct Sample {
        let time: TimeInterval
        let dx: CGFloat
        let dy: CGFloat
    }

    private var samples: [Sample] = []
    private var lastPosition: NSPoint?
    private var hasFired: Bool = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var isStarted = false

    /// Activity token from `NSProcessInfo.beginActivity(...)`.
    /// Declares this process as "doing latency-critical work"
    /// (the shake detector) so App Nap won't put us to sleep.
    /// Without this, an LSUIElement agent with no visible
    /// window gets parked and the CGEventTap callback never
    /// fires even though the tap is installed.
    private var activityToken: NSObjectProtocol?

    // MARK: Lifecycle

    /// Returns `true` if Input Monitoring access has been granted
    /// for this app. The check is dynamic — if the user just
    /// toggled the switch in System Settings, calling this again
    /// will reflect the new state without restarting the app.
    static func isInputMonitoringAuthorized() -> Bool {
        // Probe by trying to create a no-op tap. If permission
        // isn't granted, tapCreate returns nil.
        let test = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.mouseMoved.rawValue),
            callback: { _, _, _, _ in nil },
            userInfo: nil
        )
        if let test { CFMachPortInvalidate(test) }
        return test != nil
    }

    /// Open System Settings on the Input Monitoring privacy pane.
    /// Used when the user needs to grant permission.
    static func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Start the global event tap. Idempotent — safe to call
    /// multiple times. If Input Monitoring isn't currently
    /// authorized, returns false without doing anything (the
    /// caller is expected to handle the prompt).
    @discardableResult
    func start() -> Bool {
        if isStarted { return true }

        // Pre-flight: re-check the permission, since it may
        // have changed since the app launched.
        guard Self.isInputMonitoringAuthorized() else {
            NSLog("Input Monitoring not authorized; tap not installed")
            return false
        }

        let eventMask: CGEventMask = 1 << CGEventType.mouseMoved.rawValue

        // The callback runs on whatever run loop the tap is
        // attached to. We attach to the main run loop below.
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            // Re-enable the tap if the system temporarily
            // disables it (e.g. timeout, user switch).
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let userInfo {
                    let monitor = Unmanaged<ShakeMonitor>
                        .fromOpaque(userInfo)
                        .takeUnretainedValue()
                    if let tap = monitor.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                }
                return nil
            }
            if let userInfo {
                let monitor = Unmanaged<ShakeMonitor>
                    .fromOpaque(userInfo)
                    .takeUnretainedValue()
                let loc = event.location
                monitor.processMouseMoved(to: loc)
            }
            return nil
        }

        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: opaqueSelf
        ) else {
            NSLog("CGEvent.tapCreate returned nil; Input Monitoring may not be granted")
            return false
        }

        // Attach the tap's run loop source to the main run
        // loop. Status-bar-only apps (LSUIElement) can have
        // a quiet main run loop; the activity token below
        // keeps the process awake so the source keeps
        // firing.
        self.eventTap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        self.runLoopSource = src
        CGEvent.tapEnable(tap: tap, enable: true)

        // Anti-App-Nap: declare this process as doing
        // latency-critical work. Without this, the system
        // parks LSUIElement agents and the tap callback
        // never fires.
        self.activityToken = ProcessInfo.processInfo.beginActivity(
            withOptions: [.latencyCritical],
            reason: "ShakeDrop needs to detect global mouse shakes in real time"
        )

        isStarted = true
        NSLog("Shake monitor started; waiting for mouse events")
        return true
    }

    func stop() {
        guard isStarted else { return }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
        eventTap = nil
        runLoopSource = nil
        isStarted = false
        reset()
    }

    func reset() {
        samples.removeAll(keepingCapacity: true)
        lastPosition = nil
        hasFired = false
    }

    // MARK: Event processing

    private var totalEventCount: Int = 0
    private var lastShakeDebugLogTime: TimeInterval = 0

    private func processMouseMoved(to loc: NSPoint) {
        let now = CACurrentMediaTime()
        totalEventCount += 1

        // One-shot log: confirms the tap is delivering events.
        if totalEventCount == 1 {
            NSLog("[ShakeDrop] first mouseMoved event received — tap is alive")
        }

        defer {
            if lastPosition == nil { lastPosition = loc }
        }

        guard let prev = lastPosition else {
            lastPosition = loc
            return
        }
        let dx = loc.x - prev.x
        let dy = loc.y - prev.y
        lastPosition = loc

        let dist = hypot(dx, dy)
        guard dist >= minDelta else { return }

        samples.append(Sample(time: now, dx: dx, dy: dy))

        if dx != 0 || dy != 0 {
            registerReversal(at: now, currentLocation: loc)
        }

        prune(now: now)
    }

    private func registerReversal(at time: TimeInterval, currentLocation: NSPoint) {
        guard !hasFired else { return }
        let windowStart = time - maxWindow
        let relevant = samples.filter { $0.time >= windowStart }
        let totalTravel = relevant.reduce(CGFloat(0)) { $0 + hypot($1.dx, $1.dy) }

        var flips = 0
        var prevCombined: CGFloat = 0
        for s in relevant {
            let combined = s.dx + s.dy
            if combined == 0 { continue }
            let sign: CGFloat = combined > 0 ? 1 : -1
            if prevCombined != 0 && sign != prevCombined {
                flips += 1
            }
            prevCombined = sign
        }

        // Throttled debug: at most once per 250ms while the
        // user is actively shaking, so we can see the "force"
        // accumulating without drowning the console.
        if time - lastShakeDebugLogTime > 0.25 {
            lastShakeDebugLogTime = time
            NSLog("[ShakeDrop] shake strength: flips=\(flips)/\(minReversals) travel=\(Int(totalTravel))/\(Int(minTotalTravel))")
        }

        if flips >= minReversals && totalTravel >= minTotalTravel {
            hasFired = true
            NSLog("[ShakeDrop] shake detected: flips=\(flips) travel=\(totalTravel) loc=(\(currentLocation.x), \(currentLocation.y))")
            onShake?(currentLocation)
        }
    }

    private func prune(now: TimeInterval) {
        let cutoff = now - maxWindow
        if let firstKept = samples.firstIndex(where: { $0.time >= cutoff }), firstKept > 0 {
            samples.removeFirst(firstKept)
        }
        if hasFired, samples.isEmpty {
            hasFired = false
        }
    }
}

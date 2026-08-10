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
//  Heuristic (unchanged from the local version):
//   - Count sign-flips of (dx + dy) over a sliding window.
//   - Fire when >= minReversals (4) flips within maxWindow (0.8s)
//     AND total travel >= minTotalTravel (200pt).
//   - Re-arm after the window goes quiet.
//

import AppKit
import CoreGraphics
import ApplicationServices

@MainActor
final class ShakeMonitor {

    /// Fires on the main thread when a shake is detected.
    /// Argument is the screen-space location of the mouse at the
    /// moment the gesture fired.
    var onShake: ((NSPoint) -> Void)?

    // MARK: Tunables

    private let minReversals: Int = 4
    private let maxWindow: TimeInterval = 0.8
    private let minTotalTravel: CGFloat = 200
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

    // MARK: Lifecycle

    /// Returns `true` if Input Monitoring access has been granted
    /// for this app. The check is dynamic — if the user just
    /// toggled the switch in System Settings, calling this again
    /// will reflect the new state without restarting the app.
    static func isInputMonitoringAuthorized() -> Bool {
        // The framework's API for this lives under
        // IOHIDPostEvent — but the simpler heuristic is: try to
        // create a passive CGEventTap. If it succeeds, we're good.
        let test = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.mouseMoved.rawValue),
            callback: { _, _, _, _ in nil },
            userInfo: nil
        )
        return test != nil
    }

    /// Open System Settings on the Input Monitoring privacy pane.
    /// Used when the user needs to grant permission.
    static func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Start the global event tap. Call after confirming
    /// `isInputMonitoringAuthorized()`. Safe to call multiple
    /// times — subsequent calls are no-ops.
    func start() {
        guard !isStarted else { return }

        // We listen for mouseMoved; .listenOnly means we don't
        // consume the event, just observe.
        let eventMask: CGEventMask = 1 << CGEventType.mouseMoved.rawValue

        // The callback runs on the main CFRunLoop because we
        // attach the tap's run-loop source to it below.
        let callback: CGEventTapCallBack = { proxy, type, event, userInfo in
            // Re-enable the tap if the system temporarily
            // disables it (e.g. timeout, user switch).
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let proxy = userInfo {
                    let monitor = Unmanaged<ShakeMonitor>
                        .fromOpaque(proxy)
                        .takeUnretainedValue()
                    CGEvent.tapEnable(tap: monitor.eventTap!, enable: true)
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
            // Permission denied (or some other failure). Caller
            // is expected to check isInputMonitoringAuthorized()
            // first; this is the unhappy-path fallback.
            return
        }

        self.eventTap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        self.runLoopSource = src
        CGEvent.tapEnable(tap: tap, enable: true)
        isStarted = true
    }

    func stop() {
        guard isStarted else { return }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
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

    private func processMouseMoved(to loc: NSPoint) {
        let now = CACurrentMediaTime()

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

        // Count sign-flips in the combined (dx+dy) over the
        // current window. This is the same heuristic as before.
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

        if flips >= minReversals && totalTravel >= minTotalTravel {
            hasFired = true
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

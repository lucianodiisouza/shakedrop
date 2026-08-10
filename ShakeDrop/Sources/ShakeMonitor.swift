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

    /// Fires on the main thread when the left mouse button is released
    /// (a drag session ended). The coordinator uses this to dismiss the
    /// drop window so the next file starts clean.
    var onDragEnded: (() -> Void)?

    // MARK: Tunables

    /// Minimum number of direction reversals (in X **or** Y —
    /// the two axes are counted independently and summed) within
    /// the window. A real shake has many short back-and-forth
    /// wiggles; a normal mouse move has zero reversals.
    private let minReversals: Int = 4

    /// Time window over which reversals and travel accumulate.
    private let maxWindow: TimeInterval = 0.6

    /// Minimum total path length (sum of |dxi| + |dyi|) within
    /// the window. Filters out tiny micro-tremors.
    private let minTotalTravel: CGFloat = 200

    /// Minimum absolute delta to count as a real sample
    /// (filters sub-pixel jitter).
    private let minDelta: CGFloat = 6

    /// Minimum number of *distinct* samples in the window.
    /// A shake produces many small samples; a single flick
    /// produces one or two big ones. Requiring at least this
    /// many samples rules out the "user moved the mouse a
    /// lot in one direction" false positive.
    private let minSamples: Int = 6

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
            slog("Input Monitoring not authorized; tap not installed")
            return false
        }

        // CRITICAL: while the user is holding a file (a drag session),
        // macOS emits `leftMouseDragged` events, NOT `mouseMoved`. The
        // whole point of this app is to detect a shake *while a file is
        // held*, so we must watch the dragged events — otherwise the tap
        // receives nothing during the one gesture that matters. We keep
        // `mouseMoved` too so the detector still works for free-hand
        // testing, and add the right-button drag for completeness.
        // We also watch leftMouseUp so we know when a drag session
        // ends — that's our cue to dismiss the drop window and re-arm
        // the detector, so the *next* file gets a fresh drop target
        // instead of a stale one stuck at the previous location.
        let eventMask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue)

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
                // `event.location` is in CoreGraphics global display
                // space: origin top-left, Y grows downward. AppKit
                // (NSScreen, NSWindow) uses origin bottom-left, Y up.
                // Convert here so everything downstream — the shake
                // location and the drop-window placement — is in AppKit
                // coordinates. Flipping around the primary screen's
                // height is the standard conversion.
                if type == .leftMouseUp {
                    monitor.handleMouseUp()
                    return nil
                }
                let cg = event.location
                let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
                let loc = NSPoint(x: cg.x, y: primaryHeight - cg.y)
                monitor.processMouseMoved(to: loc, type: type)
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
            slog("CGEvent.tapCreate returned nil; Input Monitoring may not be granted")
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
            options: [.latencyCritical],
            reason: "ShakeDrop needs to detect global mouse shakes in real time"
        )

        isStarted = true
        slog("tap CREATED and enabled; mask includes mouseMoved+leftMouseDragged+rightMouseDragged")
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
    private var didSeeDrag: Bool = false
    private var lastShakeDebugLogTime: TimeInterval = 0

    /// Whether the left mouse button is currently held. A Finder file
    /// drag produces `leftMouseDragged` events (button down); plain
    /// cursor movement produces `mouseMoved` (button up). We only want
    /// the drop target to appear when the user is actually holding a
    /// file, so we require this to be true before firing.
    private var buttonIsDown: Bool = false

    /// Called when the left button is released. Clears drag state and
    /// re-arms the detector so the next drag+shake is clean, then tells
    /// the coordinator the drag ended.
    func handleMouseUp() {
        buttonIsDown = false
        reset()
        slog("leftMouseUp — drag ended; re-armed")
        onDragEnded?()
    }

    private func processMouseMoved(to loc: NSPoint, type: CGEventType) {
        let now = CACurrentMediaTime()
        totalEventCount += 1

        // One-shot log: confirms the tap is delivering events.
        if totalEventCount == 1 {
            slog("first mouse event received (type=\(type.rawValue)) — tap is alive")
        }
        // Log the FIRST drag event specifically: this is the event
        // type that fires while the user is holding a file, and the
        // whole feature depends on it arriving.
        if type == .leftMouseDragged && !didSeeDrag {
            didSeeDrag = true
            slog("first leftMouseDragged received — shake-while-holding can work")
        }

        // Track button state so we only fire while a file is held.
        // leftMouseDragged => button down (a drag). mouseMoved =>
        // button up. rightMouseDragged is not a file drag, so treat
        // it as "not holding".
        switch type {
        case .leftMouseDragged: buttonIsDown = true
        case .mouseMoved, .rightMouseDragged: buttonIsDown = false
        default: break
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

        // Count direction reversals in X and Y **independently**
        // and sum them. The old code combined dx+dy into a single
        // signal, which missed shakes that move predominantly
        // along one axis (e.g. shaking left/right with very
        // little vertical motion) and could stay positive when
        // the user moved in a slow arc.
        var xFlips = 0
        var yFlips = 0
        var prevSignX: CGFloat = 0
        var prevSignY: CGFloat = 0
        for s in relevant {
            if s.dx != 0 {
                let sign: CGFloat = s.dx > 0 ? 1 : -1
                if prevSignX != 0 && sign != prevSignX {
                    xFlips += 1
                }
                prevSignX = sign
            }
            if s.dy != 0 {
                let sign: CGFloat = s.dy > 0 ? 1 : -1
                if prevSignY != 0 && sign != prevSignY {
                    yFlips += 1
                }
                prevSignY = sign
            }
        }
        let flips = xFlips + yFlips
        let sampleCount = relevant.count

        // Throttled debug: at most once per 250ms while the
        // user is actively shaking, so we can see the "force"
        // accumulating without drowning the console.
        if time - lastShakeDebugLogTime > 0.25 {
            lastShakeDebugLogTime = time
            slog("shake strength: flips=\(flips)/\(minReversals) (x=\(xFlips) y=\(yFlips)) travel=\(Int(totalTravel))/\(Int(minTotalTravel)) samples=\(sampleCount)/\(minSamples)")
        }

        if flips >= minReversals
            && totalTravel >= minTotalTravel
            && sampleCount >= minSamples
            && buttonIsDown {
            hasFired = true
            slog("SHAKE DETECTED: flips=\(flips) (x=\(xFlips) y=\(yFlips)) travel=\(Int(totalTravel)) samples=\(sampleCount) loc=(\(Int(currentLocation.x)), \(Int(currentLocation.y)))")
            onShake?(currentLocation)
            // Reset the sample buffer right after firing so the
            // next shake can be detected cleanly. Otherwise the
            // post-shake decay would keep flips and travel high
            // and the detector would refuse to re-arm.
            samples.removeAll(keepingCapacity: true)
            lastPosition = nil
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

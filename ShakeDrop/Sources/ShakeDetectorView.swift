//
//  ShakeDetectorView.swift
//
//  Detects a "shake" gesture from the mouse by watching rapid
//  direction reversals in cursor movement while the view window
//  is key. Triggered callbacks fire on the main thread.
//
//  Heuristic:
//   - Sample mouseMoved events with timestamps.
//   - Track sign of dx, dy deltas. A "reversal" happens when the
//     sign of dx (or dy) flips between consecutive non-zero samples.
//   - If we accumulate >= minReversals (default 4) within
//     maxWindow (default 0.8s) AND total travel exceeds
//     minTotalTravel (default 200pt) — treat as a shake.
//

import AppKit

final class ShakeDetectorView: NSView {

    /// Called on the main thread when a shake is detected (or
    /// reset, with `false`).
    var onShake: ((Bool) -> Void)?

    // MARK: Tunables

    /// Minimum number of direction reversals within the window
    /// to count as a shake. 4 = two full back-and-forth cycles.
    private let minReversals: Int = 4

    /// Maximum time span (seconds) over which `minReversals` must
    /// accumulate.
    private let maxWindow: TimeInterval = 0.8

    /// Minimum total travel distance (points) over the window.
    /// Filters out micro-tremors.
    private let minTotalTravel: CGFloat = 200

    /// Minimum absolute delta (points) to count as a real sample.
    /// Filters out sub-pixel jitter.
    private let minDelta: CGFloat = 6

    // MARK: State

    private struct Sample {
        let time: TimeInterval
        let dx: CGFloat
        let dy: CGFloat
    }

    private var samples: [Sample] = []
    private var lastSignX: CGFloat = 0
    private var lastSignY: CGFloat = 0
    private var lastPosition: NSPoint?
    private var monitor: Any?
    private var hasFired: Bool = false

    // MARK: Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installMonitorIfNeeded()
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private func installMonitorIfNeeded() {
        guard monitor == nil, window != nil else { return }

        // Accept mouse-moved events even when the app isn't frontmost
        // — we only care about shakes while the user is interacting
        // with our window, but we need the events to flow.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            guard let self else { return event }
            // Only react when our window is key — avoids firing
            // while the user is doing something else.
            if self.window?.isKeyWindow == true {
                self.process(event: event)
            }
            return event
        }
    }

    func reset() {
        samples.removeAll(keepingCapacity: true)
        lastSignX = 0
        lastSignY = 0
        lastPosition = nil
        hasFired = false
        onShake?(false)
    }

    // MARK: Event processing

    private func process(event: NSEvent) {
        let now = event.timestamp
        let loc = event.locationInWindow

        defer {
            // Even when we don't have a previous sample, store this
            // one so the next event has a baseline.
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

        // Count reversals in the X axis.
        if dx != 0 {
            let s: CGFloat = dx > 0 ? 1 : -1
            if lastSignX != 0 && s != lastSignX {
                registerReversal(at: now)
            }
            lastSignX = s
        }
        // Same for Y — count as separate potential reversals.
        if dy != 0 {
            let s: CGFloat = dy > 0 ? 1 : -1
            if lastSignY != 0 && s != lastSignY {
                registerReversal(at: now)
            }
            lastSignY = s
        }

        prune(now: now)
    }

    private func registerReversal(at time: TimeInterval) {
        guard !hasFired else { return }
        // Count a "reversal pair" — both axes can flip per event,
        // so cap contribution per event at 1 to avoid double-fire.
        // Simple approach: just check whether we now have enough
        // reversals inside the window.
        let windowStart = time - maxWindow
        let relevant = samples.filter { $0.time >= windowStart }
        let totalTravel = relevant.reduce(CGFloat(0)) { $0 + hypot($1.dx, $1.dy) }

        // Recount sign-flips over the window from `samples` using
        // combined sign per event.
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
            onShake?(true)
        }
    }

    private func prune(now: TimeInterval) {
        let cutoff = now - maxWindow
        if let firstKept = samples.firstIndex(where: { $0.time >= cutoff }), firstKept > 0 {
            samples.removeFirst(firstKept)
        }
        // Once we fire, let things settle before re-arming.
        if hasFired {
            // Re-arm after the window passes with no activity.
            if samples.isEmpty {
                hasFired = false
            }
        }
    }

    // MARK: NSView

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }
}

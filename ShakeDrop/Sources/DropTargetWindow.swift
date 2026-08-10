//
//  DropTargetWindow.swift
//  ShakeDrop
//
//  A small, semi-transparent, square drop target that appears
//  near the cursor when a shake gesture is detected. The user
//  releases the file they're holding on top of it, and we hand
//  the URL off to NSSharingService (AirDrop).
//
//  Design notes:
//   - NSPanel with .nonactivatingPanel so it doesn't steal
//     focus from the foreground app while open.
//   - window.level = .floating so it sits above normal windows
//     but below the modal AirDrop sheet that NSSharingService
//     will present.
//   - backgroundColor = .clear + isOpaque = false so only the
//     dashed border + icon + label are visible.
//   - 8-second auto-dismiss timer; canceled as soon as a file
//     lands.
//

import AppKit
import UniformTypeIdentifiers

@MainActor
final class DropTargetWindow: NSPanel {

    static let size: CGFloat = 240
    static let dismissAfter: TimeInterval = 8.0

    private var dismissTimer: Timer?
    var onFileDropped: ((URL) -> Void)?

    /// True while the drop target is on screen. Used to ignore
    /// further shakes so the window doesn't jump around while the
    /// user is still moving the held file.
    private(set) var isPresented = false

    // MARK: Init

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )

        // Floating so we sit above normal windows, but below the
        // AirDrop share sheet that NSSharingService will present.
        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.isMovableByWindowBackground = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        self.hidesOnDeactivate = false
        self.acceptsMouseMovedEvents = false

        let content = DropTargetContentView(
            frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size)
        ) { [weak self] url in
            self?.dismiss()
            self?.onFileDropped?(url)
        }
        self.contentView = content
        // Register drag types on the content view (where the
        // drag methods actually live).
        content.registerForDraggedTypes([.fileURL])
    }

    // MARK: Show / hide

    /// Show the window near `location` (screen coordinates),
    /// clamped to the visible screen frame.
    func present(near location: NSPoint) {
        // Clamp so the window stays on screen even if the user
        // shakes near an edge.
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let half = Self.size / 2
        var x = location.x - half
        var y = location.y - half
        x = max(visible.minX + 8, min(x, visible.maxX - Self.size - 8))
        y = max(visible.minY + 8, min(y, visible.maxY - Self.size - 8))

        self.setFrame(NSRect(x: x, y: y, width: Self.size, height: Self.size),
                      display: true)
        self.orderFrontRegardless()
        isPresented = true
        slog("drop window ordered front at (\(Int(x)), \(Int(y))) size \(Int(Self.size))")

        // Auto-dismiss if the user doesn't drop anything.
        // DropTargetWindow is @MainActor; the timer fires on
        // the main run loop, so we can call dismiss() directly.
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(
            withTimeInterval: Self.dismissAfter,
            repeats: false
        ) { [weak self] _ in
            // The timer is created on the main run loop (Timer
            // default), so it's safe to call a @MainActor method
            // from its callback.
            MainActor.assumeIsolated {
                self?.dismiss()
            }
        }
    }

    func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        isPresented = false
        self.orderOut(nil)
    }
}

// MARK: - Content view

private final class DropTargetContentView: NSView {

    private let icon: NSImageView
    private let label: NSTextField
    private let onFileDropped: (URL) -> Void
    private var borderLayer: CAShapeLayer?

    init(frame frameRect: NSRect, onFileDropped: @escaping (URL) -> Void) {
        icon = NSImageView()
        label = NSTextField(labelWithString: "Drop the file here")
        self.onFileDropped = onFileDropped
        super.init(frame: frameRect)

        // Rounded-rect, semi-transparent background. The
        // dashed border is a separate CAShapeLayer overlay so
        // we can swap its color/width on drag enter/exit.
        self.wantsLayer = true
        self.layer?.cornerRadius = 16
        self.layer?.cornerCurve = .continuous
        self.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor

        let border = CAShapeLayer()
        border.frame = bounds
        border.path = CGPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            cornerWidth: 15,
            cornerHeight: 15,
            transform: nil
        )
        border.strokeColor = NSColor.white.withAlphaComponent(0.85).cgColor
        border.fillColor = NSColor.clear.cgColor
        border.lineWidth = 2
        border.lineDashPattern = [8, 6]
        self.layer?.addSublayer(border)
        self.borderLayer = border

        // Icon
        if let img = NSImage(systemSymbolName: "square.and.arrow.up.on.square",
                             accessibilityDescription: nil) {
            img.isTemplate = true
            icon.image = img
            icon.contentTintColor = .white
        }
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        // Label
        label.textColor = .white
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -16),
            icon.widthAnchor.constraint(equalToConstant: 48),
            icon.heightAnchor.constraint(equalToConstant: 48),

            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        slog("draggingEntered drop window")
        // Highlight the border to acknowledge the drag.
        borderLayer?.strokeColor = NSColor.systemBlue.cgColor
        borderLayer?.lineWidth = 3
        return [.copy]
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        borderLayer?.strokeColor = NSColor.white.withAlphaComponent(0.85).cgColor
        borderLayer?.lineWidth = 2
    }

    override func layout() {
        super.layout()
        // Resize the dashed border path to match the view.
        borderLayer?.frame = bounds
        borderLayer?.path = CGPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            cornerWidth: 15,
            cornerHeight: 15,
            transform: nil
        )
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        return pb.types?.contains(.fileURL) ?? false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard

        // Canonical way to pull file URLs off a drag pasteboard.
        // Restricting to file URLs avoids grabbing plain-text/web URLs.
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: options) as? [URL],
           let url = urls.first {
            slog("performDragOperation: got file url via readObjects: \(url.lastPathComponent)")
            onFileDropped(url)
            return true
        }

        // Fallback for older payloads that only carry raw fileURL bytes.
        if let data = pb.data(forType: .fileURL),
           let url = URL(dataRepresentation: data, relativeTo: nil) {
            slog("performDragOperation: got file url via fallback: \(url.lastPathComponent)")
            onFileDropped(url)
            return true
        }

        slog("performDragOperation: FAILED to extract a file url; pb types=\(pb.types ?? [])")
        return false
    }
}

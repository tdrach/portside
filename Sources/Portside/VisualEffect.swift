import AppKit
import SwiftUI

/// The system menu glass — NSVisualEffectView with the .menu material,
/// behind-window blending, and a continuous-corner (squircle) mask, plus
/// Liquid Glass layered on top on macOS 26+. The mask matters twice: it
/// shapes the blur region itself (a SwiftUI clip alone can't — the window
/// server computes the blur from the effect view's mask) and the window
/// shadow follows it.
struct MenuGlassBackground: NSViewRepresentable {
    static let cornerRadius: CGFloat = 20

    /// Escape hatch for chrome rendering bugs on hardware/OS combos we don't
    /// have: `defaults write design.subtract.portside PortsideClassicChrome
    /// -bool YES` skips every window hack and renders a plain system panel.
    static var classicChrome: Bool {
        UserDefaults.standard.bool(forKey: "PortsideClassicChrome")
    }

    /// The MenuBarExtra panel currently hosting us — lets the editor window
    /// dismiss the popover, which floats at status-bar level and would
    /// otherwise cover any normal window.
    static weak var currentPanel: NSWindow?

    /// The window-chrome corrections below were developed against macOS 26's
    /// MenuBarExtra internals (which backdrop layers exist, where the frame
    /// view paints). Older systems have a different hierarchy, and blindly
    /// hiding "full-size layer-backed" views there risks hiding real content
    /// — an invisible popover is far worse than a slightly opaque one. We
    /// have never run on 14/15, so those systems get the plain material.
    static var usesChromeCorrections: Bool {
        if #available(macOS 26.0, *) { return !classicChrome }
        return false
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        if !Self.usesChromeCorrections {
            let plain = NSVisualEffectView()
            plain.material = .menu
            plain.blendingMode = .withinWindow
            plain.state = .active
            return plain
        }
        let view = WindowChromeEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = Self.roundedMask(radius: Self.cornerRadius)
        Self.attachLiquidGlassIfAvailable(to: view)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}

    /// Tahoe's refraction and rim lighting over the behind-window blur base.
    /// Older systems simply keep the classic material.
    static func attachLiquidGlassIfAvailable(to host: NSView) {
        guard #available(macOS 26.0, *) else { return }
        let glass = NSGlassEffectView(frame: host.bounds)
        glass.autoresizingMask = [.width, .height]
        glass.cornerRadius = cornerRadius
        glass.wantsLayer = true
        glass.layer?.cornerCurve = .continuous
        glass.layer?.masksToBounds = true
        host.addSubview(glass)
    }

    /// Rendered through CALayer so the corners get Apple's continuous
    /// curvature, not plain circular arcs. The cap inset covers the
    /// squircle's transition zone (~1.53 × radius) so stretching never
    /// distorts the curve.
    static func roundedMask(radius: CGFloat) -> NSImage {
        let inset = ceil(radius * 1.6)
        let edge = inset * 2 + 1
        let size = NSSize(width: edge, height: edge)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let layer = CALayer()
            layer.frame = rect
            layer.backgroundColor = NSColor.black.cgColor
            layer.cornerRadius = radius
            layer.cornerCurve = .continuous
            layer.masksToBounds = true
            layer.render(in: context)
            return true
        }
        image.capInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        image.resizingMode = .stretch
        return image
    }
}

/// Owns the MenuBarExtra panel's window-level quirks:
///
/// 1. The panel and its frame view paint opaque square backings, and SwiftUI
///    adds its own full-size backdrop fills — all cleared/hidden so the
///    masked glass is the only surface (the frame view lives OUTSIDE the
///    contentView clip, so clipping alone can never fix its corners).
/// 2. When content height changes while the popover is open, the panel
///    resizes without compensating its origin (AppKit anchors bottom-left),
///    so the top edge drifts and stale shadows linger. We pin the top edge
///    for the whole presentation and drive the window height from the
///    content's authoritative size.
private final class WindowChromeEffectView: NSVisualEffectView {
    private var anchorTopY: CGFloat?
    private var lastSyncedHeight: CGFloat = 0
    private var adjusting = false
    private var observers: [NSObjectProtocol] = []

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        anchorTopY = nil
        lastSyncedHeight = 0
        guard let window else { return }
        MenuGlassBackground.currentPanel = window
        clearWindowBacking()
        // Frame changes originate outside our layout pass — observe them.
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak self] _ in
                DispatchQueue.main.async { self?.syncWindowFrame(heightAuthoritative: false) }
            })
        }
    }

    override func layout() {
        super.layout()
        clearWindowBacking()
        // Only here are our bounds fresh enough to dictate the height.
        syncWindowFrame(heightAuthoritative: true)
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        clearWindowBacking()
    }

    private func clearWindowBacking() {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        // The one clip that provably applies to EVERYTHING in the panel —
        // system backdrops, the glass layer, SwiftUI content alike.
        if let content = window.contentView {
            content.wantsLayer = true
            content.layer?.cornerRadius = MenuGlassBackground.cornerRadius
            content.layer?.cornerCurve = .continuous
            content.layer?.masksToBounds = true
        }
        // Tahoe's frame view paints its own square backing OUTSIDE the
        // contentView clip — it peeks through exactly at the corner arcs.
        if let frameView = window.contentView?.superview {
            frameView.wantsLayer = true
            frameView.layer?.backgroundColor = NSColor.clear.cgColor
            // Clearing the color is not enough: the frame DRAWS its backing
            // into layer contents, and those already-drawn white pixels shine
            // through the glass edge's antialiasing as a hairline arc at the
            // corners. Erase the drawn contents too, every pass.
            frameView.layer?.contents = nil
            frameView.layer?.cornerRadius = MenuGlassBackground.cornerRadius
            frameView.layer?.cornerCurve = .continuous
        }
        clearSystemBackdrops()
    }

    /// MenuBarExtra paints its own full-size opaque backdrop layers as
    /// siblings behind our glass — the "white underneath" that kept the
    /// panel from ever looking translucent. Hide exactly those: full-size,
    /// layer-backed leaf fills that don't contain us. Dividers and status
    /// chips are layer-backed too but nowhere near full-size, so the size
    /// guard protects them. Re-run every layout — SwiftUI repaints them.
    private func clearSystemBackdrops() {
        guard let hosting = window?.contentView else { return }
        for sibling in hosting.subviews {
            guard sibling.frame.width >= hosting.bounds.width - 1,
                  sibling.frame.height >= hosting.bounds.height - 1,
                  sibling.subviews.isEmpty,
                  !self.isDescendant(of: sibling)
            else { continue }
            let hasBackgroundFill = sibling.layer?.backgroundColor != nil
            // SwiftUI also adds a faint (~5%) full-size overlay whose edge
            // reads as a hairline white arc at the clipped corners.
            let isFaintOverlay = sibling.alphaValue > 0 && sibling.alphaValue < 0.2
            guard hasBackgroundFill || isFaintOverlay else { continue }
            sibling.layer?.backgroundColor = NSColor.clear.cgColor
            sibling.alphaValue = 0
        }
    }

    private func syncWindowFrame(heightAuthoritative: Bool) {
        guard !adjusting, let window, window.isVisible else { return }
        var frame = window.frame

        if anchorTopY == nil {
            anchorTopY = frame.maxY
            lastSyncedHeight = frame.height
        } else if frame.maxY > (anchorTopY ?? 0) + 2,
                  abs(frame.height - lastSyncedHeight) <= 0.5 {
            // Pure move with no size change: the system repositioned the
            // panel (reopen, display change) — that's authoritative. The
            // thresholds must be un-satisfiable by ANIMATED resize frames
            // (eased unfurl deltas can be sub-point), or the anchor
            // ratchets upward toward the menu bar across toggles.
            anchorTopY = frame.maxY
        }
        guard let topY = anchorTopY else { return }

        let desiredHeight = heightAuthoritative ? bounds.height : frame.height
        let heightOK = abs(frame.height - desiredHeight) <= 1
        let pinOK = abs(frame.maxY - topY) <= 0.5
        lastSyncedHeight = desiredHeight

        guard !(heightOK && pinOK) else {
            window.invalidateShadow()
            return
        }

        frame.size.height = desiredHeight
        frame.origin.y = topY - desiredHeight
        adjusting = true
        window.setFrame(frame, display: true)
        adjusting = false
        window.invalidateShadow()
    }
}

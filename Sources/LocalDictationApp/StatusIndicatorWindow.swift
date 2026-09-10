import AppKit
import LocalDictationCore
import QuartzCore

@MainActor
final class StatusIndicatorWindow: NSObject {
    fileprivate static let indicatorSize: CGFloat = CGFloat(DictationIndicatorLayout.compactSize.width)
    fileprivate static let savedFrameKey = "statusIndicatorFrame"
    private let panel: NSPanel
    private let indicatorView: DictationIndicatorView
    private var hasPositionedPanel = false

    override init() {
        let size = Self.indicatorSize
        indicatorView = DictationIndicatorView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.contentView = indicatorView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        // Keep the indicator above regular and full-screen app windows so its
        // state remains visible while the user is working elsewhere.
        panel.level = .screenSaver
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.animationBehavior = .utilityWindow
    }

    func update(for state: DictationState) {
        let presentation = DictationIndicatorPresentation(state: state)
        indicatorView.apply(presentation)
        if !hasPositionedPanel {
            restoreOrPositionPanel()
            hasPositionedPanel = true
        }
        resizePanel(for: state)
        panel.orderFrontRegardless()
    }

    /// Expands the small microphone icon only while recording. Growth is
    /// anchored to the panel's top edge so the icon stays in place while the
    /// recording meter opens downward.
    private func resizePanel(for state: DictationState) {
        let targetSize = DictationIndicatorLayout.size(for: state)
        let targetWidth = CGFloat(targetSize.width)
        let targetHeight = CGFloat(targetSize.height)
        let currentFrame = panel.frame
        guard currentFrame.width != targetWidth || currentFrame.height != targetHeight else { return }

        var newOrigin = NSPoint(x: currentFrame.origin.x, y: currentFrame.maxY - targetHeight)
        if let screen = panel.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            newOrigin.x = min(max(newOrigin.x, visible.minX), visible.maxX - targetWidth)
            newOrigin.y = min(max(newOrigin.y, visible.minY), visible.maxY - targetHeight)
        }
        let newFrame = NSRect(
            origin: newOrigin,
            size: NSSize(width: targetWidth, height: targetHeight)
        )

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(newFrame, display: true)
            indicatorView.waveformHeightConstraint.animator().constant =
                state == .recording ? DictationIndicatorView.waveformExpandedHeight : 0
        }
    }

    private func restoreOrPositionPanel() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        if let savedFrameValue = UserDefaults.standard.string(forKey: Self.savedFrameKey) {
            let savedFrame = NSRectFromString(savedFrameValue)
            let compactFrame = DictationIndicatorLayout.compactFrame(from: DictationIndicatorFrame(
                originX: savedFrame.origin.x,
                originY: savedFrame.origin.y,
                width: savedFrame.size.width,
                height: savedFrame.size.height
            ))
            let restoredFrame = NSRect(
                x: compactFrame.originX,
                y: compactFrame.originY,
                width: compactFrame.width,
                height: compactFrame.height
            )
            let isVisible = NSScreen.screens.contains { $0.visibleFrame.intersects(restoredFrame) }
            if isVisible, savedFrame.width > 0, savedFrame.height > 0 {
                panel.setFrame(restoredFrame, display: false)
                return
            }
        }

        let visibleFrame = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: visibleFrame.maxX - size.width - 18,
            y: visibleFrame.maxY - size.height - 14
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

@MainActor
private final class DictationIndicatorView: NSView {
    fileprivate static let waveformExpandedHeight: CGFloat = 60

    private let visualEffectView = NSVisualEffectView()
    private let iconView = NSImageView()
    private let spinner = NSProgressIndicator()
    private let waveformView = WaveformView()
    let waveformHeightConstraint: NSLayoutConstraint

    override init(frame frameRect: NSRect) {
        waveformHeightConstraint = waveformView.heightAnchor.constraint(equalToConstant: 0)
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)

        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 16
        visualEffectView.layer?.borderWidth = 1
        visualEffectView.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        visualEffectView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(visualEffectView)
        NSLayoutConstraint.activate([
            visualEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            visualEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            visualEffectView.topAnchor.constraint(equalTo: topAnchor),
            visualEffectView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true

        iconView.translatesAutoresizingMaskIntoConstraints = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        waveformView.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(iconView)
        visualEffectView.addSubview(spinner)
        visualEffectView.addSubview(waveformView)

        // The icon/spinner sit at a fixed offset from the top edge. The
        // panel grows downward (see resizePanel), so the wiggling meter fills
        // the space beneath the icon instead of moving it.
        let iconMargin: CGFloat = (StatusIndicatorWindow.indicatorSize - 18) / 2
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: visualEffectView.centerXAnchor),
            iconView.topAnchor.constraint(equalTo: visualEffectView.topAnchor, constant: iconMargin),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            spinner.centerXAnchor.constraint(equalTo: visualEffectView.centerXAnchor),
            spinner.topAnchor.constraint(equalTo: visualEffectView.topAnchor, constant: iconMargin),
            spinner.widthAnchor.constraint(equalToConstant: 18),
            spinner.heightAnchor.constraint(equalToConstant: 18),

            waveformView.centerXAnchor.constraint(equalTo: visualEffectView.centerXAnchor),
            waveformView.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: -8),
            waveformView.widthAnchor.constraint(equalToConstant: 18),
            waveformHeightConstraint
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        NSCursor.closedHand.push()
        defer {
            let compactFrame = DictationIndicatorLayout.compactFrame(from: DictationIndicatorFrame(
                originX: window.frame.origin.x,
                originY: window.frame.origin.y,
                width: window.frame.size.width,
                height: window.frame.size.height
            ))
            UserDefaults.standard.set(
                NSStringFromRect(NSRect(
                    x: compactFrame.originX,
                    y: compactFrame.originY,
                    width: compactFrame.width,
                    height: compactFrame.height
                )),
                forKey: StatusIndicatorWindow.savedFrameKey
            )
            NSCursor.pop()
        }
        window.performDrag(with: event)
    }

    func apply(_ presentation: DictationIndicatorPresentation) {
        setAccessibilityLabel(presentation.accessibilityLabel)

        let iconName: String
        let color: NSColor
        switch presentation.kind {
        case .ready:
            iconName = "mic.fill"
            color = .secondaryLabelColor
        case .recording:
            iconName = "mic.fill"
            color = .systemRed
        case .processing:
            iconName = "waveform"
            color = .systemOrange
        case .failed:
            iconName = "exclamationmark.triangle.fill"
            color = .systemYellow
        }

        iconView.image = NSImage(
            systemSymbolName: iconName,
            accessibilityDescription: presentation.accessibilityLabel
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
        iconView.contentTintColor = color
        iconView.isHidden = presentation.kind == .processing
        spinner.isHidden = presentation.kind != .processing
        if presentation.kind == .processing {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }

        if presentation.kind == .recording {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.45
            pulse.duration = 0.9
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            iconView.layer?.add(pulse, forKey: "recordingPulse")
            waveformView.isHidden = false
            waveformView.startAnimating()
        } else {
            iconView.layer?.removeAnimation(forKey: "recordingPulse")
            waveformView.stopAnimating()
            waveformView.isHidden = true
        }
    }
}

/// A small vertical stack of bars that wiggle like an audio meter, used to
/// make the recording state impossible to miss even out of the corner of the eye.
@MainActor
private final class WaveformView: NSView {
    private let barCount = 4
    private let barLayers: [CALayer]

    override init(frame frameRect: NSRect) {
        barLayers = (0..<barCount).map { _ in
            let bar = CALayer()
            bar.backgroundColor = NSColor.systemRed.cgColor
            bar.cornerRadius = 1.5
            bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            return bar
        }
        super.init(frame: frameRect)
        wantsLayer = true
        barLayers.forEach { layer?.addSublayer($0) }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let barHeight: CGFloat = 3
        let spacing: CGFloat = 5
        let maxWidth = bounds.width
        let totalHeight = CGFloat(barCount) * barHeight + CGFloat(barCount - 1) * spacing
        var y = (bounds.height - totalHeight) / 2 + barHeight / 2
        for bar in barLayers {
            bar.bounds = CGRect(x: 0, y: 0, width: maxWidth, height: barHeight)
            bar.position = CGPoint(x: bounds.width / 2, y: y)
            y += barHeight + spacing
        }
    }

    func startAnimating() {
        for (index, bar) in barLayers.enumerated() {
            guard bar.animation(forKey: "wiggle") == nil else { continue }
            let wiggle = CABasicAnimation(keyPath: "transform.scale.x")
            wiggle.fromValue = CGFloat.random(in: 0.25...0.45)
            wiggle.toValue = CGFloat.random(in: 0.75...1.0)
            wiggle.duration = Double.random(in: 0.3...0.5)
            wiggle.autoreverses = true
            wiggle.repeatCount = .infinity
            wiggle.timeOffset = Double(index) * 0.12
            bar.add(wiggle, forKey: "wiggle")
        }
    }

    func stopAnimating() {
        barLayers.forEach { $0.removeAnimation(forKey: "wiggle") }
    }
}

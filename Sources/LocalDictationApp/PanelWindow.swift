import AppKit

/// Shared chrome for the two auxiliary windows. Both are fixed-width, non-resizable
/// panels that are built once and reshown, so closing one must not release it.
@MainActor
class PanelWindow: NSObject {
    static let contentWidth: CGFloat = 400

    let window: NSWindow

    init(title: String) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: PanelWindow.contentWidth, height: 0),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        super.init()
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Pins a vertical stack to the window's content view at a fixed width.
    func install(_ views: [NSView]) {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: PanelWindow.contentWidth),
        ])
        window.contentView = container
    }

    func sectionHeading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: 13)
        return label
    }

    /// `width` must match the column the caption actually sits in, or the text
    /// wraps at the wrong point and the last line is cut off.
    func caption(_ text: String, width: CGFloat = PanelWindow.contentWidth - 40) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = width
        return label
    }
}

/// NSButton takes a selector, not a closure, so this adapts one.
final class ClosureButton: NSButton {
    private let onPress: () -> Void

    init(title: String, action: @escaping () -> Void) {
        onPress = action
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        target = self
        self.action = #selector(pressed)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func pressed() {
        onPress()
    }
}

/// Same closure adapter for checkboxes.
final class ClosureCheckbox: NSButton {
    private let onToggle: (Bool) -> Void

    init(title: String, isOn: Bool, action: @escaping (Bool) -> Void) {
        onToggle = action
        super.init(frame: .zero)
        setButtonType(.switch)
        self.title = title
        state = isOn ? .on : .off
        target = self
        self.action = #selector(toggled)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func toggled() {
        onToggle(state == .on)
    }
}

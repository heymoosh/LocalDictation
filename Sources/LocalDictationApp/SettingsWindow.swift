import AppKit
import ApplicationServices
import AVFoundation
import LocalDictationCore
import ServiceManagement

/// The app's only settings surface: what starts dictation, whether it opens at
/// login, and the live state of the three macOS permissions. Input Monitoring in
/// particular never shows a system prompt on its own — macOS just lists the app,
/// unchecked, in Settings — so this window is the only place it is explained.
@MainActor
final class SettingsWindow: PanelWindow {
    nonisolated static let bindingsDefaultsKey = "hotkeyBindings"
    static let hasShownDefaultsKey = "hasShownPermissionsOnboarding"

    /// Reads the saved shortcuts. Kept here so the app delegate and this window
    /// cannot disagree about the default.
    nonisolated static var bindings: [HotkeyBinding] {
        Hotkey.decodeBindings(UserDefaults.standard.data(forKey: bindingsDefaultsKey))
    }

    private let onBindingsChanged: () -> Void
    private let bindingsStack = NSStackView()
    private let launchAtLoginCheckbox: ClosureCheckbox
    private let launchAtLoginStatusLabel = NSTextField(labelWithString: "")
    private let microphoneStatusLabel = NSTextField(labelWithString: "")
    private let inputMonitoringStatusLabel = NSTextField(labelWithString: "")
    private let accessibilityStatusLabel = NSTextField(labelWithString: "")

    init(onBindingsChanged: @escaping () -> Void) {
        self.onBindingsChanged = onBindingsChanged
        launchAtLoginCheckbox = ClosureCheckbox(
            title: "Open Local Dictation at login",
            isOn: SMAppService.mainApp.status == .enabled,
            action: { _ in }
        )
        super.init(title: "Local Dictation Settings")

        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(toggleLaunchAtLogin)
        install(buildSections())
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    override func show() {
        refresh()
        super.show()
    }

    /// Permissions are granted in System Settings, so the only reliable moment to
    /// re-read them is when the user comes back to this app.
    @objc private func handleAppDidBecomeActive() {
        guard window.isVisible else { return }
        refresh()
    }

    // MARK: - Layout

    private func buildSections() -> [NSView] {
        [
            sectionHeading("What starts dictation"),
            caption("Press your shortcut once to start, again to stop. Add as many as you like — a modifier key on its own, a key combination, or an extra mouse button."),
            buildBindingsList(),
            separator(),
            sectionHeading("Startup"),
            launchAtLoginCheckbox,
            launchAtLoginStatusLabel,
            separator(),
            sectionHeading("Permissions"),
            caption("macOS requires you to grant each of these yourself. This window re-checks them every time you come back to the app."),
            permissionRow(
                title: "Microphone",
                detail: "Lets the app hear your speech.",
                statusLabel: microphoneStatusLabel,
                buttonTitle: "Open…",
                action: Self.openMicrophoneSettings
            ),
            permissionRow(
                title: "Input Monitoring",
                detail: "Lets the shortcuts above work from any app. macOS shows no popup for this one.",
                statusLabel: inputMonitoringStatusLabel,
                buttonTitle: "Open…",
                action: Self.openInputMonitoringSettings
            ),
            permissionRow(
                title: "Accessibility",
                detail: "Lets the app paste your transcript where you're typing.",
                statusLabel: accessibilityStatusLabel,
                buttonTitle: "Open…",
                action: Self.openAccessibilitySettings
            ),
        ]
    }

    private func buildBindingsList() -> NSView {
        bindingsStack.orientation = .vertical
        bindingsStack.alignment = .leading
        bindingsStack.spacing = 6
        bindingsStack.widthAnchor.constraint(equalToConstant: PanelWindow.contentWidth - 40).isActive = true
        refreshBindingRows()
        return bindingsStack
    }

    /// Rebuilt from scratch on every change: the list is a handful of rows, so
    /// there is nothing to gain from patching it in place.
    private func refreshBindingRows() {
        for view in bindingsStack.arrangedSubviews {
            bindingsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let bindings = Self.bindings
        if bindings.isEmpty {
            bindingsStack.addArrangedSubview(
                caption("No shortcuts yet. You can still start dictation from the menu bar.")
            )
        }
        for binding in bindings {
            bindingsStack.addArrangedSubview(bindingRow(binding))
        }

        let recorder = HotkeyRecorderButton(title: "Add Shortcut…") { [weak self] binding in
            self?.add(binding)
        }
        bindingsStack.addArrangedSubview(recorder)
    }

    private func bindingRow(_ binding: HotkeyBinding) -> NSView {
        let label = NSTextField(labelWithString: binding.displayName)
        label.font = .systemFont(ofSize: 12, weight: .medium)

        let remove = ClosureButton(title: "Remove") { [weak self] in self?.remove(binding) }
        let row = NSStackView(views: [label, NSView(), remove])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.widthAnchor.constraint(equalToConstant: PanelWindow.contentWidth - 40).isActive = true
        return row
    }

    private func permissionRow(
        title: String,
        detail: String,
        statusLabel: NSTextField,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.font = .systemFont(ofSize: 11)

        let detailLabel = caption(detail, width: PanelWindow.contentWidth - 130)
        let textStack = NSStackView(views: [titleLabel, detailLabel, statusLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.widthAnchor.constraint(equalToConstant: PanelWindow.contentWidth - 130).isActive = true

        let row = NSStackView(views: [textStack, NSView(), ClosureButton(title: buttonTitle, action: action)])
        row.orientation = .horizontal
        row.alignment = .top
        row.widthAnchor.constraint(equalToConstant: PanelWindow.contentWidth - 40).isActive = true
        return row
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.widthAnchor.constraint(equalToConstant: PanelWindow.contentWidth - 40).isActive = true
        return line
    }

    // MARK: - Actions

    private func add(_ binding: HotkeyBinding) {
        var bindings = Self.bindings
        guard !bindings.contains(binding) else {
            NSSound.beep()
            return
        }
        bindings.append(binding)
        store(bindings)
    }

    private func remove(_ binding: HotkeyBinding) {
        store(Self.bindings.filter { $0 != binding })
    }

    /// An empty list is a real choice, not a sentinel: it is written out and kept.
    private func store(_ bindings: [HotkeyBinding]) {
        UserDefaults.standard.set(Hotkey.encodeBindings(bindings), forKey: Self.bindingsDefaultsKey)
        refreshBindingRows()
        onBindingsChanged()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Launch at Login Could Not Be Changed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        refresh()
    }

    // MARK: - Live status

    private func refresh() {
        let launchStatus: LaunchAtLoginStatus
        switch SMAppService.mainApp.status {
        case .enabled: launchStatus = .enabled
        case .notRegistered: launchStatus = .disabled
        case .requiresApproval: launchStatus = .requiresApproval
        case .notFound: launchStatus = .unavailable
        @unknown default: launchStatus = .unavailable
        }
        launchAtLoginCheckbox.state = launchStatus.isEnabled ? .on : .off
        launchAtLoginCheckbox.isEnabled = launchStatus != .unavailable
        switch launchStatus {
        case .enabled, .disabled:
            launchAtLoginStatusLabel.stringValue = ""
        case .requiresApproval:
            apply(text: "Approve Local Dictation in System Settings → Login Items.", ok: false, to: launchAtLoginStatusLabel)
        case .unavailable:
            apply(text: "Unavailable for this build.", ok: false, to: launchAtLoginStatusLabel)
        }

        apply(
            text: AVAudioApplication.shared.recordPermission == .granted ? "Ready" : "Not yet enabled",
            ok: AVAudioApplication.shared.recordPermission == .granted,
            to: microphoneStatusLabel
        )
        let listening = CGPreflightListenEventAccess()
        apply(
            text: listening ? "Ready — relaunch the app if shortcuts still don't work" : "Not yet enabled",
            ok: listening,
            to: inputMonitoringStatusLabel
        )
        apply(
            text: AXIsProcessTrusted() ? "Ready" : "Not yet enabled",
            ok: AXIsProcessTrusted(),
            to: accessibilityStatusLabel
        )
    }

    private func apply(text: String, ok: Bool, to label: NSTextField) {
        label.stringValue = text
        label.textColor = ok ? .systemGreen : .systemOrange
        label.font = .systemFont(ofSize: 11)
    }

    // MARK: - System Settings deep links

    static func openMicrophoneSettings() {
        open("Privacy_Microphone")
    }

    static func openAccessibilitySettings() {
        open("Privacy_Accessibility")
    }

    static func openInputMonitoringSettings() {
        open("Privacy_ListenEvent")
    }

    private static func open(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}

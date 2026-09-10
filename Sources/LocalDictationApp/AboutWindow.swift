import AppKit

/// Plain "what this is and where it came from" panel.
@MainActor
final class AboutWindow: PanelWindow {
    static let toolsPageURL = URL(string: "https://humaninference.ai/tools")!

    init() {
        super.init(title: "About Local Dictation")
        install(buildSections())
    }

    private func buildSections() -> [NSView] {
        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 56).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 56).isActive = true

        let name = NSTextField(labelWithString: "Local Dictation")
        name.font = .boldSystemFont(ofSize: 16)

        let version = NSTextField(labelWithString: versionString())
        version.font = .systemFont(ofSize: 11)
        version.textColor = .secondaryLabelColor

        let titleStack = NSStackView(views: [name, version])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2

        let header = NSStackView(views: [icon, titleStack])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12

        let button = ClosureButton(title: "Visit humaninference.ai/tools") {
            NSWorkspace.shared.open(AboutWindow.toolsPageURL)
        }

        return [
            header,
            caption("Speech to text that runs entirely on this Mac. Your audio is never uploaded — transcription happens locally with Whisper, and the recording is deleted as soon as it is transcribed."),
            button,
        ]
    }

    private func versionString() -> String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (short?, build?) where short != build:
            return "Version \(short) (\(build))"
        case let (short?, _):
            return "Version \(short)"
        case let (_, build?):
            return "Build \(build)"
        default:
            return "Local build"
        }
    }
}

import AppKit

enum WorkflowFailureIconRenderer {
    /// Works on an offscreen button too, so rendering can be checked without launching RepoBar.
    @MainActor
    static func apply(to button: NSButton, count: Int, stale: Bool) -> Bool {
        button.contentTintColor = nil
        guard count > 0 else { return false }

        let image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "Failing workflows")
            ?? NSImage(size: NSSize(width: 18, height: 18))
        image.isTemplate = true
        button.image = image
        button.title = " \(count)"
        button.imagePosition = .imageLeft
        button.imageScaling = .scaleProportionallyDown
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        button.contentTintColor = .systemRed
        button.toolTip = "\(count) failing workflows in pinned repositories\(stale ? " (last known results; refresh incomplete)" : "")"
        button.setAccessibilityLabel(button.toolTip ?? "Failing workflows")
        return true
    }
}

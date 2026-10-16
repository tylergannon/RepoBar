import AppKit
@testable import RepoBar
import RepoBarCore
import Testing

struct WorkflowMonitoringUITests {
    @MainActor
    @Test
    func `failure indicator renders red with count and stale explanation offscreen`() throws {
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 120, height: 26))
        button.isBordered = false
        #expect(WorkflowFailureIconRenderer.apply(to: button, count: 2, stale: true))
        #expect(button.contentTintColor == .systemRed)
        #expect(button.title == " 2")
        #expect(button.image != nil)
        #expect(button.toolTip?.contains("refresh incomplete") == true)
        // Offscreen visual evidence; this creates no status item, app instance, or notification.
        let bitmap = try #require(button.bitmapImageRepForCachingDisplay(in: button.bounds))
        button.cacheDisplay(in: button.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/repobar-workflow-failure-indicator.png"))
        #expect(!WorkflowFailureIconRenderer.apply(to: button, count: 0, stale: false))
        #expect(button.contentTintColor == nil)
    }

    @MainActor
    @Test
    func `only pinned workflows contribute to persistent failure count`() {
        let session = Session()
        let failed = WorkflowTracker.update(
            WorkflowTrackingState(),
            snapshot: WorkflowSnapshot(branch: "main", workflows: [WorkflowObservation(id: 1, name: "Build", result: .failure)]),
            scope: "test", notifyFailures: false, notifyRecoveries: false
        ).state
        session.workflowStates = ["acme/pinned": failed, "acme/other": failed]
        session.settings.repoList.pinnedRepositories = ["Acme/Pinned", "acme/pinned"]
        #expect(session.workflowFailureCount == 1)
        session.settings.repoList.pinnedRepositories = []
        #expect(session.workflowFailureCount == 0)
    }
}

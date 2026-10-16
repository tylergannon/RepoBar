import Foundation
@testable import RepoBarCore
import Testing

struct WorkflowTrackingTests {
    private func observation(_ id: Int = 1, _ result: WorkflowResult? = nil, run: Int = 1, attempt: Int = 1, pending: Bool = false) -> WorkflowObservation {
        WorkflowObservation(
            id: id, name: "Workflow \(id)", latestRunID: run, latestAttempt: attempt, pending: pending,
            result: result, resultRunID: result == nil ? nil : run, resultAttempt: attempt, resultRunNumber: run
        )
    }

    private func update(
        _ state: WorkflowTrackingState, _ workflows: [WorkflowObservation],
        scope: String = "account|repo|main", complete: Bool = true, alerts: Bool = true
    ) -> (state: WorkflowTrackingState, events: [WorkflowTransition]) {
        WorkflowTracker.update(
            state, snapshot: WorkflowSnapshot(branch: "main", workflows: workflows, complete: complete), scope: scope,
            notifyFailures: alerts, notifyRecoveries: alerts
        )
    }

    private func update(
        _ workflows: [WorkflowObservation], scope: String = "account|repo|main", complete: Bool = true, alerts: Bool = true
    ) -> (state: WorkflowTrackingState, events: [WorkflowTransition]) {
        self.update(WorkflowTrackingState(), workflows, scope: scope, complete: complete, alerts: alerts)
    }

    @Test
    func `unrelated success never hides a failure and baseline is silent`() {
        let result = self.update([self.observation(1, .failure), self.observation(2, .success)])
        #expect(result.state.status == .failing)
        #expect(result.state.failureCount == 1)
        #expect(result.events.isEmpty)
    }

    @Test
    func `new failure and recovery each notify once across persistence`() throws {
        let suite = "workflow-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkflowTrackingStore(defaults: defaults)
        let initial = self.update([self.observation(1, .success)])
        let failure = self.update(initial.state, [self.observation(1, .failure, run: 2)])
        #expect(failure.events.count == 1)
        #expect(failure.events.first?.result == .failure)
        store.save(failure.state, key: "account|host|repo")
        let restarted = WorkflowTrackingStore(defaults: defaults).load(key: "account|host|repo")
        #expect(self.update(restarted, [self.observation(1, .failure, run: 2)]).events.isEmpty)
        let recovered = self.update(restarted, [self.observation(1, .success, run: 3)])
        #expect(recovered.events.count == 1)
        #expect(recovered.events.first?.result == .success)
        #expect(recovered.state.status == .passing)
        #expect(self.update(recovered.state, [self.observation(1, .success, run: 3)]).events.isEmpty)
    }

    @Test
    func `queued rerun preserves failure until same workflow succeeds`() {
        let failed = self.update([self.observation(1, .failure, run: 5)]).state
        // The history contains a previous success while the latest failed run is being rerun.
        let pending = self.update(failed, [self.observation(1, .success, run: 4, pending: true)])
        #expect(pending.state.status == .failing)
        #expect(pending.events.isEmpty)
        let recovery = self.update(pending.state, [self.observation(1, .success, run: 5, attempt: 2)])
        #expect(recovery.state.status == .passing)
        #expect(recovery.events.count == 1)
    }

    @Test
    func `rerun of an older workflow run cannot replace newer failure`() {
        let failed = self.update([self.observation(1, .failure, run: 9)]).state
        let older = self.update(failed, [self.observation(1, .success, run: 8, attempt: 3)])
        #expect(older.state.status == .failing)
        #expect(older.events.isEmpty)
    }

    @Test(arguments: ["cancelled", "skipped", "neutral", "stale", "unknown", ""])
    func `non decisive conclusions do not clear failure`(_ conclusion: String) {
        let failed = self.update([self.observation(1, .failure)]).state
        let result = self.update(failed, [self.observation(1, WorkflowResult.from(conclusion: conclusion), run: 2)])
        #expect(result.state.status == .failing)
        #expect(result.events.isEmpty)
    }

    @Test(arguments: ["failure", "timed_out", "action_required", "startup_failure"])
    func `failure conclusions are decisive`(_ conclusion: String) {
        #expect(WorkflowResult.from(conclusion: conclusion) == .failure)
    }

    @Test
    func `partial catalog or missing workflow retains failures without recovery`() {
        let failed = self.update([self.observation(1, .failure), self.observation(2, .success)]).state
        let partial = self.update(failed, [self.observation(2, .success, run: 2)], complete: false)
        #expect(partial.state.status == .failing)
        #expect(partial.state.stale)
        #expect(partial.events.isEmpty)
        let retired = self.update(failed, [self.observation(2, .success, run: 2)])
        #expect(retired.state.status == .passing)
        #expect(retired.events.isEmpty)
    }

    @Test
    func `new branch or selection resets baseline and absent data is unknown`() {
        let failed = self.update([self.observation(1, .failure)]).state
        let changed = self.update(failed, [self.observation(1, .success)], scope: "account|repo|release")
        #expect(changed.state.status == .passing)
        #expect(changed.events.isEmpty)
        #expect(self.update([]).state.status == .unknown)
        #expect(self.update([self.observation(1, pending: true)]).state.status == .pending)
        #expect(self.update([self.observation()]).state.status == .unknown)
    }

    @Test
    func `enabling alerts establishes silent baseline and new workflows start silently`() {
        let disabled = self.update([self.observation(1, .success)], alerts: false).state
        let enabled = self.update(disabled, [self.observation(1, .failure, run: 2)])
        #expect(enabled.events.isEmpty)
        let added = self.update(enabled.state, [self.observation(1, .failure, run: 2), self.observation(2, .failure)])
        #expect(added.events.isEmpty)
    }

    @Test
    func `first decisive result after incomplete observation is a silent baseline`() {
        let unknown = self.update([self.observation(1)], complete: false).state
        let firstFailure = self.update(unknown, [self.observation(1, .failure, run: 2)])
        #expect(firstFailure.state.status == .failing)
        #expect(firstFailure.events.isEmpty)
    }

    @Test
    func `workflow rows distinguish cancelled and pending outcomes`() {
        #expect(GitHubStatusMapper.ciStatus(fromStatus: "completed", conclusion: "cancelled") == .unknown)
        #expect(GitHubStatusMapper.ciStatus(fromStatus: "pending", conclusion: nil) == .pending)
        #expect(GitHubStatusMapper.ciStatus(fromStatus: "completed", conclusion: "timed_out") == .failing)
    }

    @Test
    func `settings migrate without enabling alerts or AI and selections roundtrip`() throws {
        var settings = try JSONDecoder().decode(UserSettings.self, from: Data("{}".utf8))
        #expect(!settings.workflowMonitoring.notifyFailures)
        #expect(!settings.workflowMonitoring.notifyRecoveries)
        #expect(!settings.aiSummaries.enabled)
        settings.workflowMonitoring.repositories["owner/repo"] = WorkflowSelection(branch: "develop", workflows: ["42", "42", " .github/workflows/ci.yml "])
        let roundtrip = try JSONDecoder().decode(UserSettings.self, from: JSONEncoder().encode(settings))
        #expect(roundtrip.workflowMonitoring == settings.workflowMonitoring)
        #expect(roundtrip.workflowMonitoring.repositories["owner/repo"]?.workflows.count == 2)
    }
}

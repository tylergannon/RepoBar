import Foundation
import RepoBarCore

extension AppState {
    var workflowNamespace: String {
        let account = self.session.settings.resolvedActiveAccount()
        let host = account?.host ?? self.session.settings.enterpriseHost ?? self.session.settings.githubHost
        return "\(account?.id ?? "legacy")|\(host.absoluteString)"
    }

    func workflowStorageKey(repository: String, settings: WorkflowMonitoringSettings) -> String {
        let selection = settings.repositories[repository.lowercased()] ?? WorkflowSelection()
        let components = [self.workflowNamespace, repository.lowercased(), selection.branch] + selection.workflows.sorted()
        return ((try? JSONEncoder().encode(components)) ?? Data()).base64EncodedString()
    }

    func restoreWorkflowTrackingState() {
        self.workflowRefreshID = UUID()
        var states: [String: WorkflowTrackingState] = [:]
        for name in self.session.settings.repoList.pinnedRepositories {
            let key = self.workflowStorageKey(repository: name, settings: self.session.settings.workflowMonitoring)
            var state = self.workflowTrackingStore.load(key: key)
            state.stale = true
            states[name.lowercased()] = state
        }
        self.session.workflowStates = states
        NotificationCenter.default.post(name: .menuRepositoriesDidChange, object: nil)
    }

    func refreshWorkflowMonitoring() async {
        let refreshID = UUID()
        self.workflowRefreshID = refreshID
        let namespace = self.workflowNamespace
        let settings = self.session.settings.workflowMonitoring
        let pinned = self.session.settings.repoList.pinnedRepositories
        let client = self.github
        for name in Set(pinned.map { $0.lowercased() }).sorted() {
            guard !Task.isCancelled, self.workflowRefreshID == refreshID, self.workflowNamespace == namespace else { return }

            let parts = name.split(separator: "/")
            guard parts.count == 2 else { continue }

            let selection = settings.repositories[name] ?? WorkflowSelection()
            let key = self.workflowStorageKey(repository: name, settings: settings)
            var state = self.workflowTrackingStore.load(key: key)
            var events: [WorkflowTransition] = []
            do {
                let snapshot = try await client.workflowSnapshot(owner: String(parts[0]), name: String(parts[1]), selection: selection)
                guard !Task.isCancelled, self.workflowRefreshID == refreshID, self.workflowNamespace == namespace,
                      self.session.settings.workflowMonitoring == settings,
                      self.session.settings.repoList.pinnedRepositories == pinned else { return }

                let result = WorkflowTracker.update(
                    state, snapshot: snapshot, scope: "\(key)|\(snapshot.branch)",
                    notifyFailures: settings.notifyFailures, notifyRecoveries: settings.notifyRecoveries
                )
                state = result.state
                events = result.events
            } catch {
                guard !Task.isCancelled, self.workflowRefreshID == refreshID, self.workflowNamespace == namespace else { return }

                state.stale = true // Missing data is never evidence of a recovery.
            }
            guard self.session.settings.workflowMonitoring == settings,
                  self.session.settings.repoList.pinnedRepositories == pinned else { return }

            // At-most-once dispatch across restarts: save the transition before attempting delivery.
            self.workflowTrackingStore.save(state, key: key)
            self.session.workflowStates[name] = state
            NotificationCenter.default.post(name: .menuRepositoriesDidChange, object: nil)
            for event in events {
                guard !Task.isCancelled, self.workflowRefreshID == refreshID, self.workflowNamespace == namespace else { return }

                await RepoBarNotifier.shared.notify(RepoBarNotification(
                    identifier: "\(key)|\(event.identifier)",
                    title: event.result == .failure ? "Workflow failed in \(name)" : "Workflow recovered in \(name)",
                    body: event.workflow.name,
                    url: event.workflow.url
                ))
            }
        }
    }

    func repositoriesWithWorkflowState(_ repos: [Repository]) -> [Repository] {
        repos.map { repo in
            guard let state = self.session.workflowStates[repo.fullName.lowercased()] else { return repo }

            var updated = repo
            updated.ciStatus = state.status
            updated.ciRunCount = nil
            return updated
        }
    }
}

import RepoBarCore
import SwiftUI

struct WorkflowMonitoringSettingsView: View {
    @Bindable var session: Session
    let appState: AppState
    @State private var repository = ""
    @State private var branch = ""
    @State private var workflows = ""

    var body: some View {
        Section {
            Toggle("Notify when a workflow fails", isOn: self.$session.settings.workflowMonitoring.notifyFailures)
                .onChange(of: self.session.settings.workflowMonitoring.notifyFailures) { _, _ in self.saveNotifications() }
            Toggle("Notify when a workflow recovers", isOn: self.$session.settings.workflowMonitoring.notifyRecoveries)
                .onChange(of: self.session.settings.workflowMonitoring.notifyRecoveries) { _, _ in self.saveNotifications() }
            if self.session.settings.repoList.pinnedRepositories.isEmpty {
                Text("Pin repositories in Repositories to monitor their workflows.")
            } else {
                Picker("Repository", selection: self.$repository) {
                    Text("Choose a pinned repository").tag("")
                    ForEach(self.session.settings.repoList.pinnedRepositories, id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: self.repository) { _, _ in self.loadSelection() }
                if !self.repository.isEmpty {
                    TextField("Branch (blank uses default branch)", text: self.$branch)
                    TextField("Workflow IDs or file paths (comma separated)", text: self.$workflows)
                    Button("Apply workflow selection") { self.saveSelection() }
                    if let state = self.session.workflowStates[self.repository.lowercased()] {
                        Text("\(state.failureCount) failing workflows\(state.stale ? "; waiting for complete refresh" : "")")
                            .font(.caption)
                    }
                }
            }
        } header: {
            Text("Workflow monitoring")
        } footer: {
            Text(
                "All active workflows on each pinned repository's default branch are tracked. " +
                    "Leave workflows blank for all, or enter numeric IDs / .github/workflows/file.yml paths. " +
                    "Failures stay red until that workflow succeeds. First observations are silent; notifications are optional."
            )
        }
    }

    private func loadSelection() {
        let selection = self.session.settings.workflowMonitoring.repositories[self.repository.lowercased()] ?? WorkflowSelection()
        self.branch = selection.branch
        self.workflows = selection.workflows.joined(separator: ", ")
    }

    private func saveSelection() {
        self.session.settings.workflowMonitoring.repositories[self.repository.lowercased()] = WorkflowSelection(
            branch: self.branch, workflows: self.workflows.split(separator: ",").map(String.init)
        )
        self.appState.persistSettings()
        self.appState.restoreWorkflowTrackingState()
        self.appState.requestRefresh(cancelInFlight: true)
    }

    private func saveNotifications() {
        self.appState.persistSettings()
        self.appState.requestRefresh(cancelInFlight: true)
    }
}

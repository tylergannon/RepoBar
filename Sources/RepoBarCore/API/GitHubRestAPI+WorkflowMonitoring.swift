import Foundation

enum WorkflowMonitoringError: LocalizedError {
    case incompleteCatalog, missingBranch

    var errorDescription: String? {
        switch self {
        case .incompleteCatalog: "Workflow catalog exceeded the 1,000-workflow safety limit. Previous results were retained."
        case .missingBranch: "GitHub did not return a default branch. Select a branch explicitly."
        }
    }
}

struct WorkflowCatalogResponse: Decodable {
    let workflows: [Workflow]
    struct Workflow: Decodable, Sendable {
        let id: Int
        let name: String
        let path: String
        let state: String
    }
}

extension GitHubRestAPI {
    func workflowSnapshot(
        owner: String, name: String, selection: WorkflowSelection = WorkflowSelection(), defaultBranch: String? = nil
    ) async throws -> WorkflowSnapshot {
        let branch: String = if selection.branch.isEmpty {
            if let defaultBranch {
                defaultBranch
            } else {
                try await self.repoDetails(owner: owner, name: name).defaultBranch ?? ""
            }
        } else {
            selection.branch
        }
        guard !branch.isEmpty else { throw WorkflowMonitoringError.missingBranch }

        let token = try await tokenProvider()
        let baseURL = await apiHost()
        var catalog: [WorkflowCatalogResponse.Workflow] = []
        for page in 1 ... 10 {
            let url = Self.workflowURL(baseURL: baseURL, owner: owner, name: name, suffix: "workflows", query: [
                URLQueryItem(name: "per_page", value: "100"), URLQueryItem(name: "page", value: "\(page)")
            ])
            let (data, response) = try await authorizedGet(url: url, token: token)
            let workflows = try GitHubDecoding.decode(WorkflowCatalogResponse.self, from: data).workflows
            catalog.append(contentsOf: workflows)
            if response.value(forHTTPHeaderField: "Link")?.contains("rel=\"next\"") != true {
                break
            }
            if page == 10 {
                throw WorkflowMonitoringError.incompleteCatalog
            }
        }
        let selected = Set(selection.workflows)
        let relevant = catalog.filter {
            selected.isEmpty ? $0.state == "active" : selected.contains(String($0.id)) || selected.contains($0.path)
        }
        let found = Set(relevant.flatMap { [String($0.id), $0.path] })
        var complete = selected.isSubset(of: found)
        var observations: [WorkflowObservation] = []
        // A busy workflow cannot crowd another workflow's latest result out of a shared page.
        for batch in relevant.repoBarBatches(of: 4) {
            try Task.checkCancellation()
            let results = await withTaskGroup(of: WorkflowObservation.self) { group in
                for workflow in batch {
                    group.addTask {
                        do {
                            return try await self.workflowObservation(
                                workflow, baseURL: baseURL.appending(path: "/repos/\(owner)/\(name)/actions"), token: token, branch: branch
                            )
                        } catch {
                            return WorkflowObservation(id: workflow.id, name: workflow.name, historyComplete: false)
                        }
                    }
                }
                var results: [WorkflowObservation] = []
                for await result in group {
                    results.append(result)
                }
                return results
            }
            observations.append(contentsOf: results)
        }
        complete = complete && observations.allSatisfy(\.historyComplete)
        try Task.checkCancellation()
        return WorkflowSnapshot(branch: branch, workflows: observations.sorted { $0.id < $1.id }, complete: complete)
    }

    private func workflowObservation(
        _ workflow: WorkflowCatalogResponse.Workflow, baseURL: URL, token: String, branch: String
    ) async throws -> WorkflowObservation {
        var runs: [ActionsRunsResponse.WorkflowRun] = []
        var exhausted = false
        for page in 1 ... 5 {
            try Task.checkCancellation()
            var components = URLComponents(url: baseURL.appending(path: "workflows/\(workflow.id)/runs"), resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "branch", value: branch), URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "page", value: "\(page)")
            ]
            let (data, response) = try await authorizedGet(url: components.url!, token: token)
            try runs.append(contentsOf: GitHubDecoding.decode(ActionsRunsResponse.self, from: data).workflowRuns)
            exhausted = response.value(forHTTPHeaderField: "Link")?.contains("rel=\"next\"") != true
            if exhausted || runs.contains(where: { WorkflowResult.from(conclusion: $0.conclusion) != nil }) {
                break
            }
        }
        // run_number orders runs of this workflow; rerunning an older run must not replace a newer run.
        runs.sort {
            if $0.runNumber != $1.runNumber {
                return ($0.runNumber ?? 0) > ($1.runNumber ?? 0)
            }
            return ($0.runAttempt ?? 1) > ($1.runAttempt ?? 1)
        }
        let latest = runs.first
        let decisive = runs.first { WorkflowResult.from(conclusion: $0.conclusion) != nil }
        return WorkflowObservation(
            id: workflow.id, name: workflow.name, url: decisive?.htmlUrl ?? latest?.htmlUrl,
            latestRunID: latest?.id, latestAttempt: latest?.runAttempt ?? 1,
            pending: ["queued", "waiting", "pending", "requested", "in_progress"].contains(latest?.status ?? ""),
            result: WorkflowResult.from(conclusion: decisive?.conclusion), resultRunID: decisive?.id,
            resultAttempt: decisive?.runAttempt ?? 1, resultRunNumber: decisive?.runNumber ?? 0,
            historyComplete: exhausted || decisive != nil
        )
    }

    static func workflowURL(baseURL: URL, owner: String, name: String, suffix: String, query: [URLQueryItem]) -> URL {
        var components = URLComponents(url: baseURL.appending(path: "/repos/\(owner)/\(name)/actions/\(suffix)"), resolvingAgainstBaseURL: false)!
        components.queryItems = query
        return components.url!
    }
}

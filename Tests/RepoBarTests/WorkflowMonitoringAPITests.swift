import Foundation
@testable import RepoBarCore
import Testing

struct WorkflowMonitoringAPITests {
    @Test
    func `discovers actual default branch and never lets unrelated workflow success hide failure`() async throws {
        let transport = WorkflowTestTransport { request in
            let path = request.url!.path
            if path == "/repos/acme/repo" {
                return ([
                    "id": 1,
                    "name": "repo",
                    "full_name": "acme/repo",
                    "default_branch": "master",
                    "fork": false,
                    "archived": false,
                    "open_issues_count": 0,
                    "stargazers_count": 0,
                    "forks_count": 0,
                    "owner": ["login": "acme"]
                ], [:])
            }
            if path.hasSuffix("/workflows") {
                return (Self.catalog([1, 2]), [:])
            }
            let branch = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "branch" }?.value
            #expect(branch == "master")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            return (Self.runs([Self.run(path.contains("/1/") ? "failure" : "success", number: 1)]), [:])
        }
        let snapshot = try await self.api(transport).workflowSnapshot(owner: "acme", name: "repo")
        let result = WorkflowTracker.update(WorkflowTrackingState(), snapshot: snapshot, scope: "master", notifyFailures: false, notifyRecoveries: false)
        #expect(snapshot.branch == "master")
        #expect(snapshot.workflows.count == 2)
        #expect(result.state.status == .failing)
    }

    @Test
    func `branch and workflow file selection exclude other workflows`() async throws {
        let transport = WorkflowTestTransport { request in
            if request.url!.path.hasSuffix("/workflows") {
                return (Self.catalog([1, 2]), [:])
            }
            #expect(request.url!.path.contains("/workflows/2/runs"))
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            #expect(query.contains(URLQueryItem(name: "branch", value: "release/next")))
            return (Self.runs([Self.run("success", number: 4)]), [:])
        }
        let selection = WorkflowSelection(branch: "release/next", workflows: [".github/workflows/2.yml"])
        let snapshot = try await self.api(transport).workflowSnapshot(owner: "acme", name: "repo", selection: selection)
        #expect(snapshot.complete)
        #expect(snapshot.workflows.map(\.id) == [2])
        #expect(await transport.requests.count == 2)
    }

    @Test
    func `paginates catalog and histories past cancelled and queued runs`() async throws {
        let transport = WorkflowTestTransport { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let page = query.first { $0.name == "page" }?.value
            let more = ["Link": "<https://api.github.com/next>; rel=\"next\""]
            if request.url!.path.hasSuffix("/workflows") {
                return (Self.catalog(page == "1" ? [1] : [2]), page == "1" ? more : [:])
            }
            if page == "1" {
                return (Self.runs([Self.run(nil, number: 5, status: "in_progress"), Self.run("cancelled", number: 4)]), more)
            }
            return (Self.runs([Self.run("failure", number: 3)]), [:])
        }
        let snapshot = try await self.api(transport).workflowSnapshot(owner: "acme", name: "repo", defaultBranch: "trunk")
        #expect(snapshot.complete)
        #expect(snapshot.workflows.count == 2)
        #expect(snapshot.workflows.allSatisfy { $0.pending && $0.result == .failure && $0.resultRunNumber == 3 })
        #expect(await transport.requests.count == 6)
    }

    @Test
    func `run number beats rerun attempt of older run`() async throws {
        let transport = WorkflowTestTransport { request in
            if request.url!.path.hasSuffix("/workflows") {
                return (Self.catalog([1]), [:])
            }
            var old = Self.run("success", number: 4)
            old["run_attempt"] = 3
            return (Self.runs([old, Self.run("failure", number: 5)]), [:])
        }
        let snapshot = try await self.api(transport).workflowSnapshot(owner: "acme", name: "repo", defaultBranch: "main")
        #expect(snapshot.workflows.first?.result == .failure)
        #expect(snapshot.workflows.first?.resultRunNumber == 5)
    }

    @Test
    func `missing selection and truncated history are incomplete not green`() async throws {
        let transport = WorkflowTestTransport { request in
            if request.url!.path.hasSuffix("/workflows") {
                return (Self.catalog([1]), [:])
            }
            return (Self.runs([Self.run("skipped", number: 6)]), ["Link": "<https://api.github.com/next>; rel=\"next\""])
        }
        let snapshot = try await self.api(transport).workflowSnapshot(
            owner: "acme", name: "repo", selection: WorkflowSelection(workflows: ["1", "999"]), defaultBranch: "main"
        )
        #expect(!snapshot.complete)
        #expect(snapshot.workflows.first?.result == nil)
        #expect(snapshot.workflows.first?.historyComplete == false)
        #expect(await transport.requests.count == 6) // catalog + five bounded history pages
    }

    @Test
    func `failed workflow request preserves partial observation as incomplete`() async throws {
        let transport = WorkflowTestTransport { request in
            if request.url!.path.hasSuffix("/workflows") {
                return (Self.catalog([1]), [:])
            }
            throw URLError(.notConnectedToInternet)
        }
        let snapshot = try await self.api(transport).workflowSnapshot(owner: "acme", name: "repo", defaultBranch: "main")
        #expect(!snapshot.complete)
        #expect(snapshot.workflows.first?.historyComplete == false)
    }

    @Test
    func `empty history is unknown and disabled workflows excluded by default`() async throws {
        let transport = WorkflowTestTransport { request in
            if request.url!.path.hasSuffix("/workflows") {
                var catalog = Self.catalog([1, 2])
                var workflows = catalog["workflows"] as! [[String: Any]]
                workflows[1]["state"] = "disabled_manually"
                catalog["workflows"] = workflows
                return (catalog, [:])
            }
            return (Self.runs([]), [:])
        }
        let snapshot = try await self.api(transport).workflowSnapshot(owner: "acme", name: "repo", defaultBranch: "main")
        #expect(snapshot.workflows.map(\.id) == [1])
        #expect(snapshot.workflows.first?.result == nil)
        #expect(snapshot.complete)
    }

    private func api(_ transport: WorkflowTestTransport) -> GitHubRestAPI {
        let loader = HTTPDataLoader { request in try await transport.data(request) }
        return GitHubRestAPI(
            apiHost: { URL(string: "https://api.github.com")! }, tokenProvider: { "test-token" },
            requestRunner: GitHubRequestRunner(etagCache: ETagCache(), dataLoader: loader),
            diag: .shared, responseDiskCache: nil, dataLoader: loader
        )
    }

    private static func catalog(_ ids: [Int]) -> [String: Any] {
        ["workflows": ids.map { ["id": $0, "name": "Workflow \($0)", "path": ".github/workflows/\($0).yml", "state": "active"] }]
    }

    private static func run(_ conclusion: String?, number: Int, status: String = "completed") -> [String: Any] {
        var run: [String: Any] = ["id": number, "run_number": number, "run_attempt": 1, "status": status, "html_url": "https://github.com/acme/repo/actions/runs/\(number)"]
        if let conclusion {
            run["conclusion"] = conclusion
        }
        return run
    }

    private static func runs(_ runs: [[String: Any]]) -> [String: Any] {
        ["total_count": runs.count, "workflow_runs": runs]
    }
}

private actor WorkflowTestTransport {
    let handler: @Sendable (URLRequest) throws -> ([String: Any], [String: String])
    private(set) var requests: [URLRequest] = []

    init(handler: @escaping @Sendable (URLRequest) throws -> ([String: Any], [String: String])) {
        self.handler = handler
    }

    func data(_ request: URLRequest) throws -> (Data, URLResponse) {
        self.requests.append(request)
        let (body, headers) = try self.handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!
        return try (JSONSerialization.data(withJSONObject: body), response)
    }
}

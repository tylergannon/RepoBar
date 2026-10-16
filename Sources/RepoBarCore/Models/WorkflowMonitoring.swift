import Foundation

/// Empty branch means the repository's current default branch; empty workflows means all active workflows.
public struct WorkflowSelection: Codable, Equatable, Sendable {
    public var branch = ""
    public var workflows: [String] = []

    public init(branch: String = "", workflows: [String] = []) {
        self.branch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        self.workflows = Array(Set(workflows.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    }
}

public struct WorkflowMonitoringSettings: Codable, Equatable, Sendable {
    public var notifyFailures = false
    public var notifyRecoveries = false
    /// Keys are lowercased owner/name. State is separately scoped to account and API host.
    public var repositories: [String: WorkflowSelection] = [:]

    public init() {}
}

public enum WorkflowResult: String, Codable, Sendable {
    case success, failure

    public static func from(conclusion: String?) -> Self? {
        switch conclusion {
        case "success": .success
        case "failure", "timed_out", "action_required", "startup_failure": .failure
        default: nil // Cancelled, skipped, neutral, and unknown outcomes cannot prove recovery.
        }
    }
}

public struct WorkflowObservation: Codable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let url: URL?
    public let latestRunID: Int?
    public let latestAttempt: Int
    public let pending: Bool
    public let result: WorkflowResult?
    public let resultRunID: Int?
    public let resultAttempt: Int
    public let resultRunNumber: Int
    public let historyComplete: Bool

    public init(
        id: Int, name: String, url: URL? = nil, latestRunID: Int? = nil, latestAttempt: Int = 1,
        pending: Bool = false, result: WorkflowResult? = nil, resultRunID: Int? = nil,
        resultAttempt: Int = 1, resultRunNumber: Int = 0, historyComplete: Bool = true
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.latestRunID = latestRunID
        self.latestAttempt = latestAttempt
        self.pending = pending
        self.result = result
        self.resultRunID = resultRunID
        self.resultAttempt = resultAttempt
        self.resultRunNumber = resultRunNumber
        self.historyComplete = historyComplete
    }
}

public struct WorkflowSnapshot: Sendable {
    public let branch: String
    public let workflows: [WorkflowObservation]
    public let complete: Bool

    public init(branch: String, workflows: [WorkflowObservation], complete: Bool = true) {
        self.branch = branch
        self.workflows = workflows
        self.complete = complete
    }
}

public struct TrackedWorkflow: Codable, Equatable, Sendable {
    public var observation: WorkflowObservation
    public var result: WorkflowResult?
    public var resultRunNumber: Int
    public var resultAttempt: Int
}

public struct WorkflowTrackingState: Codable, Equatable, Sendable {
    public var workflows: [Int: TrackedWorkflow] = [:]
    public var checkedAt: Date?
    public var stale = true
    public var notificationsEnabled = false
    public var scope = ""

    public init() {}

    public var failureCount: Int {
        self.workflows.values.count { $0.result == .failure }
    }

    public var status: CIStatus {
        if self.failureCount > 0 {
            return .failing
        }
        if self.workflows.values.contains(where: \.observation.pending) {
            return .pending
        }
        if self.stale || self.workflows.isEmpty || self.workflows.values.contains(where: { $0.result == nil }) {
            return .unknown
        }
        return .passing
    }
}

public struct WorkflowTransition: Equatable, Sendable {
    public let workflow: WorkflowObservation
    public let result: WorkflowResult

    public var identifier: String {
        "workflow-\(self.workflow.id)-\(self.workflow.resultRunID ?? 0)-\(self.workflow.resultAttempt)-\(self.result.rawValue)"
    }
}

public enum WorkflowTracker {
    /// Only a newer decisive result for the SAME workflow can replace its remembered failure.
    /// A new scope/workflow establishes a silent baseline. Persist before dispatching transitions.
    public static func update(
        _ previous: WorkflowTrackingState, snapshot: WorkflowSnapshot, scope: String,
        notifyFailures: Bool, notifyRecoveries: Bool, now: Date = Date()
    ) -> (state: WorkflowTrackingState, events: [WorkflowTransition]) {
        var state = previous.scope == scope ? previous : WorkflowTrackingState()
        let mayNotify = state.checkedAt != nil && state.notificationsEnabled
        var events: [WorkflowTransition] = []
        let observedIDs = Set(snapshot.workflows.map(\.id))
        if snapshot.complete {
            state.workflows = state.workflows.filter { observedIDs.contains($0.key) }
        }
        for observation in snapshot.workflows {
            let old = state.workflows[observation.id]
            let acceptsResult = observation.result != nil && (old?.result == nil
                || observation.resultRunNumber > (old?.resultRunNumber ?? 0)
                || (observation.resultRunNumber == old?.resultRunNumber && observation.resultAttempt >= (old?.resultAttempt ?? 0)))
            let result = acceptsResult ? observation.result : old?.result
            if mayNotify, let old, let result, old.result != result,
               result == .failure ? notifyFailures : notifyRecoveries,
               result == .failure ? old.result == .success : old.result == .failure {
                events.append(WorkflowTransition(workflow: observation, result: result))
            }
            state.workflows[observation.id] = TrackedWorkflow(
                observation: observation, result: result,
                resultRunNumber: acceptsResult ? observation.resultRunNumber : (old?.resultRunNumber ?? 0),
                resultAttempt: acceptsResult ? observation.resultAttempt : (old?.resultAttempt ?? 0)
            )
        }
        state.scope = scope
        state.checkedAt = now
        state.stale = !snapshot.complete || snapshot.workflows.contains { !$0.historyComplete }
        state.notificationsEnabled = notifyFailures || notifyRecoveries
        return (state, events)
    }
}

public struct WorkflowTrackingStore {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load(key: String) -> WorkflowTrackingState {
        guard let data = self.defaults.data(forKey: "workflow-monitor.\(key)") else { return WorkflowTrackingState() }

        return (try? JSONDecoder().decode(WorkflowTrackingState.self, from: data)) ?? WorkflowTrackingState()
    }

    public func save(_ state: WorkflowTrackingState, key: String) {
        guard let data = try? JSONEncoder().encode(state) else { return }

        self.defaults.set(data, forKey: "workflow-monitor.\(key)")
    }
}

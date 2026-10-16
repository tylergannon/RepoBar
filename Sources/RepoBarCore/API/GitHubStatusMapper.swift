enum GitHubStatusMapper {
    static func ciStatus(fromStatus status: String?, conclusion: String?) -> CIStatus {
        switch conclusion ?? status {
        case "success": .passing
        case "failure", "timed_out", "action_required", "startup_failure": .failing
        case "in_progress", "queued", "waiting", "pending", "requested": .pending
        default: .unknown
        }
    }
}

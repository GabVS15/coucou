import Foundation

// MARK: - One pill per Claude Code session
//
// Each session_id seen in a hook gets its own task ("claude:<session_id>") with its project,
// source, Mochi state and live data. The "Claude Code" placeholder pill (integration_claude)
// only shows while no session is running.

extension AppState {
    static let claudePlaceholderId = "integration_claude"

    static func claudeTaskId(_ sessionId: String) -> String { AgentTask.claudeSessionPrefix + sessionId }

    /// Creates the session's pill on its first event, or refreshes project/source/cwd. Returns its task id.
    @discardableResult
    func upsertClaudeSession(sessionId: String, projectName: String, cwd: String, source: ClaudeSource) -> String {
        let id = Self.claudeTaskId(sessionId)
        if let i = tasks.firstIndex(where: { $0.id == id }) {
            if tasks[i].projectName != projectName { tasks[i].projectName = projectName }
            if tasks[i].claudeSource != source { tasks[i].claudeSource = source }
            if !cwd.isEmpty, tasks[i].sessionCwd != cwd { tasks[i].sessionCwd = cwd }
        } else {
            var task = AgentTask(id: id, name: projectName,
                                 color: IslandConst.colorForProject(projectName),
                                 state: .idle, steps: [], source: .claudeCode)
            task.projectName = projectName
            task.claudeSource = source
            task.sessionCwd = cwd.isEmpty ? nil : cwd
            let firstSession = !tasks.contains(where: \.isClaudeSession)
            let insertAt = tasks.firstIndex(where: { $0.id == Self.claudePlaceholderId }) ?? 0
            tasks.insert(task, at: insertAt)
            // The first session takes the placeholder's focus; later ones don't steal it
            if firstSession && (focusId == nil || focusId == Self.claudePlaceholderId) { focusId = id }
            syncClaudePlaceholder()
            syncMode()
            syncView()
        }
        refreshClaudeSessionNames()
        return id
    }

    func removeClaudeSession(taskId: String) {
        guard tasks.contains(where: { $0.id == taskId }) else { return }
        tasks.removeAll { $0.id == taskId }
        liveSessions[taskId] = nil
        syncClaudePlaceholder()
        if focusId == taskId {
            focusId = tasks.first(where: \.isClaudeSession)?.id ?? tasks.first?.id
            if view == .liveSession { view = .overview }
        }
        refreshClaudeSessionNames()
        syncMode()
        syncView()
    }

    /// Placeholder pill only while no session runs; it sits first in the list.
    func syncClaudePlaceholder() {
        let hasSessions = tasks.contains(where: \.isClaudeSession)
        let hasPlaceholder = tasks.contains(where: { $0.id == Self.claudePlaceholderId })
        if hasSessions && hasPlaceholder {
            tasks.removeAll { $0.id == Self.claudePlaceholderId }
        } else if !hasSessions && !hasPlaceholder,
                  let placeholder = AgentTask.integrationAgents.first(where: { $0.id == Self.claudePlaceholderId }) {
            tasks.insert(placeholder, at: 0)
            if focusId == nil { focusId = placeholder.id }
        }
    }

    /// Pill label = project name; "project · source" when two sessions share a project.
    func refreshClaudeSessionNames() {
        let sessions = tasks.filter(\.isClaudeSession)
        var count: [String: Int] = [:]
        for t in sessions { count[t.projectName ?? t.name, default: 0] += 1 }
        for i in tasks.indices where tasks[i].isClaudeSession {
            let project = tasks[i].projectName ?? tasks[i].name
            let name = (count[project] ?? 0) > 1
                ? "\(project) · \(tasks[i].claudeSource?.label ?? "Claude")"
                : project
            if tasks[i].name != name { tasks[i].name = name }
        }
    }

    // MARK: Pill order

    /// Pills other than the focused one, most urgent first:
    /// sessions waiting for you → working sessions → integrations → idle sessions.
    var orderedOtherTasks: [AgentTask] {
        tasks.enumerated()
            .filter { $0.element.id != focusId }
            .sorted { (Self.pillRank($0.element), $0.offset) < (Self.pillRank($1.element), $1.offset) }
            .map(\.element)
    }

    private static func pillRank(_ t: AgentTask) -> Int {
        let attention: Set<BotState> = [.approval, .question, .error]
        let working: Set<BotState> = [.working, .thinking, .searching]
        if attention.contains(t.state) || t.pillBadge == .approval || t.pillBadge == .error { return 0 }
        if t.isClaudeSession && working.contains(t.state) { return 1 }
        if t.isIntegration || !t.isClaudeSession { return 2 }
        return 3
    }
}

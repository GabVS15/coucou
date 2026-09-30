import Foundation
import Darwin
import AppKit

// MARK: - HookServer
// Listens on a Unix domain socket for events from nb-hook (Claude Code hooks).
// Thread-safe: socket I/O on background threads, state updates dispatched to main queue.

final class HookServer: @unchecked Sendable {
    static let shared = HookServer()

    // Support directory paths
    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchBuddy")
    }
    static var socketPath: String { supportDir.appendingPathComponent("nb.sock").path }
    static var hookScriptPath: String {
        #if APPSTORE
        // Written to ~/.claude/coucou/nb-hook via security-scoped bookmark during hook installation
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/coucou/nb-hook").path
        #else
        return supportDir.appendingPathComponent("nb-hook").path
        #endif
    }

    private var serverFD: Int32 = -1
    private var approvalFDs: [UUID: Int32] = [:]    // one open socket per queued permission request
    private var quickReplyFDs: [UUID: Int32] = [:]  // Stop hooks held open while a question is shown
    private var quickReplyWatchers: [UUID: DispatchSourceRead] = [:]  // notice when a held hook goes away
    private var quickReplyChain: [String: Int] = [:] // quick replies in a row, per session task
    private var lastEventAt: [String: Date] = [:]   // per session task, for the idle cleanup
    private var pruneTimer: Timer?

    /// A session without any event for this long loses its pill (Desktop doesn't always send SessionEnd).
    private static let idleSessionTimeout: TimeInterval = 30 * 60

    private init() {}

    // MARK: - Start

    func start() {
        #if !APPSTORE
        installHookScript()
        #endif
        Thread.detachNewThread { self.serverThread() }
        Task { @MainActor in self.startIdlePrune() }
    }

    /// Every minute: drop sessions idle for 30 min (unless one of their permission requests is waiting).
    @MainActor
    private func startIdlePrune() {
        guard pruneTimer == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pruneIdleSessions() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        pruneTimer = timer
    }

    @MainActor
    private func pruneIdleSessions() {
        let state = AppState.shared
        let waiting = Set(state.approvalQueue.map(\.taskId))
        let cutoff = Date().addingTimeInterval(-Self.idleSessionTimeout)
        for (taskId, last) in lastEventAt where last < cutoff && !waiting.contains(taskId) {
            lastEventAt[taskId] = nil
            state.removeClaudeSession(taskId: taskId)
            nbLog("Session \(taskId.dropFirst(AgentTask.claudeSessionPrefix.count).prefix(8)) removed after 30 min idle")
        }
    }

    // MARK: - Socket server (background thread)

    private func serverThread() {
        let path = Self.socketPath
        try? FileManager.default.removeItem(atPath: path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        serverFD = fd

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cpath = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, c) in cpath.enumerated() where i < raw.count { raw[i] = UInt8(bitPattern: c) }
        }

        let bindRC = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bindRC == 0 else { close(fd); return }
        guard Darwin.listen(fd, 10) == 0 else { close(fd); return }

        while true {
            let clientFD = Darwin.accept(fd, nil, nil)
            guard clientFD >= 0 else { break }
            Thread.detachNewThread { self.handleClient(fd: clientFD) }
        }
    }

    // MARK: - Client handler (background thread)

    private func handleClient(fd: Int32) {
        // Read newline-delimited JSON
        var raw = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        outer: while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            for i in 0..<n {
                if buf[i] == UInt8(ascii: "\n") { break outer }
                raw.append(buf[i])
            }
        }

        guard !raw.isEmpty,
              let payload = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            sendLine(fd: fd, text: #"{"ok":true}"#)
            close(fd)
            return
        }

        let eventName = payload["hook_event_name"] as? String ?? ""

        if eventName == "PermissionRequest" {
            // Hold fd open — Claude Code waits for our decision (up to 120s)
            Task { @MainActor in self.processPermissionRequest(fd: fd, payload: payload) }
        } else if eventName == "StatusLine" {
            // Status line relay: plan usage only, no session involved
            let limits = payload["rate_limits"] as? [String: Any] ?? [:]
            Task { @MainActor in UsageMonitor.shared.ingest(rateLimits: limits) }
            sendLine(fd: fd, text: #"{"ok":true}"#)
            close(fd)
        } else if eventName == "Stop" {
            // Held only when Claude ends on a question and quick replies are on; otherwise answered at once
            Task { @MainActor in self.processStop(fd: fd, payload: payload) }
        } else {
            Task { @MainActor in self.processEvent(name: eventName, payload: payload) }
            sendLine(fd: fd, text: #"{"ok":true}"#)
            close(fd)
        }
    }


    // MARK: - Event → AppState
    // Each session_id has its own pill ("claude:<session_id>"): state, steps, live view and alerts
    // go to that session. View switches only happen if that session is the focused mochi;
    // otherwise its pill animates and shows a badge for alerts.

    @MainActor
    private func processEvent(name: String, payload: [String: Any]) {
        let state = AppState.shared
        let sessionId = payload["session_id"] as? String ?? "unknown"
        let cwd = payload["cwd"] as? String ?? ""
        let rawName = URL(fileURLWithPath: cwd).lastPathComponent
        let projectName = aliasProjectName(rawName.isEmpty ? "Session" : rawName)

        // VS Code, Claude Desktop, terminals and Coucou chat runs; other headless runs (claude -p, SDK scripts) are ignored
        guard let source = ClaudeSource.detect(payload) else {
            nbLog("Ignored \(name) (\(Self.sourceFields(payload)))")
            return
        }

        if name == "SessionEnd" {
            endSession(taskId: AppState.claudeTaskId(sessionId))
            return
        }

        let id = state.upsertClaudeSession(sessionId: sessionId, projectName: projectName, cwd: cwd, source: source)
        lastEventAt[id] = Date()
        let focused = state.focusId == id

        // The session moved on (answered in its own app, or Claude acts again): its question is gone.
        // Other events (Notification right after Stop, subagents…) leave it on screen.
        if ["UserPromptSubmit", "PreToolUse"].contains(name), state.quickReplies[id] != nil {
            resolveQuickReply(taskId: id, reply: nil, reason: name)
        }
        if name == "UserPromptSubmit" { quickReplyChain[id] = 0 }

        // Live session view: diff and terminal output stay in memory, never logged
        if state.liveSessionEnabled {
            let current = state.liveSessions[id] ?? LiveSession()
            let updated = LiveSessionParser.apply(event: name, payload: payload, to: current)
            if updated != current { state.liveSessions[id] = updated }
        }

        switch name {

        case "SessionStart":
            nbLog("SessionStart \(projectName) (\(sessionId.prefix(8))) from \(source.label) (\(Self.sourceFields(payload)))")
            if state.isPresent { expandIfNeeded(to: .overview) }
            SoundEngine.shared.play("work")

        case "UserPromptSubmit":
            state.updateTask(id: id, state: .thinking)
            if let prompt = payload["prompt"] as? String, !prompt.isEmpty {
                appendStep(id: id, step: String(prompt.prefix(60)))
            }
            if state.isPresent { expandIfNeeded(to: .overview) }

        case "PreToolUse":
            state.updateTask(id: id, state: .working)
            let tool = payload["tool_name"] as? String ?? "Tool"
            let input = payload["tool_input"] as? [String: Any] ?? [:]
            appendStep(id: id, step: frenchStep(tool: tool, input: input))
            nbLog("PreToolUse \(tool)")   // tool name only: commands and code never reach the log

        case "PostToolUse":
            if !isWaitingApproval(id) { state.updateTask(id: id, state: .working) }

        case "PostToolUseFailure":
            if !isWaitingApproval(id) { state.updateTask(id: id, state: .working) }
            appendStep(id: id, step: "⚠ failed")

        case "Notification":
            let message = payload["message"] as? String ?? ""
            let lower = message.lowercased()
            if lower.contains("rate limit") || lower.contains("limite d") {
                state.updateTask(id: id, state: .ratelimit)
                SoundEngine.shared.play("rate")
                UsageMonitor.shared.markLimitHit()
                if let resetsAt = UsageMonitor.shared.limitResetsAt {
                    appendStep(id: id, step: "Limit lifts at \(resetsAt.formatted(date: .omitted, time: .shortened))")
                }
            } else if message.hasSuffix("?") {
                state.updateTask(id: id, state: .question)
                appendStep(id: id, step: message)
                if !focused { setPillBadge(id: id, badge: .approval) }
            }

        case "Stop":
            state.updateTask(id: id, state: .finished)
            if let message = payload["message"] as? String, !message.isEmpty {
                appendStep(id: id, step: String(message.prefix(60)))
            }
            SoundEngine.shared.play("finish")
            if focused && state.mode == .expanded && state.view == .liveSession {
                // Stay on the live view: its Done step shows the end of the turn
            } else if focused && state.approvalQueue.isEmpty {
                expandIfNeeded(to: .finished)
            } else {
                setPillBadge(id: id, badge: .finished)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.2) {
                guard state.tasks.first(where: { $0.id == id })?.state == .finished else { return }
                state.updateTask(id: id, state: .idle)
                self.clearPillBadge(id: id)
            }

        case "StopFailure":
            state.updateTask(id: id, state: .error)
            SoundEngine.shared.play("error")
            if focused && state.approvalQueue.isEmpty {
                expandIfNeeded(to: .error)
            } else {
                setPillBadge(id: id, badge: .error)
            }

        case "SubagentStart":
            appendStep(id: id, step: "+ subagent")

        case "SubagentStop":
            appendStep(id: id, step: "• subagent done")

        default:
            break
        }
    }

    /// SessionEnd: the session's pill and live data go away; its unanswered requests go back to Claude Code.
    @MainActor
    private func endSession(taskId: String) {
        let state = AppState.shared
        for request in state.approvalQueue where request.taskId == taskId {
            resolveApproval(request.id, decision: "ask")
        }
        resolveQuickReply(taskId: taskId, reply: nil, reason: "SessionEnd")
        quickReplyChain[taskId] = nil
        lastEventAt[taskId] = nil
        state.removeClaudeSession(taskId: taskId)
    }

    @MainActor
    private func isWaitingApproval(_ taskId: String) -> Bool {
        AppState.shared.approvalQueue.contains { $0.taskId == taskId }
    }

    // MARK: - Helpers

    @MainActor
    private func expandIfNeeded(to view: IslandView) {
        let state = AppState.shared
        let isAlert: Bool
        switch view {
        case .approval, .finished, .error, .confused: isAlert = true
        default: isAlert = false
        }
        if state.mode == .expanded {
            // Only force-switch view for alerts — leave user on their current view otherwise
            if isAlert { state.view = view }
        } else if isAlert {
            // Alerts always force-expand
            NotificationCenter.default.post(name: .hookExpand, object: view)
        } else if state.mode == .hidden {
            // Non-alert work events: reveal compact only, never force-expand
            NotificationCenter.default.post(name: .hookReveal, object: nil)
        }
        // Already compact and non-alert: Mochi state update is enough, no expand
    }

    // MARK: - Quick replies (Stop hook held while Claude's closing question is shown)

    @MainActor
    private func processStop(fd: Int32, payload: [String: Any]) {
        processEvent(name: "Stop", payload: payload)

        let state = AppState.shared
        let taskId = AppState.claudeTaskId(payload["session_id"] as? String ?? "unknown")
        // stop_hook_active = Claude is already continuing because of a Stop hook (e.g. our last reply)
        if payload["stop_hook_active"] as? Bool != true { quickReplyChain[taskId] = 0 }

        guard state.quickRepliesEnabled,
              state.tasks.contains(where: { $0.id == taskId }),
              state.quickReplies[taskId] == nil,
              (quickReplyChain[taskId] ?? 0) < QuickReplySuggester.maxChained,
              let message = payload["last_assistant_message"] as? String,
              let suggestion = QuickReplySuggester.suggest(message) else {
            Task.detached { [weak self] in
                self?.sendLine(fd: fd, text: #"{"ok":true}"#)
                close(fd)
            }
            return
        }

        let prompt = QuickReplyPrompt(taskId: taskId,
                                      question: LiveSessionParser.clean(suggestion.question),
                                      options: suggestion.options.map { LiveSessionParser.clean($0) },
                                      deadline: Date().addingTimeInterval(QuickReplySuggester.waitSeconds))
        quickReplyFDs[prompt.id] = fd
        watchHookClosed(fd: fd, promptId: prompt.id, taskId: taskId)
        state.quickReplies[taskId] = prompt
        if state.focusId == taskId {
            state.isPinned = true   // stays open (no auto-close, no outside-click close) until answered or expired
        } else {
            setPillBadge(id: taskId, badge: .approval)
        }
        nbLog("Quick reply offered (\(taskId.dropFirst(AgentTask.claudeSessionPrefix.count).prefix(8)))")

        DispatchQueue.main.asyncAfter(deadline: .now() + QuickReplySuggester.waitSeconds) { [weak self] in
            guard let self, state.quickReplies[taskId]?.id == prompt.id else { return }
            self.resolveQuickReply(taskId: taskId, reply: nil, reason: "expired")   // no click: Claude stops normally
        }
    }

    /// The held Stop hook can end without us: Claude Code's hook timeout (sessions started before the
    /// hooks were updated keep the old 10 s), or the user interrupting. Then the question can no longer
    /// be answered, so it leaves the notch at once.
    @MainActor
    private func watchHookClosed(fd: Int32, promptId: UUID, taskId: String) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .utility))
        source.setEventHandler { [weak self, weak source] in
            var byte: UInt8 = 0
            let n = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
            guard n == 0 || (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK), let source else { return }
            // Peer closed: stop watching, then (once cancelled, so the fd can be closed) drop the question
            source.setCancelHandler { [weak self] in
                Task { @MainActor in self?.hookClosed(fd: fd, promptId: promptId, taskId: taskId) }
            }
            source.cancel()
        }
        quickReplyWatchers[promptId] = source
        source.resume()
    }

    @MainActor
    private func hookClosed(fd: Int32, promptId: UUID, taskId: String) {
        if AppState.shared.quickReplies[taskId]?.id == promptId {
            quickReplyWatchers[promptId] = nil
            resolveQuickReply(taskId: taskId, reply: nil, reason: "hook ended (Claude Code timeout or interrupt)")
        } else {
            close(fd)   // answered at the same moment: the fd was left for us to close
        }
    }

    /// Called by the quick reply buttons / field. Only an explicit click or Return sends text.
    @MainActor
    func sendQuickReply(taskId: String, text: String) {
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { return }
        resolveQuickReply(taskId: taskId, reply: reply, reason: "sent")
    }

    /// Releases the held Stop hook: with a reply Claude continues with it, without one it stops.
    @MainActor
    private func resolveQuickReply(taskId: String, reply: String?, reason: String) {
        let state = AppState.shared
        guard let prompt = state.quickReplies.removeValue(forKey: taskId) else { return }
        if reply == nil { nbLog("Quick reply closed: \(reason)") }
        // Unpin unless something else still waits on screen (an approval, or the focused session's question)
        if state.approvalQueue.isEmpty && state.quickReplies[state.focusId ?? ""] == nil { state.isPinned = false }

        var json = #"{"ok":true}"#
        if let reply,
           let data = try? JSONSerialization.data(withJSONObject: ["reply": reply]),
           let line = String(data: data, encoding: .utf8) {
            json = line
        }
        if let fd = quickReplyFDs.removeValue(forKey: prompt.id) {
            let line = json
            let answer: @Sendable () -> Void = { [weak self] in
                self?.sendLine(fd: fd, text: line)
                close(fd)
            }
            let watcher = quickReplyWatchers.removeValue(forKey: prompt.id)
            if let watcher, !watcher.isCancelled {
                // The fd may only be closed once its read source is cancelled
                watcher.setCancelHandler(handler: answer)
                watcher.cancel()
            } else if watcher == nil {
                Task.detached(operation: answer)
            }
            // else: the hook just went away; hookClosed() closes the fd
        }

        guard reply != nil else {
            if state.tasks.first(where: { $0.id == taskId })?.pillBadge == .approval { clearPillBadge(id: taskId) }
            return
        }
        quickReplyChain[taskId, default: 0] += 1
        nbLog("Quick reply sent (\(taskId.dropFirst(AgentTask.claudeSessionPrefix.count).prefix(8)))")   // never the text
        state.updateTask(id: taskId, state: .thinking)
        clearPillBadge(id: taskId)
        if state.focusId == taskId && state.view == .finished {
            state.view = state.liveSessionEnabled ? .liveSession : .overview
        }
    }

    // MARK: - Permission requests (blocking — Claude Code waits for the decision)
    // Requests from every session queue up; the approval view shows the oldest one.
    // Each keeps its own socket and its own 115 s timeout.

    @MainActor
    private func processPermissionRequest(fd: Int32, payload: [String: Any]) {
        let state = AppState.shared
        let sessionId = payload["session_id"] as? String ?? "unknown"
        let cwd       = payload["cwd"]        as? String ?? ""
        let rawName   = URL(fileURLWithPath: cwd).lastPathComponent
        let projectName = aliasProjectName(rawName.isEmpty ? "Session" : rawName)

        guard let source = ClaudeSource.detect(payload) else {
            Task.detached { [weak self] in
                self?.sendLine(fd: fd, text: #"{"permissionDecision":"ask"}"#)
                close(fd)
            }
            return
        }

        let tool = payload["tool_name"] as? String ?? "Tool"
        var command = tool
        if let input = payload["tool_input"] as? [String: Any] {
            command = input["command"] as? String ?? tool
        }
        nbLog("PermissionRequest \(tool)")   // tool name only: commands never reach the log

        let id = state.upsertClaudeSession(sessionId: sessionId, projectName: projectName, cwd: cwd, source: source)
        lastEventAt[id] = Date()
        let request = ApprovalInfo(sessionId: sessionId, taskId: id, tool: tool, command: command,
                                   project: projectName, sourceLabel: source.label)
        approvalFDs[request.id] = fd
        state.approvalQueue.append(request)
        state.updateTask(id: id, state: .approval)
        SoundEngine.shared.play("approval")

        if state.approvalQueue.count == 1 {
            showCurrentApproval()
        } else {
            // Waits its turn; the badge says this session needs you too
            setPillBadge(id: id, badge: .approval)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 115) { [weak self] in
            // Unanswered: "ask" → nb-hook outputs nothing → Claude Code asks in its own UI
            guard let self, self.approvalFDs[request.id] != nil else { return }
            self.resolveApproval(request.id, decision: "ask")
        }
    }

    /// Focuses the session of the oldest request and forces the island open on it.
    @MainActor
    private func showCurrentApproval() {
        let state = AppState.shared
        guard let first = state.approvalQueue.first else { return }
        state.isPinned = true
        state.setFocus(first.taskId)
        expandIfNeeded(to: .approval)
    }

    /// Called by ApprovalView buttons: answers the request on screen (the oldest one).
    @MainActor
    func sendApprovalDecision(_ decision: String) {
        guard let first = AppState.shared.approvalQueue.first else { return }
        resolveApproval(first.id, decision: decision)
    }

    /// Writes the decision to that request's nb-hook, then shows the next request or closes the view.
    @MainActor
    private func resolveApproval(_ requestId: UUID, decision: String) {
        let state = AppState.shared
        guard let index = state.approvalQueue.firstIndex(where: { $0.id == requestId }) else { return }
        let request = state.approvalQueue.remove(at: index)

        let json: String
        switch decision {
        case "allow":  json = #"{"permissionDecision":"allow"}"#
        case "always": json = #"{"permissionDecision":"always"}"#
        case "ask":    json = #"{"permissionDecision":"ask"}"#
        default:       json = #"{"permissionDecision":"deny"}"#
        }
        if let fd = approvalFDs.removeValue(forKey: requestId) {
            Task.detached { [weak self] in
                self?.sendLine(fd: fd, text: json)
                close(fd)
            }
        }

        if !isWaitingApproval(request.taskId) {
            state.updateTask(id: request.taskId, state: .working)
            clearPillBadge(id: request.taskId)
        }

        if index == 0, !state.approvalQueue.isEmpty {
            showCurrentApproval()   // next request, possibly from another session
        } else if state.approvalQueue.isEmpty {
            state.isPinned = false
            if state.view == .approval { state.view = state.tasks.isEmpty ? .empty : .overview }
        }
    }

    /// Where the event came from, for the log (no command or code).
    private static func sourceFields(_ payload: [String: Any]) -> String {
        ["entrypoint", "term_program", "bundle_id", "coucou_task"]
            .map { "\($0)=\(payload[$0] as? String ?? "")" }
            .joined(separator: " ")
    }

    // MARK: - Badge helpers

    @MainActor
    private func setPillBadge(id: String, badge: PillBadge) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        state.tasks[idx].pillBadge = badge
    }

    @MainActor
    private func clearPillBadge(id: String) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        state.tasks[idx].pillBadge = nil
    }

    @MainActor
    private func appendStep(id: String, step: String) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        state.tasks[idx].steps.append(step)
        if state.tasks[idx].steps.count > 20 { state.tasks[idx].steps.removeFirst() }
        state.tasks[idx].stepIndex = state.tasks[idx].steps.count - 1
    }

    // MARK: - Project name alias mapping

    private func aliasProjectName(_ name: String) -> String {
        let aliases: [String: String] = [
            "notch-buddy":  "Notch Buddy",
            "notchbuddy":   "Notch Buddy",
            "notch_buddy":  "Notch Buddy",
        ]
        return aliases[name.lowercased()] ?? name
    }

    // MARK: - French step labels

    private func frenchStep(tool: String, input: [String: Any]) -> String {
        let labels: [String: String] = [
            "Bash":       "Exécute",
            "Read":       "Lit",
            "Write":      "Écrit",
            "Edit":       "Modifie",
            "Glob":       "Cherche",
            "Grep":       "Recherche",
            "WebSearch":  "Recherche web",
            "WebFetch":   "Récupère",
            "TodoWrite":  "Tâches",
            "Task":       "Agent",
            "LS":         "Liste",
            "MultiEdit":  "Modifie",
            "NotebookEdit": "Notebook",
        ]
        let label = labels[tool] ?? tool
        if let cmd = input["command"] as? String {
            let short = String(cmd.prefix(40))
            return "\(label) · \(short)"
        } else if let path = input["path"] as? String {
            return "\(label) · \(URL(fileURLWithPath: path).lastPathComponent)"
        } else if let file = input["file_path"] as? String {
            return "\(label) · \(URL(fileURLWithPath: file).lastPathComponent)"
        } else if let query = input["query"] as? String {
            return "\(label) · \(String(query.prefix(40)))"
        }
        return label
    }

    // MARK: - Logging

    private func nbLog(_ message: String) {
        let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/NotchBuddy")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let logFile = logsDir.appendingPathComponent("nb.log")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(formatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logFile.path) {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            try? data.write(to: logFile)
        }
    }

    private func sendLine(fd: Int32, text: String) {
        let bytes = Array((text + "\n").utf8)
        bytes.withUnsafeBytes { buffer in
            // `&bytes[sent]` would point at a one-byte temporary copy, not into the array
            var sent = 0
            while sent < buffer.count {
                let n = Darwin.send(fd, buffer.baseAddress! + sent, buffer.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }
    }

    // MARK: - nb-hook script installation

    func installHookScript() {
        #if APPSTORE
        // In App Store mode the script is written during settings hook installation
        // (requires a security-scoped bookmark to ~/.claude chosen by the user)
        #else
        let dir = Self.supportDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let scriptURL = URL(fileURLWithPath: Self.hookScriptPath)
        try? nbHookScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755 as NSNumber],
            ofItemAtPath: scriptURL.path
        )
        #endif
    }

    // MARK: - Outdated hook detection

    /// Returns true if settings.json has a Coucou hook installed with a timeout shorter than the app needs:
    /// PermissionRequest waits up to 120 s for a click, Stop up to 45 s for a quick reply.
    static func hooksNeedUpdate() -> Bool {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = settings["hooks"] as? [String: Any] else {
            return false
        }
        let required: [String: Int] = ["PermissionRequest": 120, "Stop": 60]
        for (event, minimum) in required {
            for matcher in hooks[event] as? [[String: Any]] ?? [] {
                for hook in matcher["hooks"] as? [[String: Any]] ?? [] {
                    if let cmd = hook["command"] as? String,
                       cmd.contains("NotchBuddy") || cmd.contains("coucou"),
                       let timeout = hook["timeout"] as? Int,
                       timeout < minimum {
                        return true
                    }
                }
            }
        }
        return false
    }

    // MARK: - Claude Code settings.json hook installer

    private var _pendingHooksData: Data?

    /// Returns preview JSON without writing — call writeClaudeHooks() to confirm.
    func previewClaudeHooks() throws -> String {
        let data = try buildHooksData()
        _pendingHooksData = data
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Writes the hooks to disk (call after user confirms preview).
    func writeClaudeHooks() throws {
        guard let data = _pendingHooksData else { return }
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        // Backup first
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let stamp = formatter.string(from: Date())
        let backupURL = settingsURL.deletingLastPathComponent()
            .appendingPathComponent("settings.json.bak-\(stamp)")
        try? FileManager.default.copyItem(at: settingsURL, to: backupURL)
        try? FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        try data.write(to: settingsURL, options: .atomic)
        _pendingHooksData = nil
    }

    private func buildHooksData() throws -> Data {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = parsed
        }
        let hookPath = Self.hookScriptPath
        #if APPSTORE
        // Sandboxed apps create quarantined files; /bin/sh bypasses the quarantine flag
        let quotedCmd = "/bin/sh \"\(hookPath.replacingOccurrences(of: "\"", with: "\\\""))\""
        #else
        let quotedCmd = "\"\(hookPath.replacingOccurrences(of: "\"", with: "\\\""))\""
        #endif
        let events: [(String, Int)] = [
            ("SessionStart", 10), ("SessionEnd", 10),
            ("UserPromptSubmit", 10),
            ("PreToolUse", 10), ("PostToolUse", 10), ("PostToolUseFailure", 10),
            ("PermissionRequest", 120),
            ("Notification", 10),
            ("Stop", 60), ("StopFailure", 10),   // Stop may wait up to 45 s for a quick reply
            ("SubagentStart", 10), ("SubagentStop", 10),
        ]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for (event, timeout) in events {
            var existing = hooks[event] as? [[String: Any]] ?? []
            existing.removeAll { ($0["hooks"] as? [[String: Any]])?.contains { ($0["command"] as? String)?.contains("NotchBuddy") == true || ($0["command"] as? String)?.contains("coucou") == true } ?? false }
            existing.append(["hooks": [["type": "command", "command": quotedCmd, "timeout": timeout]]])
            hooks[event] = existing
        }
        settings["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
    }

    func uninstallClaudeHooks() throws {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: settingsURL),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = settings["hooks"] as? [String: Any] else { return }

        for key in hooks.keys {
            if var matchers = hooks[key] as? [[String: Any]] {
                matchers.removeAll { matcher in
                    (matcher["hooks"] as? [[String: Any]])?.contains {
                        ($0["command"] as? String)?.contains("NotchBuddy") == true ||
                        ($0["command"] as? String)?.contains("coucou") == true
                    } ?? false
                }
                if matchers.isEmpty { hooks.removeValue(forKey: key) }
                else { hooks[key] = matchers }
            }
        }
        settings["hooks"] = hooks
        let newData = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try newData.write(to: settingsURL, options: .atomic)
    }

    // MARK: - App Store: hooks via security-scoped bookmark

    #if APPSTORE
    /// App Store variant — needs a security-scoped bookmark URL pointing to ~/.claude
    func previewClaudeHooksAppStore(claudeURL: URL) throws -> String {
        let accessing = claudeURL.startAccessingSecurityScopedResource()
        defer { if accessing { claudeURL.stopAccessingSecurityScopedResource() } }
        let data = try buildHooksData(claudeURL: claudeURL)
        _pendingHooksData = data
        return String(data: data, encoding: .utf8) ?? ""
    }

    func writeClaudeHooksAppStore(claudeURL: URL) throws {
        guard let data = _pendingHooksData else { return }
        let accessing = claudeURL.startAccessingSecurityScopedResource()
        defer { if accessing { claudeURL.stopAccessingSecurityScopedResource() } }

        // Write the nb-hook script into ~/.claude/coucou/nb-hook
        let coucouDir = claudeURL.appendingPathComponent("coucou")
        try FileManager.default.createDirectory(at: coucouDir, withIntermediateDirectories: true)
        let scriptURL = coucouDir.appendingPathComponent("nb-hook")
        try nbHookScriptAppStore.write(to: scriptURL, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755 as NSNumber], ofItemAtPath: scriptURL.path)

        // Write settings.json (with backup)
        let settingsURL = claudeURL.appendingPathComponent("settings.json")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let backupURL = claudeURL.appendingPathComponent("settings.json.bak-\(formatter.string(from: Date()))")
        try? FileManager.default.copyItem(at: settingsURL, to: backupURL)
        try data.write(to: settingsURL, options: .atomic)
        _pendingHooksData = nil
    }

    func uninstallClaudeHooksAppStore(claudeURL: URL) throws {
        let accessing = claudeURL.startAccessingSecurityScopedResource()
        defer { if accessing { claudeURL.stopAccessingSecurityScopedResource() } }
        let settingsURL = claudeURL.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: settingsURL),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = settings["hooks"] as? [String: Any] else { return }
        for key in hooks.keys {
            if var matchers = hooks[key] as? [[String: Any]] {
                matchers.removeAll { matcher in
                    (matcher["hooks"] as? [[String: Any]])?.contains {
                        ($0["command"] as? String)?.contains("coucou") == true ||
                        ($0["command"] as? String)?.contains("NotchBuddy") == true
                    } ?? false
                }
                if matchers.isEmpty { hooks.removeValue(forKey: key) }
                else { hooks[key] = matchers }
            }
        }
        settings["hooks"] = hooks
        let newData = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try newData.write(to: settingsURL, options: .atomic)
    }

    private func buildHooksData(claudeURL: URL) throws -> Data {
        let settingsURL = claudeURL.appendingPathComponent("settings.json")
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = parsed
        }
        let hookPath = Self.hookScriptPath
        let quotedCmd = "/bin/sh \"\(hookPath.replacingOccurrences(of: "\"", with: "\\\""))\""
        let events: [(String, Int)] = [
            ("SessionStart", 10), ("SessionEnd", 10),
            ("UserPromptSubmit", 10),
            ("PreToolUse", 10), ("PostToolUse", 10), ("PostToolUseFailure", 10),
            ("PermissionRequest", 120),
            ("Notification", 10),
            ("Stop", 60), ("StopFailure", 10),   // Stop may wait up to 45 s for a quick reply
            ("SubagentStart", 10), ("SubagentStop", 10),
        ]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for (event, timeout) in events {
            var existing = hooks[event] as? [[String: Any]] ?? []
            existing.removeAll { ($0["hooks"] as? [[String: Any]])?.contains {
                ($0["command"] as? String)?.contains("coucou") == true ||
                ($0["command"] as? String)?.contains("NotchBuddy") == true
            } ?? false }
            existing.append(["hooks": [["type": "command", "command": quotedCmd, "timeout": timeout]]])
            hooks[event] = existing
        }
        settings["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
    }
    #endif
}

// MARK: - Notification names for hook server → controller communication

extension Notification.Name {
    static let hookExpand = Notification.Name("notchBuddy.hookExpand")
}

// MARK: - nb-hook Python script content

private let nbHookScript = """
#!/usr/bin/env python3
# nb-hook — Coucou hook relay for Claude Code
# Reads JSON from stdin, forwards to Coucou via Unix socket, translates response.
import sys, json, os, socket

def main():
    try:
        raw = sys.stdin.buffer.read()
        if not raw:
            return
        payload = json.loads(raw)
    except Exception:
        return

    # Enrich with terminal context
    env = os.environ
    payload.setdefault('term_program', env.get('TERM_PROGRAM', ''))
    payload.setdefault('iterm_session_id', env.get('ITERM_SESSION_ID', ''))
    payload.setdefault('term_session_id', env.get('TERM_SESSION_ID', ''))
    payload.setdefault('bundle_id', env.get('__CFBundleIdentifier', ''))
    payload.setdefault('entrypoint', env.get('CLAUDE_CODE_ENTRYPOINT', ''))
    payload.setdefault('coucou_task', env.get('COUCOU_TASK', ''))  # run launched from Coucou's chat
    if 'cwd' not in payload or not payload['cwd']:
        payload['cwd'] = os.getcwd()

    event = payload.get('hook_event_name', '')
    socket_path = os.path.expanduser(
        '~/Library/Application Support/NotchBuddy/nb.sock'
    )

    if event == 'PermissionRequest':
        # Block and wait for Coucou's decision (Claude Code allows up to 120s)
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(118)
            s.connect(socket_path)
            s.sendall((json.dumps(payload) + '\\n').encode())
            chunks = []
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                chunks.append(chunk)
                if b'\\n' in chunk:
                    break
            s.close()
            response = b''.join(chunks).decode().strip()
            if response:
                try:
                    resp_obj = json.loads(response)
                    decision = resp_obj.get('permissionDecision', '')
                except Exception:
                    decision = ''
                if decision == 'allow':
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow'}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                elif decision == 'always':
                    # Let Claude Code persist the rule via updatedPermissions
                    suggestions = payload.get('permission_suggestions', [])
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow', 'updatedPermissions': suggestions}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                elif decision == 'deny':
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'deny', 'message': 'Denied from Coucou'}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                # 'ask' or unknown: fall through → no output → Claude Code re-asks
        except Exception:
            pass
        # App unreachable, timed out, or no explicit decision — print nothing
        # Claude Code will handle the absence of output (re-ask or default behaviour)
        sys.exit(0)

    if event == 'Stop':
        # Quick replies: Coucou answers at once unless Claude ended on a question shown in the notch;
        # then it waits for a click (max ~45 s). A reply keeps Claude going; anything else lets it stop.
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(50)
            s.connect(socket_path)
            s.sendall((json.dumps(payload) + '\\n').encode())
            chunks = []
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                chunks.append(chunk)
                if b'\\n' in chunk:
                    break
            s.close()
            resp = json.loads(b''.join(chunks).decode().strip() or '{}')
            reply = resp.get('reply')
            if isinstance(reply, str) and reply.strip():
                out = {'decision': 'block', 'reason': 'The user replied from the Coucou notch: ' + reply}
                sys.stdout.write(json.dumps(out) + '\\n')
                sys.stdout.flush()
        except Exception:
            pass  # Coucou unreachable or no reply: stop normally
        sys.exit(0)

    # All other events: fire-and-forget (0.3s timeout, never blocks)
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(0.3)
        s.connect(socket_path)
        s.sendall((json.dumps(payload) + '\\n').encode())
        s.close()
    except Exception:
        pass  # Always exit cleanly — never block Claude Code

def statusline(encoded):
    # Status line relay: forward the plan usage to Coucou, then run the user's own status line
    # command with the same input so the terminal shows exactly what it showed before.
    raw = sys.stdin.buffer.read()
    try:
        limits = json.loads(raw).get('rate_limits')
        if limits:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(0.3)
            s.connect(os.path.expanduser('~/Library/Application Support/NotchBuddy/nb.sock'))
            s.sendall((json.dumps({'hook_event_name': 'StatusLine', 'rate_limits': limits}) + '\\n').encode())
            s.close()
    except Exception:
        pass  # Coucou closed or slow: the status line must still show
    if encoded:
        try:
            import base64, subprocess
            command = base64.b64decode(encoded).decode()
            sys.exit(subprocess.run(command, shell=True, input=raw).returncode)
        except Exception:
            pass

if len(sys.argv) > 1 and sys.argv[1] == '--statusline':
    statusline(sys.argv[2] if len(sys.argv) > 2 else '')
else:
    main()
sys.exit(0)
"""

// MARK: - nb-hook script for App Store (socket in sandboxed container)

private let nbHookScriptAppStore = """
#!/usr/bin/env python3
# nb-hook — Coucou (App Store) hook relay for Claude Code
# Socket lives inside the sandboxed container; script runs outside the sandbox.
import sys, json, os, socket

def main():
    try:
        raw = sys.stdin.buffer.read()
        if not raw:
            return
        payload = json.loads(raw)
    except Exception:
        return

    env = os.environ
    payload.setdefault('term_program', env.get('TERM_PROGRAM', ''))
    payload.setdefault('iterm_session_id', env.get('ITERM_SESSION_ID', ''))
    payload.setdefault('term_session_id', env.get('TERM_SESSION_ID', ''))
    payload.setdefault('bundle_id', env.get('__CFBundleIdentifier', ''))
    payload.setdefault('entrypoint', env.get('CLAUDE_CODE_ENTRYPOINT', ''))
    payload.setdefault('coucou_task', env.get('COUCOU_TASK', ''))  # run launched from Coucou's chat
    if 'cwd' not in payload or not payload['cwd']:
        payload['cwd'] = os.getcwd()

    event = payload.get('hook_event_name', '')
    socket_path = os.path.expanduser(
        '~/Library/Containers/fr.louisraille.Coucou/Data/Library/Application Support/NotchBuddy/nb.sock'
    )

    if event == 'PermissionRequest':
        # Block and wait for Coucou's decision (Claude Code allows up to 120s)
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(118)
            s.connect(socket_path)
            s.sendall((json.dumps(payload) + '\\n').encode())
            chunks = []
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                chunks.append(chunk)
                if b'\\n' in chunk:
                    break
            s.close()
            response = b''.join(chunks).decode().strip()
            if response:
                try:
                    resp_obj = json.loads(response)
                    decision = resp_obj.get('permissionDecision', '')
                except Exception:
                    decision = ''
                if decision == 'allow':
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow'}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                elif decision == 'always':
                    # Let Claude Code persist the rule via updatedPermissions
                    suggestions = payload.get('permission_suggestions', [])
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow', 'updatedPermissions': suggestions}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                elif decision == 'deny':
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'deny', 'message': 'Denied from Coucou'}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                # 'ask' or unknown: fall through → no output → Claude Code re-asks
        except Exception:
            pass
        # App unreachable, timed out, or no explicit decision — print nothing
        sys.exit(0)

    if event == 'Stop':
        # Quick replies: Coucou answers at once unless Claude ended on a question shown in the notch;
        # then it waits for a click (max ~45 s). A reply keeps Claude going; anything else lets it stop.
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(50)
            s.connect(socket_path)
            s.sendall((json.dumps(payload) + '\\n').encode())
            chunks = []
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                chunks.append(chunk)
                if b'\\n' in chunk:
                    break
            s.close()
            resp = json.loads(b''.join(chunks).decode().strip() or '{}')
            reply = resp.get('reply')
            if isinstance(reply, str) and reply.strip():
                out = {'decision': 'block', 'reason': 'The user replied from the Coucou notch: ' + reply}
                sys.stdout.write(json.dumps(out) + '\\n')
                sys.stdout.flush()
        except Exception:
            pass  # Coucou unreachable or no reply: stop normally
        sys.exit(0)

    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(0.3)
        s.connect(socket_path)
        s.sendall((json.dumps(payload) + '\\n').encode())
        s.close()
    except Exception:
        pass  # Always exit cleanly — never block Claude Code

main()
sys.exit(0)
"""

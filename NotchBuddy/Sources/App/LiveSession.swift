import Foundation

// MARK: - Live Claude Code session (in memory only — never written to disk or logs)

enum LiveStepKind: CaseIterable {
    case read, edit, bash, done

    var label: String {
        switch self {
        case .read: return "Read"
        case .edit: return "Edit"
        case .bash: return "Bash"
        case .done: return "Done"
        }
    }

    /// Maps a Claude Code tool to a step. Tools that don't read, edit or run code have no step.
    static func forTool(_ tool: String) -> LiveStepKind? {
        switch tool {
        case "Read", "Glob", "Grep", "LS":                      return .read
        case "Edit", "MultiEdit", "Write", "NotebookEdit":      return .edit
        case "Bash":                                            return .bash
        default:                                                return nil
        }
    }
}

enum LiveStepStatus: Equatable { case pending, active, done }

struct LiveCodeLine: Identifiable, Equatable {
    enum Kind: Equatable { case context, removed, added, gap }
    let id: Int
    let kind: Kind
    let number: Int?     // line number shown in the gutter (old number for removed lines)
    let text: String
}

struct LiveFile: Equatable {
    var path: String
    var lines: [LiveCodeLine]
    var modified: Bool   // true for edits (dot on the tab), false for a file that was only read
    var truncated: Bool

    /// First removed/added line, to scroll the change into view.
    var firstChangeId: Int? { lines.first { $0.kind == .removed || $0.kind == .added }?.id }
}

struct LiveTerminal: Equatable {
    var command: String
    var output: [String]
    var failed: Bool = false
}

/// One file changed during the turn: every edit's diff is kept, separated by gaps.
struct LiveFileChange: Identifiable, Equatable {
    var id: String { path }
    let path: String
    var added = 0
    var removed = 0
    var isNew = false
    var firstLine: Int? = nil   // first changed line, for "open in VS Code"
    var file: LiveFile
}

/// A Bash command run during the turn. `failed == nil` while it runs.
struct LiveCommand: Identifiable, Equatable {
    let id: Int
    let command: String
    let isTest: Bool
    var failed: Bool? = nil
}

enum LivePanel: Equatable { case file, terminal, answer, summary }

struct LiveSession: Equatable {
    var steps: [LiveStepKind: LiveStepStatus] = [:]
    var file: LiveFile? = nil
    var terminal: LiveTerminal? = nil
    var answer: [String]? = nil          // Claude's final reply for the turn (Stop hook)
    var lastCompleted: LivePanel? = nil  // file or terminal, whichever step finished last
    var cwd: String = ""

    // Turn summary
    var turnStart: Date? = nil
    var turnEnd: Date? = nil
    var changes: [LiveFileChange] = []
    var commands: [LiveCommand] = []

    var totalAdded: Int { changes.reduce(0) { $0 + $1.added } }
    var totalRemoved: Int { changes.reduce(0) { $0 + $1.removed } }
    var duration: TimeInterval? {
        guard let turnStart, let turnEnd else { return nil }
        return max(0, turnEnd.timeIntervalSince(turnStart))
    }
    /// nil: no test command this turn.
    var testsFailed: Bool? {
        let tests = commands.filter { $0.isTest && $0.failed != nil }
        return tests.isEmpty ? nil : tests.contains { $0.failed == true }
    }

    func status(_ kind: LiveStepKind) -> LiveStepStatus { steps[kind] ?? .pending }

    /// Large top panel + small bottom panel.
    /// Working: the last finished result on top, the other one below.
    /// Done: the turn summary (or the only changed file) on top, Claude's answer below.
    var panels: (top: LivePanel?, bottom: LivePanel?) {
        var available: [LivePanel] = []
        if file != nil { available.append(.file) }
        if terminal != nil { available.append(.terminal) }

        if status(.done) == .done {
            let hasAnswer = answer?.isEmpty == false
            if !changes.isEmpty || !commands.isEmpty {
                return (.summary, hasAnswer ? .answer : nil)
            }
            if hasAnswer { return (available.first ?? .answer, available.isEmpty ? nil : .answer) }
        }
        if let last = lastCompleted, available.contains(last) {
            return (last, available.first { $0 != last })
        }
        return (available.first, available.dropFirst().first)
    }
}

// MARK: - Hook payload → LiveSession
//
// Only reads what the hook sends (tool_input / tool_response): never opens files,
// so it works the same inside the App Store sandbox. Every field is optional.

enum LiveSessionParser {
    static let maxCodeLines = 400
    static let maxTerminalLines = 40
    static let maxAnswerLines = 60
    static let maxLineLength = 400
    static let maxChangedFiles = 30
    static let maxCommands = 20

    // MARK: Events

    /// Applies one hook event to the session. Returns the session unchanged for events it doesn't use.
    static func apply(event: String, payload: [String: Any], to session: LiveSession, now: Date = Date()) -> LiveSession {
        var s = session
        if let cwd = payload["cwd"] as? String, !cwd.isEmpty { s.cwd = cwd }
        let tool = payload["tool_name"] as? String ?? ""
        let input = payload["tool_input"] as? [String: Any] ?? [:]

        switch event {
        case "SessionStart", "UserPromptSubmit":
            let cwd = s.cwd
            s = LiveSession()
            s.cwd = cwd
            s.turnStart = now

        case "PreToolUse":
            guard let kind = LiveStepKind.forTool(tool) else { break }
            for (k, v) in s.steps where v == .active && k != kind { s.steps[k] = .done }
            s.steps[kind] = .active
            s.steps[.done] = .pending
            s.answer = nil
            s.turnEnd = nil
            if s.turnStart == nil { s.turnStart = now }
            if kind == .bash {
                let command = clean(input["command"] as? String ?? "")
                s.terminal = LiveTerminal(command: command, output: [])
                if s.commands.count < maxCommands {
                    s.commands.append(LiveCommand(id: s.commands.count, command: command, isTest: isTestCommand(command)))
                }
            }

        case "PostToolUse", "PostToolUseFailure":
            guard let kind = LiveStepKind.forTool(tool) else { break }
            s.steps[kind] = .done
            let response = payload["tool_response"]
            let failed = event == "PostToolUseFailure"
            switch kind {
            case .edit:
                let r = response as? [String: Any] ?? [:]
                if let file = editedFile(response: r, input: input) {
                    s.file = file
                    s.lastCompleted = .file
                    if !failed { record(file, isNew: r["type"] as? String == "create", in: &s) }
                }
            case .read where tool == "Read":
                if let file = readFile(response: response as? [String: Any] ?? [:], input: input) {
                    s.file = file
                    s.lastCompleted = .file
                }
            case .bash:
                var output = terminalOutput(response: response)
                if failed, let error = payload["error"] as? String { output += lines(of: error) }
                s.terminal = LiveTerminal(command: clean(input["command"] as? String ?? s.terminal?.command ?? ""),
                                          output: Array(output.suffix(maxTerminalLines)),
                                          failed: failed)
                s.lastCompleted = .terminal
                let command = s.terminal?.command ?? ""
                if let i = s.commands.lastIndex(where: { $0.failed == nil && $0.command == command })
                    ?? s.commands.lastIndex(where: { $0.failed == nil }) {
                    s.commands[i].failed = failed || bashFailed(response: response)
                }
            default:
                break
            }

        case "Stop":
            for (k, v) in s.steps where v == .active { s.steps[k] = .done }
            s.steps[.done] = .done
            s.turnEnd = now
            // A command whose PostToolUse never came (interrupted): drop its spinner
            for i in s.commands.indices where s.commands[i].failed == nil { s.commands[i].failed = true }
            // Final reply comes with the Stop payload (no transcript read → works in the sandbox)
            let reply = payload["last_assistant_message"] as? String ?? payload["message"] as? String ?? ""
            let replyLines = Array(lines(of: reply).prefix(maxAnswerLines))
            s.answer = replyLines.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ? replyLines : nil

        default:
            break
        }
        return s
    }

    // MARK: Edit / Write / MultiEdit — tool_response.structuredPatch

    static func editedFile(response: [String: Any], input: [String: Any]) -> LiveFile? {
        let path = response["filePath"] as? String
            ?? input["file_path"] as? String
            ?? input["notebook_path"] as? String
            ?? ""
        var out: [LiveCodeLine] = []
        var truncated = false

        func append(_ kind: LiveCodeLine.Kind, _ number: Int?, _ text: String) {
            guard out.count < maxCodeLines else { truncated = true; return }
            out.append(LiveCodeLine(id: out.count, kind: kind, number: number, text: clean(text)))
        }

        let hunks = (response["structuredPatch"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        for (i, hunk) in hunks.enumerated() {
            if i > 0 { append(.gap, nil, "") }
            var oldNo = int(hunk["oldStart"]) ?? 1
            var newNo = int(hunk["newStart"]) ?? oldNo
            for raw in (hunk["lines"] as? [Any] ?? []).compactMap({ $0 as? String }) {
                let marker = raw.first
                let text = raw.isEmpty ? "" : String(raw.dropFirst())
                switch marker {
                case "-":  append(.removed, oldNo, text); oldNo += 1
                case "+":  append(.added, newNo, text); newNo += 1
                case "\\": continue   // "\ No newline at end of file"
                case " ":  append(.context, newNo, text); oldNo += 1; newNo += 1
                default:   append(.context, newNo, raw); oldNo += 1; newNo += 1
                }
            }
        }

        // New file (Write with type "create"): no patch, the whole content is added.
        if hunks.isEmpty, let content = response["content"] as? String ?? input["content"] as? String {
            for (i, line) in lines(of: content).enumerated() { append(.added, i + 1, line) }
        }

        guard !path.isEmpty || !out.isEmpty else { return nil }
        return LiveFile(path: path, lines: out, modified: true, truncated: truncated)
    }

    // MARK: Turn summary

    /// Adds one edit to the per-file totals of the turn.
    static func record(_ file: LiveFile, isNew: Bool, in s: inout LiveSession) {
        guard !file.path.isEmpty else { return }
        let added = file.lines.filter { $0.kind == .added }.count
        let removed = file.lines.filter { $0.kind == .removed }.count
        let first = file.lines.first { $0.kind == .added || $0.kind == .removed }?.number

        if let i = s.changes.firstIndex(where: { $0.path == file.path }) {
            var c = s.changes[i]
            c.added += added
            c.removed += removed
            c.firstLine = [c.firstLine, first].compactMap { $0 }.min()
            // Append this edit's lines after a gap, renumbering ids so they stay unique
            var lines = c.file.lines
            if !lines.isEmpty { lines.append(LiveCodeLine(id: 0, kind: .gap, number: nil, text: "")) }
            lines += file.lines
            let capped = lines.prefix(maxCodeLines).enumerated().map {
                LiveCodeLine(id: $0.offset, kind: $0.element.kind, number: $0.element.number, text: $0.element.text)
            }
            c.file = LiveFile(path: file.path, lines: capped, modified: true,
                              truncated: c.file.truncated || file.truncated || lines.count > maxCodeLines)
            s.changes[i] = c
        } else if s.changes.count < maxChangedFiles {
            s.changes.append(LiveFileChange(path: file.path, added: added, removed: removed,
                                            isNew: isNew, firstLine: first, file: file))
        }
    }

    private static let testWords: Set<String> = ["test", "tests", "jest", "vitest", "pytest", "mocha",
                                                 "rspec", "phpunit", "karma", "cypress", "playwright"]
    /// Commands that merely mention tests (commit messages, searches, file listings).
    private static let notRunners: Set<String> = ["git", "echo", "cat", "grep", "rg", "ls", "find", "head", "tail", "sed"]

    /// Heuristic, any language: `npm test`, `pytest -q`, `go test ./...`, `xcodebuild test`, `swift test`…
    static func isTestCommand(_ command: String) -> Bool {
        let words = command.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard let first = words.first, !notRunners.contains(first) else { return false }
        return words.contains { testWords.contains($0) }
    }

    /// Exit status when the payload has one (the Failure event is the main signal).
    static func bashFailed(response: Any?) -> Bool {
        guard let r = response as? [String: Any] else { return false }
        if r["interrupted"] as? Bool == true { return true }
        for key in ["exit_code", "exitCode", "returnCode", "code"] {
            if let n = int(r[key]) { return n != 0 }
        }
        return false
    }

    // MARK: Read — tool_response.file

    static func readFile(response: [String: Any], input: [String: Any]) -> LiveFile? {
        let file = response["file"] as? [String: Any] ?? [:]
        let path = file["filePath"] as? String ?? input["file_path"] as? String ?? ""
        guard let content = file["content"] as? String else {
            return path.isEmpty ? nil : LiveFile(path: path, lines: [], modified: false, truncated: false)
        }
        let start = int(file["startLine"]) ?? int(input["offset"]) ?? 1
        let all = lines(of: content)
        let shown = all.prefix(maxCodeLines).enumerated().map {
            LiveCodeLine(id: $0.offset, kind: .context, number: start + $0.offset, text: clean($0.element))
        }
        return LiveFile(path: path, lines: shown, modified: false, truncated: all.count > maxCodeLines)
    }

    // MARK: Bash — tool_response.stdout / stderr

    static func terminalOutput(response: Any?) -> [String] {
        if let text = response as? String { return lines(of: text) }
        guard let r = response as? [String: Any] else { return [] }
        var out: [String] = []
        if let stdout = r["stdout"] as? String { out += lines(of: stdout) }
        if let stderr = r["stderr"] as? String { out += lines(of: stderr) }
        while out.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { out.removeLast() }
        return out
    }

    // MARK: Helpers

    private static let ansi = try? NSRegularExpression(pattern: "\u{1B}(\\[[0-9;?]*[ -/]*[@-~]|\\][^\u{07}]*\u{07}|.)")

    /// Strips ANSI escapes and control characters, expands tabs, caps the length.
    static func clean(_ text: String) -> String {
        var t = text
        if let ansi, t.contains("\u{1B}") {
            t = ansi.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
        }
        t = t.replacingOccurrences(of: "\t", with: "    ")
        t = String(t.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }.map(Character.init))
        return t.count > maxLineLength ? String(t.prefix(maxLineLength)) + "…" : t
    }

    static func lines(of text: String) -> [String] {
        var parts = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        return parts.map(clean)
    }

    private static func int(_ value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }
}

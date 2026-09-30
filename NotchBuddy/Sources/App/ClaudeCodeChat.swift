import Foundation
import AppKit

// MARK: - Claude Code runs from the chat tab
//
// In "Claude Code" mode a message runs `claude -p` in the chosen project, on the user's own
// Claude Code install and subscription (no API key). The hooks show the run as a normal session
// (pill, live view, approvals in the notch, quick replies); the chat shows its steps and final answer.
// The next message continues the same conversation with --resume.

struct RecentProject: Identifiable, Hashable {
    let path: String
    let lastUsed: Date
    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

enum RecentProjects {
    /// Folders Claude Code ran in, newest first, read from the transcripts in ~/.claude/projects.
    /// Worktrees, the home folder and folders that no longer exist are skipped.
    static func load(limit: Int = 10) -> [RecentProject] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent(".claude/projects")
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }

        var byPath: [String: Date] = [:]
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            let newest = files
                .filter { $0.pathExtension == "jsonl" }
                .compactMap { url -> (URL, Date)? in
                    guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
                    return (url, date)
                }
                .max { $0.1 < $1.1 }
            guard let (file, date) = newest, let cwd = firstCwd(in: file) else { continue }
            guard cwd != home.path, !cwd.contains("/.claude/worktrees/"),
                  fm.fileExists(atPath: cwd) else { continue }
            if (byPath[cwd] ?? .distantPast) < date { byPath[cwd] = date }
        }
        return byPath
            .map { RecentProject(path: $0.key, lastUsed: $0.value) }
            .sorted { $0.lastUsed > $1.lastUsed }
            .prefix(limit)
            .map { $0 }
    }

    /// The `"cwd":"…"` field of the first lines of a transcript.
    private static func firstCwd(in file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024),
              let text = String(data: data, encoding: .utf8) ?? String(data: data.prefix(32 * 1024), encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: #""cwd":("(?:[^"\\]|\\.)*")"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        // Decode the JSON string (escaped slashes, unicode)
        return try? JSONDecoder().decode(String.self, from: Data(text[range].utf8))
    }
}

@MainActor
final class ClaudeCodeRunner {
    static let shared = ClaudeCodeRunner()

    private var process: Process?
    private var stdoutBuffer = Data()
    private var stderrTail = ""
    private var gotResult = false
    private var stopped = false

    /// The `claude` command: usual install places, then the login shell's PATH.
    nonisolated static func claudeBinary() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return found }

        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe()
        shell.standardOutput = pipe
        shell.standardError = FileHandle.nullDevice
        guard (try? shell.run()) != nil else { return nil }
        shell.waitUntilExit()
        let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.hasPrefix("/") ? path : nil
    }

    // MARK: Run

    func send(_ prompt: String, state: AppState) {
        guard !state.codeRunning, let project = state.codeProject else { return }
        state.codeChat.append(ChatMessage(role: .user, content: prompt))
        state.codeRunning = true
        state.stateOverride = .thinking

        let resume = state.codeSessionId
        Task.detached {
            guard let binary = Self.claudeBinary() else {
                await MainActor.run {
                    self.finish(state: state, error: "Claude Code isn't installed (the `claude` command wasn't found).")
                }
                return
            }
            await MainActor.run { self.launch(binary: binary, prompt: prompt, project: project, resume: resume, state: state) }
        }
    }

    private func launch(binary: String, prompt: String, project: String, resume: String?, state: AppState) {
        var args = ["-p", prompt, "--output-format", "stream-json", "--verbose"]
        if let resume { args += ["--resume", resume] }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: project)
        p.environment = Self.environment()
        p.standardInput = FileHandle.nullDevice

        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        stdoutBuffer = Data()
        stderrTail = ""
        gotResult = false
        stopped = false

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            Task { @MainActor in self?.receive(data, state: state) }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                guard let self else { return }
                self.stderrTail = String((self.stderrTail + text).suffix(600))
            }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor in
                // Let the last stdout lines land first
                try? await Task.sleep(for: .milliseconds(150))
                self?.terminated(status: status, state: state)
            }
        }

        do {
            try p.run()
            process = p
        } catch {
            finish(state: state, error: "Couldn't start Claude Code: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard let process, process.isRunning else { return }
        stopped = true
        process.terminate()
    }

    /// The app's environment, plus the usual bin folders (an app launched from Finder gets a short PATH).
    /// COUCOU_TASK makes nb-hook tag the run so Coucou shows it as a session.
    nonisolated private static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") { env[key] = nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        env["COUCOU_TASK"] = "1"
        return env
    }

    // MARK: Output (stream-json, one event per line)

    private func receive(_ data: Data, state: AppState) {
        stdoutBuffer.append(data)
        while let newline = stdoutBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = stdoutBuffer[stdoutBuffer.startIndex..<newline]
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newline)
            guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(event, state: state)
        }
    }

    private func handle(_ event: [String: Any], state: AppState) {
        if let id = event["session_id"] as? String, !id.isEmpty, state.codeSessionId != id {
            state.codeSessionId = id
        }
        switch event["type"] as? String {
        case "assistant":
            let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for block in content where block["type"] as? String == "tool_use" {
                let name = block["name"] as? String ?? "Tool"
                let input = block["input"] as? [String: Any] ?? [:]
                state.codeChat.append(ChatMessage(role: .step, content: Self.describe(tool: name, input: input)))
            }
        case "result":
            gotResult = true
            let text = (event["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if event["is_error"] as? Bool == true {
                finish(state: state, error: text.isEmpty ? "Claude Code stopped with an error." : text)
            } else {
                finish(state: state, answer: text.isEmpty ? "Done." : text)
            }
        default:
            break
        }
    }

    private func terminated(status: Int32, state: AppState) {
        process = nil
        guard !gotResult else { return }
        if stopped {
            finish(state: state, error: "Stopped.")
        } else {
            let detail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
            finish(state: state, error: detail.isEmpty ? "Claude Code ended without an answer (code \(status))." : detail)
        }
    }

    private func finish(state: AppState, answer: String? = nil, error: String? = nil) {
        if let answer { state.codeChat.append(ChatMessage(role: .assistant, content: answer)) }
        if let error { state.codeChat.append(ChatMessage(role: .error, content: error)) }
        state.codeRunning = false
        if state.stateOverride == .thinking { state.stateOverride = nil }
        ChatStore.save(state)
        NotificationCenter.default.post(name: .triggerEmote, object: error == nil ? BotEmote.happy : BotEmote.annoyed)
    }

    /// One short line per tool. Shell commands are never shown or saved, only their description.
    static func describe(tool: String, input: [String: Any]) -> String {
        func file(_ key: String) -> String? {
            (input[key] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
        }
        switch tool {
        case "Read", "Edit", "MultiEdit", "Write", "NotebookEdit":
            return [tool, file("file_path") ?? file("notebook_path")].compactMap { $0 }.joined(separator: " ")
        case "Bash":
            let description = (input["description"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            return description.isEmpty ? "Run a command" : description
        case "Grep", "Glob":
            return [tool, input["pattern"] as? String].compactMap { $0 }.joined(separator: " ")
        case "WebSearch":
            return [tool, input["query"] as? String].compactMap { $0 }.joined(separator: " ")
        case "WebFetch":
            return [tool, (input["url"] as? String).flatMap { URL(string: $0)?.host }].compactMap { $0 }.joined(separator: " ")
        case "Task", "Agent":
            return [tool, input["description"] as? String].compactMap { $0 }.joined(separator: " · ")
        default:
            return tool
        }
    }

    // MARK: Continue in Terminal

    /// Opens Terminal on `claude --resume <id>` in the project, through a .command file
    /// (no Apple Events permission needed).
    static func openInTerminal(sessionId: String, cwd: String) {
        guard !sessionId.isEmpty,
              sessionId.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return }
        let quoted = "'" + cwd.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = "#!/bin/zsh -l\ncd \(quoted) && exec claude --resume \(sessionId)\n"
        let url = HookServer.supportDir.appendingPathComponent("resume-session.command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700 as NSNumber], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch {
            return
        }
    }
}

// MARK: - Chat persistence
// Both conversations are kept between launches in Application Support (not secrets; shell
// commands are never part of them).

enum ChatStore {
    private struct Saved: Codable {
        var question: [ChatMessage]
        var code: [ChatMessage]
        var codeSessionId: String?
    }

    private static var url: URL { HookServer.supportDir.appendingPathComponent("chat.json") }
    private static let maxMessages = 200

    @MainActor
    static func save(_ state: AppState) {
        let saved = Saved(question: Array(state.chatHistory.suffix(maxMessages)),
                          code: Array(state.codeChat.suffix(maxMessages)),
                          codeSessionId: state.codeSessionId)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? FileManager.default.createDirectory(at: HookServer.supportDir, withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    @MainActor
    static func load(into state: AppState) {
        guard let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        state.chatHistory = saved.question
        state.codeChat = saved.code
        state.codeSessionId = saved.codeSessionId
    }
}

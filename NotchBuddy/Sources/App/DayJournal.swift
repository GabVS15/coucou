import Foundation
import SwiftUI

// MARK: - Day journal
// Counters only, one small JSON file per day in Application Support/NotchBuddy/journal/, kept 30 days.
// No prompts, commands, file names or diffs: like the live view, content never reaches the disk.

struct ProjectDay: Codable, Equatable {
    var sessions: [String] = []   // first 8 characters of each session id, to count sessions once
    var turns = 0                 // prompts sent
    var edits = 0                 // Edit / Write / MultiEdit / NotebookEdit
    var commands = 0              // Bash
    var failures = 0              // failed tool calls
    var events = 0                // everything, to find the day's main project
}

struct DayLog: Codable, Equatable {
    var day: String
    var projects: [String: ProjectDay] = [:]
    var activeSeconds: Double = 0   // time Claude Code was busy anywhere (gaps over 5 min don't count)
    var approvals = 0               // permission requests answered from the notch
    var peakUsage: Double? = nil    // highest 5-hour usage seen, in %
    var prsMerged = 0
    var ciFailures = 0
    var n8nErrors = 0

    var hasClaudeActivity: Bool { projects.values.contains { $0.events > 0 } }
}

@MainActor
final class DayJournal {
    static let shared = DayJournal()

    private static let keepDays = 30
    private static let activeGap: TimeInterval = 5 * 60
    private static let editTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    private(set) var today: DayLog
    private var lastActivity: Date?
    private var saveWork: DispatchWorkItem?
    private var recapTimer: Timer?

    private static var journalDir: URL { HookServer.supportDir.appendingPathComponent("journal") }

    static func dayKey(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private init() {
        let key = Self.dayKey()
        today = Self.load(key) ?? DayLog(day: key)
    }

    func start() {
        pruneOldFiles()
        scheduleRecap()
    }

    // MARK: - Recording

    /// A Claude Code hook event from a real session (headless runs are filtered out before this).
    func record(event: String, sessionId: String, project: String, tool: String?) {
        rollOverIfNeeded()
        var p = today.projects[project] ?? ProjectDay()
        let short = String(sessionId.prefix(8))
        if !p.sessions.contains(short) { p.sessions.append(short) }
        p.events += 1
        switch event {
        case "UserPromptSubmit": p.turns += 1
        case "PreToolUse":
            if let tool, Self.editTools.contains(tool) { p.edits += 1 }
            if tool == "Bash" { p.commands += 1 }
        case "PostToolUseFailure": p.failures += 1
        default: break
        }
        today.projects[project] = p

        let now = Date()
        if let last = lastActivity, now.timeIntervalSince(last) < Self.activeGap {
            today.activeSeconds += now.timeIntervalSince(last)
        }
        lastActivity = now
        scheduleSave()
    }

    func recordApproval() { update { $0.approvals += 1 } }
    func recordUsage(_ pct: Double) {
        guard pct > (today.peakUsage ?? -1) else { return }
        update { $0.peakUsage = pct }
    }
    func recordGitHub(merged: Int, ciFailed: Int) {
        guard merged + ciFailed > 0 else { return }
        update { $0.prsMerged += merged; $0.ciFailures += ciFailed }
    }
    func recordN8nError() { update { $0.n8nErrors += 1 } }

    private func update(_ change: (inout DayLog) -> Void) {
        rollOverIfNeeded()
        change(&today)
        scheduleSave()
    }

    private func rollOverIfNeeded() {
        let key = Self.dayKey()
        guard today.day != key else { return }
        flush()
        today = DayLog(day: key)
        lastActivity = nil
    }

    // MARK: - Files

    private static func fileURL(_ key: String) -> URL { journalDir.appendingPathComponent("\(key).json") }

    private static func load(_ key: String) -> DayLog? {
        guard let data = try? Data(contentsOf: fileURL(key)) else { return nil }
        return try? JSONDecoder().decode(DayLog.self, from: data)
    }

    /// Events come in bursts: write at most every 10 s.
    private func scheduleSave() {
        guard saveWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    func flush() {
        saveWork?.cancel()
        saveWork = nil
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.journalDir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(today) else { return }
        try? data.write(to: Self.fileURL(today.day), options: .atomic)
    }

    private func pruneOldFiles() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Self.journalDir, includingPropertiesForKeys: nil) else { return }
        let cutoff = Self.dayKey(Date().addingTimeInterval(-Double(Self.keepDays) * 86_400))
        for file in files where file.pathExtension == "json" && file.deletingPathExtension().lastPathComponent < cutoff {
            try? fm.removeItem(at: file)
        }
    }

    // MARK: - Evening recap

    /// Next recap time; one timer, nothing ticking in between.
    func scheduleRecap() {
        recapTimer?.invalidate()
        recapTimer = nil
        let state = AppState.shared
        guard state.recapEnabled else { return }
        let cal = Calendar.current
        let now = Date()
        var fire = cal.date(bySettingHour: state.recapHour, minute: 0, second: 0, of: now) ?? now
        if fire <= now {
            // Past the hour: today's recap still shows if it hasn't yet (app launched late), else tomorrow's
            fire = UserDefaults.standard.string(forKey: "recapShownDay") == Self.dayKey()
                ? cal.date(byAdding: .day, value: 1, to: fire) ?? fire
                : now.addingTimeInterval(60)
        }
        armRecapTimer(at: fire)
    }

    private func armRecapTimer(at date: Date) {
        recapTimer?.invalidate()
        let timer = Timer(fire: date, interval: 0, repeats: false) { _ in
            Task { @MainActor in DayJournal.shared.recapDue() }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        recapTimer = timer
    }

    private func recapDue() {
        let state = AppState.shared
        let key = Self.dayKey()
        guard state.recapEnabled, UserDefaults.standard.string(forKey: "recapShownDay") != key else {
            scheduleRecap(); return
        }
        let recap = DayRecap(log: today, state: state)
        guard recap.hasContent else { scheduleRecap(); return }
        // Away, or busy with an alert: try again in 5 minutes (until midnight)
        let busy = state.mode == .expanded && ([.approval, .question, .error, .mail, .prompt] as [IslandView]).contains(state.view)
        if !state.isPresent || busy {
            let retry = Date().addingTimeInterval(5 * 60)
            if Self.dayKey(retry) == key { armRecapTimer(at: retry) } else { scheduleRecap() }
            return
        }
        UserDefaults.standard.set(key, forKey: "recapShownDay")
        showRecap()
        scheduleRecap()
    }

    /// Opens the recap view (evening timer, menu bar, Debug).
    func showRecap() {
        flush()
        NotificationCenter.default.post(name: .hookExpand, object: IslandView.recap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.yawn)
        }
    }
}

// MARK: - Recap content (journal + what the integrations already hold in memory)

struct RecapTile: Identifiable, Equatable {
    let id: String
    let value: String
    let label: String
    let color: String
}

@MainActor
struct DayRecap {
    let tiles: [RecapTile]
    let subtitle: String
    let hasContent: Bool

    init(log: DayLog, state: AppState) {
        let cal = Calendar.current
        var tiles: [RecapTile] = []
        let projects = log.projects.filter { $0.value.events > 0 }

        if !projects.isEmpty {
            let sessions = projects.values.reduce(0) { $0 + $1.sessions.count }
            tiles.append(RecapTile(id: "active", value: Self.duration(log.activeSeconds),
                                   label: "Claude busy · \(sessions) session\(sessions == 1 ? "" : "s")",
                                   color: "#3B9EFF"))
            let edits = projects.values.reduce(0) { $0 + $1.edits }
            let commands = projects.values.reduce(0) { $0 + $1.commands }
            let turns = projects.values.reduce(0) { $0 + $1.turns }
            tiles.append(RecapTile(id: "edits", value: "\(edits)",
                                   label: "edits · \(commands) cmd · \(turns) prompts", color: "#A78BFA"))
        }
        if log.prsMerged > 0 || log.ciFailures > 0 {
            tiles.append(RecapTile(id: "github", value: "\(log.prsMerged)",
                                   label: "PR\(log.prsMerged == 1 ? "" : "s") merged" + (log.ciFailures > 0 ? " · \(log.ciFailures) CI failed" : ""),
                                   color: "#F4505E"))
        }
        let sales = state.stripePayments.filter { $0.isSuccess && cal.isDateInToday($0.createdAt) }
        if !sales.isEmpty {
            let total = Double(sales.reduce(0) { $0 + $1.amount }) / 100
            let value = total.formatted(.currency(code: sales[0].currency.uppercased()).precision(.fractionLength(0)))
            tiles.append(RecapTile(id: "stripe", value: value,
                                   label: "\(sales.count) sale\(sales.count == 1 ? "" : "s") today", color: "#34D399"))
        }
        let deploys = state.vercelDeployments.filter { cal.isDateInToday($0.createdAt) }
        if !deploys.isEmpty {
            let failed = deploys.filter { $0.state == "ERROR" }.count
            tiles.append(RecapTile(id: "vercel", value: "\(deploys.count)",
                                   label: "deploy\(deploys.count == 1 ? "" : "s")" + (failed > 0 ? " · \(failed) failed" : ""),
                                   color: "#7C5CFF"))
        }
        let emails = state.resendEmails.filter { cal.isDateInToday($0.createdAt) }
        if !emails.isEmpty {
            tiles.append(RecapTile(id: "resend", value: "\(emails.count)",
                                   label: "email\(emails.count == 1 ? "" : "s") sent", color: "#22C55E"))
        }
        if log.n8nErrors > 0 {
            tiles.append(RecapTile(id: "n8n", value: "\(log.n8nErrors)",
                                   label: "n8n error\(log.n8nErrors == 1 ? "" : "s")", color: "#F29B38"))
        }
        let hasToday = !tiles.isEmpty
        if state.calcomLoaded {
            let tomorrow = state.calcomBookings
                .filter { $0.isActive && cal.isDateInTomorrow($0.startTime) }
                .sorted { $0.startTime < $1.startTime }
            if let first = tomorrow.first {
                tiles.append(RecapTile(id: "calcom", value: "\(tomorrow.count)",
                                       label: "tomorrow · first \(first.timeLabel)", color: "#C9956A"))
            }
        }

        self.tiles = Array(tiles.prefix(4))
        self.hasContent = hasToday

        var parts: [String] = []
        if let main = projects.max(by: { $0.value.events < $1.value.events }) {
            parts.append(projects.count == 1 ? "All on \(main.key)" : "Mostly \(main.key) · \(projects.count) projects")
        }
        if let peak = log.peakUsage { parts.append("5h peak \(Int(peak.rounded()))%") }
        if log.approvals > 0 { parts.append("\(log.approvals) approval\(log.approvals == 1 ? "" : "s") from the notch") }
        self.subtitle = parts.joined(separator: " · ")
    }

    /// "2h10", "45 min", "< 1 min".
    static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "< 1 min" }
        if minutes < 60 { return "\(minutes) min" }
        return String(format: "%dh%02d", minutes / 60, minutes % 60)
    }

    /// Plain text for the Copy button.
    var text: String {
        var lines = ["Today — \(Date().formatted(date: .complete, time: .omitted))"]
        if !subtitle.isEmpty { lines.append(subtitle) }
        lines += tiles.map { "• \($0.value) \($0.label)" }
        return lines.joined(separator: "\n")
    }
}

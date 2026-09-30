import Foundation

// MARK: - Claude Code plan usage (5-hour and 7-day windows)
// Claude Code only exposes rate limits to its status line command (Pro/Max plans). nb-hook, installed
// as the status line in front of the user's own one, forwards `rate_limits` here and then runs
// the original command, so the terminal status line stays the same.

struct UsageWindow: Codable, Equatable {
    var usedPercentage: Double
    var resetsAt: Date
}

struct UsageLimits: Codable, Equatable {
    var fiveHour: UsageWindow?
    var sevenDay: UsageWindow?
    var updatedAt: Date

    /// Windows whose reset time has passed no longer mean anything.
    func current(now: Date = Date()) -> UsageLimits? {
        var copy = self
        if let w = copy.fiveHour, w.resetsAt <= now { copy.fiveHour = nil }
        if let w = copy.sevenDay, w.resetsAt <= now { copy.sevenDay = nil }
        return copy.fiveHour == nil && copy.sevenDay == nil ? nil : copy
    }

    /// The window closest to its limit: the one the gauge shows.
    var tightest: (label: String, window: UsageWindow)? {
        let candidates = [("5h", fiveHour), ("7d", sevenDay)].compactMap { label, w in w.map { (label, $0) } }
        return candidates.max { $0.1.usedPercentage < $1.1.usedPercentage }.map { (label: $0.0, window: $0.1) }
    }
}

@MainActor
final class UsageMonitor {
    static let shared = UsageMonitor()

    /// A window reset only gets a notch message if it was nearly used up (or Claude Code hit the limit).
    private static let resetNoticeThreshold: Double = 90

    private var resetTimer: Timer?
    private var limitHit = false
    /// Last status line update, even when the numbers didn't move (not published: no redraw every 5 s).
    private(set) var lastSeen: Date?

    private init() {}

    /// Restores the last known usage, so the gauge is right after a relaunch.
    func start() {
        if let data = UserDefaults.standard.data(forKey: "usageLimits"),
           let saved = try? JSONDecoder().decode(UsageLimits.self, from: data) {
            AppState.shared.usage = saved.current()
            lastSeen = saved.updatedAt
        }
        scheduleResetTimer()
    }

    /// `rate_limits` object from Claude Code's status line JSON.
    func ingest(rateLimits: [String: Any]) {
        func window(_ key: String) -> UsageWindow? {
            guard let w = rateLimits[key] as? [String: Any],
                  let pct = (w["used_percentage"] as? NSNumber)?.doubleValue,
                  let reset = (w["resets_at"] as? NSNumber)?.doubleValue else { return nil }
            return UsageWindow(usedPercentage: pct, resetsAt: Date(timeIntervalSince1970: reset))
        }
        let limits = UsageLimits(fiveHour: window("five_hour"), sevenDay: window("seven_day"), updatedAt: Date())
        guard let current = limits.current() else { return }

        lastSeen = current.updatedAt
        if let pct = current.fiveHour?.usedPercentage { DayJournal.shared.recordUsage(pct) }
        let state = AppState.shared
        // Same numbers every few seconds while a session is open: only publish and save real changes
        guard state.usage?.fiveHour != current.fiveHour || state.usage?.sevenDay != current.sevenDay else { return }
        state.usage = current
        save(current)
        scheduleResetTimer()
    }

    private func save(_ usage: UsageLimits?) {
        if let usage, let data = try? JSONEncoder().encode(usage) {
            UserDefaults.standard.set(data, forKey: "usageLimits")
        } else {
            UserDefaults.standard.removeObject(forKey: "usageLimits")
        }
    }

    /// Claude Code said the usage limit was reached (Notification hook).
    func markLimitHit() {
        limitHit = true
    }

    /// When the limit resets, if the user had hit it.
    var limitResetsAt: Date? {
        guard let usage = AppState.shared.usage else { return nil }
        let full = [usage.fiveHour, usage.sevenDay].compactMap { $0 }.filter { $0.usedPercentage >= 100 }
        if let latest = full.map(\.resetsAt).max() { return latest }
        return limitHit ? usage.fiveHour?.resetsAt : nil
    }

    // MARK: - Reset

    private func scheduleResetTimer() {
        resetTimer?.invalidate()
        resetTimer = nil
        guard let usage = AppState.shared.usage,
              let next = [usage.fiveHour, usage.sevenDay].compactMap({ $0?.resetsAt }).min() else { return }
        // One timer, nothing ticking in between: the island stays at 0 % CPU when hidden
        let timer = Timer(fire: next.addingTimeInterval(1), interval: 0, repeats: false) { _ in
            Task { @MainActor in UsageMonitor.shared.windowReset() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        resetTimer = timer
    }

    private func windowReset() {
        let state = AppState.shared
        guard let previous = state.usage else { return }
        let now = Date()
        let expired = [("5-hour", previous.fiveHour), ("weekly", previous.sevenDay)]
            .compactMap { label, w in w.flatMap { $0.resetsAt <= now ? (label, $0) : nil } }

        state.usage = previous.current(now: now)
        save(state.usage)
        scheduleResetTimer()

        guard let tightest = expired.max(by: { $0.1.usedPercentage < $1.1.usedPercentage }),
              limitHit || tightest.1.usedPercentage >= Self.resetNoticeThreshold else { return }
        let label = tightest.0
        limitHit = false

        for task in state.tasks where task.state == .ratelimit {
            state.updateTask(id: task.id, state: .idle)
        }
        state.noteMessage = "Your \(label) limit just reset. Back to work!"
        SoundEngine.shared.play("approve")
        NotificationCenter.default.post(name: .hookExpand, object: IslandView.note)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            guard state.mode == .expanded, state.view == .note else { return }
            NotificationCenter.default.post(name: .islandCollapse, object: nil)
        }
    }
}

// MARK: - Status line relay in ~/.claude/settings.json
// statusLine.command becomes `"<nb-hook>" --statusline <base64 of the previous command>`. Base64 keeps
// the previous command intact through the shell and lets uninstall put it back exactly.

#if !APPSTORE
enum StatusLineRelay {
    private static let flag = "--statusline"

    private static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    private static func readSettings() -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return parsed
    }

    private static func isRelay(_ command: String?) -> Bool {
        guard let command else { return false }
        return command.contains(flag) && (command.contains("NotchBuddy") || command.contains("coucou"))
    }

    static var isInstalled: Bool {
        isRelay((readSettings()["statusLine"] as? [String: Any])?["command"] as? String)
    }

    /// The statusLine block before and after, for the user to check before anything is written.
    static func preview() -> (before: String, after: String) {
        let current = readSettings()["statusLine"] as? [String: Any]
        return (describe(current), describe(wrapped(current)))
    }

    static func install() throws {
        var settings = readSettings()
        settings["statusLine"] = wrapped(settings["statusLine"] as? [String: Any])
        try write(settings)
    }

    static func uninstall() throws {
        var settings = readSettings()
        guard var line = settings["statusLine"] as? [String: Any],
              let command = line["command"] as? String, isRelay(command) else { return }
        if let original = originalCommand(of: command) {
            line["command"] = original
            settings["statusLine"] = line
        } else {
            settings.removeValue(forKey: "statusLine")   // Coucou added the status line itself
        }
        try write(settings)
    }

    private static func wrapped(_ current: [String: Any]?) -> [String: Any] {
        var line = current ?? ["type": "command"]
        let existing = line["command"] as? String
        if isRelay(existing) { return line }
        let hook = "\"\(HookServer.hookScriptPath.replacingOccurrences(of: "\"", with: "\\\""))\""
        var command = "\(hook) \(flag)"
        if let existing, !existing.isEmpty {
            command += " " + Data(existing.utf8).base64EncodedString()
        }
        line["command"] = command
        if line["type"] == nil { line["type"] = "command" }
        return line
    }

    private static func originalCommand(of relay: String) -> String? {
        guard let range = relay.range(of: flag) else { return nil }
        let encoded = relay[range.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !encoded.isEmpty, let data = Data(base64Encoded: encoded) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func describe(_ line: [String: Any]?) -> String {
        guard let line,
              let data = try? JSONSerialization.data(withJSONObject: ["statusLine": line],
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "(no status line)" }
        return text
    }

    /// Dated backup, then write. Only the statusLine key differs from what was read.
    private static func write(_ settings: [String: Any]) throws {
        let fm = FileManager.default
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let backup = settingsURL.deletingLastPathComponent()
            .appendingPathComponent("settings.json.bak-\(formatter.string(from: Date()))")
        if fm.fileExists(atPath: settingsURL.path), !fm.fileExists(atPath: backup.path) {
            try fm.copyItem(at: settingsURL, to: backup)
        }
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsURL, options: .atomic)
    }
}
#endif

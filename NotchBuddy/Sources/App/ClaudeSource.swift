import AppKit

// MARK: - Where a Claude Code session runs (VS Code, Claude Desktop, a terminal)

enum ClaudeSource: Equatable {
    case vscode
    case desktop
    case terminal(name: String, bundleId: String?)
    case coucou(sessionId: String)   // launched from Coucou's chat tab (`claude -p`)

    static let desktopBundleId = "com.anthropic.claudefordesktop"

    private static let vscodeBundleIds = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium.codium"]

    /// Known terminal apps: bundle id → display name. Any other terminal still works, shown as "Terminal".
    private static let terminals: [String: String] = [
        "com.apple.Terminal":       "Terminal",
        "com.googlecode.iterm2":    "iTerm",
        "com.mitchellh.ghostty":    "Ghostty",
        "dev.warp.Warp-Stable":     "Warp",
        "net.kovidgoyal.kitty":     "kitty",
        "com.github.wez.wezterm":   "WezTerm",
        "org.alacritty":            "Alacritty",
        "co.zeit.hyper":            "Hyper",
    ]

    private static let termPrograms: [String: String] = [
        "apple_terminal": "Terminal", "iterm.app": "iTerm", "ghostty": "Ghostty",
        "warpterminal": "Warp", "wezterm": "WezTerm", "hyper": "Hyper",
    ]

    /// App name for "Open …" buttons.
    var appName: String {
        switch self {
        case .vscode:                return "VS Code"
        case .desktop:               return "Claude"
        case .terminal(let name, _): return name
        case .coucou:                return "Terminal"
        }
    }

    var label: String {
        switch self {
        case .vscode:                return "VS Code"
        case .desktop:               return "Desktop"
        case .terminal(let name, _): return name
        case .coucou:                return "Coucou"
        }
    }

    /// Detects the source from the fields nb-hook adds (entrypoint, term_program, bundle_id).
    /// Returns nil for headless runs (`claude -p`, SDK scripts) that no app window belongs to,
    /// except the ones Coucou launched itself.
    static func detect(_ payload: [String: Any]) -> ClaudeSource? {
        let entrypoint  = (payload["entrypoint"]   as? String ?? "").lowercased()
        let termProgram = (payload["term_program"] as? String ?? "")
        let bundleId    = (payload["bundle_id"]    as? String ?? "")
        let bundleLower = bundleId.lowercased()

        if !(payload["coucou_task"] as? String ?? "").isEmpty {
            return .coucou(sessionId: payload["session_id"] as? String ?? "")
        }
        if entrypoint.contains("desktop") || bundleLower == desktopBundleId { return .desktop }
        if entrypoint.contains("vscode") || termProgram.lowercased().contains("vscode")
            || vscodeBundleIds.contains(where: { $0.lowercased() == bundleLower }) { return .vscode }
        if let name = terminals[bundleId] { return .terminal(name: name, bundleId: bundleId) }
        if let name = termPrograms[termProgram.lowercased()] { return .terminal(name: name, bundleId: bundleId.isEmpty ? nil : bundleId) }
        if entrypoint.hasPrefix("sdk") { return nil }
        if !termProgram.isEmpty || !bundleId.isEmpty {
            return .terminal(name: "Terminal", bundleId: bundleId.isEmpty ? nil : bundleId)
        }
        return nil
    }

    // MARK: Open the app the session runs in

    @MainActor
    func open(cwd: String?) {
        switch self {
        case .vscode:
            let appURL = Self.vscodeBundleIds.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
            if let cwd, !cwd.isEmpty, let appURL {
                NSWorkspace.shared.open([URL(fileURLWithPath: cwd)], withApplicationAt: appURL,
                                        configuration: .init(), completionHandler: nil)
            } else {
                Self.activateOrLaunch(Self.vscodeBundleIds)
            }
        case .desktop:
            Self.activateOrLaunch([Self.desktopBundleId])
        case .terminal(_, let bundleId):
            Self.activateOrLaunch(bundleId.map { [$0] } ?? Array(Self.terminals.keys))
        case .coucou(let sessionId):
            // Headless run: continue it interactively in Terminal
            if let cwd { ClaudeCodeRunner.openInTerminal(sessionId: sessionId, cwd: cwd) }
        }
    }

    @MainActor
    private static func activateOrLaunch(_ bundleIds: [String]) {
        for id in bundleIds {
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                running.activate()
                return
            }
        }
        if let url = bundleIds.lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first {
            NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
        }
    }
}

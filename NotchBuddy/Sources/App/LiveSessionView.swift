import SwiftUI

// MARK: - Live Claude Code session
//
// Left: Mochi (drawn by BotPlacement at the layout's botX/botY), project name and the
// Read / Edit / Bash / Done steps. Right: the last file touched (diff from the hook's
// structuredPatch) and the last terminal output. Filled only from hook payloads.

struct LiveSessionView: View {
    @ObservedObject var state: AppState

    var body: some View {
        // Every view stays in the tree (IslandContentView fades them); build nothing while hidden
        if state.view == .liveSession {
            CardBackground(wash: nil) {
                HStack(alignment: .top, spacing: 0) {
                    LiveStepsColumn(state: state)
                        .frame(width: 128)
                    LiveCodePanel(session: state.liveSession)
                        .padding(.vertical, 8)
                        .padding(.trailing, 8)
                }
            }
        }
    }
}

// MARK: - Left column

private struct LiveStepsColumn: View {
    @ObservedObject var state: AppState

    private var task: AgentTask? { state.tasks.first { $0.id == "integration_claude" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Space for Mochi (BotPlacement draws it above this column)
            Spacer().frame(height: 82)

            Text(task?.name ?? "Claude Code")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(Color(hex: "#F5F6F8"))
                .lineLimit(1).truncationMode(.tail)
            Text("Claude Code")
                .font(.system(size: 11.5))
                .foregroundColor(Color(hex: "#8E939C"))
                .lineLimit(1)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(LiveStepKind.allCases, id: \.self) { kind in
                    LiveStepRow(kind: kind, status: state.liveSession.status(kind))
                }
            }
            .padding(.top, 14)

            Spacer(minLength: 0)
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct LiveStepRow: View {
    let kind: LiveStepKind
    let status: LiveStepStatus

    private static let green = Color(hex: "#34D399")
    private static let dim   = Color(hex: "#5F646D")

    var body: some View {
        HStack(spacing: 9) {
            icon.frame(width: 15, height: 15)
            Text(kind.label)
                .font(.system(size: 12.5, weight: status == .pending ? .regular : .semibold))
                .foregroundColor(labelColor)
        }
        .animation(.easeInOut(duration: 0.2), value: status)
    }

    private var labelColor: Color {
        switch status {
        case .pending: return Self.dim
        case .active:  return Color(hex: "#F5F6F8")
        case .done:    return kind == .done ? Self.green : Color(hex: "#C5C8CD")
        }
    }

    @ViewBuilder private var icon: some View {
        switch status {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundColor(Self.green)
        case .active:
            LiveSpinner()
        case .pending:
            Image(systemName: pendingSymbol)
                .font(.system(size: 12))
                .foregroundColor(Self.dim)
        }
    }

    private var pendingSymbol: String {
        switch kind {
        case .read: return "doc.text"
        case .edit: return "pencil"
        case .bash: return "apple.terminal"
        case .done: return "checkmark.circle.fill"
        }
    }
}

/// Small spinning arc. Only exists while a step is active in the visible live view.
private struct LiveSpinner: View {
    @State private var spin = false

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(Color(hex: "#F5F6F8"), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            .frame(width: 12, height: 12)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = true }
    }
}

// MARK: - Right panel: file + terminal

private struct LiveCodePanel: View {
    let session: LiveSession

    private static let bottomHeight: CGFloat = 84

    var body: some View {
        let (top, bottom) = session.panels
        VStack(spacing: 0) {
            if let top {
                content(top)
                    .frame(maxHeight: .infinity)
                    .id(top)
                    .transition(.opacity)
            } else {
                Text("Waiting for Claude Code…")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#5F646D"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let bottom {
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
                content(bottom)
                    .frame(height: Self.bottomHeight)
                    .id(bottom)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: session.panels.top)
        .animation(.easeInOut(duration: 0.25), value: session.panels.bottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(hex: "#0C0D10"))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.04), lineWidth: 1))
    }

    @ViewBuilder private func content(_ panel: LivePanel) -> some View {
        switch panel {
        case .file:
            if let file = session.file {
                VStack(spacing: 0) {
                    LiveFileTab(file: file, cwd: session.cwd)
                    LiveCodeLines(file: file)
                }
            }
        case .terminal:
            if let terminal = session.terminal { LiveTerminalView(terminal: terminal) }
        case .answer:
            if let answer = session.answer { LiveAnswerView(lines: answer) }
        case .summary:
            LiveSummaryView(session: session)
        }
    }
}

/// Claude's final reply for the turn. Inline markdown (bold, code, links) is rendered;
/// anything that doesn't parse is shown as plain text.
private struct LiveAnswerView: View {
    let lines: [String]

    private func rendered(_ line: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: line, options: options)) ?? AttributedString(line)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Claude")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .foregroundColor(Color(hex: "#34D399"))
                .padding(.bottom, 1)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : rendered(line))
                        .font(.system(size: 11.5))
                        .foregroundColor(Color(hex: "#C5C8CD"))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

private struct LiveFileTab: View {
    let file: LiveFile
    let cwd: String
    var onBack: (() -> Void)? = nil   // summary: back to the file list
    var openLine: Int? = nil          // summary: ↗ opens the file in VS Code at this line

    private var fileName: String {
        let name = (file.path as NSString).lastPathComponent
        return name.isEmpty ? "untitled" : name
    }

    private var displayPath: String { liveDisplayPath(file.path, cwd: cwd) }

    var body: some View {
        HStack(spacing: 7) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(hex: "#8E939C"))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 6) {
                LanguageBadge(fileName: fileName)
                Text(fileName)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(hex: "#E8E9EC"))
                    .lineLimit(1).truncationMode(.middle)
                if file.modified {
                    Circle().fill(Color(hex: "#F5A524")).frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .layoutPriority(1)

            Spacer(minLength: 8)

            Text(displayPath)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(Color(hex: "#5F646D"))
                .lineLimit(1).truncationMode(.head)
            if let openLine {
                OpenInVSCodeButton(path: file.path, line: openLine)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
    }
}

/// Extension badge, same look for every language: short uppercase extension on a stable color.
private struct LanguageBadge: View {
    let fileName: String

    private static let palette = ["#3178C6", "#3B82F6", "#8B5CF6", "#EC4899", "#F97316",
                                  "#EAB308", "#22C55E", "#14B8A6", "#64748B"]

    private var ext: String {
        let e = (fileName as NSString).pathExtension
        return e.isEmpty ? "TXT" : String(e.uppercased().prefix(4))
    }

    private var color: Color {
        // Stable across launches (String.hashValue is seeded per process)
        let sum = ext.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) }
        return Color(hex: Self.palette[abs(sum) % Self.palette.count])
    }

    var body: some View {
        Text(ext)
            .font(.system(size: 7.5, weight: .heavy))
            .foregroundColor(.white)
            .padding(.horizontal, 3)
            .frame(minWidth: 16, minHeight: 13)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .fixedSize()
    }
}

private struct LiveCodeLines: View {
    let file: LiveFile

    private static let rowH: CGFloat = 19

    private var gutterWidth: CGFloat {
        let maxNo = file.lines.compactMap(\.number).max() ?? 0
        return CGFloat(max(2, String(maxNo).count)) * 7.5 + 10
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(file.lines) { line in
                        row(line).id(line.id)
                    }
                    if file.truncated {
                        Text("…")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundColor(Color(hex: "#5F646D"))
                            .padding(.leading, gutterWidth + 22)
                            .frame(height: Self.rowH)
                    }
                }
                .padding(.vertical, 4)
            }
            .onAppear { scrollToChange(proxy, animated: false) }
            .onChange(of: file) { _, _ in scrollToChange(proxy, animated: true) }
        }
        .frame(maxHeight: .infinity)
    }

    private func scrollToChange(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let id = file.firstChangeId ?? file.lines.first?.id else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) }
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    @ViewBuilder private func row(_ line: LiveCodeLine) -> some View {
        if line.kind == .gap {
            Text("⋯")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Color(hex: "#3F434A"))
                .padding(.leading, gutterWidth + 22)
                .frame(maxWidth: .infinity, minHeight: Self.rowH, alignment: .leading)
        } else {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(accent(for: line.kind) ?? .clear)
                    .frame(width: 2)
                Text(line.number.map(String.init) ?? "")
                    .foregroundColor(numberColor(line.kind))
                    .frame(width: gutterWidth, alignment: .trailing)
                Text(marker(line.kind))
                    .foregroundColor(numberColor(line.kind))
                    .frame(width: 20)
                Text(line.text.isEmpty ? " " : line.text)
                    .strikethrough(line.kind == .removed, color: Color(hex: "#F4505E").opacity(0.6))
                    .foregroundColor(textColor(line.kind))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11.5, design: .monospaced))
            .frame(height: Self.rowH)
            .background(background(line.kind))
        }
    }

    private func accent(for kind: LiveCodeLine.Kind) -> Color? {
        switch kind {
        case .removed: return Color(hex: "#F4505E")
        case .added:   return Color(hex: "#34D399")
        default:       return nil
        }
    }

    private func marker(_ kind: LiveCodeLine.Kind) -> String {
        switch kind {
        case .removed: return "-"
        case .added:   return "+"
        default:       return ""
        }
    }

    private func numberColor(_ kind: LiveCodeLine.Kind) -> Color {
        switch kind {
        case .removed: return Color(hex: "#F4505E").opacity(0.85)
        case .added:   return Color(hex: "#34D399").opacity(0.85)
        default:       return Color(hex: "#4B4F57")
        }
    }

    private func textColor(_ kind: LiveCodeLine.Kind) -> Color {
        switch kind {
        case .removed: return Color(hex: "#F4505E").opacity(0.55)
        case .added:   return Color(hex: "#E8E9EC")
        default:       return Color(hex: "#C5C8CD")
        }
    }

    private func background(_ kind: LiveCodeLine.Kind) -> Color {
        switch kind {
        case .removed: return Color(hex: "#F4505E").opacity(0.12)
        case .added:   return Color(hex: "#34D399").opacity(0.10)
        default:       return .clear
        }
    }
}

private struct LiveTerminalView: View {
    let terminal: LiveTerminal

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("$").foregroundColor(Color(hex: "#6B7079"))
                        Text(terminal.command.isEmpty ? " " : terminal.command)
                            .foregroundColor(Color(hex: "#E8E9EC"))
                            .lineLimit(2).truncationMode(.tail)
                    }
                    ForEach(Array(terminal.output.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .foregroundColor(terminal.failed ? Color(hex: "#F4505E").opacity(0.8) : Color(hex: "#9BA0A8"))
                            .lineLimit(1).truncationMode(.tail)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: terminal) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

// MARK: - Turn summary (top panel once the turn is done)

/// Files changed with +/−, commands run with their result, tests, duration.
/// A single changed file shows its diff right away; with several, a click opens one.
private struct LiveSummaryView: View {
    let session: LiveSession
    @State private var selected: String? = nil

    private var shownChange: LiveFileChange? {
        if session.changes.count == 1 { return session.changes[0] }
        return session.changes.first { $0.path == selected }
    }

    var body: some View {
        VStack(spacing: 0) {
            LiveSummaryHeader(session: session)
            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
            if let change = shownChange {
                LiveFileTab(file: change.file, cwd: session.cwd,
                            onBack: session.changes.count > 1 ? { withAnimation(.easeInOut(duration: 0.2)) { selected = nil } } : nil,
                            openLine: change.firstLine ?? 1)
                LiveCodeLines(file: change.file)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(session.changes) { change in
                            LiveChangeRow(change: change, cwd: session.cwd) {
                                withAnimation(.easeInOut(duration: 0.2)) { selected = change.path }
                            }
                        }
                        if !session.changes.isEmpty && !session.commands.isEmpty {
                            Spacer().frame(height: 6)
                        }
                        LiveCommandRows(commands: session.commands)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                }
            }
        }
        .onChange(of: session.turnStart) { _, _ in selected = nil }
    }
}

private struct LiveSummaryHeader: View {
    let session: LiveSession

    var body: some View {
        HStack(spacing: 8) {
            Text(filesLabel)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(Color(hex: "#E8E9EC"))
            if !session.changes.isEmpty {
                LiveDiffCounts(added: session.totalAdded, removed: session.totalRemoved)
            }
            if let failed = session.testsFailed {
                HStack(spacing: 4) {
                    Image(systemName: failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 10))
                    Text(failed ? "Tests failed" : "Tests passed")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .foregroundColor(Color(hex: failed ? "#F4505E" : "#34D399"))
            }
            Spacer(minLength: 4)
            if let d = session.duration {
                Label(Self.format(d), systemImage: "clock")
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundColor(Color(hex: "#6B7079"))
                    .labelStyle(.titleAndIcon)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
    }

    private var filesLabel: String {
        switch session.changes.count {
        case 0: return "No file changed"
        case 1: return "1 file changed"
        case let n: return "\(n) files changed"
        }
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
        return "\(s / 3600)h \(String(format: "%02d", (s % 3600) / 60))m"
    }
}

private struct LiveDiffCounts: View {
    let added: Int
    let removed: Int

    var body: some View {
        HStack(spacing: 5) {
            Text("+\(added)").foregroundColor(Color(hex: "#34D399"))
            Text("−\(removed)").foregroundColor(Color(hex: "#F4505E"))
        }
        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
        .fixedSize()
    }
}

private struct LiveChangeRow: View {
    let change: LiveFileChange
    let cwd: String
    let onSelect: () -> Void
    @State private var hovered = false

    private var name: String { (change.path as NSString).lastPathComponent }
    private var folder: String {
        let dir = (liveDisplayPath(change.path, cwd: cwd) as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir + "/"
    }

    var body: some View {
        HStack(spacing: 7) {
            Button(action: onSelect) {
                HStack(spacing: 7) {
                    LanguageBadge(fileName: name)
                    Text(name)
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundColor(Color(hex: "#E8E9EC"))
                        .lineLimit(1).truncationMode(.middle)
                        .layoutPriority(1)
                    if change.isNew {
                        Text("new")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(Color(hex: "#34D399"))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color(hex: "#34D399").opacity(0.12))
                            .clipShape(Capsule())
                    }
                    Text(folder)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(Color(hex: "#5F646D"))
                        .lineLimit(1).truncationMode(.head)
                    Spacer(minLength: 6)
                    LiveDiffCounts(added: change.added, removed: change.removed)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            OpenInVSCodeButton(path: change.path, line: change.firstLine ?? 1)
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(hovered ? Color.white.opacity(0.05) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { hovered = $0 }
    }
}

private struct LiveCommandRows: View {
    let commands: [LiveCommand]

    var body: some View {
        ForEach(commands) { cmd in
            HStack(spacing: 7) {
                Group {
                    switch cmd.failed {
                    case .none:        LiveSpinner()
                    case .some(true):  Image(systemName: "xmark.circle.fill").foregroundColor(Color(hex: "#F4505E"))
                    case .some(false): Image(systemName: "checkmark.circle.fill").foregroundColor(Color(hex: "#34D399"))
                    }
                }
                .font(.system(size: 11))
                .frame(width: 16)
                Text("$ " + cmd.command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(hex: "#C5C8CD"))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 6)
                if cmd.isTest, let failed = cmd.failed {
                    Text(failed ? "Tests failed" : "Tests passed")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(hex: failed ? "#F4505E" : "#34D399"))
                        .fixedSize()
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 21)
        }
    }
}

/// ↗ — opens the file in VS Code at the given line (vscode:// URL, works in the sandbox too).
private struct OpenInVSCodeButton: View {
    let path: String
    let line: Int

    var body: some View {
        Button(action: open) {
            Image(systemName: "arrow.up.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(Color(hex: "#8E939C"))
                .frame(width: 18, height: 18)
                .background(Color.white.opacity(0.07))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Open in VS Code")
    }

    private func open() {
        var components = URLComponents()
        components.scheme = "vscode"
        components.host = "file"
        components.path = path + ":\(max(1, line))"
        if let url = components.url, NSWorkspace.shared.open(url) { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}

/// Path relative to the project folder when the file lives inside it, else ~-abbreviated.
private func liveDisplayPath(_ path: String, cwd: String) -> String {
    let root = cwd.hasSuffix("/") ? cwd : cwd + "/"
    if !cwd.isEmpty, path.hasPrefix(root) { return String(path.dropFirst(root.count)) }
    return (path as NSString).abbreviatingWithTildeInPath
}

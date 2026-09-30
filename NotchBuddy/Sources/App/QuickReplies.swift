import Foundation
import SwiftUI

// MARK: - Quick replies to Claude's closing question
//
// When a turn ends on a question, nb-hook holds the Stop hook up to `waitSeconds` while the
// notch shows two suggested answers and a reply field. A click sends the text back as the Stop
// hook's "block" reason, so Claude continues with it; no click → Claude stops normally.

struct QuickReplyPrompt: Identifiable, Equatable {
    let id = UUID()
    let taskId: String
    let question: String
    let options: [String]
    let deadline: Date
}

enum QuickReplySuggester {
    static let waitSeconds: TimeInterval = 45
    static let maxChained = 3            // quick replies in a row before letting Claude stop
    private static let maxOptionLength = 40

    /// The closing question and two answers for it, or nil when the message doesn't end on a question.
    /// Local rules only: options listed right before the question, "A or B?", otherwise yes / no.
    static func suggest(_ message: String) -> (question: String, options: [String])? {
        let lines = message
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let last = lines.last else { return nil }
        let question = plain(last)
        guard question.hasSuffix("?") else { return nil }

        let french = looksFrench(message)
        if let listed = listedOptions(Array(lines.dropLast().suffix(8))), listed.count >= 2 {
            return (question, Array(listed.prefix(2)))
        }
        if let pair = eitherOr(question) {
            return (question, pair)
        }
        return (question, french ? ["Oui, vas-y", "Non"] : ["Yes, go ahead", "No"])
    }

    /// "1. Tabs" / "- **Two rows** — …" lines just above the question → short labels.
    private static func listedOptions(_ lines: [String]) -> [String]? {
        let pattern = try? NSRegularExpression(pattern: #"^(?:\d+[.)]|[-*•])\s+(.+)$"#)
        var options: [String] = []
        for line in lines.reversed() {
            let range = NSRange(line.startIndex..., in: line)
            guard let m = pattern?.firstMatch(in: line, range: range),
                  let r = Range(m.range(at: 1), in: line) else {
                if options.isEmpty { continue } else { break }   // the list ends at the first non-item line
            }
            options.insert(label(String(line[r])), at: 0)
        }
        return options.filter { !$0.isEmpty }
    }

    /// "Tabs or two rows?" / "Onglets ou lignes ?" with short sides → both sides.
    private static func eitherOr(_ question: String) -> [String]? {
        var q = question
        q.removeLast()   // "?"
        q = q.trimmingCharacters(in: .whitespaces)
        for sep in [" ou ", " or "] {
            let parts = q.components(separatedBy: sep)
            guard parts.count == 2 else { continue }
            // Left side: only what follows the last comma or colon ("Tu préfères : A ou B")
            let left = parts[0].components(separatedBy: CharacterSet(charactersIn: ",:")).last ?? parts[0]
            let a = left.trimmingCharacters(in: .whitespaces)
            let b = parts[1].trimmingCharacters(in: .whitespaces)
            let short: (String) -> Bool = { s in !s.isEmpty && s.split(separator: " ").count <= 4 }
            if short(a) && short(b) { return [capitalized(a), capitalized(b)] }
        }
        return nil
    }

    // MARK: Text helpers

    /// Drops markdown emphasis and code ticks.
    private static func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Option label: before " — ", " - " or ":", markdown removed, capped.
    private static func label(_ item: String) -> String {
        var s = plain(item)
        for sep in [" — ", " – ", " - ", ": "] {
            if let r = s.range(of: sep) { s = String(s[..<r.lowerBound]) }
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:"))
        return s.count > maxOptionLength ? String(s.prefix(maxOptionLength - 1)) + "…" : s
    }

    private static func capitalized(_ s: String) -> String {
        s.prefix(1).uppercased() + s.dropFirst()
    }

    private static func looksFrench(_ text: String) -> Bool {
        let t = " " + text.lowercased() + " "
        let hints = [" tu ", " vous ", " je ", " veux ", " est-ce ", " les ", " une ", " pour ", " c'est ", "é", "è", "à "]
        return hints.filter { t.contains($0) }.count >= 2
    }
}

// MARK: - Quick reply bar (live view bottom panel, finished view)

/// Two suggested answers + a reply field + the time left. Sends only on click or Return.
struct QuickReplyBar: View {
    let prompt: QuickReplyPrompt
    var showQuestion = true
    @State private var text = ""
    @State private var remaining: CGFloat = 1
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if showQuestion {
                Text(prompt.question)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                ForEach(prompt.options, id: \.self) { option in
                    Button(action: { send(option) }) {
                        Text(option)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(hex: "#0C0D10"))
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .frame(height: 22)
                            .background(Capsule().fill(Color(hex: "#F5F6F8")))
                    }
                    .buttonStyle(.plain)
                    .layoutPriority(1)
                }
                HStack(spacing: 4) {
                    TextField("Reply…", text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#E8E9EC"))
                        .focused($fieldFocused)
                        .onSubmit { send(text) }
                        .simultaneousGesture(TapGesture().onEnded {
                            // The island panel is non-activating: ask for keyboard focus first
                            NotificationCenter.default.post(name: .islandWantsKey, object: nil)
                            DispatchQueue.main.async { fieldFocused = true }
                        })
                    if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button(action: { send(text) }) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(Color(hex: "#0C0D10"))
                                .frame(width: 16, height: 16)
                                .background(Circle().fill(Color(hex: "#F5F6F8")))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 9).padding(.trailing, 3)
                .frame(height: 22)
                .background(Capsule().fill(Color.white.opacity(0.07)))
                .overlay(Capsule().stroke(Color.white.opacity(fieldFocused ? 0.18 : 0.06), lineWidth: 1))
            }
            // Time left before Claude stops on its own
            GeometryReader { geo in
                Capsule()
                    .fill(Color.white.opacity(0.22))
                    .frame(width: geo.size.width * remaining, height: 2)
            }
            .frame(height: 2)
        }
        .onAppear { startCountdown() }
        .onChange(of: prompt.id) { _, _ in text = ""; startCountdown() }
    }

    private func startCountdown() {
        let left = max(0, prompt.deadline.timeIntervalSinceNow)
        remaining = CGFloat(left / QuickReplySuggester.waitSeconds)
        withAnimation(.linear(duration: left)) { remaining = 0 }
    }

    private func send(_ reply: String) {
        HookServer.shared.sendQuickReply(taskId: prompt.taskId, text: reply)
        text = ""
    }
}

extension Notification.Name {
    /// A view needs keyboard input (text field in the non-activating island panel).
    static let islandWantsKey = Notification.Name("notchBuddy.islandWantsKey")
}

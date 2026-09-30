import SwiftUI

// MARK: - Overview card: 3 lines (reviews requested, your PRs + CI, notifications)

struct GitHubActivityCardView: View {
    let activity: GitHubActivity
    @ObservedObject private var appState = AppState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(Color(hex: "#F4505E")).frame(width: 7, height: 7)
                Text("GitHub")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                Text("Activity")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#8E939C"))
            }
            .padding(.top, 6)
            .padding(.leading, 108)
            .padding(.trailing, 36)

            VStack(alignment: .leading, spacing: 5) {
                GitHubSummaryRow(
                    icon: "eye.fill", color: activity.reviewRequests.isEmpty ? "#4B4F57" : "#F5A524",
                    label: reviewLabel, detail: activity.reviewRequests.first?.title)
                GitHubSummaryRow(
                    icon: GitHubCIStyle.icon(activity.headlinePR?.ci ?? .none),
                    color: activity.myPRs.isEmpty ? "#4B4F57" : GitHubCIStyle.color(activity.headlinePR?.ci ?? .none),
                    label: prLabel, detail: activity.headlinePR?.title)
                if activity.notificationsAvailable {
                    GitHubSummaryRow(
                        icon: "bell.fill", color: activity.notifications.isEmpty ? "#4B4F57" : "#60A5FA",
                        label: notificationLabel, detail: activity.notifications.first?.title)
                } else {
                    GitHubSummaryRow(icon: "bell.slash", color: "#4B4F57",
                                     label: "Notifications", detail: "add the notifications scope")
                }
            }
            .padding(.top, 8)
            .padding(.leading, 108)
            .padding(.trailing, 12)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.top, 4)
        .onAppear { clearBadge() }
    }

    private var reviewLabel: String {
        switch activity.reviewRequests.count {
        case 0: return "No review requested"
        case 1: return "1 review"
        case let n: return "\(n) reviews"
        }
    }

    private var prLabel: String {
        switch activity.myPRs.count {
        case 0: return "No open PR"
        case 1: return "1 PR"
        case let n: return "\(n) PRs"
        }
    }

    private var notificationLabel: String {
        switch activity.notifications.count {
        case 0: return "No notification"
        case 50...: return "50+"
        case let n: return "\(n) unread"
        }
    }

    /// The card is on screen: the pill badge has done its job.
    private func clearBadge() {
        if let i = appState.tasks.firstIndex(where: { $0.id == "integration_github" }) {
            appState.tasks[i].pillBadge = nil
        }
    }
}

private struct GitHubSummaryRow: View {
    let icon: String
    let color: String
    let label: String
    let detail: String?

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(Color(hex: color))
                .frame(width: 14)
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(hex: "#C5C8CD"))
                .lineLimit(1)
                .fixedSize()
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#6B7079"))
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
    }
}

enum GitHubCIStyle {
    static func icon(_ ci: GitHubCI) -> String {
        switch ci {
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.circle.fill"
        case .pending: return "circle.dotted"
        case .none:    return "arrow.triangle.pull"
        }
    }

    static func color(_ ci: GitHubCI) -> String {
        switch ci {
        case .success: return "#34D399"
        case .failure: return "#F4505E"
        case .pending: return "#F5A524"
        case .none:    return "#8E939C"
        }
    }
}

// MARK: - Detail view (full island width)

struct GitHubDetailView: View {
    @ObservedObject var state: AppState

    var body: some View {
        // Every view stays in the tree (IslandContentView fades them); build nothing while hidden
        if state.view == .github {
            CardBackground(wash: nil) {
                HStack(alignment: .top, spacing: 0) {
                    GitHubSideColumn(state: state)
                        .frame(width: 128)
                    GitHubLists(activity: state.githubActivity ?? GitHubActivity())
                        .padding(.vertical, 8)
                        .padding(.trailing, 8)
                }
            }
        }
    }
}

private struct GitHubSideColumn: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Space for Mochi (BotPlacement draws it above this column)
            Spacer().frame(height: 82)

            Text("GitHub")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(Color(hex: "#F5F6F8"))
            if let login = state.githubActivity?.login, !login.isEmpty {
                Text("@\(login)")
                    .font(.system(size: 11.5))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.top, 1)
            }

            if let stats = state.githubStats {
                VStack(alignment: .leading, spacing: 6) {
                    sideStat("star.fill", "#F5A524", stats.totalStars >= 1000
                             ? String(format: "%.1fk", Double(stats.totalStars) / 1000) : "\(stats.totalStars)", "stars")
                    sideStat("square.stack.fill", "#6B7079", "\(stats.totalRepos)", "repos")
                }
                .padding(.top, 14)
            }

            Spacer(minLength: 0)

            if let error = state.githubError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#F4505E"))
                    .lineLimit(2)
                    .padding(.bottom, 4)
            }
            Button(action: { GithubPoller.shared.pollNow() }) {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(hex: "#8E939C"))
            }
            .buttonStyle(.plain)
            .padding(.bottom, 12)
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func sideStat(_ icon: String, _ color: String, _ value: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(Color(hex: color))
                .frame(width: 14)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(hex: "#C5C8CD"))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#6B7079"))
        }
    }
}

private struct GitHubLists: View {
    let activity: GitHubActivity

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                section("Review requested", count: activity.reviewRequests.count,
                        empty: "Nothing to review") {
                    ForEach(activity.reviewRequests) { pr in
                        GitHubRow(icon: "eye.fill", color: "#F5A524",
                                  title: pr.title, subtitle: "\(pr.repo) #\(pr.number)",
                                  trailing: timeAgo(pr.updatedAt), url: pr.url)
                    }
                }
                section("Your pull requests", count: activity.myPRs.count,
                        empty: "No open pull request") {
                    ForEach(activity.myPRs) { pr in
                        GitHubRow(icon: GitHubCIStyle.icon(pr.ci), color: GitHubCIStyle.color(pr.ci),
                                  title: pr.title,
                                  subtitle: "\(pr.repo) #\(pr.number)" + (pr.isDraft ? " · draft" : "")
                                      + (pr.approved ? " · approved" : ""),
                                  trailing: ciLabel(pr.ci) ?? timeAgo(pr.updatedAt), url: pr.url)
                    }
                }
                if activity.notificationsAvailable {
                    section("Notifications", count: activity.notifications.count,
                            empty: "All caught up") {
                        ForEach(activity.notifications) { n in
                            GitHubRow(icon: notificationIcon(n), color: "#60A5FA",
                                      title: n.title, subtitle: "\(n.repo) · \(reasonLabel(n.reason))",
                                      trailing: timeAgo(n.updatedAt), url: n.url)
                        }
                    }
                } else {
                    section("Notifications", count: 0,
                            empty: "Add the “notifications” scope to your token to see them") { EmptyView() }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(hex: "#0C0D10"))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.04), lineWidth: 1))
    }

    @ViewBuilder
    private func section<Rows: View>(_ title: String, count: Int, empty: String,
                                     @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title.uppercased())
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(Color(hex: "#6B7079"))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(Color(hex: "#8E939C"))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.white.opacity(0.07))
                        .clipShape(Capsule())
                }
            }
            .padding(.leading, 4)
            .padding(.bottom, 2)
            if count == 0 {
                Text(empty)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#4B4F57"))
                    .padding(.leading, 4)
            } else {
                rows()
            }
        }
    }

    private func ciLabel(_ ci: GitHubCI) -> String? {
        switch ci {
        case .success: return "passing"
        case .failure: return "failing"
        case .pending: return "running"
        case .none:    return nil
        }
    }

    private func notificationIcon(_ n: GitHubNotification) -> String {
        switch n.type {
        case "PullRequest": return "arrow.triangle.pull"
        case "Issue":       return "smallcircle.filled.circle"
        case "Release":     return "tag.fill"
        case "CheckSuite":  return "checkmark.seal"
        case "Discussion":  return "bubble.left.and.bubble.right.fill"
        default:            return "bell.fill"
        }
    }

    private func reasonLabel(_ reason: String) -> String {
        switch reason {
        case "mention", "team_mention": return "mentioned"
        case "review_requested":        return "review requested"
        case "comment":                 return "comment"
        case "author":                  return "your thread"
        case "assign":                  return "assigned"
        case "ci_activity":             return "CI"
        case "state_change":            return "state changed"
        case "subscribed", "manual":    return "watching"
        default:                        return reason.replacingOccurrences(of: "_", with: " ")
        }
    }

    private func timeAgo(_ date: Date) -> String {
        guard date != .distantPast else { return "" }
        let s = max(0, Int(Date().timeIntervalSince(date)))
        switch s {
        case ..<60:     return "now"
        case ..<3600:   return "\(s / 60)m"
        case ..<86400:  return "\(s / 3600)h"
        default:        return "\(s / 86400)d"
        }
    }
}

/// One clickable line: opens the item on github.com in the browser (read-only, nothing is changed).
private struct GitHubRow: View {
    let icon: String
    let color: String
    let title: String
    let subtitle: String
    let trailing: String
    let url: URL
    @State private var hovered = false

    var body: some View {
        Button(action: { NSWorkspace.shared.open(url) }) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: color))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(Color(hex: "#E8E9EC"))
                        .lineLimit(1).truncationMode(.tail)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#6B7079"))
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 6)
                Text(trailing)
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#6B7079"))
                    .fixedSize()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(hovered ? Color.white.opacity(0.05) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

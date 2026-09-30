import Foundation

// MARK: - GithubPoller
// Every 2 minutes (and on demand): reviews requested from the user, the user's open PRs with
// their CI state, unread notifications, plus repo/star totals. Read-only, token from the Keychain.
// Mochi reacts to changes: CI failing on one of the user's PRs, a PR approved or merged,
// a new review request.

final class GithubPoller: @unchecked Sendable {
    static let shared = GithubPoller()
    private var timer: DispatchSourceTimer?
    private let worker = GitHubWorker()
    private init() {}

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        t.schedule(deadline: .now() + 7, repeating: 120)  // every 2 minutes
        t.setEventHandler { [weak self] in self?.pollNow() }
        t.resume()
        timer = t
    }

    func pollNow() {
        guard let token = KeychainStore.shared.get("github-token") else { return }
        let worker = self.worker
        Task.detached(priority: .utility) { await worker.refresh(token: token) }
    }
}

// MARK: - Worker (serialises refreshes, remembers the previous poll for change detection)

private actor GitHubWorker {
    private var inFlight = false
    private var previous: GitHubActivity?

    private static let iso = Date.ISO8601FormatStyle()

    func refresh(token: String) async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }

        let api = GitHubAPI(token: token)
        do {
            // User + totals
            let user = try await api.object("/user")
            let login = user["login"] as? String ?? ""
            let totalRepos = (user["public_repos"] as? Int ?? 0)
                + (user["owned_private_repos"] as? Int ?? user["total_private_repos"] as? Int ?? 0)
            let repos = (try? await api.array("/user/repos?per_page=100&affiliation=owner&sort=pushed")) ?? []
            let stars = repos.reduce(0) { $0 + ($1["stargazers_count"] as? Int ?? 0) }

            var activity = GitHubActivity(login: login)
            activity.reviewRequests = try await searchPRs(api, "is:open is:pr archived:false review-requested:@me")
            var mine = try await searchPRs(api, "is:open is:pr archived:false author:@me")
            let approved = Set((try? await searchPRs(api, "is:open is:pr archived:false author:@me review:approved"))?.map(\.id) ?? [])
            for i in mine.indices {
                mine[i].approved = approved.contains(mine[i].id)
                if i < 8 { mine[i].ci = await ciState(api, mine[i]) }
            }
            activity.myPRs = mine

            do {
                activity.notifications = try await notifications(api)
            } catch GitHubAPI.Failure.status(let code) where code == 403 || code == 404 {
                activity.notificationsAvailable = false   // token without the notifications scope
            }

            let merged = await mergedSincePrevious(api, current: mine)
            let events = Self.events(previous: previous, current: activity, merged: merged)
            previous = activity

            await MainActor.run {
                let state = AppState.shared
                state.githubError = nil
                state.githubStats = GitHubStats(totalRepos: totalRepos, totalStars: stars)
                if state.githubActivity != activity { state.githubActivity = activity }
                GitHubReactions.play(events)
            }
        } catch {
            let message = (error as? GitHubAPI.Failure)?.message ?? error.localizedDescription
            await MainActor.run { AppState.shared.githubError = message }
        }
    }

    // MARK: Queries

    private func searchPRs(_ api: GitHubAPI, _ query: String) async throws -> [GitHubPR] {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?
            .replacingOccurrences(of: "+", with: "%2B")
            .replacingOccurrences(of: ":", with: "%3A") ?? ""
        let result = try await api.object("/search/issues?q=\(q)&sort=updated&order=desc&per_page=20")
        let items = result["items"] as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let id = item["id"] as? Int,
                  let number = item["number"] as? Int,
                  let html = (item["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
            let repoURL = item["repository_url"] as? String ?? ""
            let repo = repoURL.components(separatedBy: "/repos/").last ?? ""
            return GitHubPR(id: id, number: number,
                            title: item["title"] as? String ?? "#\(number)",
                            repo: repo, url: html,
                            updatedAt: Self.date(item["updated_at"]),
                            isDraft: item["draft"] as? Bool ?? false)
        }
    }

    private func ciState(_ api: GitHubAPI, _ pr: GitHubPR) async -> GitHubCI {
        guard !pr.repo.isEmpty,
              let detail = try? await api.object("/repos/\(pr.repo)/pulls/\(pr.number)"),
              let sha = (detail["head"] as? [String: Any])?["sha"] as? String else { return .none }

        var failing = false, running = false, passing = false

        if let runs = try? await api.object("/repos/\(pr.repo)/commits/\(sha)/check-runs?per_page=100"),
           let list = runs["check_runs"] as? [[String: Any]] {
            for run in list {
                if run["status"] as? String != "completed" { running = true; continue }
                switch run["conclusion"] as? String {
                case "failure", "timed_out", "cancelled", "action_required", "startup_failure": failing = true
                case "success": passing = true
                default: break
                }
            }
        }
        if let status = try? await api.object("/repos/\(pr.repo)/commits/\(sha)/status"),
           (status["total_count"] as? Int ?? 0) > 0 {
            switch status["state"] as? String {
            case "failure", "error": failing = true
            case "pending":          running = true
            case "success":          passing = true
            default: break
            }
        }
        return failing ? .failure : running ? .pending : passing ? .success : .none
    }

    private func notifications(_ api: GitHubAPI) async throws -> [GitHubNotification] {
        let list = try await api.array("/notifications?per_page=50")
        return list.compactMap { n in
            guard let id = n["id"] as? String,
                  let subject = n["subject"] as? [String: Any] else { return nil }
            let repo = (n["repository"] as? [String: Any])?["full_name"] as? String ?? ""
            let repoHTML = (n["repository"] as? [String: Any])?["html_url"] as? String
            return GitHubNotification(
                id: id,
                title: subject["title"] as? String ?? "Notification",
                repo: repo,
                reason: n["reason"] as? String ?? "",
                type: subject["type"] as? String ?? "",
                url: Self.htmlURL(api: subject["url"] as? String, repoHTML: repoHTML),
                updatedAt: Self.date(n["updated_at"]))
        }
    }

    /// PRs open at the previous poll and gone now: ask GitHub whether they were merged.
    private func mergedSincePrevious(_ api: GitHubAPI, current: [GitHubPR]) async -> [GitHubPR] {
        guard let previous else { return [] }
        let open = Set(current.map(\.id))
        var merged: [GitHubPR] = []
        for pr in previous.myPRs where !open.contains(pr.id) {
            if let detail = try? await api.object("/repos/\(pr.repo)/pulls/\(pr.number)"),
               detail["merged"] as? Bool == true {
                merged.append(pr)
            }
        }
        return merged
    }

    // MARK: Change detection (nothing on the first poll)

    static func events(previous: GitHubActivity?, current: GitHubActivity, merged: [GitHubPR]) -> GitHubReactions.Events {
        guard let previous else { return .init() }
        let before = Dictionary(previous.myPRs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var e = GitHubReactions.Events()
        e.ciFailed = current.myPRs.filter { $0.ci == .failure && before[$0.id].map { $0.ci != .failure } ?? false }
        e.approved = current.myPRs.filter { $0.approved && before[$0.id].map { !$0.approved } ?? false }
        e.merged = merged
        let knownReviews = Set(previous.reviewRequests.map(\.id))
        e.newReviews = current.reviewRequests.filter { !knownReviews.contains($0.id) }
        return e
    }

    // MARK: Helpers

    private static func date(_ value: Any?) -> Date {
        (value as? String).flatMap { try? iso.parse($0) } ?? .distantPast
    }

    /// api.github.com/repos/o/r/pulls/12 → github.com/o/r/pull/12 (issues, commits, releases likewise).
    private static func htmlURL(api: String?, repoHTML: String?) -> URL {
        if let api, api.hasPrefix("https://api.github.com/repos/") {
            let path = api.dropFirst("https://api.github.com/repos/".count)
                .replacingOccurrences(of: "/pulls/", with: "/pull/")
                .replacingOccurrences(of: "/commits/", with: "/commit/")
            if !path.contains("/releases/"), let url = URL(string: "https://github.com/\(path)") { return url }
        }
        return repoHTML.flatMap(URL.init(string:)) ?? URL(string: "https://github.com/notifications")!
    }
}

// MARK: - Minimal REST client

private struct GitHubAPI {
    let token: String

    enum Failure: Error {
        case status(Int)
        case badResponse

        var message: String {
            switch self {
            case .status(401): return "Invalid token (401)"
            case .status(403): return "Access denied or rate limited (403)"
            case .status(let c): return "API error \(c)"
            case .badResponse: return "Unexpected response"
            }
        }
    }

    func object(_ path: String) async throws -> [String: Any] {
        guard let o = try await json(path) as? [String: Any] else { throw Failure.badResponse }
        return o
    }

    func array(_ path: String) async throws -> [[String: Any]] {
        guard let a = try await json(path) as? [[String: Any]] else { throw Failure.badResponse }
        return a
    }

    private func json(_ path: String) async throws -> Any {
        guard let url = URL(string: "https://api.github.com" + path) else { throw Failure.badResponse }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw Failure.status(code) }
        return try JSONSerialization.jsonObject(with: data)
    }
}

// MARK: - Mochi reactions

@MainActor
enum GitHubReactions {
    struct Events {
        var ciFailed: [GitHubPR] = []
        var approved: [GitHubPR] = []
        var merged: [GitHubPR] = []
        var newReviews: [GitHubPR] = []
    }

    static func play(_ e: Events) {
        let state = AppState.shared
        DayJournal.shared.recordGitHub(merged: e.merged.count, ciFailed: e.ciFailed.count)
        guard let idx = state.tasks.firstIndex(where: { $0.id == "integration_github" }) else { return }
        let focused = state.focusId == "integration_github"

        if let pr = e.ciFailed.first {
            state.tasks[idx].state = .error
            state.tasks[idx].steps = ["CI failed · \(pr.title)"]
            if !focused { state.tasks[idx].pillBadge = .error }
            SoundEngine.shared.play("error")
        } else if let pr = e.merged.first ?? e.approved.first {
            let merged = !e.merged.isEmpty
            state.tasks[idx].state = .finished
            state.tasks[idx].steps = ["\(merged ? "Merged" : "Approved") · \(pr.title)"]
            if !focused { state.tasks[idx].pillBadge = .finished }
            if focused && state.mode == .expanded {
                NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
            }
            SoundEngine.shared.play("finish")
        } else if let pr = e.newReviews.first {
            state.tasks[idx].steps = ["Review requested · \(pr.title)"]
            if !focused { state.tasks[idx].pillBadge = .approval }
            SoundEngine.shared.play("peek")
        } else {
            return
        }

        // Show the compact island so the badge is visible
        NotificationCenter.default.post(name: .hookReveal, object: nil)

        // Back to idle after a minute; the activity itself stays on the card
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            guard let i = state.tasks.firstIndex(where: { $0.id == "integration_github" }) else { return }
            if state.tasks[i].state == .finished || state.tasks[i].state == .error { state.tasks[i].state = .idle }
            state.tasks[i].pillBadge = nil
        }
    }
}

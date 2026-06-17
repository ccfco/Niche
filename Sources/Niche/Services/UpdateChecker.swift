import AppKit
import Combine
import Foundation

/// GitHub Releases 轮询式更新检查(参照 Clipin UpdateReminderService)。
/// 启动后 5s 首次检查,之后每 6h 定时;12h 内不重复检查同一版本。
/// 无浮层提示:菜单栏小红点 + 设置页「关于」区承载更新 UI。
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published private(set) var autoCheckEnabled: Bool
    @Published private(set) var latestRelease: ReleaseInfo?
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var isChecking = false
    @Published private(set) var didLastCheckFail = false

    let currentVersion: String

    private let defaults = UserDefaults.standard
    private let decoder = JSONDecoder()
    private let session: URLSession
    private let apiURL = URL(string: "https://api.github.com/repos/ccfco/Niche/releases/latest")!
    private let releasesURL = URL(string: "https://github.com/ccfco/Niche/releases/latest")!
    private var periodicCheckTimer: Timer?
    private var didStart = false
    /// 检查进行中又来了强制请求(用户点「立即检查」):记下,当前检查结束后补跑一次 —— 否则被
    /// `guard !isChecking` 静默丢弃,用户的"现在就查"落空(后台检查恰在网络 await 中时尤甚)。
    private var pendingForcedCheck = false

    private enum Keys {
        static let autoCheckEnabled = "niche.updates.autoCheckEnabled"
        static let lastCheckedAt = "niche.updates.lastCheckedAt"
        static let dismissedVersion = "niche.updates.dismissedVersion"
    }

    private var dismissedVersion: String? {
        didSet { defaults.set(dismissedVersion, forKey: Keys.dismissedVersion) }
    }

    private init() {
        currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        autoCheckEnabled = defaults.object(forKey: Keys.autoCheckEnabled) as? Bool ?? true
        lastCheckedAt = defaults.object(forKey: Keys.lastCheckedAt) as? Date
        dismissedVersion = defaults.string(forKey: Keys.dismissedVersion)

        decoder.dateDecodingStrategy = .iso8601

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        guard autoCheckEnabled else { return }
        schedulePeriodicChecks()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            await self?.checkIfNeeded()
        }
    }

    func setAutoCheckEnabled(_ enabled: Bool) {
        autoCheckEnabled = enabled
        defaults.set(enabled, forKey: Keys.autoCheckEnabled)
        if enabled {
            schedulePeriodicChecks()
            Task { [weak self] in await self?.checkIfNeeded() }
        } else {
            periodicCheckTimer?.invalidate()
            periodicCheckTimer = nil
        }
    }

    func checkNow() {
        Task { [weak self] in await self?.performCheck(force: true) }
    }

    func openReleasePage() {
        NSWorkspace.shared.open(latestRelease?.releasePageURL ?? releasesURL)
    }

    func downloadLatest() {
        let target = latestRelease?.downloadURL ?? latestRelease?.releasePageURL ?? releasesURL
        NSWorkspace.shared.open(target)
    }

    // MARK: - 内部

    private func schedulePeriodicChecks() {
        periodicCheckTimer?.invalidate()
        periodicCheckTimer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.checkIfNeeded() }
        }
    }

    private func checkIfNeeded() async {
        guard autoCheckEnabled else { return }
        await performCheck(force: false)
    }

    private func performCheck(force: Bool) async {
        if isChecking {
            if force { pendingForcedCheck = true }   // 检查中:记下强制请求,结束后补跑(不静默丢)
            return
        }
        if !force, let last = lastCheckedAt, Date().timeIntervalSince(last) < 12 * 60 * 60 { return }

        isChecking = true
        defer {
            isChecking = false
            if pendingForcedCheck {                  // 兑现被合并的强制请求:重跑一次新检查
                pendingForcedCheck = false
                Task { [weak self] in await self?.performCheck(force: true) }
            }
        }

        do {
            var req = URLRequest(url: apiURL)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("Niche/\(currentVersion)", forHTTPHeaderField: "User-Agent")

            let (data, _) = try await session.data(for: req)
            let resp = try decoder.decode(GitHubReleaseResponse.self, from: data)
            let fetched = Date()

            let remote = Self.normalized(resp.tagName)
            if Self.compare(remote, Self.normalized(currentVersion)) == .orderedDescending {
                latestRelease = ReleaseInfo(
                    version: remote,
                    publishedAt: resp.publishedAt,
                    releasePageURL: resp.htmlURL,
                    downloadURL: Self.downloadURL(from: resp.assets)
                )
            } else {
                latestRelease = nil
            }

            lastCheckedAt = fetched
            defaults.set(fetched, forKey: Keys.lastCheckedAt)
            didLastCheckFail = false
        } catch {
            Log.updates.error("更新检查失败: \(error.localizedDescription, privacy: .public)")
            didLastCheckFail = true
        }
    }

    private static func downloadURL(from assets: [GitHubReleaseAsset]) -> URL? {
        let pairs = assets.map { ($0, $0.name.lowercased()) }
        return pairs.first(where: { $0.1.hasSuffix(".dmg") })?.0.browserDownloadURL
            ?? pairs.first(where: { $0.1.hasSuffix(".zip") })?.0.browserDownloadURL
    }

    private static func normalized(_ v: String) -> String {
        var s = v.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.first?.lowercased() == "v" { s = String(s.dropFirst()) }
        return s
    }

    private static func numericComponents(_ version: String) -> [Int] {
        normalized(version).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    private static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let l = numericComponents(lhs)
        let r = numericComponents(rhs)
        for i in 0..<max(l.count, r.count) {
            let lv = i < l.count ? l[i] : 0
            let rv = i < r.count ? r[i] : 0
            if lv != rv { return lv < rv ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

struct ReleaseInfo: Equatable {
    let version: String
    let publishedAt: Date?
    let releasePageURL: URL
    let downloadURL: URL?

    var displayVersion: String { version.hasPrefix("v") ? version : "v\(version)" }
}

private struct GitHubReleaseResponse: Decodable {
    let tagName: String
    let htmlURL: URL
    let publishedAt: Date?
    let body: String
    let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case body
        case assets
    }
}

private struct GitHubReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: URL
    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

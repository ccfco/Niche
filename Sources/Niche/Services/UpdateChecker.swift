import AppKit
import Combine
import Foundation

/// appcast.xml 轮询式更新检查:检测源与 Sparkle 安装用的是同一份数据(raw.githubusercontent.com
/// 静态 CDN),不打 api.github.com——后者未认证限额 60 次/小时且按 IP 算,共享出口 IP 上
/// 极易被其它流量打满,一旦打满整个检测层(含菜单栏红点、设置页、Sparkle 安装入口)全部瘫痪。
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
    private let session: URLSession
    private let appcastURL = URL(string: "https://raw.githubusercontent.com/ccfco/Niche/main/appcast.xml")!
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

    /// Sparkle 安装闭包，由 AppDelegate.setupSparkle() 注入。
    var installHandler: (() -> Void)?

    /// 触发 Sparkle 一键安装。installHandler 为 nil 只意味着集成断裂（setupSparkle 没跑）——
    /// fail-loud：os_log error + assertionFailure 暴露问题，仍打开下载页让用户不至于卡死
    /// （已记日志 + 断言，不是静默吞异常）。
    func installUpdate() {
        guard let installHandler else {
            Log.updates.error("installUpdate 调用但 installHandler 为 nil — Sparkle setup 缺失")
            assertionFailure("installHandler 未注入；setupSparkle() 必须在启动时运行")
            let target = latestRelease?.downloadURL ?? latestRelease?.releasePageURL ?? releasesURL
            NSWorkspace.shared.open(target)
            return
        }
        installHandler()
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
            var req = URLRequest(url: appcastURL)
            req.setValue("Niche/\(currentVersion)", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let fetched = Date()

            let parser = AppcastParser()
            let xmlParser = XMLParser(data: data)
            xmlParser.delegate = parser
            guard xmlParser.parse() else { throw URLError(.cannotParseResponse) }

            // appcast 可能累积多条历史 item(generate_appcast 不裁剪旧条目);
            // 只数字版本参与比较,挑其中最大的一条——同 GitHub API 时代的非法 tag 防御逻辑。
            let candidate = parser.items
                .compactMap { item -> (version: String, downloadURL: URL, pubDate: Date?)? in
                    guard let version = item.version, Self.isNumericVersion(version),
                          let downloadURL = item.downloadURL else { return nil }
                    return (version, downloadURL, item.pubDate)
                }
                .max { Self.compare($0.version, $1.version) == .orderedAscending }

            if let candidate, Self.compare(candidate.version, Self.normalized(currentVersion)) == .orderedDescending {
                latestRelease = ReleaseInfo(
                    version: candidate.version,
                    publishedAt: candidate.pubDate,
                    releasePageURL: URL(string: "https://github.com/ccfco/Niche/releases/tag/v\(candidate.version)")!,
                    downloadURL: candidate.downloadURL
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

    private static func normalized(_ v: String) -> String {
        var s = v.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.first?.lowercased() == "v" { s = String(s.dropFirst()) }
        return s
    }

    /// 是否为纯数字点分版本（1 / 1.2 / 1.2.0）。拒绝 beta/rc 等非数字段，
    /// 避免 compare 把 1.0.0-beta 误折叠成 1.0.0。
    private static func isNumericVersion(_ version: String) -> Bool {
        !version.isEmpty && version.split(separator: ".").allSatisfy { segment in
            !segment.isEmpty && segment.allSatisfy(\.isNumber)
        }
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

/// Sparkle appcast(标准 RSS + sparkle 命名空间)的最小化解析器,只取 UpdateChecker 需要的三个字段。
/// 不用 shouldProcessNamespaces,elementName 直接拿到 "sparkle:shortVersionString" 这种限定名。
private final class AppcastParser: NSObject, XMLParserDelegate {
    struct Item {
        var version: String?
        var pubDate: Date?
        var downloadURL: URL?
    }

    private(set) var items: [Item] = []
    private var current: Item?
    private var currentElement = ""
    private var pubDateText = ""

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        switch elementName {
        case "item":
            current = Item()
        case "enclosure":
            if let urlString = attributeDict["url"] {
                current?.downloadURL = URL(string: urlString)
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        switch currentElement {
        case "sparkle:shortVersionString":
            let appended = (current?.version ?? "") + string
            current?.version = appended
        case "pubDate":
            pubDateText += string
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "pubDate" {
            current?.pubDate = Self.rfc822Formatter.date(from: pubDateText.trimmingCharacters(in: .whitespacesAndNewlines))
            pubDateText = ""
        }
        if elementName == "sparkle:shortVersionString" {
            let trimmed = current?.version?.trimmingCharacters(in: .whitespacesAndNewlines)
            current?.version = trimmed
        }
        if elementName == "item", let item = current {
            items.append(item)
            current = nil
        }
        // 结束标签后立刻清空,否则标签间的换行/缩进空白会被 foundCharacters 当作
        // 仍在当前标签内、误追加进 version/pubDate(实测踩过:"0.1.3\n            ")。
        currentElement = ""
    }

    private static let rfc822Formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter
    }()
}

import Foundation

// MARK: - GitHub 数据模型（对应 Kotlin GitHubModels）

/// GitHub 仓库信息（也作为账号/组织仓库列表项使用）
struct GitHubRepo {
    let name: String
    let fullName: String
    let description: String?
    let fork: Bool
    /// 仅 fork 仓库有值（API 的 parent.full_name）
    let parentFullName: String?
    let defaultBranch: String
    let language: String?
    let updatedAt: String?
    let pushedAt: String?

    /// 仓库属主（从 fullName = "owner/repo" 拆分）
    var owner: String {
        guard let idx = fullName.firstIndex(of: "/") else { return fullName }
        return String(fullName[..<idx])
    }
}

/// Git Tree 条目（目录或文件）
struct GitHubTreeEntry {
    let path: String
    /// "tree" = 文件夹，"blob" = 文件
    let type: String
    let sha: String
    /// 文件大小（字节）；文件夹条目可能为 nil
    let size: Int64?
    var updatedAt: String? = nil
}

/// GitHub Release 版本
struct GitHubRelease {
    let tagName: String
    let name: String?
    let publishedAt: String?
    let assets: [GitHubAsset]
    let prerelease: Bool
    let draft: Bool
}

/// GitHub Release 资产（可下载文件）
struct GitHubAsset {
    let name: String
    /// browser_download_url
    let downloadUrl: String
    let size: Int64
    let contentType: String?
    let updatedAt: String?
}

// MARK: - 链接解析（对应 Kotlin GitHubLinkParser）

/// GitHub 链接解析结果
enum GitHubLinkType {
    /// 仓库链接；subPath 为 tree/blob/releases 后的路径部分（可空；浏览层与源码一致，进仓库根）
    case repository(owner: String, repo: String, subPath: String?)
    /// 用户 / 组织主页链接
    case account(owner: String)
    /// 文件直链（raw / releases download / github raw），直接下载
    case directFile(url: String, fileName: String)
}

/// 从一段文本中识别 GitHub 链接。匹配优先级：DirectFile > Repository > Account。
enum GitHubLinkParser {
    /// github.com 本身的功能/营销页路径，不应识别为账号
    private static let specialPaths: Set<String> = [
        "features", "topics", "trending", "collections", "events", "sponsors",
        "about", "pricing", "login", "signup", "join", "marketplace", "explore",
        "notifications", "settings", "new", "orgs", "sites", "customer-stories",
        "team", "enterprise", "readme", "contact", "security", "resources"
    ]

    static func parse(_ text: String) -> GitHubLinkType? {
        guard let url = firstURL(in: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }

        // 1) 文件直链（优先级最高）
        if let m = find(#"raw\.githubusercontent\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/[^/]+/(.+)"#, in: url),
           let name = fileNameOf(m[3]) {
            return .directFile(url: url, fileName: name)
        }
        if let m = find(#"github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/releases/download/[^/]+/(.+)"#, in: url),
           let name = fileNameOf(m[3]) {
            return .directFile(url: url, fileName: name)
        }
        if let m = find(#"github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/raw/[^/]+/(.+)"#, in: url),
           let name = fileNameOf(m[3]) {
            return .directFile(url: url, fileName: name)
        }

        // 2) 仓库链接
        if let m = find(#"github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)(?:/(.*))?"#, in: url) {
            let owner = m[1]
            if specialPaths.contains(owner.lowercased()) { return nil }
            let repo = m[2]
            var subPath: String? = nil
            if m.count > 3 {
                let cleaned = m[3].split(separator: "?").first.map(String.init) ?? m[3]
                let noFrag = cleaned.split(separator: "#").first.map(String.init) ?? cleaned
                if !noFrag.isEmpty { subPath = noFrag }
            }
            return .repository(owner: owner, repo: repo, subPath: subPath)
        }

        // 3) 账号 / 组织链接
        if let m = find(#"github\.com/([A-Za-z0-9_.-]+)/?(?:[?#]|$)"#, in: url) {
            let owner = m[1]
            if specialPaths.contains(owner.lowercased()) { return nil }
            return .account(owner: owner)
        }

        return nil
    }

    /// 取文本中第一个 URL，并去掉尾部中英文标点（与 ShareLinkParser 同规则）
    private static func firstURL(in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"https?://[^\s]+"#),
              let m = re.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range, in: text) else { return nil }
        var url = String(text[r])
        let trailing = Set("。，,；;)]}'\"")
        while let last = url.last, trailing.contains(last) { url.removeLast() }
        return url
    }

    /// 正则搜索（不区分大小写），返回各捕获组字符串（无捕获组的位置以 "" 占位与 Kotlin groupValues 对齐）
    private static func find(_ pattern: String, in text: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) else { return nil }
        var groups: [String] = []
        for i in 0..<m.numberOfRanges {
            if let r = Range(m.range(at: i), in: text) { groups.append(String(text[r])) }
            else { groups.append("") }
        }
        return groups
    }

    /// 从路径段取最后一段作为文件名，去掉 query/fragment；空则返回 nil
    private static func fileNameOf(_ path: String) -> String? {
        let clean = (path.split(separator: "?").first.map(String.init) ?? path)
        let noFrag = clean.split(separator: "#").first.map(String.init) ?? clean
        let name = noFrag.split(separator: "/").last.map(String.init) ?? ""
        return name.isEmpty ? nil : name
    }
}

// MARK: - GitHub REST API（对应 Kotlin GitHubApi）

/// validateToken 的校验结果（对应 Kotlin TokenCheck）
enum GitHubTokenCheck {
    case valid(login: String)
    /// GitHub 明确拒绝（HTTP 401）
    case invalid
    /// 无法判定（网络异常等）
    case unknown
}

/**
 * GitHub REST API 封装（匿名 / 可选 Token）。
 * - 未配置 Token：限额 60 次/小时/IP；配置 Token：5000 次/小时；
 * - Token 仅用于提升限额，不用于登录态；严禁打印到日志；
 * - 所有方法失败（网络异常 / 非 2xx / 解析失败）返回 nil（与 Kotlin 一致，不抛错）。
 *
 * 与 Kotlin 的差异：响应缓存简化为进程内内存缓存（成功 120 秒），
 * Kotlin 的 GitHubResponseCache 是带失败短 TTL 的统一缓存（详见集成说明）。
 */
final class GitHubAPI {
    static let shared = GitHubAPI()
    private init() {}

    /// 可选 Token（集成层注入；nil/空 = 匿名）
    var token: String?
    /// 携带的 Token 被 GitHub 拒绝（HTTP 401）时回调，只回调一次（上层据此清除 Token 恢复匿名）
    var onUnauthorized: (() -> Void)?

    private var unauthorizedNotified = false

    // 进程内内存缓存：key → (响应文本, 存入时间)
    private var cache: [String: (body: String, at: Date)] = [:]
    private let cacheLock = NSLock()
    private static let cacheTTL: TimeInterval = 120

    private func noteResponseCode(_ code: Int) {
        if code != 401 || unauthorizedNotified { return }
        unauthorizedNotified = true
        cacheLock.lock()
        cache.removeAll()
        cacheLock.unlock()
        onUnauthorized?()
    }

    private func tokenFingerprint() -> String {
        guard let token = token, !token.isEmpty else { return "anon" }
        return String(wMD5Hex(token).prefix(8))
    }

    /// 获取单个仓库信息：GET /repos/{owner}/{repo}
    func getRepo(owner: String, repo: String) async -> GitHubRepo? {
        guard let raw = await cachedBody(key: "repo:\(owner)/\(repo)",
                                         url: "https://api.github.com/repos/\(owner)/\(repo)"),
              let json = wJSONObj(Data(raw.utf8)) else { return nil }
        return parseRepo(json)
    }

    /// 获取目录树（仅当前层，**不加 recursive=1**）：GET /repos/{owner}/{repo}/git/trees/{sha}
    func getTree(owner: String, repo: String, sha: String) async -> [GitHubTreeEntry]? {
        guard let raw = await cachedBody(key: "tree:\(owner)/\(repo)/\(sha)",
                                         url: "https://api.github.com/repos/\(owner)/\(repo)/git/trees/\(sha)"),
              let json = wJSONObj(Data(raw.utf8)) else { return nil }
        return json.wObjs("tree").map { o in
            GitHubTreeEntry(
                path: o.wStr("path"),
                type: o.wStr("type"),
                sha: o.wStr("sha"),
                size: o.wHas("size") && !(o["size"] is NSNull) ? o.wLong("size") : nil
            )
        }
    }

    /// Releases 列表（分页，per_page=100）
    func getReleases(owner: String, repo: String, page: Int = 1) async -> [GitHubRelease]? {
        guard let raw = await cachedBody(key: "releases:\(owner)/\(repo):\(page)",
                                         url: "https://api.github.com/repos/\(owner)/\(repo)/releases?per_page=100&page=\(page)"),
              let arr = wJSONArr(Data(raw.utf8)) else { return nil }
        return arr.map(parseRelease)
    }

    /// 用户公开仓库列表（分页，sort=updated）
    func getUserRepos(owner: String, page: Int = 1) async -> [GitHubRepo]? {
        guard let raw = await cachedBody(key: "userrepos:\(owner):\(page):\(tokenFingerprint())",
                                         url: "https://api.github.com/users/\(owner)/repos?per_page=100&page=\(page)&sort=updated"),
              let arr = wJSONArr(Data(raw.utf8)) else { return nil }
        return arr.map(parseRepo)
    }

    /// 组织公开仓库列表（分页，sort=updated）
    func getOrgRepos(owner: String, page: Int = 1) async -> [GitHubRepo]? {
        guard let raw = await cachedBody(key: "orgrepos:\(owner):\(page):\(tokenFingerprint())",
                                         url: "https://api.github.com/orgs/\(owner)/repos?per_page=100&page=\(page)&sort=updated"),
              let arr = wJSONArr(Data(raw.utf8)) else { return nil }
        return arr.map(parseRepo)
    }

    /// 判断 owner 是用户还是组织：GET /users/{owner} 取 type（"User" / "Organization"）
    func getUserType(owner: String) async -> String? {
        guard let raw = await cachedBody(key: "usertype:\(owner)",
                                         url: "https://api.github.com/users/\(owner)"),
              let json = wJSONObj(Data(raw.utf8)) else { return nil }
        let type = json.wStr("type")
        return type.isEmpty ? nil : type
    }

    /// 当前 Token 对应用户的登录名：GET /user 取 login
    func getUserLogin() async -> String? {
        guard let raw = await cachedBody(key: "userlogin:\(tokenFingerprint())",
                                         url: "https://api.github.com/user"),
              let json = wJSONObj(Data(raw.utf8)) else { return nil }
        let login = json.wStr("login")
        return login.isEmpty ? nil : login
    }

    /// 校验一个**尚未保存**的 Token：GET /user（不走缓存）
    func validateToken(_ token: String) async -> GitHubTokenCheck {
        var req = Wave2HTTP.request(url: "https://api.github.com/user", headers: [
            "User-Agent": "YunX",
            "Accept": "application/vnd.github+json",
            "Authorization": "Bearer \(token)"
        ])
        req.httpMethod = "GET"
        guard let raw = try? await Wave2HTTP.send(req) else { return .unknown }
        if !(200..<300).contains(raw.http.statusCode) {
            return raw.http.statusCode == 401 ? .invalid : .unknown
        }
        guard let json = wJSONObj(raw.data) else { return .unknown }
        let login = json.wStr("login")
        return login.isEmpty ? .unknown : .valid(login: login)
    }

    /**
     * 仓库 README 原文：优先 API（Accept: application/vnd.github.raw），
     * 失败兜底 raw.githubusercontent.com/{owner}/{repo}/{defaultBranch}/README.md。
     */
    func getReadme(owner: String, repo: String, defaultBranch: String) async -> String? {
        let key = "readme:\(owner)/\(repo)/\(defaultBranch)"
        if let cached = cacheGet(key) { return cached }
        var headers = [
            "User-Agent": "YunX",
            "Accept": "application/vnd.github.raw"
        ]
        if let token = token, !token.isEmpty { headers["Authorization"] = "Bearer \(token)" }
        let apiReq = Wave2HTTP.request(url: "https://api.github.com/repos/\(owner)/\(repo)/readme", headers: headers)
        if let raw = try? await Wave2HTTP.send(apiReq) {
            noteResponseCode(raw.http.statusCode)
            if (200..<300).contains(raw.http.statusCode) && !raw.text.isEmpty {
                if raw.data.count <= 128 * 1024 { cachePut(key, raw.text) }
                return raw.text
            }
        }
        let fallbackReq = buildRequest(url: "https://raw.githubusercontent.com/\(owner)/\(repo)/\(defaultBranch)/README.md")
        if let raw = try? await Wave2HTTP.send(fallbackReq), (200..<300).contains(raw.http.statusCode), !raw.text.isEmpty {
            if raw.data.count <= 128 * 1024 { cachePut(key, raw.text) }
            return raw.text
        }
        return nil
    }

    /// 某路径最后一次提交时间（ISO8601）：GET /commits?path=&per_page=1 取 [0].commit.committer.date
    func getLastCommitDate(owner: String, repo: String, path: String) async -> String? {
        let url = "https://api.github.com/repos/\(owner)/\(repo)/commits?path=\(wFormEncode(path))&per_page=1"
        guard let raw = try? await Wave2HTTP.send(buildRequest(url: url)) else { return nil }
        noteResponseCode(raw.http.statusCode)
        guard (200..<300).contains(raw.http.statusCode), let arr = wJSONArr(raw.data),
              let first = arr.first else { return nil }
        let date = first.wObj("commit")?.wObj("committer")?.wStr("date") ?? ""
        return date.isEmpty ? nil : date
    }

    // MARK: 内部解析

    private func parseRepo(_ o: [String: Any]) -> GitHubRepo {
        GitHubRepo(
            name: o.wStr("name"),
            fullName: o.wStr("full_name"),
            description: o.wStr("description").isEmpty ? nil : o.wStr("description"),
            fork: o.wBool("fork"),
            parentFullName: {
                let parent = o.wObj("parent")?.wStr("full_name") ?? ""
                return parent.isEmpty ? nil : parent
            }(),
            defaultBranch: o.wStr("default_branch").isEmpty ? "main" : o.wStr("default_branch"),
            language: o.wStr("language").isEmpty ? nil : o.wStr("language"),
            updatedAt: o.wStr("updated_at").isEmpty ? nil : o.wStr("updated_at"),
            pushedAt: o.wStr("pushed_at").isEmpty ? nil : o.wStr("pushed_at")
        )
    }

    private func parseRelease(_ o: [String: Any]) -> GitHubRelease {
        GitHubRelease(
            tagName: o.wStr("tag_name"),
            name: o.wStr("name").isEmpty ? nil : o.wStr("name"),
            publishedAt: o.wStr("published_at").isEmpty ? nil : o.wStr("published_at"),
            assets: o.wObjs("assets").map { a in
                GitHubAsset(
                    name: a.wStr("name"),
                    downloadUrl: a.wStr("browser_download_url"),
                    size: a.wLong("size"),
                    contentType: a.wStr("content_type").isEmpty ? nil : a.wStr("content_type"),
                    updatedAt: a.wStr("updated_at").isEmpty ? nil : a.wStr("updated_at")
                )
            },
            prerelease: o.wBool("prerelease"),
            draft: o.wBool("draft")
        )
    }

    // MARK: 请求执行与缓存

    private func buildRequest(url: String) -> URLRequest {
        var headers = [
            "User-Agent": "YunX",
            "Accept": "application/vnd.github+json"
        ]
        if let token = token, !token.isEmpty { headers["Authorization"] = "Bearer \(token)" }
        return Wave2HTTP.request(url: url, headers: headers)
    }

    private func cacheGet(_ key: String) -> String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let entry = cache[key], Date().timeIntervalSince(entry.at) < GitHubAPI.cacheTTL else { return nil }
        return entry.body
    }

    private func cachePut(_ key: String, _ body: String) {
        cacheLock.lock()
        cache[key] = (body, Date())
        cacheLock.unlock()
    }

    /// 走内存缓存取响应文本；非 2xx / 空 body 返回 nil
    private func cachedBody(key: String, url: String) async -> String? {
        if let cached = cacheGet(key) { return cached }
        guard let raw = try? await Wave2HTTP.send(buildRequest(url: url)) else { return nil }
        noteResponseCode(raw.http.statusCode)
        guard (200..<300).contains(raw.http.statusCode), !raw.data.isEmpty else { return nil }
        cachePut(key, raw.text)
        return raw.text
    }
}

// MARK: - GitHub 下载镜像（对应 Kotlin GitHubMirror）

/**
 * GitHub 下载镜像统一入口（gh-proxy 系）。
 * 生效规则（activePrefix）：1. 用户固定前缀 → 用它；2. 否则最近一次测速最快者；
 * 3. 都没有 → 预选池第一个。
 *
 * 与 Kotlin 的差异：Kotlin 用 OkHttp EventListener 单独量 TCP 建连 ping，
 * URLSession 没有等价回调，这里只量吞吐（速度从响应头到达后起算），不产出 ping；
 * 测速结果/最快前缀持久化在 UserDefaults（Kotlin 在 SettingsRepository）。
 */
enum GitHubMirror {
    /// 内置预选镜像前缀池（顺序与源码一致）
    static let presets = [
        "https://v4.gh-proxy.org/",
        "https://v6.gh-proxy.org/",
        "https://gh-proxy.org/",
        "https://cdn.gh-proxy.org/",
        "https://axisnow.gh-proxy.org/"
    ]

    /// 测速样本：GyanD/codexffmpeg 固定版本 Release 资产（约 88MB，支持 Range）
    private static let probeURL =
        "https://github.com/GyanD/codexffmpeg/releases/download/7.1/ffmpeg-7.1-essentials_build.zip"
    private static let probeUA = "YunX-Desktop"
    /// 测速分片大小（256KB）
    private static let probeBytes = 256 * 1024
    /// 单个镜像测速硬超时（秒）
    private static let probeTimeout: TimeInterval = 8
    /// 自动测速结果有效期（6 小时）
    private static let ttlMs: Int64 = 6 * 60 * 60 * 1000

    private static let fixedKey = "github_mirror_prefix"
    private static let fastestKey = "github_mirror_fastest"
    private static let probedAtKey = "github_mirror_probed_at"

    /// 单个镜像的测速结果（speedBps 为 nil = 失败/超时/不支持 Range）
    struct Probe {
        let prefix: String
        let speedBps: Int64?
        var ok: Bool { speedBps != nil }
    }

    /// 用户固定的镜像前缀（集成层设置页读写；nil/空 = 自动）
    static var userFixedPrefix: String? {
        get {
            let value = UserDefaults.standard.string(forKey: fixedKey) ?? ""
            return value.isEmpty ? nil : value
        }
        set {
            if let value = newValue, !value.isEmpty {
                UserDefaults.standard.set(value, forKey: fixedKey)
            } else {
                UserDefaults.standard.removeObject(forKey: fixedKey)
            }
        }
    }

    /// 最近一次测速中最快的镜像（持久化值兜底）
    static func fastestPrefix() -> String? {
        if let fastest = probeResults.filter({ $0.ok }).max(by: { ($0.speedBps ?? 0) < ($1.speedBps ?? 0) }) {
            return fastest.prefix
        }
        let saved = UserDefaults.standard.string(forKey: fastestKey) ?? ""
        return saved.isEmpty ? nil : saved
    }

    /// 当前生效的镜像前缀
    static func activePrefix() -> String {
        if let fixed = userFixedPrefix { return fixed }
        return fastestPrefix() ?? presets[0]
    }

    /// 给原始 GitHub 直链拼镜像前缀（下载失败时集成层回退未拼前缀的原链）
    static func mirrorUrl(_ url: String) -> String {
        activePrefix() + url
    }

    /// 本轮测速结果（进程内）
    private(set) static var probeResults: [Probe] = []
    private static var probing = false

    /// 启动时调用：测速结果过期（或从未测过）时异步刷新一次
    static func ensureFresh() {
        let probedAt = Int64(UserDefaults.standard.double(forKey: probedAtKey) * 1000)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        if now - probedAt > ttlMs {
            Task { await refresh() }
        }
    }

    /// 触发一次全量测速（并发探测全部预选镜像），最快者持久化；重复调用忽略
    static func refresh() async {
        if probing { return }
        probing = true
        defer { probing = false }
        var results: [Probe] = []
        await withTaskGroup(of: Probe.self) { group in
            for prefix in presets {
                group.addTask { await probe(prefix) }
            }
            for await result in group { results.append(result) }
        }
        // 保持预选池顺序展示
        probeResults = presets.compactMap { prefix in results.first(where: { $0.prefix == prefix }) }
        let fastest = probeResults.filter { $0.ok }.max(by: { ($0.speedBps ?? 0) < ($1.speedBps ?? 0) })
        if let fastest = fastest {
            UserDefaults.standard.set(fastest.prefix, forKey: fastestKey)
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: probedAtKey)
    }

    /// 探测单个镜像：Range 拉 256KB，速度 = 字节数 / 响应头到达后的耗时（纯吞吐）
    private static func probe(_ prefix: String) async -> Probe {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = probeTimeout
        config.timeoutIntervalForResource = probeTimeout
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: URL(string: prefix + probeURL)!)
        req.setValue(probeUA, forHTTPHeaderField: "User-Agent")
        req.setValue("bytes=0-\(probeBytes - 1)", forHTTPHeaderField: "Range")
        do {
            let (bytes, response) = try await session.bytes(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 206 else {
                return Probe(prefix: prefix, speedBps: nil)
            }
            let startedAt = Date()
            var read = 0
            for try await _ in bytes {
                read += 1
                if read >= probeBytes { break }
            }
            let elapsedMs = Int64(Date().timeIntervalSince(startedAt) * 1000)
            let speed = (read > 0 && elapsedMs > 0) ? Int64(read) * 1000 / elapsedMs : nil
            return Probe(prefix: prefix, speedBps: speed)
        } catch {
            return Probe(prefix: prefix, speedBps: nil)
        }
    }
}

/// GitHub 浏览会话（平台私有会话，不用 Models 的 ShareSession）
struct GitHubSession {
    let shareId: String
    let stoken: String
    let title: String
}

// MARK: - GitHub 浏览层（对应 Kotlin ResolveViewModel 的 GitHub fid 方案）

/**
 * GitHub 浏览状态机：把仓库/账号映射成 ShareFile 列表，fid 方案与 Kotlin 编排层逐字一致：
 * - 仓库会话 shareId = `github:<owner/repo>`，根目录 fid = `github:root`，
 *   根下两项：`github:code:<默认分支>`（代码）、`github:releases`；
 * - 代码目录：文件夹 `github:code:<tree sha>`、文件 `github:file:<仓库内路径>`，
 *   根代码目录首项 `github:zip`（下载完整源码 ZIP）；fsize 未知为 -1；
 * - Releases：`github:release:<tag>`、资产 `github:asset:<browser_download_url>`、
 *   分页哨兵 `github:more_rel:<下一页>`；
 * - 账号会话 shareId = `github:user:<owner>`，根 fid = `github:account_root`，
 *   仓库项 `github:repo:<fullName>`、分页哨兵 `github:more_acct:<下一页>`；
 * - 直链会话 shareId = `github:direct`，open 时直接给出 DownloadLink。
 */
final class GitHubBrowse {
    private let api: GitHubAPI

    private(set) var currentRepo: GitHubRepo?
    private(set) var currentOwner: String?
    private var ownerType: String?
    private var releasesAccum: [GitHubRelease] = []
    private var reposAccum: [GitHubRepo] = []
    private var directFileURL: String = ""

    init(api: GitHubAPI = .shared) {
        self.api = api
    }

    struct OpenResult {
        let session: GitHubSession
        /// 进入后应加载的根目录 fid（直链时为空串）
        let rootFid: String
        /// 直链文件时直接给出（不进列表）
        let directLink: DownloadLink?
    }

    /// 打开一个 GitHub 链接（对应 startGitHubResolve；仓库 subPath 与源码一致不深进、统一进根）
    func open(link: GitHubLinkType) async throws -> OpenResult {
        currentRepo = nil
        currentOwner = nil
        ownerType = nil
        releasesAccum = []
        reposAccum = []
        switch link {
        case .repository(let owner, let repo, _):
            guard let info = await api.getRepo(owner: owner, repo: repo) else {
                throw Wave2Error("无法获取仓库信息：\(owner)/\(repo)")
            }
            currentRepo = info
            return OpenResult(
                session: GitHubSession(shareId: "github:\(info.fullName)", stoken: "", title: info.fullName),
                rootFid: "github:root",
                directLink: nil
            )
        case .account(let owner):
            currentOwner = owner
            return OpenResult(
                session: GitHubSession(shareId: "github:user:\(owner)", stoken: "", title: owner),
                rootFid: "github:account_root",
                directLink: nil
            )
        case .directFile(let url, let fileName):
            directFileURL = url
            return OpenResult(
                session: GitHubSession(shareId: "github:direct", stoken: "", title: fileName),
                rootFid: "",
                directLink: DownloadLink(fid: "github:direct", filename: fileName, downloadUrl: url, size: -1)
            )
        }
    }

    /// 按 fid 加载一层目录（对应 loadGitHubDir 分发 + more/repo 的处理）
    func listDir(fid: String) async throws -> [ShareFile] {
        if fid == "github:root" { return rootEntries() }
        if fid.hasPrefix("github:code:") {
            return try await codeDir(sha: String(fid.dropFirst("github:code:".count)))
        }
        if fid == "github:releases" { return try await releasesPage(page: 1, first: true) }
        if fid.hasPrefix("github:more_rel:") {
            let page = Int(fid.dropFirst("github:more_rel:".count)) ?? 1
            return try await releasesPage(page: page, first: false)
        }
        if fid.hasPrefix("github:release:") {
            return releaseAssets(tag: String(fid.dropFirst("github:release:".count)))
        }
        if fid == "github:account_root" { return try await accountPage(page: 1, first: true) }
        if fid.hasPrefix("github:more_acct:") {
            let page = Int(fid.dropFirst("github:more_acct:".count)) ?? 1
            return try await accountPage(page: page, first: false)
        }
        if fid.hasPrefix("github:repo:") {
            let fullName = String(fid.dropFirst("github:repo:".count))
            let owner = fullName.split(separator: "/").first.map(String.init) ?? ""
            let name = fullName.split(separator: "/").dropFirst().first.map(String.init) ?? ""
            guard let info = await api.getRepo(owner: owner, repo: name) else {
                throw Wave2Error("无法获取仓库信息：\(fullName)")
            }
            currentRepo = info
            releasesAccum = []
            return rootEntries()
        }
        throw Wave2Error("未知的 GitHub 目录：\(fid)")
    }

    /// 仓库根目录：代码 + Releases 两个文件夹
    func rootEntries() -> [ShareFile] {
        guard let repo = currentRepo else { return [] }
        return [
            ShareFile(fid: "github:code:\(repo.defaultBranch)", fname: "代码", fsize: -1,
                      isdir: true, pdirFid: "", fidToken: "", modifyTime: repo.pushedAt ?? ""),
            ShareFile(fid: "github:releases", fname: "Releases", fsize: -1,
                      isdir: true, pdirFid: "", fidToken: "", modifyTime: "")
        ]
    }

    /// 代码目录：tree（不 recursive）映射为文件夹/文件；根代码目录首项加源码 ZIP
    func codeDir(sha: String) async throws -> [ShareFile] {
        guard let repo = currentRepo else { throw Wave2Error("加载目录失败") }
        guard let entries = await api.getTree(owner: repo.owner, repo: repo.name, sha: sha) else {
            throw Wave2Error("加载目录失败")
        }
        var files: [ShareFile] = []
        if sha == repo.defaultBranch {
            files.append(ShareFile(fid: "github:zip", fname: "下载完整源码 ZIP", fsize: -1,
                                   isdir: false, pdirFid: "", fidToken: "",
                                   modifyTime: repo.pushedAt ?? ""))
        }
        for entry in entries {
            let displayName = entry.path.split(separator: "/").last.map(String.init) ?? entry.path
            if entry.type == "tree" {
                files.append(ShareFile(fid: "github:code:\(entry.sha)", fname: displayName, fsize: -1,
                                       isdir: true, pdirFid: "", fidToken: "", modifyTime: ""))
            } else {
                files.append(ShareFile(fid: "github:file:\(entry.path)", fname: displayName,
                                       fsize: entry.size ?? -1, isdir: false, pdirFid: "",
                                       fidToken: "", modifyTime: ""))
            }
        }
        return files
    }

    /// Releases 分页（累加，按 tag 去重；满页追加「加载更多」哨兵）
    func releasesPage(page: Int, first: Bool) async throws -> [ShareFile] {
        guard let repo = currentRepo else { throw Wave2Error("加载 Releases 失败") }
        if first { releasesAccum = [] }
        let rels = await api.getReleases(owner: repo.owner, repo: repo.name, page: page)
        if rels == nil && first { throw Wave2Error("加载 Releases 失败") }
        if let rels = rels {
            var seen = Set(releasesAccum.map { $0.tagName })
            releasesAccum += rels.filter { seen.insert($0.tagName).inserted }
        }
        var files = releasesAccum.map { rel in
            ShareFile(fid: "github:release:\(rel.tagName)", fname: rel.tagName, fsize: -1,
                      isdir: true, pdirFid: "", fidToken: "", modifyTime: rel.publishedAt ?? "")
        }
        if let rels = rels, rels.count == 100 {
            files.append(ShareFile(fid: "github:more_rel:\(page + 1)", fname: "加载更多", fsize: -1,
                                   isdir: true, pdirFid: "", fidToken: "", modifyTime: ""))
        }
        return files
    }

    /// 单个 Release 的资产列表（从已累加的 releases 里按 tag 找）
    func releaseAssets(tag: String) -> [ShareFile] {
        guard let rel = releasesAccum.first(where: { $0.tagName == tag }) else { return [] }
        return rel.assets.map { asset in
            ShareFile(fid: "github:asset:\(asset.downloadUrl)", fname: asset.name, fsize: asset.size,
                      isdir: false, pdirFid: "", fidToken: "", modifyTime: asset.updatedAt ?? "")
        }
    }

    /// 账号/组织仓库列表：先用 /users/{owner} 的 type 选端点；分页累加；满页加哨兵
    func accountPage(page: Int, first: Bool) async throws -> [ShareFile] {
        guard let owner = currentOwner else { throw Wave2Error("无法获取仓库列表") }
        if first {
            reposAccum = []
            ownerType = nil
        }
        if ownerType == nil { ownerType = await api.getUserType(owner: owner) }
        var repos: [GitHubRepo]?
        if ownerType == "Organization" {
            repos = await api.getOrgRepos(owner: owner, page: page)
        } else {
            repos = await api.getUserRepos(owner: owner, page: page)
            if repos == nil { repos = await api.getOrgRepos(owner: owner, page: page) }
        }
        if repos == nil && page == 1 { throw Wave2Error("无法获取 \(owner) 的仓库列表") }
        if let repos = repos {
            var seen = Set(reposAccum.map { $0.fullName })
            reposAccum += repos.filter { seen.insert($0.fullName).inserted }
        }
        var files = reposAccum.map { repo in
            ShareFile(fid: "github:repo:\(repo.fullName)", fname: repo.name, fsize: -1,
                      isdir: true, pdirFid: "", fidToken: "", modifyTime: repo.updatedAt ?? "")
        }
        if let repos = repos, repos.count == 100 {
            files.append(ShareFile(fid: "github:more_acct:\(page + 1)", fname: "加载更多", fsize: -1,
                                   isdir: true, pdirFid: "", fidToken: "", modifyTime: ""))
        }
        return files
    }

    /**
     * 按 fid 计算下载目标（对应 githubUrlForFid + 镜像转换）：
     * 返回 (镜像后的下载 URL, 未镜像的原始 URL 作 fallback)。无法识别返回 nil。
     * GitHub 下载不需要额外请求头。
     */
    func downloadTarget(for file: ShareFile) -> (url: String, fallbackUrl: String)? {
        guard let raw = rawURL(forFid: file.fid) else { return nil }
        return (GitHubMirror.mirrorUrl(raw), raw)
    }

    /// fid → 未镜像的 GitHub 直链
    func rawURL(forFid fid: String) -> String? {
        if fid == "github:direct" { return directFileURL.isEmpty ? nil : directFileURL }
        if fid.hasPrefix("github:asset:") { return String(fid.dropFirst("github:asset:".count)) }
        guard let repo = currentRepo else { return nil }
        if fid == "github:zip" {
            return "https://codeload.github.com/\(repo.owner)/\(repo.name)/zip/refs/heads/\(repo.defaultBranch)"
        }
        if fid.hasPrefix("github:file:") {
            let path = String(fid.dropFirst("github:file:".count))
            return "https://raw.githubusercontent.com/\(repo.owner)/\(repo.name)/\(repo.defaultBranch)/\(GitHubBrowse.encodePath(path))"
        }
        return nil
    }

    /// 递归收集某代码目录下全部 blob（批量下载用；对应 collectGitHubBlobs，深度上限 32）
    func collectAllFiles(sha: String, prefix: String = "", depth: Int = 0) async -> [(path: String, size: Int64)] {
        guard depth < 32, let repo = currentRepo,
              let entries = await api.getTree(owner: repo.owner, repo: repo.name, sha: sha) else { return [] }
        var out: [(path: String, size: Int64)] = []
        for entry in entries {
            if entry.type == "tree" {
                out += await collectAllFiles(sha: entry.sha, prefix: prefix, depth: depth + 1)
            } else {
                out.append((entry.path, entry.size ?? -1))
            }
        }
        return out
    }

    /// 对 raw 直链路径逐段 URL 编码（保留 `/`；与源码一致用 URLEncoder 语义，空格变 `+`）
    static func encodePath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { wFormEncode(String($0)) }
            .joined(separator: "/")
    }
}

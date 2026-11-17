import Foundation

/// 百度网盘 API 封装（URLSession），移植自 Kotlin BaiduApi + BaiduResolveRepository。
///
/// 与 Kotlin 版的行为对齐要点：
/// - 所有业务请求手动带 Cookie 头，不使用系统 Cookie 存储；
/// - errno=8888（限流）自动重试 3 次、间隔 2 秒（对应 Kotlin executeJson）；
/// - 分享解析：有提取码先 verify 换 sekey（randsk），公共分享跳过 verify、sekey 为空；
/// - 取链必须登录：游客只能浏览列表。登录后走「转存到 YunX临时转存 → locatedownload 取高速直链
///   → 立即删除转存文件」（appall 直链自带签名，删后仍有效）；
/// - 下载请求头只有 Cookie + netdisk UA（对应 Kotlin ResolveViewModel.enqueueDownload 百度分支）。
/// 错误统一用 QuarkError 承载（Kotlin 侧为独立的 BaiduApiException，Swift 侧统一）。
final class BaiduAPI {
    static let shared = BaiduAPI()

    // MARK: - 常量（对应 Kotlin BaiduConstants）

    static let appId = "250528"
    static let uaWeb = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    /// 下载直链专用 UA（百度网盘安卓客户端串），取链与下载都用它
    static let uaNetdisk = "netdisk;12.24.6;piano;android-android;16;JSbridge4.4.0;jointBridge;1.1.0"

    /// 临时转存目录名（与 Kotlin 版一致）
    private static let tempDirName = "YunX临时转存"
    private static let tempDirPath = "/YunX临时转存"

    /// 分享列表翻页：单页 100、安全上限 100 页（Kotlin BaiduResolveRepository）
    private static let listPageSize = 100
    private static let listMaxPages = 100

    // MARK: - 基础设施

    /// 禁用系统 Cookie 存储：Cookie 全部手工管理，与 Kotlin 版一致
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    /// bdstoken 实例缓存（对应 Kotlin BaiduApi.bdstokenCache）
    private var bdstokenCache: String?
    /// 列表时缓存的 share_id/uk（surl → (shareId, uk)），转存时复用
    private var shareInfos: [String: (shareId: String, uk: String)] = [:]

    private init() {}

    private struct RawResponse {
        let data: Data
        let http: HTTPURLResponse
    }

    private func send(_ request: URLRequest) async throws -> RawResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw QuarkError("请求失败：无响应")
        }
        return RawResponse(data: data, http: http)
    }

    // MARK: - JSON 小工具（容忍 errno 等字段以字符串形式返回）

    private func jsonString(_ dict: [String: Any], _ key: String) -> String {
        if let s = dict[key] as? String { return s }
        if let n = dict[key] as? NSNumber { return n.stringValue }
        return ""
    }

    private func jsonInt(_ dict: [String: Any], _ key: String) -> Int {
        if let n = dict[key] as? NSNumber { return n.intValue }
        if let s = dict[key] as? String { return Int(s) ?? 0 }
        return 0
    }

    private func jsonLong(_ dict: [String: Any], _ key: String) -> Int64 {
        if let n = dict[key] as? NSNumber { return n.int64Value }
        if let s = dict[key] as? String { return Int64(s) ?? 0 }
        return 0
    }

    /// byte 级对齐 Java URLEncoder.encode(s, "UTF-8")：
    /// 安全字节为 A-Za-z0-9 与 `-._*`，空格 → `+`，其余按 UTF-8 字节 %XX（大写十六进制）。
    /// 百度 form body 与查询参数都用这套编码（与 Swift 默认的 addingPercentEncoding 语义不同）。
    private func formEncode(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for byte in s.utf8 {
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x2E, 0x5F, 0x2A: // 0-9 A-Z a-z - . _ *
                out.append(Character(UnicodeScalar(byte)))
            case 0x20:
                out.append("+")
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    /// 执行请求并解析 JSON；errno=8888（限流）自动重试 3 次、间隔 2 秒，
    /// 重试时补 Accept / Accept-Language 头（对应 Kotlin executeJson）。
    /// 请求由闭包按「是否重试」重新构造（URLRequest 是值类型，可安全复制修改）。
    private func executeJson(build: (Bool) -> URLRequest) async throws -> [String: Any] {
        var retries = 0
        while true {
            let raw = try await send(build(retries > 0))
            guard let obj = (try? JSONSerialization.jsonObject(with: raw.data)) as? [String: Any] else {
                throw QuarkError("响应解析失败（HTTP \(raw.http.statusCode)）")
            }
            if jsonInt(obj, "errno") == 8888 && retries < 3 {
                retries += 1
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                continue
            }
            return obj
        }
    }

    /// errno 校验（对应 Kotlin checkErrno）：msg 取 err_msg → show_msg → fallback
    private func checkErrno(_ obj: [String: Any], fallback: String) throws {
        let errno = jsonInt(obj, "errno")
        if errno != 0 {
            var msg = jsonString(obj, "err_msg")
            if msg.isEmpty { msg = jsonString(obj, "show_msg") }
            if msg.isEmpty { msg = fallback }
            throw QuarkError("\(msg)（errno=\(errno)）", code: errno)
        }
    }

    private func baseRequest(url: String, cookie: String, ua: String) -> URLRequest {
        var req = URLRequest(url: URL(string: url)!)
        if !cookie.isEmpty { req.setValue(cookie, forHTTPHeaderField: "Cookie") }
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        return req
    }

    /// 给请求补限流重试用的额外头
    private func withRetryHeaders(_ req: URLRequest, isRetry: Bool) -> URLRequest {
        guard isRetry else { return req }
        var r = req
        r.setValue("*/*", forHTTPHeaderField: "Accept")
        r.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        return r
    }

    // MARK: - 账号

    /// gettemplatevariable：取 result 字段（username / bdstoken）；errno≠0 返回 nil
    private func templateVariable(fields: [String], cookie: String) async -> [String: Any]? {
        let fieldsJson = "[" + fields.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        let url = "https://pan.baidu.com/api/gettemplatevariable?clienttype=0&app_id=\(BaiduAPI.appId)&web=1&fields=\(formEncode(fieldsJson))"
        guard let obj = try? await executeJson(build: { retry in
            self.withRetryHeaders(self.baseRequest(url: url, cookie: cookie, ua: BaiduAPI.uaWeb), isRetry: retry)
        }), jsonInt(obj, "errno") == 0 else { return nil }
        return obj["result"] as? [String: Any]
    }

    /// 验证 Cookie 并取昵称（对应 Kotlin fetchNickname 走 gettemplatevariable username）
    func fetchNickname(cookie: String) async -> String? {
        guard let result = await templateVariable(fields: ["username"], cookie: cookie) else { return nil }
        let name = jsonString(result, "username")
        return name.isEmpty ? nil : name
    }

    /// bdstoken（带实例缓存；对应 Kotlin getBdstoken）
    func getBdstoken(cookie: String) async -> String? {
        if let cached = bdstokenCache, !cached.isEmpty { return cached }
        guard let result = await templateVariable(fields: ["bdstoken"], cookie: cookie) else { return nil }
        let token = jsonString(result, "bdstoken")
        if token.isEmpty { return nil }
        bdstokenCache = token
        return token
    }

    /// 清缓存后重新拉 bdstoken（对应 Kotlin refreshBdstoken）
    func refreshBdstoken(cookie: String) async -> String? {
        bdstokenCache = nil
        return await getBdstoken(cookie: cookie)
    }

    /// 登出/换账号时清会话缓存（对应 Kotlin clearSessionCache）
    func clearSessionCache() {
        bdstokenCache = nil
        shareInfos = [:]
    }

    /// 网盘空间（对应 Kotlin getQuota）；失败返回 nil
    func getQuota(cookie: String) async -> QuotaInfo? {
        let version = Int64(Date().timeIntervalSince1970 * 1000)
        let url = "https://pan.baidu.com/api/quota?clienttype=0&app_id=\(BaiduAPI.appId)&web=1&channel=chunlei&version=\(version)"
        var req = baseRequest(url: url, cookie: cookie, ua: BaiduAPI.uaWeb)
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        req.setValue("https://pan.baidu.com/disk/main", forHTTPHeaderField: "Referer")
        guard let raw = try? await send(req),
              let obj = (try? JSONSerialization.jsonObject(with: raw.data)) as? [String: Any],
              jsonInt(obj, "errno") == 0 else { return nil }
        return QuotaInfo(used: jsonLong(obj, "used"), total: jsonLong(obj, "total"))
    }

    // MARK: - 分享解析

    /// 创建分享会话：有提取码先 verify 换 sekey；公共分享（无提取码）跳过 verify、sekey 为空。
    /// verify 带当前百度 Cookie（可为空串）。标题由列表响应回填，会话先置空。
    func createSession(parsed: ShareLinkParser.ParsedShare, pwdOverride: String?) async throws -> ShareSession {
        let pwd = (pwdOverride != nil && !pwdOverride!.isEmpty) ? pwdOverride : parsed.pwd
        var sekey = ""
        if let pwd = pwd, !pwd.isEmpty {
            sekey = try await verifyShare(
                surl: parsed.shareId, pwd: pwd,
                cookie: CookieStore.shared.cookie(for: .baidu)
            )
        }
        return ShareSession(shareId: parsed.shareId, stoken: sekey, title: "", platform: .baidu)
    }

    /// 验证提取码，返回 randsk（即 sekey，本身是 URL 编码形态，后续原样使用）
    /// （对应 Kotlin verifyShare）
    func verifyShare(surl: String, pwd: String, cookie: String) async throws -> String {
        let url = "https://pan.baidu.com/share/verify?surl=\(surl)"
        let body = "pwd=\(formEncode(pwd))&vcode_str=&vcode="
        let obj = try await executeJson { retry in
            var req = self.baseRequest(url: url, cookie: cookie, ua: BaiduAPI.uaWeb)
            req.httpMethod = "POST"
            req.setValue("https://pan.baidu.com/s/\(surl)", forHTTPHeaderField: "Referer")
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = body.data(using: .utf8)
            return self.withRetryHeaders(req, isRetry: retry)
        }
        try checkErrno(obj, fallback: "验证提取码失败")
        return jsonString(obj, "randsk")
    }

    /// 分享文件列表单页（对应 Kotlin listShare）。
    /// 目录 fid=path（导航传参）、文件 fid=fs_id（转存传参）、pdirFid=path。
    func listShare(session: ShareSession, dir: String, page: Int) async throws -> (title: String, shareId: String, uk: String, files: [ShareFile]) {
        let surl = session.shareId
        let sekey = session.stoken
        let root = (dir.isEmpty || dir == "/") ? 1 : 0
        var url = "https://pan.baidu.com/rest/2.0/xpan/share?method=list&shorturl=\(surl)&page=\(page)&num=\(BaiduAPI.listPageSize)&root=\(root)&dir=\(formEncode(dir))"
        if !sekey.isEmpty { url += "&sekey=\(sekey)" }
        // 子目录（root=0）必须携带 BDCLND（= verify 的 randsk），否则 errno=2；顶层无需但带上无妨
        // （与 Kotlin 代码一致：sekey 非空且 Cookie 缺 BDCLND 时手动补齐）
        let cookie = CookieStore.shared.cookie(for: .baidu)
        let authCookie = (!sekey.isEmpty && !cookie.contains("BDCLND=")) ? "\(cookie); BDCLND=\(sekey)" : cookie
        let obj = try await executeJson { retry in
            var req = self.baseRequest(url: url, cookie: authCookie, ua: BaiduAPI.uaWeb)
            req.setValue("https://pan.baidu.com/s/\(surl)", forHTTPHeaderField: "Referer")
            return self.withRetryHeaders(req, isRetry: retry)
        }
        let errno = jsonInt(obj, "errno")
        if errno != 0 {
            // 无 sekey 却失败 → 多数是加密分享；errno=-6 是未登录/身份验证失败，单独区分提示
            if sekey.isEmpty {
                if errno == -6 {
                    throw QuarkError("该分享需要提取码，或需要登录百度网盘（errno=-6）", code: errno)
                }
                throw QuarkError("该分享需要提取码（errno=\(errno)）", code: errno)
            }
            try checkErrno(obj, fallback: "获取分享文件列表失败")
        }
        let list = obj["list"] as? [[String: Any]] ?? []
        let files = list.map { item -> ShareFile in
            let isdir = jsonString(item, "isdir") == "1"
            let path = jsonString(item, "path")
            return ShareFile(
                fid: isdir ? path : jsonString(item, "fs_id"),
                fname: jsonString(item, "server_filename"),
                fsize: jsonLong(item, "size"),
                isdir: isdir,
                pdirFid: path,
                fidToken: "",
                modifyTime: jsonString(item, "server_mtime")
            )
        }
        return (jsonString(obj, "title"), jsonString(obj, "share_id"), jsonString(obj, "uk"), files)
    }

    /// 拉取整个目录的分享文件列表（满页才翻页，上限 100 页），
    /// 同时缓存 share_id/uk 供转存复用，并回带分享标题。
    func listAllShareFiles(session: ShareSession, dir: String) async throws -> (title: String, files: [ShareFile]) {
        var all: [ShareFile] = []
        var title = ""
        var page = 1
        while page <= BaiduAPI.listMaxPages {
            let result = try await listShare(session: session, dir: dir, page: page)
            if !result.title.isEmpty { title = result.title }
            if !result.shareId.isEmpty && !result.uk.isEmpty {
                shareInfos[session.shareId] = (result.shareId, result.uk)
            }
            all.append(contentsOf: result.files)
            if result.files.count < BaiduAPI.listPageSize { break }
            page += 1
        }
        return (title, all)
    }

    // MARK: - 个人网盘 / 转存

    /// 创建目录，返回是否成功（对应 Kotlin createDir：api/create?a=commit，filemanager 恒 errno=2 不用）
    func createDir(path: String, cookie: String) async -> Bool {
        guard let token = await getBdstoken(cookie: cookie) else { return false }
        let url = "https://pan.baidu.com/api/create?a=commit&channel=chunlei&web=1&app_id=\(BaiduAPI.appId)&clienttype=0&bdstoken=\(token)"
        // body 与 Kotlin 原文一致（size 后无等号）
        let body = "path=\(formEncode(path))&isdir=1&size&block_list=%5B%5D&method=post&dataType=json"
        guard let obj = try? await executeJson(build: { retry in
            var req = self.baseRequest(url: url, cookie: cookie, ua: BaiduAPI.uaWeb)
            req.httpMethod = "POST"
            req.setValue("https://pan.baidu.com/disk/main", forHTTPHeaderField: "Referer")
            req.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            req.httpBody = body.data(using: .utf8)
            return self.withRetryHeaders(req, isRetry: retry)
        }) else { return false }
        return jsonInt(obj, "errno") == 0
    }

    /// 列出个人网盘目录的子项 path 集合（对应 Kotlin listDir）；失败返回空
    func listDir(dir: String, cookie: String) async -> [String] {
        let url = "https://pan.baidu.com/api/list?clienttype=0&app_id=\(BaiduAPI.appId)&web=1&order=time&desc=1&dir=\(formEncode(dir))&num=100&page=1"
        guard let obj = try? await executeJson(build: { retry in
            self.withRetryHeaders(self.baseRequest(url: url, cookie: cookie, ua: BaiduAPI.uaWeb), isRetry: retry)
        }), jsonInt(obj, "errno") == 0 else { return [] }
        let list = obj["list"] as? [[String: Any]] ?? []
        return list.map { jsonString($0, "path") }
    }

    /// 确保「YunX临时转存」目录存在，返回其路径；建失败回退根目录 "/"（对应 Kotlin ensureTempDir）
    func ensureTempDir(cookie: String) async -> String {
        let rootPaths = await listDir(dir: "/", cookie: cookie)
        if rootPaths.contains(BaiduAPI.tempDirPath) { return BaiduAPI.tempDirPath }
        if await createDir(path: BaiduAPI.tempDirPath, cookie: cookie) { return BaiduAPI.tempDirPath }
        return "/"
    }

    /// 转存分享文件到指定目录，返回转存后的新 fs_id 与新路径（对应 Kotlin transfer）
    func transfer(session: ShareSession, fsId: String, toDir: String, cookie: String) async throws -> (fsId: String, path: String) {
        let info = try await requireShareInfo(session: session)
        guard let token = await getBdstoken(cookie: cookie) else {
            throw QuarkError("获取 bdstoken 失败，请重新登录")
        }
        let sekey = session.stoken
        let url = "https://pan.baidu.com/share/transfer?shareid=\(info.shareId)&from=\(info.uk)&channel=chunlei&sekey=\(sekey)&ondup=newcopy&web=1&app_id=\(BaiduAPI.appId)&bdstoken=\(token)&clienttype=0"
        let body = "fsidlist=%5B%22\(fsId)%22%5D&path=\(formEncode(toDir))"
        // transfer 必须携带 BDCLND（= sekey），缺失会 errno=2
        let authCookie = cookie.contains("BDCLND=") ? cookie : "\(cookie); BDCLND=\(sekey)"
        let obj = try await executeJson { retry in
            var req = self.baseRequest(url: url, cookie: authCookie, ua: BaiduAPI.uaWeb)
            req.httpMethod = "POST"
            req.setValue("https://pan.baidu.com", forHTTPHeaderField: "Origin")
            req.setValue("https://pan.baidu.com/s/", forHTTPHeaderField: "Referer")
            req.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            req.httpBody = body.data(using: .utf8)
            return self.withRetryHeaders(req, isRetry: retry)
        }
        try checkErrno(obj, fallback: "转存失败")
        let extra = obj["extra"] as? [String: Any]
        let list = extra?["list"] as? [[String: Any]] ?? []
        guard let first = list.first else { throw QuarkError("转存失败：未返回新文件") }
        let newFsId = jsonString(first, "to_fs_id")
        if newFsId.isEmpty { throw QuarkError("转存失败：未返回新文件") }
        let newPath = jsonString(first, "to")
        // 与 Kotlin 原文一致：to 为空时回退 "<toDir>/"（正常响应 to 必有值）
        return (newFsId, newPath.isEmpty ? "\(toDir)/" : newPath)
    }

    /// 取转存所需的 share_id/uk：优先用列表时的缓存，没有就先列一次根目录
    /// （对应 Kotlin BaiduResolveRepository.requireShareInfo）
    private func requireShareInfo(session: ShareSession) async throws -> (shareId: String, uk: String) {
        if let cached = shareInfos[session.shareId] { return cached }
        _ = try await listAllShareFiles(session: session, dir: session.platform.rootDirKey)
        guard let cached = shareInfos[session.shareId] else {
            throw QuarkError("获取分享信息失败，请重新解析")
        }
        return cached
    }

    // MARK: - 下载直链

    /// 获取高速下载直链（对应 Kotlin locateDownload：locatedownload 接口）。
    /// urls[] 选链：优先 encrypt==0 的明文通道（https 优先），排除 rank1 的 d2-ant 加密通道；
    /// 全部为加密通道时退回第一个 https 候选，最后兜底第一个候选。
    func locateDownload(path: String, cookie: String) async throws -> String {
        let time = Int64(Date().timeIntervalSince1970)
        // 抓包常量（psign/rand/devuid/cuid/deviceid）有 BDUSS 登录态时可直接复用，与 Kotlin 一致
        var url = "https://d.pcs.baidu.com/rest/2.0/pcs/file?method=locatedownload"
        url += "&app_id=\(BaiduAPI.appId)"
        url += "&clienttype=17&ver=4.0"
        url += "&ant=1&check_blue=1&es=1&esl=1&apn_id=1_-1"
        url += "&freeisp=0&queryfree=0&use=1&dtype=1&eck=1&ehps=1"
        url += "&err_ver=1.0&network_type=WIFI&channel=0"
        url += "&path=\(formEncode(path))"
        url += "&time=\(time)"
        url += "&rand=5ed606e9da222cde0474cdf70eda884b"
        url += "&devuid=0F1E9FC2E084472DA5A61C4CF4C759AF"
        url += "&cuid=0F1E9FC2E084472DA5A61C4CF4C759AF"
        url += "&deviceid=348642637967375013"
        url += "&psign=860a071f77c860e8cea06e4e54c518f3"
        url += "&version=2.2.111.34&version_app=12.24.6&vip=0"
        let obj = try await executeJson { retry in
            var req = self.baseRequest(url: url, cookie: cookie, ua: BaiduAPI.uaNetdisk)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = "0".data(using: .utf8)
            return self.withRetryHeaders(req, isRetry: retry)
        }
        try checkErrno(obj, fallback: "获取高速下载链接失败")
        let urls = obj["urls"] as? [[String: Any]] ?? []
        let candidates = urls.filter { !jsonString($0, "url").isEmpty }
        let plain = candidates
            .filter { (dict: [String: Any]) -> Bool in
                // encrypt 缺省按 1（加密）处理，与 Kotlin optInt("encrypt", 1) 一致
                if dict["encrypt"] == nil { return false }
                return jsonInt(dict, "encrypt") == 0
            }
            .sorted { a, b in
                // https 优先（对应 Kotlin sortedBy { !startsWith("https") } 的稳定排序）
                let ah = jsonString(a, "url").hasPrefix("https")
                let bh = jsonString(b, "url").hasPrefix("https")
                return ah && !bh
            }
        if let first = plain.first { return jsonString(first, "url") }
        if let https = candidates.first(where: { jsonString($0, "url").hasPrefix("https") }) {
            return jsonString(https, "url")
        }
        if let first = candidates.first { return jsonString(first, "url") }
        throw QuarkError("未返回下载链接")
    }

    /// 删除个人网盘文件（对应 Kotlin deleteFile：filemanager opera=delete）；失败静默
    func deleteFile(path: String, cookie: String) async {
        guard let token = await getBdstoken(cookie: cookie) else { return }
        let url = "https://pan.baidu.com/api/filemanager?async=2&onnest=fail&opera=delete&bdstoken=\(token)&newVerify=1&clienttype=0&app_id=\(BaiduAPI.appId)&web=1"
        let body = "filelist=\(formEncode("[\"\(path)\"]"))"
        _ = try? await executeJson { retry in
            var req = self.baseRequest(url: url, cookie: cookie, ua: BaiduAPI.uaWeb)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            req.httpBody = body.data(using: .utf8)
            return self.withRetryHeaders(req, isRetry: retry)
        }
    }

    // MARK: - 取链编排（对应 Kotlin BaiduResolveRepository.getShareDownloadLink）

    /// 点文件后的完整取链流程，返回直链和「下载必须用的 Cookie」。
    /// 百度游客不支持下载（未登录仅能浏览文件列表），无 Cookie 直接报错。
    /// 流程：空间校验 → 确保临时目录 → 转存 → locatedownload 取链 → 立即删除转存文件
    /// （appall 直链自带签名，删除后仍有效；删除失败不阻断）。
    func resolveDownloadLink(file: ShareFile, session: ShareSession) async throws -> (link: DownloadLink, cookie: String) {
        let cookie = CookieStore.shared.cookie(for: .baidu)
        if cookie.isEmpty {
            throw QuarkError("下载需要先登录百度网盘（未登录仅能浏览文件列表）")
        }
        try await ensureSpace(size: file.fsize, cookie: cookie)
        let toDir = await ensureTempDir(cookie: cookie)
        let transferred = try await transfer(session: session, fsId: file.fid, toDir: toDir, cookie: cookie)
        let url = try await locateDownload(path: transferred.path, cookie: cookie)
        // 立即删转存文件；若落在临时目录下，再尝试删临时目录本身（非空会失败，静默即可）
        await deleteFile(path: transferred.path, cookie: cookie)
        if transferred.path.hasPrefix(BaiduAPI.tempDirPath + "/") {
            await deleteFile(path: BaiduAPI.tempDirPath, cookie: cookie)
        }
        let link = DownloadLink(
            fid: transferred.fsId,
            filename: file.fname,
            downloadUrl: url,
            size: file.fsize
        )
        return (link, cookie)
    }

    /// 转存前置空间校验（对应 Kotlin TransferSpaceGuard.ensureEnoughSpace）：
    /// 大小未知或配额查询失败一律放行，不足才拦截。
    private func ensureSpace(size: Int64, cookie: String) async throws {
        if size <= 0 { return }
        guard let quota = await getQuota(cookie: cookie), quota.total > 0 else { return }
        let free = quota.total - quota.used
        if size > free {
            throw QuarkError("剩余空间不足：需要 \(formatBytes(size))，当前可用 \(formatBytes(free))")
        }
    }
}

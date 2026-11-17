import Foundation

/// 夸克 API 封装（URLSession），移植自 Kotlin QuarkApi + QuarkResolveRepository（夸克部分）。
///
/// 与 Kotlin 版的行为对齐要点：
/// - 所有业务请求手动带 Cookie 头，不使用系统 Cookie 存储（对应 OkHttp 无 CookieJar 的行为）；
/// - 每次响应的 Set-Cookie 里的 __puus/__pus 会合并回本地 Cookie 并保存（对应 cookieSink 落库）；
/// - 取下载直链：登录态先走「免转存」，失败自动回退「转存到唯一临时子目录 → 轮询 → 取链」，
///   下载完成后由调用方删临时子目录；未登录走游客取链（约 50MB 上限，靠响应下发的 __pugs 过 CDN）。
final class QuarkAPI {
    static let shared = QuarkAPI()

    // MARK: - 常量（对应 Kotlin QuarkConstants）

    /// 解析/下载 API 强制 User-Agent（夸克 PC 客户端串）
    static let apiUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.12-a038f7b798 Safari/537.36 Channel/pckk_other_ch"

    /// 下载直链防盗链必须携带的 Referer
    static let downloadReferer = "https://pan.quark.cn/"

    private static let shareTokenURL = "https://drive-pc.quark.cn/1/clouddrive/share/sharepage/token?pr=ucpro&fr=pc"
    private static let shareDetailURL = "https://drive-pc.quark.cn/1/clouddrive/share/sharepage/detail?pr=ucpro&fr=pc"
    private static let downloadURL = "https://drive-pc.quark.cn/1/clouddrive/file/download?pr=ucpro&fr=pc&sys=win32&ve=3.23.2"
    private static let fileURL = "https://drive-pc.quark.cn/1/clouddrive/file?pr=ucpro&fr=pc"
    private static let saveURL = "https://drive-pc.quark.cn/1/clouddrive/share/sharepage/save?pr=ucpro&fr=pc"
    private static let taskURL = "https://drive-pc.quark.cn/1/clouddrive/task?pr=ucpro&fr=pc"
    private static let deleteURL = "https://drive-pc.quark.cn/1/clouddrive/file/delete?pr=ucpro&fr=pc&uc_param_str="
    private static let configURL = "https://drive-pc.quark.cn/1/clouddrive/config?pr=ucpro&fr=pc"
    private static let memberURL = "https://drive-pc.quark.cn/1/clouddrive/member?pr=ucpro&fr=pc&fetch_subscribe=true&_ch=home"
    private static let accountInfoURL = "https://pan.quark.cn/account/info"

    /// 临时转存目录名（与 Kotlin 版一致）
    private static let tempDirName = "YunX临时转存"

    /// __puus 提前刷新间隔：90 分钟（Kotlin PUUS_REFRESH_INTERVAL_MS）
    private static let puusRefreshIntervalMs: Int64 = 90 * 60 * 1000

    /// 分享列表翻页参数（Kotlin QuarkResolveRepository：单页 50、安全上限 200 页）
    private static let listPageSize = 50
    private static let listMaxPages = 200

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

    /// 游客态令牌 `__pugs=...`（未登录取链时由响应 Set-Cookie 下发，约 3 小时有效；
    /// 游客直链下载必须回带，缺了 CDN 返回 412）。进程内复用，对应 Kotlin QuarkApi.guestPugs。
    private var guestPugs: String = ""

    private init() {}

    private struct RawResponse {
        let data: Data
        let http: HTTPURLResponse

        /// 响应 Set-Cookie 解析出的 (name, value) 列表
        var cookiePairs: [(name: String, value: String)] {
            guard let url = http.url else { return [] }
            var fields: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let k = key as? String, let v = value as? String { fields[k] = v }
            }
            return HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
                .map { (name: $0.name, value: $0.value) }
        }
    }

    private func send(_ request: URLRequest) async throws -> RawResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw QuarkError("请求失败：无响应")
        }
        return RawResponse(data: data, http: http)
    }

    /// 把响应里的 __puus/__pus 合并回本地 Cookie（对应 Kotlin mergeCookieFromResponse + cookieSink 落库）。
    /// 仅当本次请求用的 Cookie 就是当前保存的那一份时才回写。
    private func mergeBack(_ raw: RawResponse, requestCookie: String?) {
        guard let requestCookie = requestCookie, !requestCookie.isEmpty else { return }
        let store = CookieStore.shared
        guard store.cookie == requestCookie else { return }
        let merged = CookieStore.mergeFromSetCookies(original: requestCookie, setCookiePairs: raw.cookiePairs)
        if merged != requestCookie { store.cookie = merged }
    }

    // MARK: - 请求构造（对应 Kotlin get / postJson / postJsonGuest）

    private func getRequest(url: String, cookie: String) -> URLRequest {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "GET"
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue(QuarkAPI.apiUserAgent, forHTTPHeaderField: "User-Agent")
        return req
    }

    private func postJSON(url: String, cookie: String, body: [String: Any]) throws -> URLRequest {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue(QuarkAPI.apiUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// 游客请求：Cookie 为空时不发 Cookie 头（首次取链手上没有任何令牌）
    private func postJSONGuest(url: String, cookie: String, body: [String: Any]) throws -> URLRequest {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        if !cookie.isEmpty { req.setValue(cookie, forHTTPHeaderField: "Cookie") }
        req.setValue(QuarkAPI.apiUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    // MARK: - JSON 小工具（对应 org.json 的 opt* 语义）

    private func jsonString(_ dict: [String: Any], _ key: String) -> String {
        if let s = dict[key] as? String { return s }
        if let n = dict[key] as? NSNumber { return n.stringValue }
        return ""
    }

    private func jsonInt(_ dict: [String: Any], _ key: String) -> Int {
        (dict[key] as? NSNumber)?.intValue ?? 0
    }

    private func jsonLong(_ dict: [String: Any], _ key: String) -> Int64 {
        (dict[key] as? NSNumber)?.int64Value ?? 0
    }

    private func jsonBool(_ dict: [String: Any], _ key: String) -> Bool {
        (dict[key] as? NSNumber)?.boolValue ?? false
    }

    /// 严格百分号编码（对应 Kotlin URLEncoder 对 stoken / task_id 的处理）
    private func urlEncode(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// 对应 Kotlin parseData：校验 status==200，失败透传服务端 message，成功返回 data 对象
    private func dataObject(_ raw: RawResponse, requestCookie: String?) throws -> [String: Any] {
        mergeBack(raw, requestCookie: requestCookie)
        guard let obj = (try? JSONSerialization.jsonObject(with: raw.data)) as? [String: Any] else {
            // 非 JSON（多半是 HTML 错误页/风控页）时带上 HTTP 状态码便于分辨
            throw QuarkError("响应解析失败（HTTP \(raw.http.statusCode)）")
        }
        if jsonInt(obj, "status") != 200 {
            let msg = jsonString(obj, "message")
            throw QuarkError(msg.isEmpty ? "请求失败" : msg, code: jsonInt(obj, "code"))
        }
        guard let data = obj["data"] as? [String: Any] else {
            throw QuarkError("响应缺少 data")
        }
        return data
    }

    // MARK: - 账号

    /// 验证 Cookie 并取昵称（对应 Kotlin fetchNickname）；失败返回 nil
    func fetchNickname(cookie: String) async -> String? {
        var req = URLRequest(url: URL(string: QuarkAPI.accountInfoURL)!)
        req.httpMethod = "GET"
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue(QuarkAPI.apiUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              jsonBool(obj, "success"),
              let d = obj["data"] as? [String: Any] else { return nil }
        let nickname = jsonString(d, "nickname")
        return nickname.isEmpty ? nil : nickname
    }

    /// 网盘空间详情（对应 Kotlin getQuota）；失败返回 nil
    func getQuota(cookie: String) async -> QuotaInfo? {
        let req = getRequest(url: QuarkAPI.memberURL, cookie: cookie)
        guard let raw = try? await send(req),
              let obj = (try? JSONSerialization.jsonObject(with: raw.data)) as? [String: Any],
              let data = obj["data"] as? [String: Any] else { return nil }
        return QuotaInfo(used: jsonLong(data, "use_capacity"), total: jsonLong(data, "total_capacity"))
    }

    /// 刷新会话 Cookie（对应 Kotlin refreshSession / AList refreshPuus）：
    /// 剥离 __puus 后请求 /config，服务端在 Set-Cookie 中重新下发 __puus/__pus。
    /// 返回合并后的 Cookie；网络失败返回 nil（调用方回退原 Cookie）。
    func refreshSession(cookie: String) async -> String? {
        var req = URLRequest(url: URL(string: QuarkAPI.configURL)!)
        req.httpMethod = "GET"
        req.setValue(CookieStore.withoutPuus(cookie), forHTTPHeaderField: "Cookie")
        req.setValue(QuarkAPI.apiUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(QuarkAPI.downloadReferer, forHTTPHeaderField: "Referer")
        guard let raw = try? await send(req) else { return nil }
        let merged = CookieStore.mergeFromSetCookies(original: cookie, setCookiePairs: raw.cookiePairs)
        let store = CookieStore.shared
        if merged != cookie && store.cookie == cookie { store.cookie = merged }
        return merged
    }

    /// 返回「保证 __puus 未过期」的 Cookie（对应 Kotlin QuarkAccountRepository.getFreshCookie）：
    /// 距上次刷新超过 90 分钟时先刷新并保存；刷新失败回退当前 Cookie。
    func freshCookie() async -> String {
        let store = CookieStore.shared
        let current = store.cookie
        if current.isEmpty { return current }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if nowMs - store.lastRefreshMs <= QuarkAPI.puusRefreshIntervalMs { return current }
        if let refreshed = await refreshSession(cookie: current) {
            store.cookie = refreshed
            store.lastRefreshMs = nowMs
            return refreshed
        }
        return current
    }

    // MARK: - 分享解析

    /// 创建分享会话：短码/提取码由 ShareLinkParser 解析好传入 → 换 stoken
    /// （对应 Kotlin QuarkResolveRepository.createSession）
    func createSession(parsed: ShareLinkParser.ParsedShare, pwdOverride: String?) async throws -> ShareSession {
        let pwd = (pwdOverride != nil && !pwdOverride!.isEmpty) ? pwdOverride : parsed.pwd
        let token = try await getShareToken(shareId: parsed.shareId, pwd: pwd, cookie: CookieStore.shared.cookie)
        return ShareSession(shareId: parsed.shareId, stoken: token.stoken, title: token.title, platform: .quark)
    }

    /// 4.1 获取分享 Token（对应 Kotlin getShareToken）
    func getShareToken(shareId: String, pwd: String?, cookie: String) async throws -> ShareToken {
        let body: [String: Any] = [
            "pwd_id": shareId,
            "passcode": pwd ?? "",
            "support_visit_limit_private_share": true
        ]
        let req = try postJSON(url: QuarkAPI.shareTokenURL, cookie: cookie, body: body)
        let raw = try await send(req)
        let data = try dataObject(raw, requestCookie: cookie)
        return ShareToken(
            stoken: jsonString(data, "stoken"),
            title: jsonString(data, "title"),
            firstFid: jsonString(data, "first_fid")
        )
    }

    /// 4.2 获取分享文件列表单页（对应 Kotlin getShareFiles；字段以抓包为准：
    /// file_name / size / dir / share_fid_token）
    func getShareFiles(shareId: String, stoken: String, pdirFid: String, cookie: String, page: Int, size: Int) async throws -> [ShareFile] {
        var url = QuarkAPI.shareDetailURL
        url += "&pwd_id=\(shareId)"
        url += "&stoken=\(urlEncode(stoken))"
        url += "&pdir_fid=\(pdirFid)"
        url += "&ver=2&force=0"
        url += "&_page=\(page)&_size=\(size)"
        url += "&_fetch_banner=0&_fetch_share=0&fetch_relate_conversation=0&_fetch_total=1"
        url += "&_sort=file_type:asc,file_name:asc"
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "GET"
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue(QuarkAPI.apiUserAgent, forHTTPHeaderField: "User-Agent")
        // 该接口需携带 Origin / Referer，否则可能返回 400
        req.setValue("https://pan.quark.cn", forHTTPHeaderField: "Origin")
        req.setValue("https://pan.quark.cn/", forHTTPHeaderField: "Referer")
        let raw = try await send(req)
        let data = try dataObject(raw, requestCookie: cookie)
        let list = data["list"] as? [[String: Any]] ?? []
        return list.map { item in
            ShareFile(
                fid: jsonString(item, "fid"),
                fname: jsonString(item, "file_name"),
                fsize: jsonLong(item, "size"),
                isdir: jsonBool(item, "dir"),
                pdirFid: jsonString(item, "pdir_fid"),
                fidToken: jsonString(item, "share_fid_token"),
                modifyTime: jsonString(item, "updated_at")
            )
        }
    }

    /// 拉取整个目录的分享文件列表（自动翻页 + 按 fid 去重，
    /// 对应 Kotlin QuarkResolveRepository.listFiles：整页无新增即停止，避免死循环）
    func listAllShareFiles(session: ShareSession, pdirFid: String) async throws -> [ShareFile] {
        let cookie = CookieStore.shared.cookie
        var all: [ShareFile] = []
        var seen = Set<String>()
        var page = 1
        while page <= QuarkAPI.listMaxPages {
            let batch = try await getShareFiles(
                shareId: session.shareId, stoken: session.stoken,
                pdirFid: pdirFid, cookie: cookie,
                page: page, size: QuarkAPI.listPageSize
            )
            if batch.isEmpty { break }
            var added = 0
            for file in batch {
                let key = file.fid.isEmpty ? "\(file.pdirFid)/\(file.fname)" : file.fid
                if seen.insert(key).inserted {
                    all.append(file)
                    added += 1
                }
            }
            if added == 0 { break }
            page += 1
        }
        return all
    }

    // MARK: - 个人网盘 / 转存

    /// 7.1 个人网盘文件列表（对应 Kotlin getFileList；字段兼容 file_name/fname 等两种命名）
    func getFileList(pdirFid: String, cookie: String, page: Int = 1, size: Int = 100) async throws -> [ShareFile] {
        let url = "\(QuarkAPI.fileURL)&pdir_fid=\(pdirFid)&page=\(page)&size=\(size)"
        let req = getRequest(url: url, cookie: cookie)
        let raw = try await send(req)
        let data = try dataObject(raw, requestCookie: cookie)
        let list = data["list"] as? [[String: Any]] ?? []
        return list.map { item in
            let name = jsonString(item, "file_name")
            let sizeValue: Int64 = item["size"] != nil ? jsonLong(item, "size") : jsonLong(item, "fsize")
            return ShareFile(
                fid: jsonString(item, "fid"),
                fname: name.isEmpty ? jsonString(item, "fname") : name,
                fsize: sizeValue,
                isdir: jsonBool(item, "dir") || jsonInt(item, "isdir") == 1,
                pdirFid: jsonString(item, "pdir_fid"),
                fidToken: jsonString(item, "fid_token"),
                modifyTime: jsonString(item, "modify_time")
            )
        }
    }

    /// 创建目录，返回新目录 fid（对应 Kotlin createFolder）
    func createFolder(name: String, parentFid: String, cookie: String) async throws -> String {
        let body: [String: Any] = [
            "pdir_fid": parentFid,
            "file_name": name,
            "dir_path": "",
            "dir_init_lock": false
        ]
        let req = try postJSON(url: QuarkAPI.fileURL, cookie: cookie, body: body)
        let raw = try await send(req)
        let data = try dataObject(raw, requestCookie: cookie)
        let fid = jsonString(data, "fid")
        if fid.isEmpty { throw QuarkError("创建临时目录失败") }
        return fid
    }

    /// 确保「YunX临时转存」目录存在，返回其 fid（对应 Kotlin QuarkResolveRepository.ensureTempDir）
    func ensureTempDir(cookie: String) async throws -> String {
        let rootFiles = try await getFileList(pdirFid: "0", cookie: cookie)
        if let existing = rootFiles.first(where: { $0.isdir && $0.fname == QuarkAPI.tempDirName }) {
            return existing.fid
        }
        return try await createFolder(name: QuarkAPI.tempDirName, parentFid: "0", cookie: cookie)
    }

    /// 5. 转存分享文件到指定目录，返回异步任务 id（对应 Kotlin saveShareFile）
    func saveShareFile(shareId: String, stoken: String, pdirFid: String, fid: String, fidToken: String, toPdirFid: String, cookie: String) async throws -> String {
        let body: [String: Any] = [
            "pwd_id": shareId,
            "stoken": stoken,
            "pdir_fid": pdirFid,
            "to_pdir_fid": toPdirFid,
            "fid_list": [fid],
            "fid_token_list": [fidToken],
            "scene": "link"
        ]
        let req = try postJSON(url: QuarkAPI.saveURL, cookie: cookie, body: body)
        let raw = try await send(req)
        let data = try dataObject(raw, requestCookie: cookie)
        let taskId = jsonString(data, "task_id")
        if taskId.isEmpty { throw QuarkError("转存失败") }
        return taskId
    }

    /// 轮询异步转存任务（最多 10 次 × 1 秒），返回转存后的新 fid；超时/失败返回 nil
    /// （对应 Kotlin pollTask：完成标志 finished_at>0 或 status/task_status==2，
    ///   新 fid 在 data.save_as.save_as_top_fids[0]）
    func pollTask(taskId: String, cookie: String) async -> String? {
        let url = "\(QuarkAPI.taskURL)&task_id=\(urlEncode(taskId))&retry_index=0"
        for _ in 0..<10 {
            if let fid = await pollTaskOnce(url: url, cookie: cookie) { return fid }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return nil
    }

    private func pollTaskOnce(url: String, cookie: String) async -> String? {
        let req = getRequest(url: url, cookie: cookie)
        guard let raw = try? await send(req),
              let obj = (try? JSONSerialization.jsonObject(with: raw.data)) as? [String: Any],
              jsonInt(obj, "status") == 200,
              let data = obj["data"] as? [String: Any] else { return nil }
        let finished = jsonLong(data, "finished_at") > 0
            || jsonInt(data, "status") == 2
            || jsonInt(data, "task_status") == 2
        if !finished { return nil }
        guard let saveAs = data["save_as"] as? [String: Any],
              let fids = saveAs["save_as_top_fids"] as? [Any],
              let first = fids.first as? String, !first.isEmpty else { return nil }
        return first
    }

    /// 6.2 删除文件（下载完成后清理临时转存目录；失败不阻断，对应 Kotlin deleteFile）
    @discardableResult
    func deleteFile(fid: String, cookie: String) async -> String? {
        let body: [String: Any] = [
            "action_type": 2,
            "filelist": [fid],
            "exclude_fids": [String]()
        ]
        guard let req = try? postJSON(url: QuarkAPI.deleteURL, cookie: cookie, body: body),
              let raw = try? await send(req),
              let data = try? dataObject(raw, requestCookie: cookie) else { return nil }
        let taskId = jsonString(data, "task_id")
        return taskId.isEmpty ? nil : taskId
    }

    // MARK: - 下载直链

    /// 6.1 获取下载直链（转存后用新 fid 调用；对应 Kotlin getDownloadLink。
    /// 该接口失败响应无 status 字段，用 code 识别，如 21001 file not found）
    func getDownloadLink(fid: String, cookie: String) async throws -> DownloadLink {
        let body: [String: Any] = ["fids": [fid]]
        let req = try postJSON(url: QuarkAPI.downloadURL, cookie: cookie, body: body)
        let raw = try await send(req)
        mergeBack(raw, requestCookie: cookie)
        return try parseDownloadData(raw, errorMapper: { code, message in
            (message.isEmpty ? "获取下载链接失败" : message, code)
        })
    }

    /// 6.1c 免转存分享取链（登录态；对应 Kotlin getShareDownloadLinkWithoutSave）：
    /// 不转存，直接把分享凭证交给 download 接口换直链，不受游客约 50MB 限制，
    /// 也不会在网盘里留临时目录。
    func getShareDownloadLinkWithoutSave(fid: String, fidToken: String, shareId: String, stoken: String, cookie: String) async throws -> DownloadLink {
        let body: [String: Any] = [
            "fids": [fid],
            "fids_token": [fidToken],
            "pwd_id": shareId,
            "stoken": stoken,
            "speedup_session": "",
            "token": ""
        ]
        let req = try postJSON(url: QuarkAPI.downloadURL, cookie: cookie, body: body)
        let raw = try await send(req)
        mergeBack(raw, requestCookie: cookie)
        return try parseDownloadData(raw, errorMapper: { code, message in
            (QuarkAPI.noSaveErrorMessage(code: code, message: message), code)
        })
    }

    /// 6.1b 游客分享取链（未登录；对应 Kotlin getGuestShareDownloadLink）。
    /// 与登录取链同一端点，差别只在请求语义：body 带分享参数、不带登录 Cookie。
    /// 响应 Set-Cookie 下发的 __pugs 是后续下载直链要带的 Cookie（缺了 CDN 412），
    /// 捕获后写进 DownloadLink.guestCookie 并缓存供同批次后续文件复用。
    /// 实测仅约 50MB 以内的小文件可用（超出报 23018）。
    func getGuestShareDownloadLink(fid: String, fidToken: String, shareId: String, stoken: String) async throws -> DownloadLink {
        let body: [String: Any] = [
            "fids": [fid],
            "fids_token": [fidToken],
            "pwd_id": shareId,
            "stoken": stoken,
            "speedup_session": "",
            "token": ""
        ]
        let req = try postJSONGuest(url: QuarkAPI.downloadURL, cookie: guestPugs, body: body)
        let raw = try await send(req)
        // 先取本次响应的 __pugs（与本次直链同响应绑定，不能用上一次的值）
        let responsePugs = pugs(from: raw.cookiePairs)
        if let responsePugs = responsePugs { guestPugs = responsePugs }
        var link = try parseDownloadData(raw, errorMapper: { code, message in
            (QuarkAPI.guestErrorMessage(code: code, message: message), code)
        })
        link.guestCookie = responsePugs ?? guestPugs
        return link
    }

    /// 从 Cookie 对里取出游客态令牌，返回可直接当 Cookie 头用的 `__pugs=值`；没有则 nil
    private func pugs(from pairs: [(name: String, value: String)]) -> String? {
        guard let pair = pairs.first(where: { $0.name == "__pugs" && !$0.value.isEmpty }) else { return nil }
        return "__pugs=\(pair.value)"
    }

    /// download 接口的 data 是数组，单独解析（对应 Kotlin 三个取链函数的公共尾部）
    private func parseDownloadData(_ raw: RawResponse, errorMapper: (Int, String) -> (String, Int)) throws -> DownloadLink {
        guard let obj = (try? JSONSerialization.jsonObject(with: raw.data)) as? [String: Any] else {
            throw QuarkError("响应解析失败（HTTP \(raw.http.statusCode)）")
        }
        let code = jsonInt(obj, "code")
        if jsonInt(obj, "status") != 200 && code != 0 {
            let mapped = errorMapper(code, jsonString(obj, "message"))
            throw QuarkError(mapped.0, code: mapped.1)
        }
        guard let array = obj["data"] as? [[String: Any]], let item = array.first else {
            throw QuarkError("未返回下载链接")
        }
        let name = jsonString(item, "file_name")
        return DownloadLink(
            fid: jsonString(item, "fid"),
            filename: name.isEmpty ? jsonString(item, "filename") : name,
            downloadUrl: jsonString(item, "download_url"),
            size: jsonLong(item, "size")
        )
    }

    /// 免转存取链的错误码 → 中文提示（31001=登录态失效；23018=服务端仍按游客大小限制放行）
    private static func noSaveErrorMessage(code: Int, message: String) -> String {
        switch code {
        case 31001: return "夸克登录态已失效，请到「设置」页重新粘贴 Cookie 后再试"
        case 23018: return "服务端按游客限制拒绝了该文件（夸克约 50MB 上限）"
        default: return message.isEmpty ? "获取下载链接失败" : message
        }
    }

    /// 游客取链的错误码 → 中文提示（23018=超出游客大小上限、31001=需要登录）
    private static func guestErrorMessage(code: Int, message: String) -> String {
        switch code {
        case 23018: return "该文件超出游客可获取的大小上限（夸克实测约 50MB），请先在「设置」页粘贴夸克 Cookie 再下载"
        case 31001: return "该分享需要登录夸克网盘后才能下载"
        default: return message.isEmpty ? "获取下载链接失败" : message
        }
    }

    // MARK: - 取链编排（对应 Kotlin ResolveViewModel.fetchDownloadLink + QuarkResolveRepository）

    /// 点文件后的完整取链流程，返回直链和「下载必须用的那份 Cookie」。
    ///
    /// - 未设置 Cookie：游客取链，下载 Cookie = 直链自带的 guestCookie（__pugs）。
    /// - 已设置 Cookie：先刷新 __puus（直链签名绑定取链时刻的 Cookie，取链与下载必须同一份），
    ///   优先免转存取链；失败自动回退转存流程（唯一临时子目录 → 转存 → 轮询 → 取链），
    ///   此时 link.cleanupDirFid 带回临时子目录 fid，由调用方在下载完成后删除。
    func resolveDownloadLink(file: ShareFile, session: ShareSession) async throws -> (link: DownloadLink, cookie: String) {
        let stored = CookieStore.shared.cookie
        if stored.isEmpty {
            let link = try await getGuestShareDownloadLink(
                fid: file.fid, fidToken: file.fidToken,
                shareId: session.shareId, stoken: session.stoken
            )
            return (link, link.guestCookie)
        }
        let fresh = await freshCookie()
        do {
            let link = try await getShareDownloadLinkWithoutSave(
                fid: file.fid, fidToken: file.fidToken,
                shareId: session.shareId, stoken: session.stoken,
                cookie: fresh
            )
            return (link, fresh)
        } catch {
            // 个别分享类型服务端仍要求「先转存再取链」→ 回退转存流程（与 Kotlin 版一致）
            let link = try await transferAndGetLink(file: file, session: session, cookie: fresh)
            return (link, fresh)
        }
    }

    /// 转存取链全流程（对应 Kotlin QuarkResolveRepository.getShareDownloadLink）：
    /// 空间校验 → 确保临时目录 → 建唯一子目录 tr_<纳秒>_<随机>（绕开夸克转存去重，
    /// 避免二次转存返回已删除 fid 导致 download 404/code 21001）→ 转存 → 轮询 → 取链。
    /// 取链成功后不立即删子目录：下载期间 fid 必须存活，删除推迟到下载完成回调。
    private func transferAndGetLink(file: ShareFile, session: ShareSession, cookie: String) async throws -> DownloadLink {
        try await ensureSpace(size: file.fsize, cookie: cookie)
        let baseDir = try await ensureTempDir(cookie: cookie)
        let subDirName = "tr_\(Int(Date().timeIntervalSince1970 * 1_000_000_000))_\(Int.random(in: 0..<1_000_000))"
        let subDirFid = try await createFolder(name: subDirName, parentFid: baseDir, cookie: cookie)
        let taskId = try await saveShareFile(
            shareId: session.shareId, stoken: session.stoken,
            pdirFid: file.pdirFid, fid: file.fid, fidToken: file.fidToken,
            toPdirFid: subDirFid, cookie: cookie
        )
        guard let savedFid = await pollTask(taskId: taskId, cookie: cookie) else {
            throw QuarkError("转存超时，请稍后重试")
        }
        var link = try await getDownloadLink(fid: savedFid, cookie: cookie)
        link.cleanupDirFid = subDirFid
        return link
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

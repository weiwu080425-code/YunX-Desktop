import Foundation

/// UC 网盘 API 封装（URLSession），移植自 Kotlin UCApi + UCResolveRepository。
///
/// UC 与夸克同属一套体系（响应结构 status/code/message/data、__puus/__pus Cookie 机制相同），
/// 但端点域名（pc-api.uc.cn）、参数（pr=UCBrowser）与 UA 都不同，逐项按 Kotlin 源码对齐：
/// - 列表必须用 transfer_share/detail（不能用 v2/detail）；
/// - 取链免转存：登录态直接 file/download 换直链；视频文件优先走 video_preview 取原画直链；
/// - 游客取链实测大文件也放行、没有大小上限（与夸克不同），靠响应下发的 __pugs 过 CDN；
/// - UC Cookie 独立保存在 CookieStore 的 .uc 分区。
final class UCAPI {
    static let shared = UCAPI()

    // MARK: - 常量（对应 Kotlin UCConstants）

    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    /// 游客取链/下载专用 UA（UC PC 客户端串）
    static let guestUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) uc-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch"
    static let guestSecChUa = "\"Not=A?Brand\";v=\"99\", \"Chromium\";v=\"100\", \"Google Chrome\";v=\"100\""
    /// member 接口用的 UC 客户端 UA
    static let cloudUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) uc-cloud-drive/1.6.1 Chrome/100.0.4896.160 Electron/18.3.5.16-b62cf9c50d Safari/537.36 Channel/ucpan_other_ch"

    static let webOrigin = "https://drive.uc.cn"
    static let downloadReferer = "https://drive.uc.cn/"

    private static let apiBase = "https://pc-api.uc.cn"
    private static let tokenURL = "https://pc-api.uc.cn/1/clouddrive/share/sharepage/token?pr=UCBrowser&fr=pc"
    private static let transferDetailURL = "https://pc-api.uc.cn/1/clouddrive/transfer_share/detail?entry=ft&fr=pc&pr=UCBrowser"
    private static let downloadURL = "https://pc-api.uc.cn/1/clouddrive/file/download?entry=ft&fr=pc&pr=UCBrowser"
    private static let videoPreviewURL = "https://pc-api.uc.cn/1/clouddrive/share/sharepage/video_preview?pr=UCBrowser&fr=h5"
    private static let configURL = "https://pc-api.uc.cn/1/clouddrive/config?pr=UCBrowser&fr=pc"
    private static let memberURL = "https://pc-api.uc.cn/1/clouddrive/member?pr=UCBrowser&fr=pc&fetch_subscribe=true&_ch=home"
    private static let accountInfoURL = "https://drive.uc.cn/account/info"

    /// __puus 提前刷新间隔：90 分钟（与夸克一致）
    private static let puusRefreshIntervalMs: Int64 = 90 * 60 * 1000

    /// 分享列表翻页参数（与夸克版一致：单页 50、安全上限 200 页）
    private static let listPageSize = 50
    private static let listMaxPages = 200

    /// 视频扩展名集合（命中时优先走 video_preview 取原画直链，对应 Kotlin UCResolveRepository）
    private static let videoExtensions: Set<String> = ["mp4", "mkv", "mov", "avi", "webm", "flv", "ts", "m3u8", "wmv", "rmvb"]

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

    /// 游客态令牌 `__pugs=...`（未登录取链时由响应 Set-Cookie 下发；游客直链下载必须回带，缺了 403）。
    /// 进程内复用，对应 Kotlin UCApi.guestPugs。
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

    /// 把响应里的 __puus/__pus 合并回 UC 的本地 Cookie（对应 Kotlin UCApi.parseData 每次响应都合并）。
    /// 仅当本次请求用的 Cookie 就是当前保存的那一份时才回写。
    private func mergeBack(_ raw: RawResponse, requestCookie: String?) {
        guard let requestCookie = requestCookie, !requestCookie.isEmpty else { return }
        let store = CookieStore.shared
        guard store.cookie(for: .uc) == requestCookie else { return }
        let merged = CookieStore.mergeFromSetCookies(original: requestCookie, setCookiePairs: raw.cookiePairs)
        if merged != requestCookie { store.setCookie(merged, for: .uc) }
    }

    // MARK: - 请求构造

    private func getRequest(url: String, cookie: String) -> URLRequest {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "GET"
        if !cookie.isEmpty { req.setValue(cookie, forHTTPHeaderField: "Cookie") }
        req.setValue(UCAPI.userAgent, forHTTPHeaderField: "User-Agent")
        return req
    }

    private func postJSON(url: String, cookie: String, body: [String: Any], ua: String, extraHeaders: [String: String] = [:]) throws -> URLRequest {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        if !cookie.isEmpty { req.setValue(cookie, forHTTPHeaderField: "Cookie") }
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    // MARK: - JSON 小工具

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

    /// 严格百分号编码（对应 Kotlin URLEncoder 对 stoken 等的处理）
    private func urlEncode(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// 对应 Kotlin parseData：校验 status==200，失败透传服务端 message，成功返回 data 对象
    private func dataObject(_ raw: RawResponse, requestCookie: String?) throws -> [String: Any] {
        mergeBack(raw, requestCookie: requestCookie)
        guard let obj = (try? JSONSerialization.jsonObject(with: raw.data)) as? [String: Any] else {
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
        var req = URLRequest(url: URL(string: UCAPI.accountInfoURL)!)
        req.httpMethod = "GET"
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue(UCAPI.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              jsonBool(obj, "success"),
              let d = obj["data"] as? [String: Any] else { return nil }
        let nickname = jsonString(d, "nickname")
        return nickname.isEmpty ? nil : nickname
    }

    /// 网盘空间详情（对应 Kotlin getQuota：member 接口 + CLOUD_UA）；失败返回 nil
    func getQuota(cookie: String) async -> QuotaInfo? {
        var req = URLRequest(url: URL(string: UCAPI.memberURL)!)
        req.httpMethod = "GET"
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue(UCAPI.cloudUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(UCAPI.webOrigin, forHTTPHeaderField: "Origin")
        req.setValue(UCAPI.downloadReferer, forHTTPHeaderField: "Referer")
        guard let raw = try? await send(req),
              let obj = (try? JSONSerialization.jsonObject(with: raw.data)) as? [String: Any],
              let data = obj["data"] as? [String: Any] else { return nil }
        return QuotaInfo(used: jsonLong(data, "use_capacity"), total: jsonLong(data, "total_capacity"))
    }

    /// 刷新会话 Cookie（对应 Kotlin refreshSession）：剥离 __puus 后请求 /config，
    /// 服务端在 Set-Cookie 中重新下发 __puus/__pus。返回合并后的 Cookie；失败返回 nil。
    func refreshSession(cookie: String) async -> String? {
        var req = URLRequest(url: URL(string: UCAPI.configURL)!)
        req.httpMethod = "GET"
        req.setValue(CookieStore.withoutPuus(cookie), forHTTPHeaderField: "Cookie")
        req.setValue(UCAPI.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(UCAPI.downloadReferer, forHTTPHeaderField: "Referer")
        guard let raw = try? await send(req) else { return nil }
        let merged = CookieStore.mergeFromSetCookies(original: cookie, setCookiePairs: raw.cookiePairs)
        let store = CookieStore.shared
        if merged != cookie && store.cookie(for: .uc) == cookie { store.setCookie(merged, for: .uc) }
        return merged
    }

    /// 返回「保证 __puus 未过期」的 Cookie（对应 Kotlin UCAccountRepository.getFreshCookie）：
    /// 距上次刷新超过 90 分钟时先刷新并保存；刷新失败回退当前 Cookie。
    func freshCookie() async -> String {
        let store = CookieStore.shared
        let current = store.cookie(for: .uc)
        if current.isEmpty { return current }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if nowMs - store.lastRefreshMs(for: .uc) <= UCAPI.puusRefreshIntervalMs { return current }
        if let refreshed = await refreshSession(cookie: current) {
            store.setCookie(refreshed, for: .uc)
            store.setLastRefreshMs(nowMs, for: .uc)
            return refreshed
        }
        return current
    }

    // MARK: - 分享解析

    /// 创建分享会话：短码/提取码由 ShareLinkParser 解析好传入 → 换 stoken
    func createSession(parsed: ShareLinkParser.ParsedShare, pwdOverride: String?) async throws -> ShareSession {
        let pwd = (pwdOverride != nil && !pwdOverride!.isEmpty) ? pwdOverride : parsed.pwd
        let token = try await getShareToken(shareId: parsed.shareId, pwd: pwd, cookie: CookieStore.shared.cookie(for: .uc))
        return ShareSession(shareId: parsed.shareId, stoken: token.stoken, title: token.title, platform: .uc)
    }

    /// 获取分享 Token（对应 Kotlin getShareToken；注意 body 是 share_for_transfer，
    /// 与夸克的 support_visit_limit_private_share 不同）
    func getShareToken(shareId: String, pwd: String?, cookie: String) async throws -> ShareToken {
        let body: [String: Any] = [
            "pwd_id": shareId,
            "passcode": pwd ?? "",
            "share_for_transfer": true
        ]
        let req = try postJSON(url: UCAPI.tokenURL, cookie: cookie, body: body, ua: UCAPI.userAgent)
        let raw = try await send(req)
        let data = try dataObject(raw, requestCookie: cookie)
        return ShareToken(
            stoken: jsonString(data, "stoken"),
            title: jsonString(data, "title"),
            firstFid: jsonString(data, "first_fid")
        )
    }

    /// 获取分享文件列表单页（对应 Kotlin getTransferShareFiles；解析流程必须用这个端点，
    /// 不能用 v2/detail）。列表取 data.list，兼容 data.detail_info.list。
    func getTransferShareFiles(shareId: String, stoken: String, pdirFid: String, cookie: String, page: Int, size: Int) async throws -> [ShareFile] {
        var url = UCAPI.transferDetailURL
        url += "&pwd_id=\(shareId)"
        url += "&pdir_fid=\(pdirFid)"
        url += "&fetch_file_list=1&passcode="
        url += "&_page=\(page)&_size=\(size)"
        url += "&_fetch_total=1&_fetch_task=1&_fetch_share=1&_sort="
        url += "&stoken=\(urlEncode(stoken))"
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "GET"
        if !cookie.isEmpty { req.setValue(cookie, forHTTPHeaderField: "Cookie") }
        req.setValue(UCAPI.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://fast.uc.cn", forHTTPHeaderField: "Origin")
        req.setValue("https://fast.uc.cn/", forHTTPHeaderField: "Referer")
        let raw = try await send(req)
        let data = try dataObject(raw, requestCookie: cookie)
        var list = data["list"] as? [[String: Any]]
        if list == nil, let detail = data["detail_info"] as? [String: Any] {
            list = detail["list"] as? [[String: Any]]
        }
        return (list ?? []).map { item in
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

    /// 拉取整个目录的分享文件列表（自动翻页 + 按 fid 去重，整页无新增即停；与夸克版同逻辑）
    func listAllShareFiles(session: ShareSession, pdirFid: String) async throws -> [ShareFile] {
        let cookie = CookieStore.shared.cookie(for: .uc)
        var all: [ShareFile] = []
        var seen = Set<String>()
        var page = 1
        while page <= UCAPI.listMaxPages {
            let batch = try await getTransferShareFiles(
                shareId: session.shareId, stoken: session.stoken,
                pdirFid: pdirFid, cookie: cookie,
                page: page, size: UCAPI.listPageSize
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

    // MARK: - 下载直链

    /// 登录态免转存取链（对应 Kotlin getShareDownloadLink）：body 只四项
    func getShareDownloadLink(file: ShareFile, session: ShareSession, cookie: String) async throws -> DownloadLink {
        let body: [String: Any] = [
            "fids": [file.fid],
            "pwd_id": session.shareId,
            "stoken": session.stoken,
            "fids_token": [file.fidToken]
        ]
        let req = try postJSON(url: UCAPI.downloadURL, cookie: cookie, body: body, ua: UCAPI.userAgent)
        let raw = try await send(req)
        mergeBack(raw, requestCookie: cookie)
        return try parseDownloadData(raw) { _, message in
            message.isEmpty ? "获取下载链接失败" : message
        }
    }

    /// 游客取链（对应 Kotlin getGuestShareDownloadLink）：同端点同 body，不带账号 Cookie，
    /// 只带缓存的游客 __pugs（如有），请求用游客 UA + Sec-Ch-Ua。
    /// 先从本次响应 Set-Cookie 捕获 __pugs（与本次直链同响应绑定），写进 DownloadLink.guestCookie。
    /// UC 游客实测大文件也放行、没有大小上限（与夸克不同）。
    func getGuestShareDownloadLink(file: ShareFile, session: ShareSession) async throws -> DownloadLink {
        let body: [String: Any] = [
            "fids": [file.fid],
            "pwd_id": session.shareId,
            "stoken": session.stoken,
            "fids_token": [file.fidToken]
        ]
        let req = try postJSON(
            url: UCAPI.downloadURL, cookie: guestPugs, body: body, ua: UCAPI.guestUserAgent,
            extraHeaders: ["Sec-Ch-Ua": UCAPI.guestSecChUa]
        )
        let raw = try await send(req)
        let responsePugs = pugs(from: raw.cookiePairs)
        if let responsePugs = responsePugs { guestPugs = responsePugs }
        var link = try parseDownloadData(raw) { code, message in
            UCAPI.guestErrorMessage(code: code, message: message)
        }
        link.guestCookie = responsePugs ?? guestPugs
        return link
    }

    /// 视频原画直链（仅登录态，对应 Kotlin getVideoPreview）：成功返回原画 URL，
    /// 失败返回 nil 由调用方回退普通取链。原画直链可绕过服务端把首段替换成宣传片的问题。
    func getVideoPreview(file: ShareFile, session: ShareSession, cookie: String) async -> String? {
        var url = UCAPI.videoPreviewURL
        url += "&pwd_id=\(urlEncode(session.shareId))"
        url += "&stoken=\(urlEncode(session.stoken))"
        url += "&fid=\(urlEncode(file.fid))"
        url += "&fid_token=\(urlEncode(file.fidToken))"
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "GET"
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue(UCAPI.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(UCAPI.webOrigin, forHTTPHeaderField: "Origin")
        req.setValue(UCAPI.downloadReferer, forHTTPHeaderField: "Referer")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let raw = try? await send(req) else { return nil }
        mergeBack(raw, requestCookie: cookie)
        guard let obj = (try? JSONSerialization.jsonObject(with: raw.data)) as? [String: Any] else { return nil }
        guard jsonInt(obj, "status") == 200 || jsonInt(obj, "code") == 0,
              let data = obj["data"] as? [String: Any],
              let playInfo = data["play_info"] as? [String: Any] else { return nil }
        let playUrl = jsonString(playInfo, "url")
        return playUrl.isEmpty ? nil : playUrl
    }

    /// download 接口的 data 是数组，单独解析（对应 Kotlin 取链函数的公共尾部）
    private func parseDownloadData(_ raw: RawResponse, errorMapper: (Int, String) -> String) throws -> DownloadLink {
        guard let obj = (try? JSONSerialization.jsonObject(with: raw.data)) as? [String: Any] else {
            throw QuarkError("响应解析失败（HTTP \(raw.http.statusCode)）")
        }
        let code = jsonInt(obj, "code")
        if jsonInt(obj, "status") != 200 && code != 0 {
            throw QuarkError(errorMapper(code, jsonString(obj, "message")), code: code)
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

    /// 从 Cookie 对里取出游客态令牌，返回可直接当 Cookie 头用的 `__pugs=值`；没有则 nil
    private func pugs(from pairs: [(name: String, value: String)]) -> String? {
        guard let pair = pairs.first(where: { $0.name == "__pugs" && !$0.value.isEmpty }) else { return nil }
        return "__pugs=\(pair.value)"
    }

    /// 游客取链的错误码 → 中文提示（对应 Kotlin getGuestShareDownloadLink 的码映射）
    private static func guestErrorMessage(code: Int, message: String) -> String {
        switch code {
        case 31001: return "该分享需要登录 UC 网盘后才能下载"
        case 23018: return "该文件超出游客可获取的大小上限，请先登录 UC 网盘再下载"
        case 14001: return "分享已失效或提取码有误，请重新解析"
        case 41020: return "文件令牌已过期，请重新解析分享"
        default: return message.isEmpty ? "获取下载链接失败" : message
        }
    }

    private func isVideoFile(_ file: ShareFile) -> Bool {
        let ext = (file.fname as NSString).pathExtension.lowercased()
        return UCAPI.videoExtensions.contains(ext)
    }

    // MARK: - 取链编排（对应 Kotlin UCResolveRepository + ResolveViewModel）

    /// 点文件后的完整取链流程，返回直链、下载必须用的 Cookie、是否游客态。
    ///
    /// - 未设置 UC Cookie：游客取链，下载 Cookie = 直链自带的 guestCookie（__pugs）。
    /// - 已设置 Cookie：先刷新 __puus；视频文件优先 video_preview 原画直链，
    ///   失败或非视频走免转存取链。UC 下载不转存、不做空间校验。
    func resolveDownloadLink(file: ShareFile, session: ShareSession) async throws -> (link: DownloadLink, cookie: String, isGuest: Bool) {
        let stored = CookieStore.shared.cookie(for: .uc)
        if stored.isEmpty {
            let link = try await getGuestShareDownloadLink(file: file, session: session)
            return (link, link.guestCookie, true)
        }
        let fresh = await freshCookie()
        if isVideoFile(file),
           let previewUrl = await getVideoPreview(file: file, session: session, cookie: fresh) {
            let link = DownloadLink(fid: file.fid, filename: file.fname, downloadUrl: previewUrl, size: file.fsize)
            return (link, fresh, false)
        }
        let link = try await getShareDownloadLink(file: file, session: session, cookie: fresh)
        return (link, fresh, false)
    }
}

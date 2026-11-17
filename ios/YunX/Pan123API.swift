import Foundation

/// 123 云盘 API 封装（移植自 Kotlin Pan123Api + Pan123Constants + Pan123DeviceId + Pan123LoginSupport）。
///
/// 鉴权体系：
/// - 登录 `user.123pan.cn/api/user/sign_in`：无需签名，返回 JWT（data.token），成功判定 code == 200；
/// - 分享列表 `yun.123pan.cn/b/api/share/get`：匿名、无需签名；
/// - 其余鉴权请求：必须带 `auth-key` / `auth-value` 签名头（CRC32 派生，见 makeSign）。
///
/// 下载流程：分享文件无需转存——直接拿 ShareKey + FileID + S3KeyFlag + Etag + Size
/// 换 DownloadURL（download-v2 包装），对 params 做 Base64 解码得真实 CDN 直链，下载带 Referer。
/// 凭据形态：authorToken（账号密码登录换得，或网页登录后从 localStorage 复制粘贴），当 Bearer 用。
final class Pan123API {
    static let shared = Pan123API()
    private init() {}

    // MARK: - 常量（对应 Kotlin Pan123Constants）

    private static let loginBase = "https://user.123pan.cn"
    private static let apiBase = "https://yun.123pan.cn"
    private static let downloadBase = "https://www.123865.com"

    private static let loginURL = "\(loginBase)/api/user/sign_in"
    private static let signInOrigin = loginBase
    private static let signInReferer = "\(loginBase)/"
    private static let appVersionSignIn = "132"
    private static let shareGetURL = "\(apiBase)/b/api/share/get"
    private static let shareDownloadInfoURL = "\(downloadBase)/b/api/share/download/info"
    private static let fileListURL = "\(apiBase)/b/api/file/list/new"
    private static let fileDownloadInfoURL = "\(apiBase)/api/file/download_info"
    private static let userInfoURL = "\(apiBase)/b/api/user/info"

    static let webUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36"
    /// Dart UA（分享列表匿名请求）
    private static let dartUA = "Dart/3.12 (dart:io)"
    private static let platformWeb = "web"
    private static let platformAndroid = "android"
    private static let appVersionWeb = "3"
    private static let appVersionAndroid = "39"

    /// 分享下载真实 CDN 直链下载时必须携带的 Referer
    static let downloadReferer = "https://yun.123pan.cn/"

    /// 下载请求头（桌面 ResolveViewModel：UA + Referer）
    static var downloadHeaders: [String: String] {
        ["User-Agent": webUA, "Referer": downloadReferer]
    }

    // 签名算法常量：数字 0-9 的替换表（索引 = 数字值）、内部固定 OS/VER、时间基准偏移 +16h
    private static let signTable = "adefghlmyijnopkqrstubcvwsz"
    private static let signOS = "web"
    private static let signVer = "3"
    private static let signOffsetSeconds: Int64 = 57600

    /// 设备标识（loginuuid 请求头，32 位十六进制）：持久化、跨启动稳定（对应 Kotlin Pan123DeviceId）
    private var loginuuid: String {
        let key = "pan123_loginuuid"
        if let saved = UserDefaults.standard.string(forKey: key),
           saved.range(of: #"^[0-9a-fA-F]{32}$"#, options: .regularExpression) != nil {
            return saved
        }
        let value = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    /// 分享会话（对应编排层 createSession 的产物：ShareKey + 提取码 + 标题）
    struct ShareSession {
        let shareKey: String
        let sharePwd: String
        let title: String
    }

    /// 登录结果（对应 Kotlin Pan123LoginResult）：失败文案绝不复述服务端原文
    enum LoginResult {
        case success(token: String)
        case failure(message: String)
    }

    // MARK: - 签名算法

    /**
     * 生成 123 云盘签名头：
     * - auth-key (timeSign) = crc32_hex(替换表映射后的 UTC "YYYYMMDDHHmm"，基准 ts + 57600s = +16h)；
     * - auth-value = "<ts>-<random>-<crc32_hex(ts|random|path|web|3|auth_key)>"；
     * 签名内部固定 OS=web / VER=3（与请求头 platform/app-version 无关）。
     * - Parameter path: URL 路径：含 /b 前缀、不含 host、不含 query
     */
    func makeSign(path: String, ts: Int64 = Int64(Date().timeIntervalSince1970)) -> (authKey: String, authValue: String) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = Date(timeIntervalSince1970: TimeInterval(ts + Pan123API.signOffsetSeconds))
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let minute = String(format: "%04d%02d%02d%02d%02d",
                            comps.year ?? 0, comps.month ?? 0, comps.day ?? 0,
                            comps.hour ?? 0, comps.minute ?? 0)
        let table = Array(Pan123API.signTable)
        let substituted = minute.map { ch -> Character in
            let d = Int(String(ch))!
            return table[d]
        }
        let authKey = wCRC32Hex(String(substituted))
        let random = Int.random(in: 0..<10_000_000)
        let data = "\(ts)|\(random)|\(path)|\(Pan123API.signOS)|\(Pan123API.signVer)|\(authKey)"
        let authValue = "\(ts)-\(random)-\(wCRC32Hex(data))"
        return (authKey, authValue)
    }

    // MARK: - 登录

    /**
     * 账号密码登录 → data.token（authorToken）。
     * 注意：密码按原值提交（不 trim），账号才 trim；成功判定是 code == 200（不是其它接口的 0）。
     */
    func passwordLogin(account: String, password: String) async -> LoginResult {
        let passport = account.trimmingCharacters(in: .whitespaces)
        if passport.isEmpty || password.isEmpty {
            return .failure(message: "请输入账号和密码")
        }
        if passport.count > 254 || password.count > 256 {
            return .failure(message: "账号或密码过长")
        }
        do {
            let body = try Wave2HTTP.jsonBody([
                "passport": passport,
                "password": password,
                "remember": false
            ])
            let req = Wave2HTTP.request(url: Pan123API.loginURL, method: "POST", headers: [
                "platform": Pan123API.platformWeb,
                "app-version": Pan123API.appVersionSignIn,
                "loginuuid": loginuuid,
                "Origin": Pan123API.signInOrigin,
                "Referer": Pan123API.signInReferer,
                "User-Agent": Pan123API.webUA,
                "Content-Type": "application/json;charset=UTF-8"
            ], body: body)
            let raw = try await Wave2HTTP.send(req)
            let json = wJSONObj(raw.data)
            let code = json?.wInt("code", -1) ?? -1
            let token = json?.wObj("data")?.wStr("token") ?? ""
            if (200...299).contains(raw.http.statusCode) && code == 200 && Pan123API.isValidToken(token) {
                return .success(token: token)
            }
            return .failure(message: Pan123API.describeLoginFailure(
                httpStatus: raw.http.statusCode, code: code,
                serverMessage: json?.wStr("message") ?? ""
            ))
        } catch {
            return .failure(message: "网络异常，无法连接 123 登录服务，请稍后重试")
        }
    }

    /// 校验登录态 + 取昵称：GET /b/api/user/info → data.Nickname；失败返回 nil
    func fetchNickname(token: String) async -> String? {
        do {
            let json = try await getAuth(url: Pan123API.userInfoURL, path: "/b/api/user/info", token: token)
            try checkOk(json, fallback: "获取用户信息失败")
            let nickname = json.wObj("data")?.wStr("Nickname") ?? ""
            return nickname.isEmpty ? nil : nickname
        } catch { return nil }
    }

    /// 网盘空间详情：GET /b/api/user/info → SpaceUsed / SpacePermanent / SpaceTemp；失败返回 nil
    func getQuota(token: String) async -> QuotaInfo? {
        do {
            let json = try await getAuth(url: Pan123API.userInfoURL, path: "/b/api/user/info", token: token)
            try checkOk(json, fallback: "获取空间详情失败")
            guard let data = json.wObj("data") else { return nil }
            return QuotaInfo(
                used: data.wLong("SpaceUsed"),
                total: data.wLong("SpacePermanent") + data.wLong("SpaceTemp")
            )
        } catch { return nil }
    }

    // MARK: - 分享

    /// 创建分享会话：用分享根目录列表校验提取码 + 取标题（对应编排层 createSession）
    func createSession(shareKey: String, pwd: String?) async throws -> ShareSession {
        let sharePwd = pwd ?? ""
        let (files, _) = try await getShareFiles(
            shareKey: shareKey, sharePwd: sharePwd, parentFileId: "0", next: "0", page: 1
        )
        let firstName = files.first?.fname ?? ""
        let title = firstName.isEmpty ? shareKey : firstName
        return ShareSession(shareKey: shareKey, sharePwd: sharePwd, title: title)
    }

    /**
     * 读取分享文件/目录列表单页（匿名），支持提取码、翻页、进入子目录。
     * - Returns: (文件列表, 下一页游标 or nil=末页)。Next=="-1" 无下一页，空串 "" 表示还有下一页。
     */
    func getShareFiles(shareKey: String, sharePwd: String, parentFileId: String,
                       next: String, page: Int) async throws -> (files: [ShareFile], nextCursor: String?) {
        // 参数顺序与抓包一致；无提取码时不传 SharePwd（传空值会 400 "请输入Next"）
        var url = Pan123API.shareGetURL
        url += "?limit=100"
        url += "&next=\(next)"
        url += "&orderBy=file_name"
        url += "&orderDirection=asc"
        url += "&shareKey=\(wFormEncode(shareKey))"
        url += "&ParentFileId=\(parentFileId)"
        url += "&Page=\(page)"
        if !sharePwd.isEmpty {
            url += "&SharePwd=\(wFormEncode(sharePwd))"
        }
        let req = Wave2HTTP.request(url: url, headers: ["User-Agent": Pan123API.dartUA])
        let json = try await executeJson(req)
        try checkOk(json, fallback: "获取文件列表失败")
        guard let data = json.wObj("data") else { return ([], nil) }
        if data.wBool("Expired") {
            throw Wave2Error("分享已失效")
        }
        let files = parseInfoList(data)
        let nextCursor = data.wStr("Next") == "-1" ? nil : data.wStr("Next")
        return (files, nextCursor)
    }

    /// 分享列目录全部（对应编排层 listFiles：next 固定 "0"，翻页靠 Page 递增；
    /// 结束条件：Next=="-1" 或列表为空）。dirFid 根目录传 "0"
    func listAllShareFiles(session: ShareSession, dirFid: String) async throws -> [ShareFile] {
        var all: [ShareFile] = []
        var page = 1
        while true {
            let (files, nextCursor) = try await getShareFiles(
                shareKey: session.shareKey, sharePwd: session.sharePwd,
                parentFileId: dirFid, next: "0", page: page
            )
            all += files
            let hasMore = !files.isEmpty && nextCursor != nil
            page += 1
            if !hasMore || page >= 50 { break }
        }
        return all
    }

    /**
     * 分享文件取下载直链（POST /b/api/share/download/info，需登录 token + 签名）。
     * - Parameter file: 列表项（fidToken 编码了 "S3KeyFlag|Etag|StorageNode"）
     * - Returns: 解码后的真实 CDN 直链（下载需带 Referer: https://yun.123pan.cn/）
     */
    func getShareDownloadLink(shareKey: String, file: ShareFile, token: String) async throws -> DownloadLink {
        if token.isEmpty { throw Wave2Error("请先登录123云盘") }
        let (s3KeyFlag, etag, _) = Pan123API.decodeToken(file.fidToken)
        let body = try Wave2HTTP.jsonBody([
            "ShareKey": shareKey,
            "FileID": file.fid,
            "S3KeyFlag": s3KeyFlag,
            "Size": file.fsize,
            "Etag": etag
        ])
        // 签名 path 与请求头一致（含 /b）；分享下载信息走 android 平台头，签名内部仍固定 web/3
        let json = try await postAuth(
            url: Pan123API.shareDownloadInfoURL, path: "/b/api/share/download/info",
            body: body, token: token,
            platform: Pan123API.platformAndroid, appVersion: Pan123API.appVersionAndroid
        )
        try checkOk(json, fallback: "获取下载链接失败")
        guard let data = json.wObj("data") else { throw Wave2Error("获取下载链接失败") }
        let downloadUrl = data.wStr("DownloadURL")
        if downloadUrl.isEmpty { throw Wave2Error("获取下载链接失败") }
        // download-v2 包装 URL → Base64 解码 params 得真实 CDN 文件 URL
        let decoded = decodeDownloadUrl(downloadUrl) ?? downloadUrl
        // 同样循环跟随可能存在的 redirect_url（auto_redirect=0）
        let realUrl = await followRedirectUrl(decoded)
        return DownloadLink(fid: file.fid, filename: file.fname, downloadUrl: realUrl, size: file.fsize)
    }

    // MARK: - 个人盘

    /// 个人盘文件列表单页：GET /b/api/file/list/new。返回 (文件列表, 下一页游标 or null)
    func listCloudFiles(parentFileId: String, token: String) async throws -> (files: [ShareFile], nextCursor: String?) {
        var url = Pan123API.fileListURL
        url += "?driveId=0&limit=100&next=0&orderBy=update_time&orderDirection=desc"
        url += "&parentFileId=\(parentFileId)"
        url += "&trashed=false&SearchData=&Page=1&OnlyLookAbnormalFile=0"
        url += "&event=homeListFile&operateType=1&inDirectSpace=false"
        let json = try await getAuth(url: url, path: "/b/api/file/list/new", token: token)
        try checkOk(json, fallback: "获取文件列表失败")
        guard let data = json.wObj("data") else { return ([], nil) }
        let files = parseInfoList(data)
        let next = data.wStr("Next") == "-1" ? nil : data.wStr("Next")
        return (files, next)
    }

    /// 个人盘下载信息：POST /api/file/download_info（注意无 /b/）。返回真实直链
    func getDownloadLink(file: ShareFile, token: String) async throws -> DownloadLink {
        let (s3keyFlag, etag, _) = Pan123API.decodeToken(file.fidToken)
        let body = try Wave2HTTP.jsonBody([
            "driveId": 0,
            "etag": etag,
            "fileId": Int64(file.fid) ?? 0,
            "s3keyFlag": s3keyFlag,
            "type": 0,
            "fileName": file.fname,
            "size": file.fsize
        ])
        let json = try await postAuth(
            url: Pan123API.fileDownloadInfoURL, path: "/api/file/download_info",
            body: body, token: token
        )
        try checkOk(json, fallback: "获取下载链接失败")
        guard let data = json.wObj("data") else { throw Wave2Error("获取下载链接失败") }
        let raw = data.wStr("DownloadUrl")
        if raw.isEmpty { throw Wave2Error("获取下载链接失败") }
        let decoded = decodeDownloadUrl(raw) ?? raw
        let url = await followRedirectUrl(decoded)
        return DownloadLink(fid: file.fid, filename: file.fname, downloadUrl: url, size: file.fsize)
    }

    // MARK: - 内部工具

    /// 解析响应 InfoList（分享与个人盘结构一致）
    private func parseInfoList(_ data: [String: Any]) -> [ShareFile] {
        data.wObjs("InfoList").map { item in
            ShareFile(
                fid: item.wStr("FileId"),
                fname: item.wStr("FileName"),
                fsize: item.wLong("Size"),
                isdir: item.wInt("Type") == 1,
                pdirFid: item.wStr("ParentFileId"),
                // 123 下载/转存需要 S3KeyFlag + Etag + StorageNode，编码进 fidToken："S3KeyFlag|Etag|StorageNode"
                fidToken: "\(item.wStr("S3KeyFlag"))|\(item.wStr("Etag"))|\(item.wStr("StorageNode"))",
                modifyTime: item.wStr("UpdateAt")
            )
        }
    }

    /// 解码 fidToken（"S3KeyFlag|Etag|StorageNode"；旧格式两段时 StorageNode 为空）
    static func decodeToken(_ fidToken: String) -> (s3KeyFlag: String, etag: String, storageNode: String) {
        let parts = fidToken.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        return (
            parts.count > 0 ? parts[0] : "",
            parts.count > 1 ? parts[1] : "",
            parts.count > 2 ? parts[2] : ""
        )
    }

    /**
     * 解码 123 下载 URL（兼容两种形态）：
     * - 形态 1：整段 base64（alist 风格）→ 直接解码
     * - 形态 2：download-v2?params=<base64 URL-safe> → 解码 params
     */
    private func decodeDownloadUrl(_ downloadUrl: String) -> String? {
        let trimmed = downloadUrl.trimmingCharacters(in: .whitespaces)
        if !trimmed.contains("://") {
            guard let data = Data(base64Encoded: trimmed),
                  let s = String(data: data, encoding: .utf8),
                  s.lowercased().hasPrefix("http") else { return nil }
            return s
        }
        guard let idx = trimmed.range(of: "params=") else { return nil }
        let rest = trimmed[idx.upperBound...]
        let params = rest.split(separator: "&").first.map(String.init) ?? String(rest)
        let normalized = params.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard let data = wBase64Decode(normalized),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    /**
     * 跟随 123 CDN 的 redirect_url：带 auto_redirect=0 时，GET 直链返回
     * JSON {"code":0,"data":{"redirect_url":"..."}} 而非直接文件，
     * 且 redirect_url 自身也可能带 auto_redirect=0（可能多跳）。循环跟随（最多 5 跳），
     * 每跳仅当响应体很小（≤8KB，JSON 跳转页）才读取解析；大响应视为真实文件流，返回当前 URL。
     */
    private func followRedirectUrl(_ initialUrl: String) async -> String {
        var url = initialUrl
        for _ in 0..<5 {
            guard let next = await probeJsonRedirect(url) else { return url }
            url = next
        }
        return url
    }

    /// 探测单跳：响应为小 JSON 且含 data.redirect_url 时返回新地址，否则 nil
    private func probeJsonRedirect(_ url: String) async -> String? {
        do {
            let req = Wave2HTTP.request(url: url, headers: [
                "Referer": Pan123API.downloadReferer,
                "User-Agent": Pan123API.dartUA
            ])
            let raw = try await Wave2HTTP.send(req)
            let len = Int64(raw.http.value(forHTTPHeaderField: "Content-Length") ?? "") ?? -1
            guard len >= 0 && len <= 8192 else { return nil }
            guard raw.text.trimmingCharacters(in: .whitespaces).hasPrefix("{"),
                  let json = wJSONObj(raw.data),
                  let redirect = json.wObj("data")?.wStr("redirect_url"), !redirect.isEmpty else { return nil }
            return redirect
        } catch { return nil }
    }

    /// 成功判定：code == 0（登录接口除外，为 200）
    private func checkOk(_ json: [String: Any], fallback: String) throws {
        let code = json.wInt("code", -1)
        if code == 0 { return }
        let msg = json.wStr("message").isEmpty ? fallback : json.wStr("message")
        throw Wave2Error("\(msg)（code=\(code)）")
    }

    /// 鉴权 GET（带 auth-key/auth-value 签名头）
    private func getAuth(url: String, path: String, token: String) async throws -> [String: Any] {
        let (ak, av) = makeSign(path: path)
        let req = Wave2HTTP.request(url: url, headers: [
            "platform": Pan123API.platformWeb,
            "app-version": Pan123API.appVersionWeb,
            "authorization": "Bearer \(token)",
            "loginuuid": loginuuid,
            "auth-key": ak,
            "auth-value": av,
            "User-Agent": Pan123API.webUA,
            "Accept": "application/json, text/plain, */*"
        ])
        return try await executeJson(req)
    }

    /// 鉴权 POST（带 auth-key/auth-value 签名头；签名内部固定 web/3）
    private func postAuth(url: String, path: String, body: Data, token: String,
                          platform: String = Pan123API.platformWeb,
                          appVersion: String = Pan123API.appVersionWeb) async throws -> [String: Any] {
        let (ak, av) = makeSign(path: path)
        let req = Wave2HTTP.request(url: url, method: "POST", headers: [
            "platform": platform,
            "app-version": appVersion,
            "authorization": "Bearer \(token)",
            "loginuuid": loginuuid,
            "auth-key": ak,
            "auth-value": av,
            "Content-Type": "application/json;charset=UTF-8",
            "User-Agent": Pan123API.webUA
        ], body: body)
        return try await executeJson(req)
    }

    private func executeJson(_ request: URLRequest) async throws -> [String: Any] {
        let raw = try await Wave2HTTP.send(request)
        if raw.data.isEmpty {
            throw Wave2Error("请求失败：响应为空（\(raw.http.statusCode)）")
        }
        guard let json = wJSONObj(raw.data) else {
            throw Wave2Error("请求失败：响应解析失败（HTTP \(raw.http.statusCode)）")
        }
        return json
    }

    // MARK: - 登录纯逻辑（对应 Kotlin Pan123LoginSupport，绝不透传服务端原文）

    /// 登录返回的令牌是否可用：非空、长度合理、不含控制字符
    static func isValidToken(_ value: String) -> Bool {
        if value.isEmpty || value.count > 16384 { return false }
        return value.range(of: #"[\x00-\x1f\x7f]"#, options: .regularExpression) == nil
    }

    /// 把登录失败的响应翻译成一句能给用户看的中文（服务端文案只用于分类，一个字都不回显）
    static func describeLoginFailure(httpStatus: Int, code: Int, serverMessage: String) -> String {
        let message = serverMessage.lowercased()
        let frequentKeywords = ["频繁", "频率", "次数", "稍后"]
        let verifyKeywords = ["验证码", "滑块", "安全验证", "验证失败", "captcha", "verify"]
        let frozenKeywords = ["冻结", "封禁", "封停", "注销", "禁用"]
        if (300...399).contains(httpStatus) { return "123 登录接口发生变化，请稍后重试" }
        if httpStatus == 429 { return "123 登录请求过于频繁，请稍后重试" }
        if httpStatus >= 500 { return "123 登录服务暂时不可用，请稍后重试" }
        if code == 429 { return "123 登录请求过于频繁，请稍后重试" }
        if frequentKeywords.contains(where: { message.contains($0) }) { return "123 登录请求过于频繁，请稍后重试" }
        if verifyKeywords.contains(where: { message.contains($0) }) { return "123 要求额外安全验证，请改用网页登录完成验证" }
        if frozenKeywords.contains(where: { message.contains($0) }) { return "123 账号暂时不可登录，请先在官方客户端检查账号状态" }
        return "123 登录失败，请检查账号和密码后重试"
    }
}

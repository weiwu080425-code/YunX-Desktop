import Foundation

/// 蓝奏云优享版 API 封装（移植自 Kotlin ILanzouApi + ILanzouConstants）。
///
/// 认证参数 appToken + uuid 走 URL query；appToken 特殊编码（标准编码后把 %3A 还原为冒号）。
/// 个人盘接口在 `apis.ilanzou.com`，分享接口在 `apix.ilanzou.com`，两套主机分别组装 URL。
/// 凭据形态：账号密码登录换 appToken（login），或直接粘贴已有 appToken；uuid 由 getUuid 获取，
/// 集成层应持久化 uuid 并全程复用（对应桌面版 ILanzouAccountRepository 的缓存）。
final class ILanzouAPI {
    static let shared = ILanzouAPI()
    private init() {}

    // MARK: - 常量（对应 Kotlin ILanzouConstants）

    static let apiBase = "https://apis.ilanzou.com"
    static let webSite = "https://www.ilanzou.com"
    /// 下载请求头（桌面 ResolveViewModel：UA + Referer + Origin，不带 Cookie）
    static let downloadReferer = "\(webSite)/"
    static let downloadOrigin = webSite
    static let webUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    private static let devType = "6"
    private static let devModel = "chrome"
    private static let shareDevModel = "Chrome"
    private static let devVersion = "125"
    /// 页大小固定 60
    private static let pageSize = 60

    private static let getUuidURL = "\(apiBase)/unproved/getUuid"
    private static let loginURL = "\(apiBase)/unproved/login"
    private static let accountMapURL = "\(apiBase)/proved/user/account/map"
    private static let fileListURL = "\(apiBase)/proved/record/file/list"
    private static let fileRedirectURL = "\(apiBase)/unproved/file/redirect"
    private static let fileTransferURL = "\(apiBase)/proved/file/transfer"
    private static let fileTransferNumURL = "\(apiBase)/proved/file/transfer/num"

    private static let shareAPIBase = "https://apix.ilanzou.com"
    private static let shareListURL = "\(shareAPIBase)/unproved/share/list"
    private static let shareRedirectURL = "\(shareAPIBase)/unproved/file/redirect"

    /// 根目录 id
    static let rootFolderId = "0"
    /// AES 密钥（下载取链的 auth / downloadId / timestamp 参数）
    private static let aesKey = "lanZouY-disk-app"
    private static let folderPrefix = "d:"
    private static let filePrefix = "f:"

    /// 下载请求头（取链成功后下载文件时使用）
    static var downloadHeaders: [String: String] {
        [
            "User-Agent": webUA,
            "Referer": downloadReferer,
            "Origin": downloadOrigin
        ]
    }

    /// 账号信息
    struct AccountInfo { let userId: String; let account: String; let nickname: String }

    /// 登录失效标记（服务端 code -1 / -2 或 401/403）
    private struct LoginExpired: Error {}
    /// 访问验证（409 + text/html）标记
    private struct AccessChallenge: Error {}

    // MARK: - 认证

    /// 获取设备标识
    func getUuid() async throws -> String {
        let url = buildUrl(path: ILanzouAPI.getUuidURL, uuid: "", appToken: nil, extra: true, params: [])
        let json = try await exec(Wave2HTTP.request(url: url, headers: commonHeaders(json: false)))
        let uuid = json.wStr("uuid")
        guard uuid.range(of: #"^[A-Za-z0-9_-]{8,128}$"#, options: .regularExpression) != nil else {
            throw Wave2Error("蓝奏优享未返回有效设备标识")
        }
        return uuid
    }

    /// 账号密码登录，返回 appToken
    func login(loginName: String, loginPwd: String, uuid: String) async throws -> String {
        let name = loginName.trimmingCharacters(in: .whitespaces)
        if name.isEmpty || loginPwd.isEmpty { throw Wave2Error("请输入蓝奏优享账号和密码") }
        if name.count > 254 { throw Wave2Error("蓝奏优享用户名过长") }
        if loginPwd.count > 256 { throw Wave2Error("蓝奏优享密码过长") }
        let url = buildUrl(path: ILanzouAPI.loginURL, uuid: uuid, appToken: nil, extra: true, params: [])
        let body = try Wave2HTTP.jsonBody(["loginName": name, "loginPwd": loginPwd])
        let json = try await execLogin(Wave2HTTP.request(
            url: url, method: "POST", headers: commonHeaders(json: true), body: body
        ))
        let token = json.wObj("data")?.wStr("appToken") ?? ""
        guard token.count >= 16,
              token.range(of: #"^[A-Za-z0-9._~+/=:!%&?\-]+$"#, options: .regularExpression) != nil else {
            throw Wave2Error("蓝奏优享未返回登录凭据，请稍后重试")
        }
        return token
    }

    /// 账号信息；失败返回 nil
    func fetchAccountInfo(appToken: String, uuid: String) async -> AccountInfo? {
        do {
            let url = buildUrl(path: ILanzouAPI.accountMapURL, uuid: uuid, appToken: appToken, extra: true, params: [])
            let json = try await exec(Wave2HTTP.request(url: url, headers: commonHeaders(json: false)))
            guard let map = json.wObj("map") else { return nil }
            var userId = wFirstNonBlank(map.wStr("userId"), map.wStr("userId"))
            if userId.isEmpty {
                let n = map.wInt("userId")
                if n != 0 { userId = "\(n)" }
            }
            if userId.isEmpty { return nil }
            var nickname = wFirstNonBlank(map.wStr("nickName"), map.wStr("nickname"), map.wStr("account"))
            if nickname.isEmpty { nickname = "蓝奏优享用户" }
            return AccountInfo(userId: userId, account: map.wStr("account"), nickname: nickname)
        } catch { return nil }
    }

    /// 容量信息：服务端单位为 KiB，换算成字节；失败返回 nil
    func getQuota(appToken: String, uuid: String) async -> QuotaInfo? {
        do {
            let url = buildUrl(path: ILanzouAPI.accountMapURL, uuid: uuid, appToken: appToken, extra: true, params: [])
            let json = try await exec(Wave2HTTP.request(url: url, headers: commonHeaders(json: false)))
            guard let map = json.wObj("map") else { return nil }
            let used = map.wLong("usedSize") * 1024
            let total = (map.wLong("totalSize") + map.wLong("vipSize") + map.wLong("rewardSize")) * 1024
            return QuotaInfo(used: used, total: total)
        } catch { return nil }
    }

    // MARK: - 个人盘

    /// 个人盘文件列表：自动翻页，合并文件夹与文件。folderId 根目录传 "0"
    func listFiles(appToken: String, uuid: String, folderId: String) async throws -> [ShareFile] {
        var all: [ShareFile] = []
        var seen = Set<String>()
        var page = 1
        while page <= 1000 {
            let params = [
                ("offset", "\(page)"),
                ("limit", "\(ILanzouAPI.pageSize)"),
                ("folderId", folderId),
                ("type", "0")
            ]
            let url = buildUrl(path: ILanzouAPI.fileListURL, uuid: uuid, appToken: appToken, extra: true, params: params)
            let json = try await exec(Wave2HTTP.request(url: url, headers: commonHeaders(json: false)))
            let list = json.wObjs("list")
            if list.isEmpty { break }
            var added = 0
            for item in list {
                if let file = parseItem(item), seen.insert(file.fid).inserted {
                    all.append(file)
                    added += 1
                }
            }
            if added == 0 { throw Wave2Error("蓝奏优享分页重复或不完整，请重新打开目录") }
            let totalPage = json.wInt("totalPage")
            if totalPage > 0 && page >= totalPage { break }
            if totalPage <= 0 && list.count < ILanzouAPI.pageSize { break }
            page += 1
        }
        return all
    }

    /// 个人盘下载取链：302 Location 或 JSON url / data.url；大小未知（0，交给下载层探测）
    func getDownloadLink(appToken: String, uuid: String, fileId: String, userId: String) async throws -> DownloadLink {
        let ts = wNowMs()
        let encTs = aesHex("\(ts)")
        // downloadId = AES('<fileId>|<userId>')，auth = AES('<fileId>|<毫秒时间戳>')，timestamp 与 auth 共用同一 ts
        let params = [
            ("enable", "1"),
            ("downloadId", aesHex("\(fileId)|\(userId)")),
            ("auth", aesHex("\(fileId)|\(ts)")),
            ("timestamp", encTs)
        ]
        // 该接口不带 extra=2
        let url = buildUrl(path: ILanzouAPI.fileRedirectURL, uuid: uuid, appToken: appToken,
                           extra: false, params: params, timestamp: encTs)
        let raw = try await Wave2HTTP.send(Wave2HTTP.request(url: url, headers: commonHeaders(json: false)),
                                           noRedirect: true)
        if (300...399).contains(raw.http.statusCode),
           let location = raw.http.value(forHTTPHeaderField: "Location"), !location.isEmpty {
            let resolved = URL(string: location, relativeTo: URL(string: ILanzouAPI.apiBase))?.absoluteString ?? location
            return DownloadLink(fid: ILanzouAPI.filePrefix + fileId, filename: "", downloadUrl: resolved, size: 0)
        }
        guard let json = wJSONObj(raw.data) else { throw Wave2Error("蓝奏优享未返回下载地址") }
        try checkCode(json)
        let link = wFirstNonBlank(json.wStr("url"), json.wObj("data")?.wStr("url") ?? "")
        if link.isEmpty { throw Wave2Error("蓝奏优享未返回下载地址，请检查文件权限") }
        return DownloadLink(fid: ILanzouAPI.filePrefix + fileId, filename: "", downloadUrl: link, size: 0)
    }

    // MARK: - 分享

    /// 分享文件列表（匿名可用）。folderId 为 nil 时返回分享根条目，传入数字目录 id 时返回该目录内容；自动翻页
    func shareList(shareId: String, folderId: String?, uuid: String) async throws -> [ShareFile] {
        var all: [ShareFile] = []
        var seen = Set<String>()
        var page = 1
        while page <= 1000 {
            var params: [(String, String)] = []
            if let folderId = folderId, !folderId.isEmpty { params.append(("folderId", folderId)) }
            params.append(("offset", "\(page)"))
            params.append(("limit", "\(ILanzouAPI.pageSize)"))
            let url = shareUrl(path: ILanzouAPI.shareListURL, uuid: uuid, shareId: shareId, params: params)
            let json = try await execShare(Wave2HTTP.request(url: url, headers: commonHeaders(json: false)))
            let list = json.wObjs("list")
            if list.isEmpty { break }
            var added = 0
            for item in list {
                if let file = parseItem(item), seen.insert(file.fid).inserted {
                    all.append(file)
                    added += 1
                }
            }
            if added == 0 { break }
            let totalPage = json.wInt("totalPage")
            if totalPage > 0 && page >= totalPage { break }
            if totalPage <= 0 && list.count < ILanzouAPI.pageSize { break }
            page += 1
        }
        return all
    }

    /// 分享文件下载取链（匿名可用）：/unproved/file/redirect 返回 302 Location 或 JSON url。
    /// downloadId = AES('<fileId>|<userId>')、auth = AES('<fileId>|<ts>')（未登录 userId 传空串）。
    func shareDownload(shareId: String, fileId: String, userId: String, uuid: String) async throws -> DownloadLink {
        let ts = wNowMs()
        let params = [
            ("downloadId", aesHex("\(fileId)|\(userId)")),
            ("enable", "1"),
            ("devType", ILanzouAPI.devType),
            ("uuid", uuid),
            ("timestamp", aesHex("\(ts)")),
            ("auth", aesHex("\(fileId)|\(ts)")),
            ("shareId", shareId)
        ]
        let query = params.map { "\($0.0)=\(wTokenEncode($0.1))" }.joined(separator: "&")
        let url = "\(ILanzouAPI.shareRedirectURL)?\(query)"
        let raw = try await Wave2HTTP.send(Wave2HTTP.request(url: url, headers: commonHeaders(json: false)),
                                           noRedirect: true)
        if (300...399).contains(raw.http.statusCode),
           let location = raw.http.value(forHTTPHeaderField: "Location"), !location.isEmpty {
            let resolved = URL(string: location, relativeTo: URL(string: ILanzouAPI.shareAPIBase))?.absoluteString ?? location
            return DownloadLink(fid: ILanzouAPI.filePrefix + fileId, filename: "", downloadUrl: resolved, size: 0)
        }
        guard let json = wJSONObj(raw.data) else { throw Wave2Error("蓝奏优享未返回下载地址") }
        let link = wFirstNonBlank(json.wStr("url"), json.wObj("data")?.wStr("url") ?? "")
        if link.isEmpty {
            throw Wave2Error(wFirstNonBlank(json.wStr("msg"), "蓝奏优享未返回下载地址，请检查文件权限"))
        }
        return DownloadLink(fid: ILanzouAPI.filePrefix + fileId, filename: "", downloadUrl: link, size: 0)
    }

    /// 分享转存（需登录）：返回 transferKey（可能为空，表示已同步完成）
    func transferShare(appToken: String, uuid: String, shareId: String,
                       fileIds: [String], folderIds: [String], targetFolderId: String) async throws -> String {
        let url = buildUrl(path: ILanzouAPI.fileTransferURL, uuid: uuid, appToken: appToken, extra: true, params: [])
        let body = try Wave2HTTP.jsonBody([
            "targetFileId": fileIds.joined(separator: ","),
            "targetFolderId": folderIds.joined(separator: ","),
            "folderId": targetFolderId.isEmpty ? ILanzouAPI.rootFolderId : targetFolderId,
            "shareId": shareId
        ])
        let json = try await exec(Wave2HTTP.request(url: url, method: "POST", headers: commonHeaders(json: true), body: body))
        return wFirstNonBlank(
            json.wObj("data")?.wStr("transferKey") ?? "",
            json.wObj("map")?.wStr("transferKey") ?? "",
            json.wStr("transferKey"),
            json.wStr("data")
        )
    }

    /// 分享转存进度：返回 map.num（== 1 表示完成）
    func transferCount(appToken: String, uuid: String, transferKey: String) async throws -> Int {
        let url = buildUrl(path: ILanzouAPI.fileTransferNumURL, uuid: uuid, appToken: appToken,
                           extra: true, params: [("transferKey", transferKey)])
        let json = try await exec(Wave2HTTP.request(url: url, headers: commonHeaders(json: false)))
        return json.wObj("map")?.wInt("num") ?? 0
    }

    // MARK: - 内部

    private func parseItem(_ item: [String: Any]) -> ShareFile? {
        if item.wInt("fileType") == 2 {
            let fid = wFirstNonBlank(item.wStr("folderId"), "\(item.wInt("folderId"))")
            if fid.isEmpty || fid == "0" { return nil }
            return ShareFile(
                fid: ILanzouAPI.folderPrefix + fid,
                fname: item.wStr("folderName"),
                fsize: 0, isdir: true, pdirFid: "", fidToken: "",
                modifyTime: wFirstNonBlank(item.wStr("updTime"), item.wStr("addTime"))
            )
        }
        let fid = wFirstNonBlank(item.wStr("fileId"), "\(item.wInt("fileId"))")
        if fid.isEmpty || fid == "0" { return nil }
        return ShareFile(
            fid: ILanzouAPI.filePrefix + fid,
            fname: item.wStr("fileName"),
            fsize: item.wLong("fileSize") * 1024,
            isdir: false, pdirFid: "", fidToken: "",
            modifyTime: wFirstNonBlank(item.wStr("updTime"), item.wStr("addTime"))
        )
    }

    /// 个人盘 URL 组装：公共头参数 + 业务参数（可带 appToken）
    private func buildUrl(path: String, uuid: String, appToken: String?, extra: Bool,
                          params: [(String, String)], timestamp: String? = nil) -> String {
        var parts: [(String, String)] = [
            ("uuid", uuid),
            ("devType", ILanzouAPI.devType),
            ("devCode", uuid),
            ("devModel", ILanzouAPI.devModel),
            ("devVersion", ILanzouAPI.devVersion),
            ("appVersion", ""),
            ("timestamp", timestamp ?? aesHex("\(wNowMs())"))
        ]
        if let appToken = appToken, !appToken.isEmpty { parts.append(("appToken", appToken)) }
        if extra { parts.append(("extra", "2")) }
        parts += params
        let query = parts.map { "\($0.0)=\(wTokenEncode($0.1))" }.joined(separator: "&")
        return "\(path)?\(query)"
    }

    /// 分享 URL 组装：公共参数 + shareId + 业务参数（不带 appToken）
    private func shareUrl(path: String, uuid: String, shareId: String, params: [(String, String)]) -> String {
        var parts: [(String, String)] = [
            ("uuid", uuid),
            ("devType", ILanzouAPI.devType),
            ("devCode", uuid),
            ("devModel", ILanzouAPI.shareDevModel),
            ("devVersion", ILanzouAPI.devVersion),
            ("appVersion", ""),
            ("timestamp", aesHex("\(wNowMs())")),
            ("extra", "2"),
            ("shareId", shareId)
        ]
        parts += params
        let query = parts.map { "\($0.0)=\(wTokenEncode($0.1))" }.joined(separator: "&")
        return "\(path)?\(query)"
    }

    private func commonHeaders(json: Bool) -> [String: String] {
        var headers = [
            "User-Agent": ILanzouAPI.webUA,
            "Origin": ILanzouAPI.webSite,
            "Referer": ILanzouAPI.downloadReferer,
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "zh-CN,zh;q=0.9",
            // 该站 CDN/WAF（ESA + acw_tc）对浏览器式请求放行、对"裸"HTTP 客户端返回空列表，
            // 故补全 Chrome 客户端提示头，否则 list 恒为空
            "sec-ch-ua": "\"Google Chrome\";v=\"131\", \"Chromium\";v=\"131\", \"Not_A Brand\";v=\"24\"",
            "sec-ch-ua-mobile": "?0",
            "sec-ch-ua-platform": "\"Windows\"",
            "sec-fetch-dest": "empty",
            "sec-fetch-mode": "cors",
            "sec-fetch-site": "same-site"
        ]
        if json { headers["Content-Type"] = "application/json; charset=utf-8" }
        return headers
    }

    /// 分享接口执行：非 200 时用服务端 msg，不当成登录失效
    private func execShare(_ request: URLRequest) async throws -> [String: Any] {
        let raw = try await Wave2HTTP.send(request)
        guard let json = wJSONObj(raw.data) else {
            throw Wave2Error("蓝奏优享分享请求失败（\(raw.http.statusCode)）")
        }
        let code = json.wInt("code", -1)
        if code != 200 {
            throw Wave2Error(wFirstNonBlank(json.wStr("msg"), "蓝奏优享分享请求失败（\(code)）"))
        }
        return json
    }

    /// 执行请求并校验业务码；409 + text/html 访问验证自动重试一次
    private func exec(_ request: URLRequest) async throws -> [String: Any] {
        do {
            return try await doExec(request)
        } catch is AccessChallenge {
            do {
                return try await doExec(request)
            } catch is AccessChallenge {
                throw Wave2Error("蓝奏优享的访问验证未通过，请稍后重试或使用网页登录")
            }
        } catch is LoginExpired {
            throw Wave2Error("蓝奏优享登录已过期，请重新登录")
        }
    }

    /// 登录专用执行：登录失败（如「用户账号不存在」「密码错误」）原样透出服务端 msg；
    /// 仍保留 409 访问验证重试
    private func execLogin(_ request: URLRequest) async throws -> [String: Any] {
        do {
            return try await doExecLogin(request)
        } catch is AccessChallenge {
            do {
                return try await doExecLogin(request)
            } catch is AccessChallenge {
                throw Wave2Error("蓝奏优享的访问验证未通过，请稍后重试")
            }
        }
    }

    private func doExecLogin(_ request: URLRequest) async throws -> [String: Any] {
        let raw = try await Wave2HTTP.send(request)
        let contentType = raw.http.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard (200...299).contains(raw.http.statusCode) else {
            if raw.http.statusCode == 409 && contentType.contains("text/html") { throw AccessChallenge() }
            throw Wave2Error("蓝奏优享请求失败（\(raw.http.statusCode)）")
        }
        guard let json = wJSONObj(raw.data) else {
            if contentType.contains("text/html") { throw AccessChallenge() }
            throw Wave2Error("蓝奏优享请求失败（\(raw.http.statusCode)）")
        }
        if json.wInt("code", -1) != 200 {
            throw Wave2Error(json.wStr("msg").isEmpty ? "蓝奏优享登录失败，请检查账号密码" : json.wStr("msg"))
        }
        return json
    }

    private func doExec(_ request: URLRequest) async throws -> [String: Any] {
        let raw = try await Wave2HTTP.send(request)
        let contentType = raw.http.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard (200...299).contains(raw.http.statusCode) else {
            if raw.http.statusCode == 401 || raw.http.statusCode == 403 { throw LoginExpired() }
            if raw.http.statusCode == 409 && contentType.contains("text/html") { throw AccessChallenge() }
            throw Wave2Error("蓝奏优享请求失败（\(raw.http.statusCode)），请检查登录信息或稍后重试")
        }
        guard let json = wJSONObj(raw.data) else {
            if contentType.contains("text/html") { throw AccessChallenge() }
            throw Wave2Error("蓝奏优享请求失败（\(raw.http.statusCode)），请检查登录信息或稍后重试")
        }
        try checkCode(json)
        return json
    }

    private func checkCode(_ json: [String: Any]) throws {
        let code = json.wInt("code", -1)
        if code == 200 { return }
        if code == -1 || code == -2 { throw LoginExpired() }
        throw Wave2Error("蓝奏优享请求失败（\(code)），请检查登录信息或稍后重试")
    }

    /// AES/ECB/PKCS7 → 小写十六进制（下载取链的 auth / downloadId / timestamp 参数）
    private func aesHex(_ plain: String) -> String {
        wAESECBHex(key: ILanzouAPI.aesKey, plain: plain)
    }
}

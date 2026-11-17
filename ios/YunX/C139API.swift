import Foundation

// MARK: - 139 移动云盘 API（对应 Kotlin C139Api + C139Constants）

/// 移动云盘（139 云盘）外链解析，移植自 Kotlin C139Api + C139Constants。
///
/// 接口在 `share-kd-njs.yun.139.com`（与个人盘 kd-njs 不同机）：
/// - 外链详情 POST /yun-share/richlifeApp/devapp/IBatchOprTask/getOutLinkInfoV6：
///   **匿名即可**（account 传空、无 Authorization、无签名头），但必须带几个伪装头；
/// - 取直链 POST /yun-share/richlifeApp/devapp/IFileDownload/dlFromOutLinkV3：
///   AES-CBC 加密 + mcloud-sign 签名头，需要登录态 Authorization（Basic 凭证）。
///   直链是 OBS 预签名地址（900 秒有效），下载时 UA 必须用 PC_UA（Chrome/120）。
/// 凭据形态：粘贴登录 Cookie，从中提取 `authorization=` 的 Basic 值与账号
/// （ORCHES-I-ACCOUNT-ENCRYPT 或 Login_UserNumber）。
final class C139API {
    static let shared = C139API()
    private init() {}

    // MARK: 常量（C139Constants）

    static let pcUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    /// 外链详情接口要求的移动端 UA（PC UA 会被拒：getOutLinkInfoV6 error 9999）
    static let mobileUA = "Mozilla/5.0 (Linux; Android 10; TAS-AN00 Build/HUAWEITAS-AN00; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/150.0.7871.181 Mobile Safari/537.36 MCloudApp/12.27.0"

    private static let shareBase = "https://share-kd-njs.yun.139.com"
    private static let infoURL = "\(shareBase)/yun-share/richlifeApp/devapp/IBatchOprTask/getOutLinkInfoV6"
    private static let downloadURL = "\(shareBase)/yun-share/richlifeApp/devapp/IFileDownload/dlFromOutLinkV3"
    private static let generalURL = "\(shareBase)/yun-share/richlifeApp/devapp/IOutLinkQuery/getOutLinkGeneral"

    /// 外链详情接口专属头（源码实证：缺失/错误都会被拒）
    private static let flagHeaderName = "hcy-cool-flag"
    private static let flagHeaderValue = "1"
    private static let deviceInfoHeaderName = "x-deviceinfo"
    private static let deviceInfoHeaderValue = "||3|12.27.0|||||chrome 150.0.0.0|360X444|zh-cn|||"
    private static let huaweiChannelHeaderName = "x-huawei-channelsrc"
    private static let huaweiChannelHeaderValue = "10245500"
    private static let mmSourceHeaderName = "x-mm-source"
    private static let mmSourceHeaderValue = "0002"

    /// AES-CBC 固定密钥（源码硬编码）
    private static let aesKey = "PVGDwmcvfs1uV3d1"

    /// 分享根目录的父目录标记
    static let rootParentId = "root"
    /// 单页条数（源码在 200 条内循环累加）
    static let pageSize = 200
    static let maxItems = 20000

    /// 外链详情一次返回的全部内容
    struct ShareInfo {
        /// 分享者账号
        let account: String
        let files: [ShareFile]
        let title: String
    }

    /// 分享会话（shareId = linkId，stoken = passwd；平台私有会话，不用 Models 的 ShareSession）
    struct ShareSession {
        let shareId: String
        let stoken: String
        let title: String
    }

    /// 从粘贴的 Cookie 中提取出的登录态
    struct Credential {
        /// Basic 凭证（Cookie 里 authorization= 的值）
        let authorization: String
        /// 账号（手机号）
        let account: String
    }

    // MARK: - Cookie 解析（对应 Kotlin C139Constants 的同名函数）

    /// 取 Cookie 中某字段的值（忽略大小写；Cookie 里 authorization 的 key 是小写）
    static func cookieValue(_ cookie: String, _ name: String) -> String? {
        for part in cookie.split(separator: ";") {
            let kv = part.trimmingCharacters(in: .whitespaces)
            guard let eq = kv.firstIndex(of: "=") else { continue }
            let key = String(kv[..<eq])
            if key.lowercased() == name.lowercased() {
                let value = String(kv[kv.index(after: eq)...])
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    /// 从粘贴的 Cookie 里取 Authorization（Basic 凭证）：authorization= 的值
    static func extractAuthorization(_ cookie: String) -> String? {
        guard let value = cookieValue(cookie, "authorization") else { return nil }
        return value.isEmpty ? nil : value
    }

    /// 从粘贴的 Cookie 里取账号：优先 ORCHES-I-ACCOUNT-ENCRYPT（base64 手机号），其次 Login_UserNumber
    static func extractAccount(_ cookie: String) -> String? {
        if let encrypted = cookieValue(cookie, "ORCHES-I-ACCOUNT-ENCRYPT"),
           let raw = wBase64Decode(encrypted),
           let text = String(data: raw, encoding: .utf8),
           !text.isEmpty {
            return text
        }
        return cookieValue(cookie, "Login_UserNumber")
    }

    /// 从粘贴的 Cookie 构造登录态；提取不到返回 nil
    static func credential(fromCookie cookie: String) -> Credential? {
        guard let auth = extractAuthorization(cookie) else { return nil }
        return Credential(authorization: auth, account: extractAccount(cookie) ?? "")
    }

    // MARK: - 会话

    /// 创建分享会话：用匿名详情探一次根目录，顺带校验外链有效性并取标题
    func createSession(linkId: String, passwd: String) async throws -> ShareSession {
        let info = try await getShareInfo(linkId: linkId, passwd: passwd,
                                          parentId: C139API.rootParentId, account: "")
        return ShareSession(
            shareId: linkId,
            stoken: passwd,
            title: info.title.isEmpty ? linkId : info.title
        )
    }

    // MARK: - 分享列目录

    /**
     * 列某一级目录（匿名）：POST getOutLinkInfoV6。
     * parentId 根目录传 rootParentId("root")。内部按 200 条步进把全部页取完
     * （文件与文件夹在同一列表：文件夹在 caLst、普通文件在 coLst，coType==2 的也是文件夹）。
     */
    func listShareFiles(linkId: String, passwd: String, parentId: String,
                        account: String = "") async throws -> [ShareFile] {
        try await getShareInfo(linkId: linkId, passwd: passwd,
                               parentId: parentId, account: account).files
    }

    /// 取整个外链详情（分页在内部累加完毕）
    func getShareInfo(linkId: String, passwd: String, parentId: String, account: String) async throws -> ShareInfo {
        var files: [ShareFile] = []
        var title = ""
        var sharer = ""
        var begin = 1
        while begin <= C139API.maxItems {
            let body: [String: Any] = [
                "account": account,
                "linkID": linkId,
                "passwd": passwd,
                "pCaID": parentId.isEmpty ? C139API.rootParentId : parentId,
                "bNum": begin,
                "eNum": begin + C139API.pageSize - 1,
                "coIDLst": [Any](),
                "caIDLst": [Any]()
            ]
            let json = try await postPlain(url: C139API.infoURL, body: body)
            try checkResult(json, fallback: "获取分享列表失败")
            guard let data = json.wObj("data") else {
                return ShareInfo(account: sharer, files: files, title: title)
            }
            if title.isEmpty { title = data.wStr("lkName") }
            if sharer.isEmpty { sharer = data.wStr("account") }
            // 文件夹：caLst（文件夹没有大小字段）
            for item in data.wObjs("caLst") {
                let id = item.wStr("caID")
                if id.isEmpty { continue }
                files.append(ShareFile(
                    fid: id, fname: item.wStr("caName"), fsize: 0, isdir: true,
                    pdirFid: parentId, fidToken: "", modifyTime: item.wStr("ud")
                ))
            }
            // 内容：coLst（coType==2 也是文件夹）
            for item in data.wObjs("coLst") {
                let id = item.wStr("coID")
                if id.isEmpty { continue }
                let isDir = item.wInt("coType") == 2
                files.append(ShareFile(
                    fid: id,
                    fname: item.wStr("coName"),
                    fsize: isDir ? 0 : item.wLong("coSize"),
                    isdir: isDir,
                    pdirFid: parentId,
                    fidToken: "",
                    modifyTime: item.wStr("ud")
                ))
            }
            begin += C139API.pageSize
            // 终止条件：累计达到 total，或本页不足一页且无 total
            let total = data.wInt("total")
            let pageCount = data.wObjs("caLst").count + data.wObjs("coLst").count
            if total > 0 && files.count >= total { break }
            if total == 0 && pageCount < C139API.pageSize { break }
        }
        return ShareInfo(account: sharer, files: files, title: title)
    }

    /// 外链公开信息：POST getOutLinkGeneral（匿名；能拿到 lkName 标题与明文 passwd）
    func getShareGeneral(linkId: String) async throws -> (title: String, passwd: String)? {
        let json = try await postPlain(url: C139API.generalURL, body: ["getOutLinkInfoReq": ["linkID": linkId]])
        try checkResult(json, fallback: "获取分享信息失败")
        guard let data = json.wObj("data") else { return nil }
        return (data.wStr("lkName"), data.wStr("passwd"))
    }

    // MARK: - 取直链

    /**
     * 文件直链：POST dlFromOutLinkV3（加密 + 签名，需登录态）。
     * 返回 OBS 预签名直链（900 秒），下载时 UA 必须用 PC_UA。
     */
    func getDownloadLink(linkId: String, file: ShareFile, credential: Credential) async throws -> DownloadLink {
        let body: [String: Any] = [
            "dlFromOutLinkReqV3": [
                "account": credential.account,
                "linkID": linkId,
                "coIDLst": [["coID": file.fid, "category": 1]],
                "isDownList": false
            ]
        ]
        let json = try await postEncrypted(url: C139API.downloadURL, body: body,
                                           credential: credential, encrypt: true)
        try checkResult(json, fallback: "获取下载链接失败")
        let url = json.wObj("data")?.wStr("redrUrl") ?? ""
        if url.isEmpty { throw Wave2Error("获取下载链接失败") }
        return DownloadLink(fid: file.fid, filename: file.fname, downloadUrl: url, size: file.fsize)
    }

    /// 下载请求头：139 直链只要求 PC_UA（与列表/取链接口的移动端 UA 不同，源码实证）
    static func downloadHeaders() -> [String: String] {
        ["User-Agent": pcUA]
    }

    // MARK: - 内部实现：明文 / 加密请求

    /// 明文 JSON POST（外链详情专用）：匿名、移动端 UA + 几个伪装头，无 Authorization、无签名
    private func postPlain(url: String, body: [String: Any]) async throws -> [String: Any] {
        var headers = [
            "User-Agent": C139API.mobileUA,
            "Accept": "application/json, text/plain, */*",
            "Content-Type": "application/json;charset=UTF-8",
            "Origin": "https://yun.139.com",
            "Referer": "https://yun.139.com/"
        ]
        headers[C139API.flagHeaderName] = C139API.flagHeaderValue
        headers[C139API.deviceInfoHeaderName] = C139API.deviceInfoHeaderValue
        headers[C139API.huaweiChannelHeaderName] = C139API.huaweiChannelHeaderValue
        headers[C139API.mmSourceHeaderName] = C139API.mmSourceHeaderValue
        var req = Wave2HTTP.request(url: url, headers: headers)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await executeJson(req)
    }

    /**
     * 加密 JSON POST（取直链等登录态接口）：请求体 AES-CBC 加密，
     * 响应同样解密（服务端可能在密文后追加 gzip，解密后还要解压）。
     * 头带 Authorization + mcloud-sign（对加密后 base64 文本签名）+ timestamp。
     */
    private func postEncrypted(url: String, body: [String: Any], credential: Credential, encrypt: Bool) async throws -> [String: Any] {
        let jsonData = try JSONSerialization.data(withJSONObject: body)
        let jsonText = String(data: jsonData, encoding: .utf8) ?? "{}"
        let timestamp = C139API.timestampNow()
        let payload = encrypt ? C139API.encryptBody(jsonText) : jsonText
        let sign = C139API.mcloudSign(body: payload, timestamp: timestamp)
        var headers = [
            "User-Agent": C139API.pcUA,
            "Accept": "application/json, text/plain, */*",
            "Content-Type": "application/json;charset=UTF-8",
            "Origin": "https://yun.139.com",
            "Referer": "https://yun.139.com/",
            "Authorization": credential.authorization,
            "mcloud-sign": sign,
            "timestamp": timestamp,
            "x-m4c-caller": "PC",
            "x-m4c-src": "10002",
            "x-inner-ntwk": "2",
            "cmsfile": "100"
        ]
        if encrypt { headers["x-m4c-encrypt"] = "1" }
        var req = Wave2HTTP.request(url: url, headers: headers)
        req.httpMethod = "POST"
        req.httpBody = Data(payload.utf8)
        let raw = try await Wave2HTTP.send(req)
        var text = raw.text
        if encrypt {
            guard let decrypted = C139API.decryptBody(text) else {
                throw Wave2Error("请求失败：响应解密失败（HTTP \(raw.http.statusCode)）")
            }
            text = decrypted
        }
        guard let data = text.data(using: .utf8), let json = wJSONObj(data) else {
            throw Wave2Error("请求失败：响应解析失败（HTTP \(raw.http.statusCode)）")
        }
        return json
    }

    private func executeJson(_ request: URLRequest) async throws -> [String: Any] {
        let raw = try await Wave2HTTP.send(request)
        if raw.data.isEmpty { throw Wave2Error("请求失败：响应为空（\(raw.http.statusCode)）") }
        guard let json = wJSONObj(raw.data) else {
            throw Wave2Error("请求失败：响应解析失败（HTTP \(raw.http.statusCode)）")
        }
        return json
    }

    /// 成功判定：resultCode == "0"
    private func checkResult(_ json: [String: Any], fallback: String) throws {
        let code = json.wHas("resultCode") ? "\(json.wInt("resultCode"))" : json.wStr("resultCode")
        if code == "0" { return }
        let desc = json.wStr("resultDesc").isEmpty ? json.wStr("desc") : json.wStr("resultDesc")
        throw Wave2Error(desc.isEmpty ? "\(fallback)（code=\(code)）" : desc)
    }

    // MARK: - 加密与签名（对应 Kotlin C139Crypto）

    /// 时间戳格式：yyyy-MM-dd HH:mm:ss（本机时区，与源码一致）
    static func timestampNow() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }

    /// 请求体加密：随机 IV(16) + AES/CBC/PKCS5(key) 加密，整体 base64
    static func encryptBody(_ plain: String) -> String {
        let iv = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        guard let cipher = wAES(key: Data(aesKey.utf8), iv: iv, encrypt: true, data: Data(plain.utf8)) else {
            return plain
        }
        return (iv + cipher).base64EncodedString()
    }

    /// 响应解密：base64 → 前 16 字节 IV → AES/CBC 解密；密文后可能追加 gzip，需再解压
    static func decryptBody(_ cipherBase64: String) -> String? {
        guard let raw = wBase64Decode(cipherBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
              raw.count > 16 else { return nil }
        let iv = raw.subdata(in: 0..<16)
        let cipher = raw.subdata(in: 16..<raw.count)
        guard let plain = wAES(key: Data(aesKey.utf8), iv: iv, encrypt: false, data: cipher) else { return nil }
        var data = plain
        // 服务端可能在密文后面追加 gzip 段：解密结果若以 gzip 魔数开头先解压
        if data.count >= 2 && data[0] == 0x1f && data[1] == 0x8b, let unzipped = wGunzip(data) {
            data = unzipped
        }
        return String(data: data, encoding: .utf8)
    }

    /**
     * mcloud-sign 签名：对（加密后）请求体文本做 encodeURIComponent →
     * 字符按码点升序排序 → base64 → md5，与 md5("$timestamp:$random") 相加再 md5，
     * 拼成 `$timestamp,$random,$sign`（sign 大写）。
     * random 全程同一个值（md5 输入与拼头都用它）。
     */
    static func mcloudSign(body: String, timestamp: String) -> String {
        let random = randomString(16)
        let encoded = wURIComponentEncode(body)
        let sorted = String(encoded.sorted())
        let b64 = Data(sorted.utf8).base64EncodedString()
        let part1 = wMD5Hex(b64)
        let part2 = wMD5Hex("\(timestamp):\(random)")
        let sign = wMD5Hex(part1 + part2).uppercased()
        return "\(timestamp),\(random),\(sign)"
    }

    /// 随机串（字母数字），与源码 randomString 同形态
    private static func randomString(_ length: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return (0..<length).map { _ in String(alphabet[Int.random(in: 0..<alphabet.count)]) }.joined()
    }
}

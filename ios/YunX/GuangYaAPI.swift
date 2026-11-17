import Foundation

/// 光鸭云盘 API 封装（移植自 Kotlin GuangYaApi + GuangYaConstants + GuangYaResolveRepository）。
/// 业务 API 带 did/dt/traceparent 头；账号 API 带一整套 X-Device-* 头；Authorization 仅在有令牌时携带。
///
/// 凭据形态：账号 access token（Bearer）。可由 signIn（账号密码登录）换取后粘贴保存，
/// 或在官网网页登录后把 access_token 粘贴进来；refreshToken 用 refresh_token 续期。
/// 分享列目录与取链本身匿名可用；分享者未开启免登录下载时（业务码 207），
/// 已登录用户走「转存到临时目录 → 从个人盘取链」，下载完成后由集成层调 deleteFiles 清理临时目录。
final class GuangYaAPI {
    static let shared = GuangYaAPI()
    private init() {}

    // MARK: - 常量（对应 Kotlin GuangYaConstants）

    static let clientId = "aMe-8VSlkrbQXpUR"
    private static let apiBase = "https://api.guangyapan.com"
    private static let accountBase = "https://account.guangyapan.com"
    static let webSite = "https://www.guangyapan.com"
    /// 下载直链必须携带的 Referer
    static let downloadReferer = "\(webSite)/"
    static let webUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    private static let clientVersion = "0.0.1"
    private static let sdkVersion = "9.1.3"
    private static let protocolVersion = "301"
    private static let deviceModel = "chrome%2F131.0.0.0"
    private static let deviceName = "PC-Chrome"
    private static let osVersion = "Win32"
    private static let platformVersion = "1"

    private static let authTokenURL = "\(accountBase)/v1/auth/token"
    private static let userMeURL = "\(accountBase)/v1/user/me"
    private static let captchaInitURL = "\(accountBase)/v1/shield/captcha/init"
    private static let signinURL = "\(accountBase)/v1/auth/signin"

    private static let getAssetsURL = "\(apiBase)/assets/v1/get_assets"
    private static let shareSummaryURL = "\(apiBase)/userres/v1/get_share_summary"
    private static let shareAccessTokenURL = "\(apiBase)/userres/v1/get_share_access_token"
    private static let shareFilesURL = "\(apiBase)/userres/v1/get_share_page_files_list"
    private static let shareDownloadURL = "\(apiBase)/userres/v1/get_share_download_url"
    private static let restoreShareURL = "\(apiBase)/userres/v1/restore_share"

    private static let fileListURL = "\(apiBase)/userres/v1/file/get_file_list"
    private static let createDirURL = "\(apiBase)/userres/v1/file/create_dir"
    private static let deleteFileURL = "\(apiBase)/userres/v1/file/delete_file"
    private static let resDownloadURL = "\(apiBase)/userres/v1/get_res_download_url"
    private static let taskStatusURL = "\(apiBase)/userres/v1/get_task_status"

    /// 分享 / 个人盘根目录 id（空串）
    static let rootParentId = ""
    private static let pageSize = 100
    private static let taskDelayMs: UInt64 = 750
    private static let taskMaxPolls = 80

    /// 下载请求头（桌面 ResolveViewModel：UA + Referer，不带 Authorization/Cookie）
    static var downloadHeaders: [String: String] {
        ["User-Agent": webUA, "Referer": downloadReferer]
    }

    // MARK: - 模型

    /// 设备标识（deviceId 32 位十六进制 + deviceSign）
    struct Device { let deviceId: String; let deviceSign: String }

    /// 刷新 / 登录成功返回的令牌对
    struct Tokens { let accessToken: String; let refreshToken: String; let expiresIn: Int64 }

    /// 账号信息
    struct AccountInfo { let userId: String; let nickname: String }

    /// 分享会话（对应编排层 createSession 的产物：shareId + 分享访问令牌 + 标题）
    struct ShareSession {
        let shareId: String
        /// 分享访问令牌（get_share_access_token 换得，不是账号 token）
        let accessToken: String
        let title: String
    }

    /// 分享下载受限（业务码 207）：分享者未开启免登录下载，需登录并转存后下载
    struct ShareRestricted: Error {}

    private struct CaptchaNeeded: Error {}

    /// 未登录（匿名分享）时业务请求兜底使用的设备 id（业务 API 始终需要 did），进程内生成一次
    private let publicDeviceId: String = GuangYaAPI.newDeviceId()
    /// 已登录设备的 did（集成层登录后注入；对应 Kotlin deviceIdProvider）
    var loggedInDeviceId: String? = nil

    // MARK: - 设备标识生成（对应 Kotlin GuangYaConstants 的 new* 函数）

    /// 生成 32 位十六进制设备 id
    static func newDeviceId() -> String {
        let hex = "0123456789abcdef"
        return String((0..<32).map { _ in hex.randomElement()! })
    }

    /// 形如 wdi10.<32位十六进制>xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx 的设备签名
    static func newDeviceSign(deviceId: String) -> String {
        let hex = "0123456789abcdef"
        let tail = String((0..<32).map { _ in hex.randomElement()! })
        return "wdi10.\(deviceId)\(tail)"
    }

    /// 生成一对新设备标识（登录用；集成层应持久化并复用同一对）
    static func newDevice() -> Device {
        let id = newDeviceId()
        return Device(deviceId: id, deviceSign: newDeviceSign(deviceId: id))
    }

    /// X-Device-Id：取 deviceSign 中第一个 "." 之后的 32 个字符；不足则回退 deviceId
    static func deviceIdFromSign(_ deviceSign: String, fallback: String) -> String {
        guard let idx = deviceSign.firstIndex(of: ".") else { return fallback }
        let rest = deviceSign[deviceSign.index(after: idx)...]
        return rest.count >= 32 ? String(rest.prefix(32)) : fallback
    }

    /// 生成 traceparent（每次请求重新生成）
    static func newTraceparent() -> String {
        func hex(_ n: Int) -> String {
            let chars = "0123456789abcdef"
            return String((0..<n).map { _ in chars.randomElement()! })
        }
        return "00-\(hex(32))-\(hex(16))-01"
    }

    // MARK: - 认证

    /// 人机验证初始化结果：token 可能为空（部分场景服务端不要求）；url 非空表示需要网页验证
    private struct CaptchaInit { let token: String?; let url: String? }

    private func initCaptcha(device: Device, meta: [String: Any], action: String) async throws -> CaptchaInit {
        let body: [String: Any] = [
            "client_id": GuangYaAPI.clientId,
            "action": action,
            "device_id": device.deviceId,
            "captcha_token": "",
            "meta": meta
        ]
        let json = try await executeJson(accountRequest(
            url: GuangYaAPI.captchaInitURL, body: try Wave2HTTP.jsonBody(body), device: device
        ))
        return CaptchaInit(
            token: json.wStr("captcha_token").isEmpty ? nil : json.wStr("captcha_token"),
            url: json.wStr("url").isEmpty ? nil : json.wStr("url")
        )
    }

    /// 密码登录：先初始化人机验证再 signin；仅在 captcha_required / captcha_invalid 时重试（最多 2 次）
    func signIn(username: String, password: String, device: Device) async throws -> Tokens {
        let normalized = GuangYaAPI.normalizeAccount(username)
        let meta = GuangYaAPI.metaFor(normalized)
        var captcha = try await initCaptcha(device: device, meta: meta, action: "POST:/v1/auth/signin")
        var attempt = 0
        while true {
            do {
                return try await doSignIn(username: normalized, password: password,
                                          captchaToken: captcha.token, device: device)
            } catch is CaptchaNeeded {
                if attempt >= 2 {
                    throw Wave2Error("光鸭安全验证未通过，请重试或切换网页登录")
                }
                attempt += 1
                captcha = try await initCaptcha(device: device, meta: meta, action: "POST:/v1/auth/signin")
            }
        }
    }

    private func doSignIn(username: String, password: String, captchaToken: String?, device: Device) async throws -> Tokens {
        let body: [String: Any] = [
            "client_id": GuangYaAPI.clientId,
            "username": username,
            "password": password
        ]
        var headers: [String: String] = [:]
        if let captchaToken = captchaToken, !captchaToken.isEmpty {
            headers["X-Captcha-Token"] = captchaToken
        }
        let json = try await executeJson(accountRequest(
            url: GuangYaAPI.signinURL, body: try Wave2HTTP.jsonBody(body), device: device, extraHeaders: headers
        ))
        let code = json.wStr("code")
        let error = json.wStr("error")
        if code == "captcha_required" || error == "captcha_required" ||
            code == "captcha_invalid" || error == "captcha_invalid" {
            throw CaptchaNeeded()
        }
        if !isSuccess(json) { throw Wave2Error(mapSigninError(json, error: error)) }
        return try parseTokens(json)
    }

    /// 刷新 Token。凭据失效返回 nil
    func refreshToken(refreshToken: String, device: Device) async throws -> Tokens? {
        let body: [String: Any] = [
            "client_id": GuangYaAPI.clientId,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ]
        let json = try await executeJson(accountRequest(
            url: GuangYaAPI.authTokenURL, body: try Wave2HTTP.jsonBody(body), device: device,
            extraHeaders: ["X-Action": "401"]
        ))
        if !isSuccess(json) { return nil }
        return try parseTokens(json)
    }

    /// 账号信息：GET /v1/user/me；失败返回 nil
    func fetchAccountInfo(accessToken: String, device: Device) async -> AccountInfo? {
        do {
            let json = try await executeJson(accountRequest(
                url: GuangYaAPI.userMeURL, body: nil, device: device, token: accessToken
            ))
            if !isSuccess(json) { return nil }
            let userId = wFirstNonBlank(json.wStr("sub"), json.wStr("user_id"), json.wStr("userId"))
            let nickname = wFirstNonBlank(
                json.wStr("nickname"), json.wStr("nick_name"), json.wStr("name"), json.wStr("username")
            )
            return userId.isEmpty ? nil : AccountInfo(userId: userId, nickname: nickname)
        } catch { return nil }
    }

    /// 容量信息：POST /assets/v1/get_assets；失败返回 nil
    func getQuota(accessToken: String, device: Device) async -> QuotaInfo? {
        do {
            let json = try await executeJson(businessRequest(
                url: GuangYaAPI.getAssetsURL, body: try Wave2HTTP.jsonBody([:]), device: device, token: accessToken
            ))
            try checkBusiness(json, fallback: "获取容量信息失败")
            guard let data = dataOf(json) else { return nil }
            let totalStr = data.wStr("totalSpaceSize")
            let total = Int64(totalStr) ?? data.wLong("totalSpaceSize")
            if total < 0 { return nil }
            let used = Int64(data.wStr("usedSpaceSize")) ?? 0
            return QuotaInfo(used: used, total: total)
        } catch { return nil }
    }

    // MARK: - 分享

    /// 创建分享会话：提取码换分享访问令牌 + 摘要取标题（对应编排层 createSession）
    func createSession(shareId: String, pwd: String?) async throws -> ShareSession {
        let token = try await getShareAccessToken(shareId: shareId, code: pwd ?? "")
        let title = await getShareSummary(shareId: shareId) ?? "光鸭分享"
        return ShareSession(shareId: shareId, accessToken: token, title: title)
    }

    /// 分享摘要标题；失败返回 nil
    func getShareSummary(shareId: String) async -> String? {
        do {
            let json = try await executeJson(businessRequest(
                url: GuangYaAPI.shareSummaryURL,
                body: try Wave2HTTP.jsonBody(["shareId": shareId]),
                device: nil, token: nil
            ))
            try checkBusiness(json, fallback: "获取分享信息失败")
            let data = dataOf(json) ?? json
            let title = wFirstNonBlank(data.wStr("title"), data.wStr("shareName"))
            return title.isEmpty ? nil : title
        } catch { return nil }
    }

    /// 用提取码换取分享访问令牌。code 209 = 提取码错误
    func getShareAccessToken(shareId: String, code: String) async throws -> String {
        let json = try await executeJson(businessRequest(
            url: GuangYaAPI.shareAccessTokenURL,
            body: try Wave2HTTP.jsonBody(["shareId": shareId, "code": code]),
            device: nil, token: nil
        ))
        try checkBusiness(json, fallback: "获取分享访问令牌失败")
        guard let data = dataOf(json) else { throw Wave2Error("光鸭分享链接无效") }
        let token = wFirstNonBlank(data.wStr("accessToken"), data.wStr("access_token"))
        if token.isEmpty { throw Wave2Error("光鸭分享链接无效") }
        return token
    }

    /// 分享列目录单页：返回 (文件列表, 下一页游标 or nil=无更多)
    func listShareFiles(accessToken: String, parentId: String, cursor: String?) async throws -> (files: [ShareFile], nextCursor: String?) {
        var body: [String: Any] = [
            "parentId": parentId,
            "pageSize": GuangYaAPI.pageSize,
            "orderBy": 0,
            "sortType": 0,
            "accessToken": accessToken
        ]
        if let cursor = cursor, !cursor.isEmpty { body["cursor"] = cursor }
        let json = try await executeJson(businessRequest(
            url: GuangYaAPI.shareFilesURL, body: try Wave2HTTP.jsonBody(body), device: nil, token: nil
        ))
        try checkBusiness(json, fallback: "获取分享文件列表失败")
        guard let data = dataOf(json) else { return ([], nil) }
        let list = parseFileList(listArray(data))
        let hasMore = data.wBool("hasMore")
        let next = data.wStr("cursor").isEmpty ? nil : data.wStr("cursor")
        let effectiveNext = (hasMore && next != nil) ? next : (hasMore ? next : nil)
        return (list, effectiveNext)
    }

    /// 分享列目录全部（游标翻页 + 按 fid 去重，对应编排层 listFiles）
    func listAllShareFiles(session: ShareSession, parentId: String) async throws -> [ShareFile] {
        var all: [ShareFile] = []
        var seen = Set<String>()
        var cursor: String? = nil
        var page = 0
        repeat {
            let (files, next) = try await listShareFiles(
                accessToken: session.accessToken, parentId: parentId, cursor: cursor
            )
            for f in files where seen.insert(f.fid).inserted { all.append(f) }
            cursor = next
            page += 1
        } while cursor != nil && page < 1000
        return all
    }

    /// 分享取下载地址；业务码 207 抛 ShareRestricted（需登录并转存）
    func getShareDownloadUrl(file: ShareFile, accessToken: String) async throws -> DownloadLink {
        let json = try await executeJson(businessRequest(
            url: GuangYaAPI.shareDownloadURL,
            body: try Wave2HTTP.jsonBody(["fileId": file.fid, "accessToken": accessToken]),
            device: nil, token: nil
        ))
        if json.wStr("code") == "207" { throw ShareRestricted() }
        try checkBusiness(json, fallback: "获取下载地址失败")
        guard let data = dataOf(json) else {
            throw Wave2Error("光鸭未返回有效下载地址，请确认下载权限")
        }
        let url = downloadUrlOf(data)
        if url.isEmpty { throw Wave2Error("光鸭未返回有效下载地址，请确认下载权限") }
        let size = Int64(data.wStr("size")) ?? file.fsize
        return DownloadLink(fid: file.fid, filename: file.fname, downloadUrl: url, size: size)
    }

    /// 分享取链编排（对应编排层 getShareDownloadLink）：
    /// 先匿名分享取链；受限（207）且有账号 token 时转存到临时目录再从个人盘取链，
    /// 返回的 link.cleanupDirFid 为临时目录 id，下载完成后集成层调 deleteFiles 清理。
    func resolveDownloadLink(session: ShareSession, file: ShareFile, accountToken: String?) async throws -> DownloadLink {
        do {
            return try await getShareDownloadUrl(file: file, accessToken: session.accessToken)
        } catch is ShareRestricted {
            guard let token = accountToken, !token.isEmpty else {
                throw Wave2Error("该光鸭分享需登录并转存后下载，请先登录光鸭云盘")
            }
            return try await transferAndDownload(session: session, file: file, token: token)
        }
    }

    /// 受限分享下载：在个人盘根目录建临时目录 → restore_share 转存 → 轮询目标文件 → 个人盘取链
    private func transferAndDownload(session: ShareSession, file: ShareFile, token: String) async throws -> DownloadLink {
        let folderName = "AsterLink临时转存_\(UUID().uuidString)"
        let folderId = try await createDir(accessToken: token, parentId: "", name: folderName)
        do {
            try await restoreShare(accountToken: token, shareToken: session.accessToken,
                                   fileIds: [file.fid], parentId: folderId)
            let target = try await pollCopiedFile(token: token, folderId: folderId, source: file)
            var link = try await getDownloadLink(accessToken: token, file: target)
            link = DownloadLink(fid: target.fid, filename: file.fname,
                                downloadUrl: link.downloadUrl, size: link.size,
                                cleanupDirFid: folderId, guestCookie: link.guestCookie)
            return link
        } catch {
            // 取链/校验失败：清掉刚建的临时目录，避免残留
            _ = try? await deleteFiles(accessToken: token, fileIds: [folderId])
            throw error
        }
    }

    /// 轮询临时目录直到转存完成（同名文件出现），最多 30 次、间隔 750ms
    private func pollCopiedFile(token: String, folderId: String, source: ShareFile) async throws -> ShareFile {
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: GuangYaAPI.taskDelayMs * 1_000_000)
            let files = (try? await listCloudFiles(accessToken: token, parentId: folderId)) ?? []
            let matches = files.filter { !$0.isdir && $0.fname == source.fname }
            if matches.count > 1 { throw Wave2Error("光鸭临时目录出现同名文件，无法确定下载目标") }
            if let target = matches.first {
                if source.fsize > 0 && target.fsize > 0 && source.fsize != target.fsize {
                    throw Wave2Error("光鸭转存文件大小不一致")
                }
                return target
            }
        }
        throw Wave2Error("光鸭转存已提交，目标文件暂不可见，请稍后重试")
    }

    /**
     * 转存分享：body 的 accessToken 是分享访问令牌（session.accessToken），
     * Authorization 用账号 access token；返回含 taskId 时用账号 token 轮询任务状态。
     */
    func restoreShare(accountToken: String, shareToken: String, fileIds: [String], parentId: String) async throws {
        let body: [String: Any] = [
            "accessToken": shareToken,
            "fileIds": fileIds,
            "parentId": parentId
        ]
        let json = try await executeJson(businessRequest(
            url: GuangYaAPI.restoreShareURL, body: try Wave2HTTP.jsonBody(body), device: nil, token: accountToken
        ))
        try checkBusiness(json, fallback: "转存失败")
        let taskId = dataOf(json)?.wStr("taskId") ?? ""
        if !taskId.isEmpty { try await waitTask(accessToken: accountToken, taskId: taskId) }
    }

    // MARK: - 个人盘

    /// 个人盘列目录：page 从 0 开始自动翻页
    func listCloudFiles(accessToken: String, parentId: String) async throws -> [ShareFile] {
        var all: [ShareFile] = []
        var seen = Set<String>()
        var page = 0
        while page < 1000 {
            let body: [String: Any] = [
                "parentId": parentId,
                "pageSize": GuangYaAPI.pageSize,
                "orderBy": 0,
                "sortType": 0,
                "page": page
            ]
            let json = try await executeJson(businessRequest(
                url: GuangYaAPI.fileListURL, body: try Wave2HTTP.jsonBody(body), device: nil, token: accessToken
            ))
            try checkBusiness(json, fallback: "获取文件列表失败")
            guard let data = dataOf(json) else { break }
            let list = parseFileList(listArray(data))
            if list.isEmpty { break }
            var added = 0
            for f in list where seen.insert(f.fid).inserted { all.append(f); added += 1 }
            if added == 0 { throw Wave2Error("光鸭文件列表分页重复，请重试") }
            let total = Int64(data.wStr("total")) ?? data.wLong("total")
            if total > 0 && all.count >= total { break }
            if total <= 0 && list.count < GuangYaAPI.pageSize { break }
            page += 1
        }
        return all
    }

    /// 新建目录，返回新目录 id
    func createDir(accessToken: String, parentId: String, name: String) async throws -> String {
        let body: [String: Any] = [
            "parentId": parentId,
            "dirName": name,
            "failIfNameExist": true
        ]
        let json = try await executeJson(businessRequest(
            url: GuangYaAPI.createDirURL, body: try Wave2HTTP.jsonBody(body), device: nil, token: accessToken
        ))
        try checkBusiness(json, fallback: "新建文件夹失败")
        guard let data = dataOf(json) else {
            throw Wave2Error("光鸭未创建文件夹，请检查是否存在同名文件")
        }
        let id = wFirstNonBlank(data.wStr("fileId"), data.wStr("id"))
        if id.isEmpty || data.wStr("resType") == "1" {
            throw Wave2Error("光鸭未创建文件夹，请检查是否存在同名文件")
        }
        return id
    }

    /// 删除文件（清理临时转存目录用）
    @discardableResult
    func deleteFiles(accessToken: String, fileIds: [String]) async throws -> Bool {
        let json = try await executeJson(businessRequest(
            url: GuangYaAPI.deleteFileURL,
            body: try Wave2HTTP.jsonBody(["fileIds": fileIds]),
            device: nil, token: accessToken
        ))
        try checkBusiness(json, fallback: "删除失败")
        let taskId = dataOf(json)?.wStr("taskId") ?? ""
        if !taskId.isEmpty { try await waitTask(accessToken: accessToken, taskId: taskId) }
        return true
    }

    /// 个人盘取下载地址
    func getDownloadLink(accessToken: String, file: ShareFile) async throws -> DownloadLink {
        let json = try await executeJson(businessRequest(
            url: GuangYaAPI.resDownloadURL,
            body: try Wave2HTTP.jsonBody(["fileId": file.fid]),
            device: nil, token: accessToken
        ))
        try checkBusiness(json, fallback: "获取下载地址失败")
        guard let data = dataOf(json) else {
            throw Wave2Error("光鸭未返回有效下载地址，请确认下载权限")
        }
        let url = downloadUrlOf(data)
        if url.isEmpty { throw Wave2Error("光鸭未返回有效下载地址，请确认下载权限") }
        let size = Int64(data.wStr("size")) ?? file.fsize
        return DownloadLink(fid: file.fid, filename: file.fname, downloadUrl: url, size: size)
    }

    /// 任务状态轮询：status 2 且 detail.code 0 = 成功
    func waitTask(accessToken: String, taskId: String) async throws {
        try await Task.sleep(nanoseconds: GuangYaAPI.taskDelayMs * 1_000_000)
        for _ in 0..<GuangYaAPI.taskMaxPolls {
            let json = try await executeJson(businessRequest(
                url: GuangYaAPI.taskStatusURL,
                body: try Wave2HTTP.jsonBody(["taskId": taskId]),
                device: nil, token: accessToken
            ))
            try checkBusiness(json, fallback: "任务状态查询失败")
            if let data = dataOf(json) {
                let status = data.wInt("status")
                let detail = data.wObj("detail")
                let detailCode = detail?.wInt("code") ?? 0
                if status == 2 && detailCode == 0 { return }
                if status == 3 || (status == 2 && detailCode != 0) {
                    throw Wave2Error((detail?.wStr("msg") ?? "").isEmpty ? "光鸭操作失败" : detail!.wStr("msg"))
                }
            }
            try await Task.sleep(nanoseconds: GuangYaAPI.taskDelayMs * 1_000_000)
        }
        throw Wave2Error("光鸭操作仍在处理中，请稍后刷新列表确认结果")
    }

    // MARK: - 内部

    private func downloadUrlOf(_ data: [String: Any]) -> String {
        wFirstNonBlank(
            data.wStr("signedURL"), data.wStr("signedUrl"), data.wStr("downloadUrl"),
            data.wStr("download_url"), data.wStr("url"), data.wStr("cdnUrl")
        )
    }

    private func parseTokens(_ json: [String: Any]) throws -> Tokens {
        let data = json.wObj("data") ?? json
        let access = wFirstNonBlank(data.wStr("access_token"), data.wStr("accessToken"))
        if access.isEmpty { throw Wave2Error("光鸭登录失败，请检查账号密码，或切换网页登录") }
        let refresh = wFirstNonBlank(data.wStr("refresh_token"), data.wStr("refreshToken"))
        return Tokens(accessToken: access, refreshToken: refresh, expiresIn: expiresInSeconds(data))
    }

    /// 令牌有效期（秒）：优先 expires_in；否则用绝对时间 expire_time/expires_at 反推（毫秒或秒都兼容）
    private func expiresInSeconds(_ data: [String: Any]) -> Int64 {
        let now = wNowMs()
        var direct: Int64 = 0
        if let n = data["expires_in"] as? NSNumber { direct = n.int64Value }
        else if let s = data["expires_in"] as? String { direct = Int64(s) ?? 0 }
        if direct > 0 { return min(direct, 31_536_000) }
        var absolute: Int64 = 0
        for key in ["expire_time", "expires_at"] {
            if let n = data[key] as? NSNumber { absolute = n.int64Value; break }
            if let s = data[key] as? String, let v = Int64(s) { absolute = v; break }
        }
        if absolute <= 0 { return 0 }
        let millis = absolute > 1_000_000_000_000 ? absolute : absolute * 1000
        return max(0, min((millis - now) / 1000, 31_536_000))
    }

    /// 账号规范化为接口要求的形态：11 位手机号 → "+86 xxx"；带 +86 前缀去空格
    static func normalizeAccount(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return s }
        let digits = s.filter { $0.isNumber }
        if s.hasPrefix("+86") {
            return "+86 " + String(digits.dropFirst(2))
        }
        if s.count == 11 && s.allSatisfy({ $0.isNumber }) {
            return "+86 \(s)"
        }
        return s
    }

    private static func metaFor(_ account: String) -> [String: Any] {
        if account.hasPrefix("+") { return ["phone_number": account] }
        if account.contains("@") { return ["email": account] }
        return ["username": account]
    }

    private func mapSigninError(_ json: [String: Any], error: String) -> String {
        let code = json.wStr("code").isEmpty ? error : json.wStr("code")
        let serverMsg = wFirstNonBlank(json.wStr("msg"), json.wStr("message"), json.wStr("error_description"))
        switch code {
        case "too_many_requests":
            return "光鸭登录尝试过于频繁，请稍后重试"
        case "invalid_password", "invalid_account_or_password", "invalid_credentials", "unauthenticated", "user_not_found":
            return "光鸭账号或密码不正确，请检查后重试"
        case "password_required", "password_not_set":
            return "该光鸭账号尚未设置密码，请切换网页登录"
        case "verification_required", "verification_code_required":
            return "光鸭需要短信验证，请切换网页登录继续"
        default:
            return serverMsg.isEmpty ? "光鸭登录失败，请检查账号密码，或切换网页登录" : serverMsg
        }
    }

    /// 列出阵列字段：光鸭不同接口/版本用 list / items / files / records / content 等多种命名
    private func listArray(_ data: [String: Any]) -> [[String: Any]] {
        for key in ["list", "items", "files", "records", "content"] {
            let arr = data.wObjs(key)
            if !arr.isEmpty || data.wHas(key) { return arr }
        }
        return []
    }

    private func parseFileList(_ arr: [[String: Any]]) -> [ShareFile] {
        arr.map { parseFile($0) }
    }

    private func parseFile(_ item: [String: Any]) -> ShareFile {
        let fid = wFirstNonBlank(
            item.wStr("fileId"), item.wStr("file_id"), item.wStr("id"),
            item.wStr("resId"), item.wStr("resourceId")
        )
        let name = wFirstNonBlank(
            item.wStr("fileName"), item.wStr("name"), item.wStr("filename"),
            item.wStr("dirName"), item.wStr("title")
        )
        let size = Int64(wFirstNonBlank(item.wStr("fileSize"), item.wStr("size"), item.wStr("file_size"))) ?? 0
        let resType = item.wStr("resType")
        let dirType = item.wStr("dirType")
        let isDir: Bool
        if resType == "2" { isDir = true }
        else if resType == "1" { isDir = false }
        else {
            isDir = item.wBool("isDir") || item.wBool("isdir") || item.wBool("dir") ||
                item.wBool("isFolder") || item.wBool("folder") ||
                !item.wStr("dirName").isEmpty ||
                ["folder", "dir", "directory", "0"].contains(item.wStr("type").lowercased()) ||
                ["folder", "dir", "directory", "0"].contains(item.wStr("fileType").lowercased()) ||
                (!name.contains(".") && dirType == "1")
        }
        let parent = wFirstNonBlank(item.wStr("parentId"), item.wStr("parentFileId"), item.wStr("parent_id"))
        let time = wFirstNonBlank(
            item.wStr("updatedAt"), item.wStr("updateAt"), item.wStr("updated_at"),
            item.wStr("updateTime"), item.wStr("mtime"), item.wStr("utime"),
            item.wStr("createdAt"), item.wStr("createTime"), item.wStr("ctime")
        )
        return ShareFile(fid: fid, fname: name, fsize: size, isdir: isDir,
                         pdirFid: parent, fidToken: "", modifyTime: time)
    }

    private func checkBusiness(_ json: [String: Any], fallback: String) throws {
        if isSuccess(json) { return }
        let code = json.wStr("code")
        let serverMsg = wFirstNonBlank(json.wStr("msg"), json.wStr("message"), json.wStr("error_description"))
        let mapped: String?
        switch code {
        case "209": mapped = "光鸭分享提取码错误或缺失"
        case "200", "201", "202": mapped = "光鸭分享已取消、过期或不可访问"
        case "205", "206", "207", "504": mapped = "光鸭分享下载受限，请在官网确认该分享的下载权限"
        case "157": mapped = "光鸭网盘空间不足"
        default: mapped = nil
        }
        throw Wave2Error(mapped ?? (serverMsg.isEmpty ? "\(fallback)（code=\(code)）" : serverMsg))
    }

    private func isSuccess(_ json: [String: Any]) -> Bool {
        if json.wBool("success", true) == false { return false }
        if !json.wStr("error").isEmpty { return false }
        let code = json.wStr("code")
        return code.isEmpty || code == "0"
    }

    private func dataOf(_ json: [String: Any]) -> [String: Any]? { json.wObj("data") }

    private func businessRequest(url: String, body: Data, device: Device?, token: String?) -> URLRequest {
        var headers: [String: String] = [
            "Accept": "application/json, text/plain, */*",
            "Content-Type": "application/json",
            "User-Agent": GuangYaAPI.webUA,
            "Origin": GuangYaAPI.webSite,
            "Referer": GuangYaAPI.downloadReferer,
            "dt": "4",
            "traceparent": GuangYaAPI.newTraceparent()
        ]
        // did 为业务 API 必需设备头：登录设备优先，其次上层注入，最后匿名兜底设备
        let did = device?.deviceId ?? loggedInDeviceId ?? publicDeviceId
        if !did.isEmpty { headers["did"] = did }
        if let token = token, !token.isEmpty { headers["Authorization"] = "Bearer \(token)" }
        return Wave2HTTP.request(url: url, method: "POST", headers: headers, body: body)
    }

    private func accountRequest(url: String, body: Data?, device: Device,
                                token: String? = nil, extraHeaders: [String: String] = [:]) -> URLRequest {
        let deviceId = GuangYaAPI.deviceIdFromSign(device.deviceSign, fallback: device.deviceId)
        var headers: [String: String] = [
            "X-Client-Id": GuangYaAPI.clientId,
            "X-Client-Version": GuangYaAPI.clientVersion,
            // X-Device-Id / X-Device-Sign 需 URL 编码
            "X-Device-Id": wFormEncode(deviceId),
            "X-Device-Model": GuangYaAPI.deviceModel,
            "X-Device-Name": GuangYaAPI.deviceName,
            "X-Device-Sign": wFormEncode(device.deviceSign),
            "X-Os-Version": GuangYaAPI.osVersion,
            "X-Platform-Version": GuangYaAPI.platformVersion,
            "X-Protocol-Version": GuangYaAPI.protocolVersion,
            "X-Sdk-Version": GuangYaAPI.sdkVersion,
            "Accept": "application/json, text/plain, */*",
            "User-Agent": GuangYaAPI.webUA
        ]
        if let token = token, !token.isEmpty { headers["Authorization"] = "Bearer \(token)" }
        for (k, v) in extraHeaders { headers[k] = v }
        if body != nil { headers["Content-Type"] = "application/json" }
        return Wave2HTTP.request(url: url, method: body == nil ? "GET" : "POST", headers: headers, body: body)
    }

    private func executeJson(_ request: URLRequest) async throws -> [String: Any] {
        let raw = try await Wave2HTTP.send(request)
        if raw.data.isEmpty {
            if !(200...299).contains(raw.http.statusCode) {
                throw Wave2Error("请求失败（HTTP \(raw.http.statusCode)）")
            }
            throw Wave2Error("请求失败：响应为空")
        }
        guard let json = wJSONObj(raw.data) else {
            throw Wave2Error("请求失败：响应解析失败（HTTP \(raw.http.statusCode)）")
        }
        return json
    }
}

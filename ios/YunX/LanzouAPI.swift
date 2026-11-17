import Foundation

/// 蓝奏云 API 封装（移植自 Kotlin LanzouApi + LanzouConstants + LanzouCrypto）：
/// - 匿名分享：分享页 HTML → 同源 iframe → ajaxm/ajaxfile 取参数 → HEAD 探测直链 → 验证并下载；
/// - 个人盘：粘贴 Cookie（ylogin + phpdisk_info）→ mydisk.php 取 uid/vei → doupload.php 系列 task。
///
/// 蓝奏可能返回 acw_sc__v2 的 JS 校验页（并下发 down_ip 等 Cookie）：按 host 记录 Cookie，
/// 遇到校验页时本地计算 Cookie 并重放一次（纯字符串变换，见 acwScV2）。
///
/// 注意：本类带按 host 的 Cookie 罐状态，集成层应全程复用同一个实例（shared）。
final class LanzouAPI {
    static let shared = LanzouAPI()
    private init() {}

    // MARK: - 常量（对应 Kotlin LanzouConstants）

    static let webUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    private static let mydiskURL = "https://pc.woozooo.com/mydisk.php"
    private static let mydiskFilesURL = "https://pc.woozooo.com/mydisk.php?item=files&action=index"
    private static let douploadURL = "https://pc.woozooo.com/doupload.php"
    private static let origin = "https://pc.woozooo.com"
    static let rootFolderId = "-1"
    private static let maxFilePages = 1000
    private static let maxFolderPages = 500
    /// 下载节点注入的 Cookie（缺它下载节点拒绝直链）
    static let downIPCookie = "down_ip=1"
    private static let folderPrefix = "d:"
    private static let filePrefix = "f:"

    /// 是否为蓝奏云域名（域名族 lanzou*、lan[zs]o[ux]，后缀 com/net/org/cn）
    static func isLanzouHost(_ host: String) -> Bool {
        host.range(of: #"^(?:[a-z0-9-]+\.)*(?:lanzou[a-z]?|lan[zs]o[ux])\.(?:com|net|org|cn)$"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// 将分享链接规范为 https、去掉 fragment、去掉结尾多余斜杠
    static func normalizeShareUrl(_ url: String) -> String {
        var u = url.trimmingCharacters(in: .whitespaces)
        if u.lowercased().hasPrefix("http://") { u = "https://" + u.dropFirst(7) }
        if let hash = u.firstIndex(of: "#") { u = String(u[..<hash]) }
        while u.hasSuffix("/") { u.removeLast() }
        return u
    }

    // MARK: - 模型

    /// 个人盘登录态参数（从 mydisk.php 提取）
    struct LoginParams { let uid: String; let vei: String }

    /// 文件夹分页参数（分享页里的 lx/fid/t/k）
    struct FolderParams { let lx: String; let fid: String; let t: String; let k: String }

    /// 分享页解析结果（集成层缓存，供列目录 / 取直链复用，对应 Kotlin LanzouSharePage）
    struct SharePage {
        let shareUrl: String
        let baseUrl: String
        let title: String
        let isFolder: Bool
        let needsPwd: Bool
        let iframeUrl: String?
        let fileId: String?
        let folderParams: FolderParams?
        let html: String
        let singleFile: ShareFile?
    }

    /// 个人盘建分享的结果
    struct ShareInfoResult { let shareUrl: String; let passcode: String }

    // MARK: - acw_sc__v2（对应 Kotlin LanzouCrypto）

    /// 重排位置表：把 arg1 的第 pos[z] 个字符放到第 z 位（1-based）
    private static let acwPos: [Int] = [
        15, 35, 29, 24, 33, 16, 1, 38, 10, 9, 19, 31, 40, 27, 22, 23, 25, 13, 6, 11,
        39, 18, 20, 8, 14, 21, 32, 26, 2, 30, 7, 4, 17, 5, 3, 28, 34, 37, 12, 36
    ]
    /// 异或掩码（40 位十六进制，即 20 字节）
    private static let acwMask = "3000176000856006061501533003690027800375"

    /// 计算 acw_sc__v2：arg1 按位置表重排 → 与掩码逐字节异或 → 20 字节小写十六进制串
    static func acwScV2(_ arg1: String) -> String {
        let chars = Array(arg1)
        var q = [Character](repeating: "0", count: acwPos.count)
        for x in chars.indices {
            for z in acwPos.indices where acwPos[z] == x + 1 { q[z] = chars[x] }
        }
        let u = Array(String(q))
        let mask = Array(acwMask)
        var out = ""
        var i = 0
        while i + 2 <= u.count && i + 2 <= mask.count {
            let a = Int(String(u[i..<(i + 2)]), radix: 16) ?? 0
            let b = Int(String(mask[i..<(i + 2)]), radix: 16) ?? 0
            out += String(format: "%02x", a ^ b)
            i += 2
        }
        return out
    }

    /// 页面若为 acw_sc__v2 校验页则返回应设置的 Cookie 值（无 arg1 时返回 nil）
    static func challengeCookie(_ source: String) -> String? {
        guard let arg1 = regexGroup(#"\barg1\s*=\s*'([0-9A-Fa-f]{40})'"#, in: source, group: 1) else { return nil }
        return acwScV2(arg1)
    }

    // MARK: - 按 host 的 Cookie 罐

    private var cookieJar: [String: [String: String]] = [:]
    private let jarLock = NSLock()

    private func hostOf(_ url: String) -> String { URL(string: url)?.host ?? "" }

    private func setCookie(host: String, name: String, value: String) {
        if host.isEmpty { return }
        jarLock.lock(); defer { jarLock.unlock() }
        cookieJar[host, default: [:]][name] = value
    }

    private func cookieHeader(host: String) -> String {
        jarLock.lock(); defer { jarLock.unlock() }
        return cookieJar[host]?.map { "\($0.key)=\($0.value)" }.joined(separator: "; ") ?? ""
    }

    /// 合并按域 Cookie 罐与调用方追加的 Cookie 串（如 down_ip=1）
    private func mergedCookie(host: String, extra: String?) -> String {
        [cookieHeader(host: host), extra ?? ""].filter { !$0.isEmpty }.joined(separator: "; ")
    }

    // MARK: - 正则小工具

    private static func regexGroup(_ pattern: String, in text: String, group: Int = 1,
                                   options: NSRegularExpression.Options = []) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, options: [], range: range),
              m.numberOfRanges > group,
              let r = Range(m.range(at: group), in: text) else { return nil }
        return String(text[r])
    }

    private static func regexMatch(_ pattern: String, in text: String,
                                   options: NSRegularExpression.Options = []) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, options: [], range: range),
              let r = Range(m.range, in: text) else { return nil }
        return String(text[r])
    }

    // MARK: - 个人盘

    /// 从 mydisk.php 提取 uid / vei（凭据 = 粘贴的整串 Cookie）
    func fetchLoginParams(cookie: String) async throws -> LoginParams {
        let req = Wave2HTTP.request(url: LanzouAPI.mydiskFilesURL, headers: [
            "Cookie": cookie,
            "User-Agent": LanzouAPI.webUA,
            "Referer": LanzouAPI.mydiskURL,
            "Origin": LanzouAPI.origin
        ])
        let raw = try await Wave2HTTP.send(req)
        guard (200...299).contains(raw.http.statusCode) else {
            throw Wave2Error("蓝奏登录态无效，请重新登录")
        }
        let html = raw.text
        let uid = LanzouAPI.regexGroup(#"uid['"]?\s*[=:]\s*['"]?(\d{1,20})"#, in: html)
        let vei = LanzouAPI.regexGroup(#"vei['"]?\s*[=:]\s*['"]?([A-Za-z0-9_\-+/=]{1,256})"#, in: html)
        guard let uid = uid, !uid.isEmpty, let vei = vei, !vei.isEmpty else {
            throw Wave2Error("蓝奏登录态无效，请重新登录")
        }
        return LoginParams(uid: uid, vei: vei)
    }

    /// 个人盘列目录：文件夹（task=47）+ 文件（task=5）合并。folderId 根目录传 "-1"
    func listCloudFiles(cookie: String, uid: String, vei: String, folderId: String) async throws -> [ShareFile] {
        var result: [ShareFile] = []
        let folderJson = try await doupload(cookie: cookie, uid: uid, vei: vei,
                                            fields: [("task", "47"), ("folder_id", folderId)], allowEnd: true)
        for item in folderJson.wObjs("text") {
            let id = wFirstNonBlank(item.wStr("fol_id"), item.wStr("id"))
            if id.isEmpty { continue }
            result.append(ShareFile(
                fid: LanzouAPI.folderPrefix + id,
                fname: wFirstNonBlank(item.wStr("name"), item.wStr("name_all")),
                fsize: 0, isdir: true, pdirFid: folderId, fidToken: "",
                modifyTime: item.wStr("time")
            ))
        }
        var seen = Set<String>()
        var pg = 1
        while pg <= LanzouAPI.maxFilePages {
            let json = try await doupload(cookie: cookie, uid: uid, vei: vei,
                                          fields: [("task", "5"), ("folder_id", folderId), ("pg", "\(pg)")],
                                          allowEnd: true)
            let arr = json.wObjs("text")
            if arr.isEmpty { break }
            var added = 0
            for item in arr {
                let id = item.wStr("id")
                if id.isEmpty || !seen.insert(id).inserted { continue }
                result.append(ShareFile(
                    fid: LanzouAPI.filePrefix + id,
                    fname: wFirstNonBlank(item.wStr("name_all"), item.wStr("name")),
                    fsize: LanzouAPI.parseDisplaySize(item.wStr("size")),
                    isdir: false, pdirFid: folderId, fidToken: "",
                    modifyTime: item.wStr("time")
                ))
                added += 1
            }
            if added == 0 { throw Wave2Error("蓝奏文件分页重复，请刷新后重试") }
            pg += 1
        }
        return result
    }

    /// 获取文件分享链接（task=22）
    func createFileShare(cookie: String, uid: String, vei: String, fileId: String) async throws -> ShareInfoResult {
        let json = try await doupload(cookie: cookie, uid: uid, vei: vei,
                                      fields: [("task", "22"), ("file_id", fileId)])
        guard let info = json.wObj("info") else { throw Wave2Error("蓝奏未返回分享链接") }
        return buildShareInfo(raw: info.wStr("f_id"), domain: info.wStr("is_newd"), pwd: info.wStr("pwd"))
    }

    /// 个人盘文件下载：蓝奏云未提供个人盘直链接口，按官方能力组合实现——
    /// 先用 task=22 生成该文件的分享链接，再走匿名分享的下载链路取直链。
    func getPersonalDownloadLink(cookie: String, uid: String, vei: String,
                                 fileId: String, fileName: String) async throws -> (link: DownloadLink, headers: [String: String]) {
        let info = try await createFileShare(cookie: cookie, uid: uid, vei: vei, fileId: fileId)
        let page = try await resolveShare(shareUrl: info.shareUrl, pwd: info.passcode)
        let file = page.singleFile ?? ShareFile(
            fid: page.shareUrl, fname: fileName, fsize: 0, isdir: false, pdirFid: "", fidToken: "", modifyTime: ""
        )
        return try await getShareDownloadLink(page: page, file: file, pwd: info.passcode)
    }

    // MARK: - 匿名分享

    /// 获取分享页并解析（文件夹分享 / 文件分享）。shareUrl 传完整链接（集成层由链接识别给出）
    func resolveShare(shareUrl: String, pwd: String?) async throws -> SharePage {
        let normalized = LanzouAPI.normalizeShareUrl(shareUrl)
        let html = try await fetchPageFollowingLanzou(normalized)
        guard let uri = URL(string: normalized), let host = uri.host else {
            throw Wave2Error("蓝奏分享链接无效")
        }
        let origin = "\(uri.scheme ?? "https")://\(host)"
        let title = extractTitle(html)
        let needsPwd = html.contains("请输入密码") || html.contains("id=\"pwbox\"") ||
            html.contains("input_password") || html.contains("密码不正确")
        let isFolder = html.contains("filemoreajax") || html.contains("class=\"filemore\"") ||
            html.contains("file_more")
        let iframeUrl = LanzouAPI.regexGroup(#"<iframe[^>]+src=["']([^"']+)["']"#, in: html)
            .map { absolutize(origin, $0) }
        let fileId = LanzouAPI.regexGroup(#"(?:ajaxm|ajaxfile)\.php\?file=(\d+)"#, in: html)
            ?? LanzouAPI.regexGroup(#"name=["']file["']\s+value=["'](\d+)["']"#, in: html)
            ?? LanzouAPI.regexGroup(#"file=(\d+)"#, in: html)
        var folderParams: FolderParams? = nil
        if isFolder {
            let lx = jsVar(html, "lx")
            let fid = jsVar(html, "fid") ?? uri.path.split(separator: "/").last.map(String.init) ?? ""
            let t = jsVar(html, "t")
            let k = jsVar(html, "k")
            if let lx = lx, let t = t, let k = k {
                folderParams = FolderParams(lx: lx, fid: fid, t: t, k: k)
            }
        }
        let pathTrimmed = uri.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let shareId = pathTrimmed.split(separator: "/").last.map(String.init) ?? pathTrimmed
        // 单文件分享的展示大小：页面文本「文件大小：1.5 M」
        let sizePattern = #"(?:文件大小|大小)\s*[:：]\s*([\d.]+)\s*([KMGT]?)(?:i?B)?"#
        let displaySize: Int64 = {
            guard let num = LanzouAPI.regexGroup(sizePattern, in: html, group: 1) else { return 0 }
            let unit = LanzouAPI.regexGroup(sizePattern, in: html, group: 2) ?? ""
            return LanzouAPI.parseDisplaySize("\(num) \(unit)")
        }()
        let singleFile: ShareFile? = isFolder ? nil : ShareFile(
            fid: shareId, fname: title, fsize: displaySize, isdir: false,
            pdirFid: "", fidToken: "", modifyTime: ""
        )
        return SharePage(
            shareUrl: normalized, baseUrl: origin,
            title: title.isEmpty ? "蓝奏分享" : title,
            isFolder: isFolder, needsPwd: needsPwd,
            iframeUrl: iframeUrl, fileId: fileId,
            folderParams: folderParams, html: html, singleFile: singleFile
        )
    }

    /// 文件夹分页列表（dirFid 与 Kotlin 版一致未使用：蓝奏文件夹分享不支持进子目录）
    func listShareFolder(page: SharePage, pwd: String?) async throws -> [ShareFile] {
        guard let params = page.folderParams else {
            throw Wave2Error("蓝奏分享分页异常，请重试")
        }
        var all: [ShareFile] = []
        var seen = Set<String>()
        var pg = 1
        while pg <= LanzouAPI.maxFolderPages {
            var attempt = 0
            var json: [String: Any]? = nil
            while attempt <= 2 {
                do {
                    json = try await formPost(
                        url: "\(page.baseUrl)/filemoreajax.php",
                        fields: [
                            ("lx", params.lx), ("fid", params.fid), ("t", params.t), ("k", params.k),
                            ("pwd", pwd ?? ""), ("pg", "\(pg)")
                        ],
                        referer: page.shareUrl, origin: page.baseUrl, cookie: nil
                    )
                    break
                } catch {
                    attempt += 1
                    if attempt > 2 { throw Wave2Error("蓝奏请求过于频繁，请稍后再试") }
                    try await Task.sleep(nanoseconds: 300_000_000)
                }
            }
            guard let body = json else { break }
            let zt = body.wInt("zt")
            switch zt {
            case 1: break
            case 2: return all
            case 3: throw Wave2Error("蓝奏提取码错误，请检查后重新解析")
            case 4:
                pg -= 1
                if attempt >= 2 { throw Wave2Error("蓝奏请求过于频繁，请稍后再试") }
            default: throw Wave2Error("蓝奏解析失败，请确认分享链接和提取码后重试")
            }
            let arr = body.wObjs("text")
            if arr.isEmpty { break }
            var added = 0
            for item in arr {
                let id = item.wStr("id")
                if id.isEmpty || !seen.insert(id).inserted { continue }
                all.append(ShareFile(
                    fid: id,
                    fname: wFirstNonBlank(item.wStr("name_all"), item.wStr("name")),
                    fsize: LanzouAPI.parseDisplaySize(item.wStr("size")),
                    isdir: false, pdirFid: "", fidToken: "",
                    modifyTime: item.wStr("time")
                ))
                added += 1
            }
            if added == 0 { throw Wave2Error("蓝奏分页重复，请重新打开目录") }
            pg += 1
        }
        return all
    }

    /// 获取分享文件下载直链（匿名）。返回直链 + 下载请求头（对齐桌面 ResolveViewModel：
    /// UA + Referer=最终节点 origin + Cookie down_ip=1，并合并探测期间节点下发/本地计算的 Cookie）
    func getShareDownloadLink(page: SharePage, file: ShareFile, pwd: String?) async throws -> (link: DownloadLink, headers: [String: String]) {
        let origin = page.baseUrl
        var html = page.html
        if let iframe = page.iframeUrl {
            let iframeHost = URL(string: iframe)?.host
            let shareHost = URL(string: page.shareUrl)?.host
            if let iframeHost = iframeHost, let shareHost = shareHost,
               iframeHost.caseInsensitiveCompare(shareHost) == .orderedSame {
                html = try await fetchPage(iframe, referer: page.shareUrl, cookie: nil)
            } else if iframeHost != nil {
                throw Wave2Error("蓝奏下载页面地址异常，请检查分享链接")
            }
        }
        guard let fileId = page.fileId
            ?? LanzouAPI.regexGroup(#"(?:ajaxm|ajaxfile)\.php\?file=(\d+)"#, in: html)
            ?? LanzouAPI.regexGroup(#"file=(\d+)"#, in: html) else {
            throw Wave2Error("蓝奏解析失败，请确认分享链接和提取码后重试")
        }
        let withPwd = !(pwd ?? "").isEmpty
        let ajaxUrl = resolveAjaxUrl(html, origin: origin, fileId: fileId, withPwd: withPwd)
        guard let sign = jsVar(html, "wp_sign") ?? jsVar(html, "sign") ?? inputValue(html, "sign") else {
            throw Wave2Error("蓝奏分享页缺少下载参数，请重新解析")
        }
        let ajaxData = jsVar(html, "ajaxdata")
        let kd = jsVarRaw(html, "kdns") ?? "1"
        var fields: [(String, String)] = [("action", "downprocess"), ("sign", sign)]
        if withPwd {
            fields.append(("p", pwd!))
            fields.append(("kd", "1"))
        } else {
            let key = ajaxData ?? jsVar(html, "websignkey") ?? inputValue(html, "websignkey") ?? ""
            fields.append(("signs", jsVar(html, "signs") ?? key))
            fields.append(("websignkey", key))
            fields.append(("websign", jsVar(html, "websign") ?? ""))
            fields.append(("kd", kd))
            fields.append(("ves", "1"))
        }
        let ajaxJson = try await formPost(ajaxUrl, fields: fields, referer: page.shareUrl, origin: origin, cookie: nil)
        try validateAjax(ajaxJson)
        let dom = ajaxJson.wStr("dom")
        let rel = ajaxJson.wStr("url")
        guard !dom.isEmpty, !rel.isEmpty, !rel.hasPrefix("/"), !rel.contains("://"),
              let domURL = URL(string: dom), let scheme = domURL.scheme, let dHost = domURL.host else {
            throw Wave2Error("蓝奏解析失败，请确认分享链接和提取码后重试")
        }
        let jump = "\(scheme)://\(dHost)/file/\(rel)"
        let (finalUrl, size) = try await probeAndVerify(jump, shareOrigin: origin)
        let link = DownloadLink(
            fid: file.fid,
            filename: file.fname.isEmpty ? ajaxJson.wStr("inf") : file.fname,
            downloadUrl: finalUrl,
            size: size
        )
        let finalHost = URL(string: finalUrl)?.host ?? dHost
        let finalOrigin = URL(string: finalUrl).map { "\($0.scheme ?? "https")://\(finalHost)" } ?? origin
        var headers = [
            "User-Agent": LanzouAPI.webUA,
            "Referer": "\(finalOrigin)/"
        ]
        let cookie = mergedCookie(host: finalHost, extra: LanzouAPI.downIPCookie)
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        return (link, headers)
    }

    // MARK: - 直链探测

    private func probeAndVerify(_ jump: String, shareOrigin: String) async throws -> (String, Int64) {
        var url = jump
        setCookie(host: hostOf(jump), name: "down_ip", value: "1")
        var confirmedHosts = Set<String>()
        var challenges = Set<String>()
        var visited = Set<String>()
        for _ in 0..<8 {
            guard let uri = URL(string: url), let host = uri.host else {
                throw Wave2Error("蓝奏下载地址暂时不可用，请稍后重试")
            }
            if !visited.insert(url).inserted {
                throw Wave2Error("蓝奏下载地址循环跳转，请重新解析")
            }
            let response = try await headRequest(url, shareOrigin: shareOrigin)
            switch response.code {
            case 300...399:
                guard let loc = response.location else {
                    throw Wave2Error("蓝奏下载地址暂时不可用，请稍后重试")
                }
                url = absolutize("\(uri.scheme ?? "https")://\(host)", loc)
                continue
            case 200, 206:
                let size = response.size
                let isHtml = (response.contentType ?? "").contains("text/html")
                if isHtml {
                    let body = try await httpGetText(url, referer: shareOrigin)
                    if let challenge = LanzouAPI.challengeCookie(body) {
                        if !challenges.insert(host).inserted {
                            throw Wave2Error("蓝奏需要进一步验证，请在分享页完成验证后重试")
                        }
                        setCookie(host: host, name: "acw_sc__v2", value: challenge)
                        continue
                    }
                    if body.contains("验证并下载") {
                        if confirmedHosts.insert(host).inserted,
                           let verified = try await submitVerify(nodeUrl: url, html: body, shareOrigin: shareOrigin) {
                            url = verified
                            continue
                        }
                        throw Wave2Error("蓝奏需要进一步验证，请在分享页完成验证后重试")
                    }
                    throw Wave2Error("蓝奏返回的是验证页面，未创建下载任务，请在分享页完成验证后重试")
                }
                if size <= 0 {
                    let fallback = try await rangeProbe(url, shareOrigin: shareOrigin)
                    if fallback > 0 { return (url, fallback) }
                }
                return (url, size)
            case 403, 404, 410:
                throw Wave2Error("蓝奏下载地址已失效，请稍后重新解析")
            case 429:
                throw Wave2Error("蓝奏下载请求过于频繁，请稍后再试")
            default:
                let fallback = try await rangeProbe(url, shareOrigin: shareOrigin)
                if fallback > 0 { return (url, fallback) }
                throw Wave2Error("蓝奏下载地址暂时不可用，请稍后重试")
            }
        }
        throw Wave2Error("蓝奏下载地址暂时不可用，请稍后重试")
    }

    /// 提交「验证并下载」，返回新的直链 URL 或 nil
    private func submitVerify(nodeUrl: String, html: String, shareOrigin: String) async throws -> String? {
        guard let uri = URL(string: nodeUrl) else { return nil }
        // 新版确认页：data : { 'file':'<base64>','el':el,'sign':'<base64>' }
        var dataBlock: String? = nil
        if let re = try? NSRegularExpression(pattern: #"data\s*:\s*\{([^{}]*(?:\{[^{}]*\}[^{}]*)*)\}"#,
                                             options: [.dotMatchesLineSeparators]) {
            let range = NSRange(html.startIndex..., in: html)
            for m in re.matches(in: html, options: [], range: range) {
                if let r = Range(m.range(at: 1), in: html) {
                    let block = String(html[r])
                    if block.contains("'file'") || block.contains("\"file\"") { dataBlock = block; break }
                }
            }
        }
        let file = dataBlock.flatMap { LanzouAPI.regexGroup(#"['"]?file['"]?\s*:\s*['"]([^'"]+)['"]"#, in: $0) }
            ?? LanzouAPI.regexGroup(#"name=["']file["'][^>]*value=["']([^"']+)["']"#, in: html)
        guard let file = file else { return nil }
        let sign = dataBlock.flatMap { LanzouAPI.regexGroup(#"['"]?sign['"]?\s*:\s*['"]([^'"]+)['"]"#, in: $0) }
            ?? jsVar(html, "sign") ?? inputValue(html, "sign")
        guard let sign = sign else { return nil }
        // 节点页面 2 秒后才显示按钮，需等同样时长再提交
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let ajaxUrl = URL(string: "ajax.php", relativeTo: uri)?.absoluteString
            ?? "\(uri.scheme ?? "https")://\(uri.host ?? "")/ajax.php"
        let json: [String: Any]
        do {
            json = try await formPost(
                ajaxUrl,
                fields: [("file", file), ("el", "2"), ("sign", sign)],
                referer: nodeUrl,
                origin: "\(uri.scheme ?? "https")://\(uri.host ?? "")",
                cookie: nil
            )
        } catch {
            throw Wave2Error("蓝奏下载验证服务暂时不可用，请稍后重试")
        }
        let zt = json.wInt("zt")
        let url = json.wStr("url")
        if zt != 1 || url.isEmpty {
            throw Wave2Error(url.isEmpty ? "蓝奏需要进一步验证，请在分享页完成验证后重试" : url)
        }
        if url == "?SignError" { throw Wave2Error("蓝奏下载验证已过期，请重新解析") }
        return url
    }

    private struct HeadResult { let code: Int; let location: String?; let size: Int64; let contentType: String? }

    private func headRequest(_ url: String, shareOrigin: String) async throws -> HeadResult {
        var headers = [
            "User-Agent": LanzouAPI.webUA,
            "Referer": "\(shareOrigin)/"
        ]
        let c = mergedCookie(host: hostOf(url), extra: LanzouAPI.downIPCookie)
        if !c.isEmpty { headers["Cookie"] = c }
        let req = Wave2HTTP.request(url: url, method: "HEAD", headers: headers)
        let raw = try await Wave2HTTP.send(req, noRedirect: true)
        let cr = raw.http.value(forHTTPHeaderField: "Content-Range")
        let size: Int64
        if let cr = cr {
            size = Int64(cr.split(separator: "/").last ?? "") ?? 0
        } else if raw.http.statusCode == 200 {
            size = Int64(raw.http.value(forHTTPHeaderField: "Content-Length") ?? "") ?? 0
        } else {
            size = 0
        }
        return HeadResult(
            code: raw.http.statusCode,
            location: raw.http.value(forHTTPHeaderField: "Location"),
            size: size,
            contentType: raw.http.value(forHTTPHeaderField: "Content-Type")
        )
    }

    private func rangeProbe(_ url: String, shareOrigin: String) async throws -> Int64 {
        var headers = [
            "User-Agent": LanzouAPI.webUA,
            "Referer": "\(shareOrigin)/",
            "Range": "bytes=0-8191"
        ]
        let c = mergedCookie(host: hostOf(url), extra: LanzouAPI.downIPCookie)
        if !c.isEmpty { headers["Cookie"] = c }
        let req = Wave2HTTP.request(url: url, headers: headers)
        let raw = try await Wave2HTTP.send(req, noRedirect: true)
        if let cr = raw.http.value(forHTTPHeaderField: "Content-Range") {
            return Int64(cr.split(separator: "/").last ?? "") ?? 0
        }
        return 0
    }

    private func httpGetText(_ url: String, referer: String?) async throws -> String {
        var headers = ["User-Agent": LanzouAPI.webUA]
        if let referer = referer { headers["Referer"] = referer }
        let c = mergedCookie(host: hostOf(url), extra: LanzouAPI.downIPCookie)
        if !c.isEmpty { headers["Cookie"] = c }
        let raw = try await Wave2HTTP.send(Wave2HTTP.request(url: url, headers: headers))
        return raw.text
    }

    private func fetchPageFollowingLanzou(_ url: String) async throws -> String {
        var current = url
        var challenged = Set<String>()
        for _ in 0..<8 {
            let host = hostOf(current)
            var headers = [
                "User-Agent": LanzouAPI.webUA,
                "Referer": current
            ]
            let c = cookieHeader(host: host)
            if !c.isEmpty { headers["Cookie"] = c }
            let raw = try await Wave2HTTP.send(Wave2HTTP.request(url: current, headers: headers), noRedirect: true)
            let code = raw.http.statusCode
            if (300...399).contains(code) {
                guard let loc = raw.http.value(forHTTPHeaderField: "Location") else {
                    throw Wave2Error("蓝奏页面跳转次数过多，请重新解析")
                }
                let next = absolutize(current, loc)
                guard let nextHost = URL(string: next)?.host, LanzouAPI.isLanzouHost(nextHost) else {
                    throw Wave2Error("蓝奏分享链接无效")
                }
                current = next
                continue
            }
            let body = raw.text
            if body.count > 2_000_000 { throw Wave2Error("蓝奏分享页面过大或异常") }
            if let challenge = LanzouAPI.challengeCookie(body) {
                if !challenged.insert(host).inserted {
                    throw Wave2Error("蓝奏需要进一步验证，请在分享页完成验证后重试")
                }
                setCookie(host: host, name: "acw_sc__v2", value: challenge)
                continue
            }
            if body.contains("文件已取消") || body.contains("不存在") {
                throw Wave2Error("蓝奏文件已取消分享或不存在")
            }
            if body.contains("请求过于频繁") || body.contains("稍后再试") {
                throw Wave2Error("蓝奏请求过于频繁，请稍后再试")
            }
            return body
        }
        throw Wave2Error("蓝奏页面跳转次数过多，请重新解析")
    }

    private func fetchPage(_ url: String, referer: String?, cookie: String?) async throws -> String {
        var headers = [
            "User-Agent": LanzouAPI.webUA,
            "Referer": referer ?? url
        ]
        let c = mergedCookie(host: hostOf(url), extra: cookie)
        if !c.isEmpty { headers["Cookie"] = c }
        let raw = try await Wave2HTTP.send(Wave2HTTP.request(url: url, headers: headers))
        guard (200...299).contains(raw.http.statusCode) else {
            throw Wave2Error("蓝奏文件已取消分享或不存在")
        }
        return raw.text
    }

    private func validateAjax(_ json: [String: Any]) throws {
        if json.wInt("zt") == 1 { return }
        let inf = json.wStr("inf")
        if inf.contains("密码") || inf.contains("提取码") {
            throw Wave2Error("蓝奏提取码错误，请检查后重新解析")
        }
        if inf.contains("不存在") || inf.contains("取消") || inf.contains("过期") || inf.contains("删除") {
            throw Wave2Error("蓝奏文件已取消分享或不存在")
        }
        if inf.contains("频繁") || inf.contains("次数") || inf.contains("稍后") {
            throw Wave2Error("蓝奏请求过于频繁，请稍后再试")
        }
        throw Wave2Error("蓝奏解析失败，请确认分享链接和提取码后重试")
    }

    /// doupload.php 系列统一请求；allowEnd 时 zt==2 视为成功（列表结束）
    private func doupload(cookie: String, uid: String, vei: String,
                          fields: [(String, String)], allowEnd: Bool = false) async throws -> [String: Any] {
        let req = Wave2HTTP.request(
            url: "\(LanzouAPI.douploadURL)?uid=\(uid)&vei=\(vei)",
            method: "POST",
            headers: [
                "Cookie": cookie,
                "User-Agent": LanzouAPI.webUA,
                "Referer": LanzouAPI.mydiskURL,
                "Origin": LanzouAPI.origin,
                "X-Requested-With": "XMLHttpRequest",
                "Content-Type": "application/x-www-form-urlencoded"
            ],
            body: Wave2HTTP.formBody(fields)
        )
        let raw = try await Wave2HTTP.send(req)
        if raw.http.statusCode == 401 || raw.http.statusCode == 403 {
            throw Wave2Error("蓝奏登录已过期，请重新登录")
        }
        guard let json = wJSONObj(raw.data) else {
            throw Wave2Error("蓝奏文件操作失败，请在官网检查权限和文件类型")
        }
        let zt = json.wInt("zt", -1)
        switch zt {
        case 1: return json
        case 2 where allowEnd: return json
        case 4: throw Wave2Error("蓝奏请求频繁，请稍后重试")
        case 9: throw Wave2Error("蓝奏登录已过期，请重新登录")
        default: throw Wave2Error("蓝奏文件操作失败（\(zt)），请在官网检查权限和文件类型")
        }
    }

    private func formPost(_ url: String, fields: [(String, String)], referer: String,
                          origin: String, cookie: String?) async throws -> [String: Any] {
        let body = try await formPostRaw(url, fields: fields, referer: referer, origin: origin, cookie: cookie)
        guard let json = wJSONObj(body) else {
            if body.trimmingCharacters(in: .whitespaces).hasPrefix("<") {
                throw Wave2Error("蓝奏返回了验证页面，请稍后重试或在分享页完成验证")
            }
            throw Wave2Error("蓝奏解析服务响应异常，请稍后重试")
        }
        return json
    }

    private func formPostRaw(_ url: String, fields: [(String, String)], referer: String,
                             origin: String, cookie: String?) async throws -> Data {
        var headers = [
            "User-Agent": LanzouAPI.webUA,
            "Referer": referer,
            "Origin": origin,
            "X-Requested-With": "XMLHttpRequest",
            "Content-Type": "application/x-www-form-urlencoded"
        ]
        let c = mergedCookie(host: hostOf(url), extra: cookie)
        if !c.isEmpty { headers["Cookie"] = c }
        let req = Wave2HTTP.request(url: url, method: "POST", headers: headers, body: Wave2HTTP.formBody(fields))
        let raw = try await Wave2HTTP.send(req, noRedirect: true)
        if raw.http.statusCode == 429 { throw Wave2Error("蓝奏请求过于频繁，请稍后再试") }
        if raw.data.count > 4_000_000 { throw Wave2Error("蓝奏解析服务返回内容过大，请稍后重试") }
        if !(200...299).contains(raw.http.statusCode) && raw.data.isEmpty {
            throw Wave2Error("蓝奏解析服务响应异常（HTTP \(raw.http.statusCode)），请稍后重试")
        }
        return raw.data
    }

    private func buildShareInfo(raw: String, domain: String, pwd: String) -> ShareInfoResult {
        let base: String
        if domain.isEmpty { base = "https://pan.lanzoui.com" }
        else if domain.contains("://") { base = domain }
        else { base = "https://\(domain)" }
        let url: String
        if raw.contains("://") {
            url = raw
        } else if let u = URL(string: base), let scheme = u.scheme, let host = u.host {
            url = "\(scheme)://\(host)/\(raw.hasPrefix("/") ? String(raw.dropFirst()) : raw)"
        } else {
            url = "\(base)/\(raw)"
        }
        return ShareInfoResult(shareUrl: url, passcode: pwd)
    }

    private func extractTitle(_ html: String) -> String {
        if let t = LanzouAPI.regexGroup(#"<title>([^<]*)</title>"#, in: html) {
            let clean = t.replacingOccurrences(of: " - 蓝奏云", with: "")
                .replacingOccurrences(of: "蓝奏云", with: "")
                .trimmingCharacters(in: .whitespaces)
            if !clean.isEmpty && !clean.contains("密码") { return clean }
        }
        if let t = LanzouAPI.regexGroup(#"class=["']n["']>([^<]+)<"#, in: html) {
            return t.trimmingCharacters(in: .whitespaces)
        }
        if let t = LanzouAPI.regexGroup(#"var\s+filename\s*=\s*['"]([^'"]+)['"]"#, in: html) { return t }
        return ""
    }

    private func jsVar(_ html: String, _ name: String) -> String? {
        LanzouAPI.regexGroup(#"(?:(?:var|let|const)\s+)?"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*['"]([^'"]*)['"]"#, in: html)
    }

    /// 读取未加引号的 JS 变量值（如 `var kdns = 0`）
    private func jsVarRaw(_ html: String, _ name: String) -> String? {
        guard let v = LanzouAPI.regexGroup(#"(?:var|let|const)\s+"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*([^;,\n\r]+)"#, in: html) else { return nil }
        return v.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
    }

    /// 下载接口 URL：优先页面里的 domain1/domain2（新版在 apifile.woozooo.com，跨域），
    /// 其次页面中出现的绝对 ajaxm/ajaxfile 地址，最后回退同源
    private func resolveAjaxUrl(_ html: String, origin: String, fileId: String, withPwd: Bool) -> String {
        let candidate = jsVar(html, "domain1").flatMap { $0.contains("/ajax") ? $0 : nil }
            ?? jsVar(html, "domain2").flatMap { $0.contains("/ajax") ? $0 : nil }
            ?? LanzouAPI.regexMatch(#"https?://[^'"\s]+/(?:ajaxm|ajaxfile)\.php\?file=\d+"#, in: html)
        if let candidate = candidate, !candidate.isEmpty { return candidate }
        return withPwd ? "\(origin)/ajaxfile.php?file=\(fileId)" : "\(origin)/ajaxm.php?file=\(fileId)"
    }

    private func inputValue(_ html: String, _ name: String) -> String? {
        LanzouAPI.regexGroup(#"<input[^>]*name=["']"# + NSRegularExpression.escapedPattern(for: name) + #"["'][^>]*value=["']([^"']*)["']"#, in: html)
            ?? LanzouAPI.regexGroup(#"<input[^>]*value=["']([^"']*)["'][^>]*name=["']"# + NSRegularExpression.escapedPattern(for: name) + #"["']"#, in: html)
    }

    private func absolutize(_ base: String, _ target: String) -> String {
        if target.hasPrefix("http://") || target.hasPrefix("https://") { return target }
        guard let uri = URL(string: base), let scheme = uri.scheme, let host = uri.host else { return target }
        let root = "\(scheme)://\(host)"
        return target.hasPrefix("/") ? root + target : "\(root)/\(target)"
    }

    /// "1.5 M" / "200 K" 形态的展示大小 → 字节（1024 进制）
    static func parseDisplaySize(_ text: String) -> Int64 {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return 0 }
        guard let m = regexGroup(#"([\d.]+)\s*([KMGT]?)"#, in: t, group: 1, options: .caseInsensitive),
              let value = Double(m) else { return 0 }
        let unit = (regexGroup(#"([\d.]+)\s*([KMGT]?)"#, in: t, group: 2, options: .caseInsensitive) ?? "").uppercased()
        let factor: Int64
        switch unit {
        case "K": factor = 1024
        case "M": factor = 1024 * 1024
        case "G": factor = 1024 * 1024 * 1024
        case "T": factor = 1024 * 1024 * 1024 * 1024
        default: factor = 1
        }
        return Int64(value * Double(factor))
    }
}

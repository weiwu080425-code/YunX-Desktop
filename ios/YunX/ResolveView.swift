import SwiftUI

@MainActor
final class ResolveViewModel: ObservableObject {
    @Published var inputText = ""
    @Published var shareTitle = ""
    @Published var files: [ShareFile] = []
    @Published var isParsing = false
    @Published var isLoadingDir = false
    /// 正在取链的文件 id（取链含转存轮询，可能要几秒）
    @Published var busyFileId: String?
    @Published var errorMessage: String?
    /// 面包屑目录名（不含根目录）
    @Published var pathNames: [String] = []

    private var session: ShareSession?
    /// 已成功建立会话的平台（第二批平台的会话是各自的私有结构体，不走上面这个）
    private var activePlatform: SharePlatform?
    /// 本次解析用的提取码（迅雷列根目录、蓝奏取链还要用）
    private var parsedPwd: String?
    private var dirStack: [String] = []
    private var currentDirFid = "0"

    // 第二批平台的私有会话
    private var xunleiSession: XunleiAPI.ShareSession?
    private var xunleiLoginExpired = false
    private var pan123Session: Pan123API.ShareSession?
    private var pan115Session: Pan115API.ShareSession?
    private var c139Session: C139API.ShareSession?
    private var guangyaSession: GuangYaAPI.ShareSession?
    private var lanzouPage: LanzouAPI.SharePage?
    private var ilanzouShareId = ""
    private var githubBrowse: GitHubBrowse?
    private var githubRootFid = ""

    private let quarkAPI = QuarkAPI.shared

    init() {
        // 迅雷 panCall 的 401 自动刷新：用存着的 refresh_token 换新 token 对并落库
        XunleiAPI.shared.refreshTokenProvider = { deviceId in
            let store = CookieStore.shared
            guard !store.xunleiRefreshToken.isEmpty else { return nil }
            let pair = await XunleiAPI.shared.refreshToken(
                refreshToken: store.xunleiRefreshToken,
                deviceId: deviceId,
                authType: store.xunleiAuthType
            )
            if let pair {
                store.xunleiAccessToken = pair.access
                if !pair.refresh.isEmpty { store.xunleiRefreshToken = pair.refresh }
            }
            return pair
        }
        // GitHub 可选 Token 注入；被 401 拒绝时清掉恢复匿名
        let savedGitHubToken = CookieStore.shared.githubToken
        GitHubAPI.shared.token = savedGitHubToken.isEmpty ? nil : savedGitHubToken
        GitHubAPI.shared.onUnauthorized = {
            CookieStore.shared.githubToken = ""
            GitHubAPI.shared.token = nil
        }
    }

    /// 当前平台：已解析出会话用会话的平台；否则按输入文案里识别到的平台；都无则默认夸克
    var detectedPlatform: SharePlatform? {
        activePlatform ?? session?.platform ?? ShareLinkParser.parse(inputText)?.platform
    }
    var effectivePlatform: SharePlatform { detectedPlatform ?? .quark }

    /// 当前目录的根键：GitHub 的根 fid 由 open() 返回，其余用平台 rootDirKey
    private var rootKey: String {
        effectivePlatform == .github ? githubRootFid : effectivePlatform.rootDirKey
    }

    var hasSession: Bool {
        session != nil || xunleiSession != nil || pan123Session != nil || pan115Session != nil
            || c139Session != nil || guangyaSession != nil || lanzouPage != nil
            || !ilanzouShareId.isEmpty || githubBrowse != nil
    }

    /// 当前平台是否游客模式（没存该平台凭据）
    var isGuest: Bool {
        switch effectivePlatform {
        case .quark, .baidu, .uc, .pan115, .c139:
            return CookieStore.shared.cookie(for: effectivePlatform).isEmpty
        case .xunlei:
            return CookieStore.shared.xunleiAccessToken.isEmpty
        case .pan123:
            return CookieStore.shared.pan123Token.isEmpty
        case .guangya:
            return CookieStore.shared.guangyaAccessToken.isEmpty
        case .lanzou, .ilanzou, .github, .starsea:
            return false
        }
    }

    var inputPlaceholder: String {
        if let platform = detectedPlatform {
            return "粘贴\(platform.shortName)分享文案（含链接和提取码）"
        }
        return "粘贴分享文案（夸克 / 百度 / UC / 迅雷 / 123 / 115 / 139 / 光鸭 / 蓝奏 / 蓝奏优享 / GitHub），或迅雷口令 / 星海口令"
    }

    /// 游客模式提示文案（按当前平台显示）
    var guestHint: String {
        switch effectivePlatform {
        case .quark:
            return "未设置 Cookie：当前是游客模式，只能下载约 50MB 以内的小文件。点右上角齿轮按钮粘贴 Cookie 后可下大文件。"
        case .baidu:
            return "未设置百度 Cookie：当前是游客模式，可以浏览文件列表，但下载必须先登录。点右上角齿轮按钮粘贴百度 Cookie 后再下载。"
        case .uc:
            return "未设置 UC Cookie：当前是游客模式，可以直接下载文件；粘贴 Cookie 后下载更稳定。点右上角齿轮按钮设置。"
        case .xunlei:
            return "未登录迅雷：可以浏览分享文件列表，但下载必须先登录。点右上角齿轮按钮粘贴迅雷网页凭据，或用账号密码登录。"
        case .pan123:
            return "未登录 123 云盘：可以浏览分享文件列表，但下载必须先登录。点右上角齿轮按钮用账号密码登录或粘贴 token。"
        case .pan115:
            return "未保存 115 Cookie：可以浏览分享列表，小文件可直接下载；大文件取链需要登录 Cookie。点右上角齿轮按钮粘贴。"
        case .c139:
            return "未保存 139 Cookie：可以浏览分享文件列表，但下载需要登录。点右上角齿轮按钮粘贴 139 网页版登录 Cookie。"
        case .guangya:
            return "未登录光鸭：普通分享可直接下载；受限分享需要登录并转存后才能下载。点右上角齿轮按钮用账号密码登录。"
        case .lanzou, .ilanzou, .github, .starsea:
            return ""
        }
    }

    func parse() {
        let text = inputText
        isParsing = true
        errorMessage = nil
        Task {
            do {
                guard let parsed = ShareLinkParser.parse(text) else {
                    throw QuarkError("无法识别分享链接（支持夸克 / 百度 / UC / 迅雷 / 123 / 115 / 139 / 光鸭 / 蓝奏 / 蓝奏优享 / GitHub，也可粘贴迅雷口令或星海口令）")
                }
                try await startSession(parsed: parsed, originalText: text)
                if xunleiLoginExpired {
                    errorMessage = "迅雷登录已过期，已按游客模式浏览（可看列表，下载请重新登录）"
                }
            } catch {
                errorMessage = ResolveViewModel.message(of: error)
            }
            isParsing = false
        }
    }

    /// 按平台建立会话并加载根目录；星海/迅雷口令先转换成链接再递归走目标平台
    private func startSession(parsed: ShareLinkParser.ParsedShare, originalText: String) async throws {
        parsedPwd = parsed.pwd
        xunleiLoginExpired = false
        switch parsed.platform {
        case .starsea:
            let link = try await StarSeaAPI.shared.resolveToShareLink(
                command: parsed.command ?? originalText, passcode: parsed.pwd)
            guard let next = ShareLinkParser.parse(link) else {
                throw QuarkError("星海口令转换出的链接无法识别")
            }
            try await startSession(parsed: next, originalText: link)
        case .xunlei where parsed.command != nil:
            // 迅雷中文口令 → 带提取码的分享链接；转换失败再试星海口令（两者都是纯文本口令）
            let keyword = parsed.command ?? ""
            do {
                let link = try await XunleiAPI.shared.parseKouling(keyword: keyword)
                guard let next = ShareLinkParser.parse(link) else {
                    throw QuarkError("迅雷口令转换出的链接无法识别")
                }
                try await startSession(parsed: next, originalText: link)
            } catch {
                if let seaLink = try? await StarSeaAPI.shared.resolveToShareLink(command: keyword, passcode: nil),
                   let next = ShareLinkParser.parse(seaLink) {
                    try await startSession(parsed: next, originalText: seaLink)
                    return
                }
                throw error
            }
        case .quark:
            let s = try await quarkAPI.createSession(parsed: parsed, pwdOverride: nil)
            session = s
            shareTitle = s.title
            try await finishStart(platform: .quark)
        case .baidu:
            let s = try await BaiduAPI.shared.createSession(parsed: parsed, pwdOverride: nil)
            session = s
            shareTitle = s.title
            try await finishStart(platform: .baidu)
        case .uc:
            let s = try await UCAPI.shared.createSession(parsed: parsed, pwdOverride: nil)
            session = s
            shareTitle = s.title
            try await finishStart(platform: .uc)
        case .xunlei:
            let creds = try await xunleiCredentials()
            let s = try await XunleiAPI.shared.createSession(
                shareId: parsed.shareId, passCode: parsed.pwd ?? "",
                accessToken: creds.access, deviceId: creds.deviceId, captchaToken: creds.captcha)
            xunleiSession = s
            shareTitle = s.title
            try await finishStart(platform: .xunlei)
        case .pan123:
            let s = try await Pan123API.shared.createSession(shareKey: parsed.shareId, pwd: parsed.pwd)
            pan123Session = s
            shareTitle = s.title
            try await finishStart(platform: .pan123)
        case .pan115:
            let s = try await Pan115API.shared.createSession(
                shareCode: parsed.shareId, receiveCode: parsed.pwd ?? "",
                cookie: CookieStore.shared.cookie(for: .pan115))
            pan115Session = s
            shareTitle = s.title
            try await finishStart(platform: .pan115)
        case .c139:
            let s = try await C139API.shared.createSession(linkId: parsed.shareId, passwd: parsed.pwd ?? "")
            c139Session = s
            shareTitle = s.title
            try await finishStart(platform: .c139)
        case .guangya:
            let s = try await GuangYaAPI.shared.createSession(shareId: parsed.shareId, pwd: parsed.pwd)
            guangyaSession = s
            shareTitle = s.title
            try await finishStart(platform: .guangya)
        case .lanzou:
            let page = try await LanzouAPI.shared.resolveShare(
                shareUrl: parsed.rawUrl.isEmpty ? parsed.shareId : parsed.rawUrl, pwd: parsed.pwd)
            lanzouPage = page
            shareTitle = page.title
            try await finishStart(platform: .lanzou)
        case .ilanzou:
            ilanzouShareId = parsed.shareId
            shareTitle = "蓝奏优享分享"
            try await finishStart(platform: .ilanzou)
        case .github:
            guard let link = GitHubLinkParser.parse(originalText) else {
                throw QuarkError("无法识别 GitHub 链接")
            }
            let browse = GitHubBrowse()
            let result = try await browse.open(link: link)
            githubBrowse = browse
            githubRootFid = result.rootFid
            shareTitle = result.session.title
            if let direct = result.directLink {
                // 文件直链：不进列表，直接给一行可下载的文件
                activePlatform = .github
                dirStack = []
                pathNames = []
                currentDirFid = ""
                files = [ShareFile(fid: "github:direct", fname: direct.filename,
                                   fsize: direct.size, isdir: false, pdirFid: "",
                                   fidToken: "", modifyTime: "")]
                return
            }
            try await finishStart(platform: .github)
        }
    }

    /// 会话建好后的统一收尾：重置目录栈并加载根目录
    private func finishStart(platform: SharePlatform) async throws {
        activePlatform = platform
        dirStack = []
        pathNames = []
        currentDirFid = rootKey
        try await loadCurrentDir()
    }

    func enterFolder(_ file: ShareFile) {
        // GitHub 分页哨兵「加载更多」：不进新目录，把下一页追加到当前列表
        if effectivePlatform == .github, file.fid.hasPrefix("github:more_") {
            loadMoreGitHub(file)
            return
        }
        dirStack.append(file.fid)
        pathNames.append(file.fname)
        currentDirFid = file.fid
        reload()
    }

    private func loadMoreGitHub(_ sentinel: ShareFile) {
        guard let browse = githubBrowse else { return }
        isLoadingDir = true
        errorMessage = nil
        Task {
            do {
                let more = try await browse.listDir(fid: sentinel.fid)
                files.removeAll { $0.fid == sentinel.fid }
                files.append(contentsOf: more)
            } catch {
                errorMessage = ResolveViewModel.message(of: error)
            }
            isLoadingDir = false
        }
    }

    /// 面包屑回退：level 0 = 分享根目录；当前层（level == pathNames.count）无需操作
    /// （对应 Kotlin ResolveViewModel.navigateToLevel）
    func navigateToLevel(_ level: Int) {
        if level < 0 || level >= pathNames.count { return }
        dirStack = Array(dirStack.prefix(level))
        pathNames = Array(pathNames.prefix(level))
        currentDirFid = dirStack.last ?? rootKey
        reload()
    }

    private func reload() {
        guard hasSession else { return }
        isLoadingDir = true
        errorMessage = nil
        Task {
            do {
                try await loadCurrentDir()
            } catch {
                errorMessage = ResolveViewModel.message(of: error)
            }
            isLoadingDir = false
        }
    }

    /// 按会话平台拉取当前目录文件列表；百度的分享标题在列表响应里，shareTitle 为空时回填
    private func loadCurrentDir() async throws {
        switch activePlatform {
        case .quark:
            guard let s = session else { return }
            files = try await quarkAPI.listAllShareFiles(session: s, pdirFid: currentDirFid)
        case .uc:
            guard let s = session else { return }
            files = try await UCAPI.shared.listAllShareFiles(session: s, pdirFid: currentDirFid)
        case .baidu:
            guard let s = session else { return }
            let result = try await BaiduAPI.shared.listAllShareFiles(session: s, dir: currentDirFid)
            files = result.files
            if shareTitle.isEmpty && !result.title.isEmpty { shareTitle = result.title }
        case .xunlei:
            guard let s = xunleiSession else { return }
            let creds = try await xunleiCredentials()
            if currentDirFid == rootKey {
                files = try await XunleiAPI.shared.listShareRoot(
                    shareId: s.shareId, passCode: parsedPwd ?? "",
                    accessToken: creds.access, deviceId: creds.deviceId, captchaToken: creds.captcha)
            } else {
                files = try await XunleiAPI.shared.listShareDir(
                    shareId: s.shareId, parentId: currentDirFid, passCodeToken: s.stoken,
                    accessToken: creds.access, deviceId: creds.deviceId, captchaToken: creds.captcha)
            }
        case .pan123:
            guard let s = pan123Session else { return }
            files = try await Pan123API.shared.listAllShareFiles(session: s, dirFid: currentDirFid)
        case .pan115:
            guard let s = pan115Session else { return }
            files = try await Pan115API.shared.listAllShareFiles(
                session: s, dirFid: currentDirFid, cookie: CookieStore.shared.cookie(for: .pan115))
        case .c139:
            guard let s = c139Session else { return }
            let account = C139API.credential(fromCookie: CookieStore.shared.cookie(for: .c139))?.account ?? ""
            files = try await C139API.shared.listShareFiles(
                linkId: s.shareId, passwd: s.stoken, parentId: currentDirFid, account: account)
        case .guangya:
            guard let s = guangyaSession else { return }
            files = try await GuangYaAPI.shared.listAllShareFiles(session: s, parentId: currentDirFid)
        case .lanzou:
            guard let page = lanzouPage else { return }
            if page.isFolder {
                files = try await LanzouAPI.shared.listShareFolder(page: page, pwd: parsedPwd)
            } else if let single = page.singleFile {
                files = [single]
            } else {
                files = []
            }
        case .ilanzou:
            let uuid = try await ilanzouUuid()
            let folderId: String? = currentDirFid == rootKey
                ? nil
                : String(currentDirFid.dropFirst(2)) // 去掉 "d:" 前缀
            files = try await ILanzouAPI.shared.shareList(
                shareId: ilanzouShareId, folderId: folderId, uuid: uuid)
        case .github:
            guard let browse = githubBrowse else { return }
            files = try await browse.listDir(fid: currentDirFid)
        case .starsea, nil:
            return
        }
    }

    // MARK: - 平台凭据组装

    private struct XunleiCreds {
        let access: String
        let deviceId: String
        let captcha: String
    }

    /// 迅雷身份三件套：存着的 token 先过 ensureFreshToken 预检（快过期自动刷新并落库）；
    /// 刷新不动时降级游客浏览（列表匿名可看），并标记登录过期提示。
    private func xunleiCredentials() async throws -> XunleiCreds {
        let store = CookieStore.shared
        let deviceId = store.xunleiDeviceId.isEmpty ? XunleiAPI.newDeviceId() : store.xunleiDeviceId
        var access = store.xunleiAccessToken
        if !access.isEmpty {
            do {
                let fresh = try await XunleiAPI.shared.ensureFreshToken(
                    accessToken: access, refreshToken: store.xunleiRefreshToken,
                    deviceId: deviceId, authType: store.xunleiAuthType)
                access = fresh.access
                store.xunleiAccessToken = fresh.access
                if !fresh.refresh.isEmpty { store.xunleiRefreshToken = fresh.refresh }
            } catch {
                access = ""
                xunleiLoginExpired = true
            }
        }
        XunleiAPI.shared.useWebCaptchaChannel = store.xunleiAuthType == "webToken"
        return XunleiCreds(access: access, deviceId: deviceId, captcha: store.xunleiCaptchaToken)
    }

    /// 蓝奏优享设备 uuid：存着的优先，没有就向服务端申请一个并落库
    private func ilanzouUuid() async throws -> String {
        let store = CookieStore.shared
        if !store.ilanzouUuid.isEmpty { return store.ilanzouUuid }
        let uuid = try await ILanzouAPI.shared.getUuid()
        store.ilanzouUuid = uuid
        return uuid
    }

    /// 光鸭账号 token（给受限分享转存用）：顺带把登录设备 did 注入客户端；未登录返回 nil
    private func guangyaAccountToken() -> String? {
        let store = CookieStore.shared
        let token = store.guangyaAccessToken
        if token.isEmpty { return nil }
        GuangYaAPI.shared.loggedInDeviceId = store.guangyaDevice().deviceId
        return token
    }

    private func startDownload(link: DownloadLink, file: ShareFile,
                               headers: [String: String], cleanup: (() -> Void)? = nil) {
        DownloadCenter.shared.start(
            urlString: link.downloadUrl,
            filename: link.filename.isEmpty ? file.fname : link.filename,
            fileKey: file.id,
            headers: headers,
            cleanup: cleanup
        )
    }

    func download(_ file: ShareFile) {
        guard hasSession else { return }
        busyFileId = file.id
        errorMessage = nil
        Task {
            do {
                try await performDownload(file)
            } catch {
                errorMessage = ResolveViewModel.message(of: error)
            }
            busyFileId = nil
        }
    }

    private func performDownload(_ file: ShareFile) async throws {
                switch effectivePlatform {
                case .quark:
                    guard let s = session else { throw QuarkError("会话已失效，请重新解析") }
                    let (link, cookie) = try await quarkAPI.resolveDownloadLink(file: file, session: s)
                    // 夸克下载请求头（对应 Kotlin ResolveViewModel.enqueueDownload 的夸克分支）：
                    // Cookie 必须是取链用的同一份；游客链用直链自带的 __pugs。
                    var headers: [String: String] = [
                        "User-Agent": QuarkAPI.apiUserAgent,
                        "Referer": QuarkAPI.downloadReferer
                    ]
                    if !cookie.isEmpty { headers["Cookie"] = cookie }
                    let cleanupDirFid = link.cleanupDirFid
                    let downloadCookie = cookie
                    let apiRef = quarkAPI
                    DownloadCenter.shared.start(
                        urlString: link.downloadUrl,
                        filename: link.filename.isEmpty ? file.fname : link.filename,
                        fileKey: file.id,
                        headers: headers
                    ) {
                        // 下载完成才删临时转存子目录（下载期间 fid 必须存活）；失败静默
                        if let dirFid = cleanupDirFid {
                            Task { await apiRef.deleteFile(fid: dirFid, cookie: downloadCookie) }
                        }
                    }
                case .baidu:
                    guard let s = session else { throw QuarkError("会话已失效，请重新解析") }
                    let (link, cookie) = try await BaiduAPI.shared.resolveDownloadLink(file: file, session: s)
                    // 百度下载请求头（对应 Kotlin enqueueDownload 百度分支）：只有 Cookie + netdisk UA。
                    // 转存文件在取链后已立即删除，直链自带签名、无需 cleanup。
                    var headers: [String: String] = ["User-Agent": BaiduAPI.uaNetdisk]
                    if !cookie.isEmpty { headers["Cookie"] = cookie }
                    DownloadCenter.shared.start(
                        urlString: link.downloadUrl,
                        filename: link.filename.isEmpty ? file.fname : link.filename,
                        fileKey: file.id,
                        headers: headers
                    )
                case .uc:
                    guard let s = session else { throw QuarkError("会话已失效，请重新解析") }
                    let (link, cookie, isGuest) = try await UCAPI.shared.resolveDownloadLink(file: file, session: s)
                    // UC 下载请求头（对应 Kotlin enqueueDownload 的 UC 分支）：
                    // 缺 Referer 会被限速约 100KB/s；游客态用游客 UA + Sec-Ch-Ua + __pugs。
                    var headers: [String: String]
                    if isGuest {
                        headers = [
                            "User-Agent": UCAPI.guestUserAgent,
                            "Sec-Ch-Ua": UCAPI.guestSecChUa,
                            "Referer": UCAPI.downloadReferer,
                            "Origin": UCAPI.webOrigin
                        ]
                    } else {
                        headers = [
                            "User-Agent": UCAPI.userAgent,
                            "Referer": UCAPI.downloadReferer,
                            "Origin": UCAPI.webOrigin
                        ]
                    }
                    if !cookie.isEmpty { headers["Cookie"] = cookie }
                    DownloadCenter.shared.start(
                        urlString: link.downloadUrl,
                        filename: link.filename.isEmpty ? file.fname : link.filename,
                        fileKey: file.id,
                        headers: headers
                    )
                case .xunlei:
                    guard let s = xunleiSession else { throw QuarkError("会话已失效，请重新解析") }
                    let creds = try await xunleiCredentials()
                    // 迅雷取链内部已转存→取链→删转存文件；下载头只有 App UA（浏览器 UA 会被 CDN 降级）
                    let (link, headers) = try await XunleiAPI.shared.resolveDownloadLink(
                        shareId: s.shareId, passCodeToken: s.stoken, file: file,
                        accessToken: creds.access, deviceId: creds.deviceId, captchaToken: creds.captcha)
                    startDownload(link: link, file: file, headers: headers)
                case .pan123:
                    guard let s = pan123Session else { throw QuarkError("会话已失效，请重新解析") }
                    let token = CookieStore.shared.pan123Token
                    if token.isEmpty {
                        throw QuarkError("123 云盘下载需要先登录：点右上角齿轮，用账号密码登录或粘贴 token")
                    }
                    let link = try await Pan123API.shared.getShareDownloadLink(
                        shareKey: s.shareKey, file: file, token: token)
                    startDownload(link: link, file: file, headers: Pan123API.downloadHeaders)
                case .pan115:
                    guard let s = pan115Session else { throw QuarkError("会话已失效，请重新解析") }
                    let cookie = CookieStore.shared.cookie(for: .pan115)
                    let (link, headers) = try await Pan115API.shared.resolveDownloadLink(
                        session: s, file: file, cookie: cookie)
                    let cleanupDir = link.cleanupDirFid
                    startDownload(link: link, file: file, headers: headers) {
                        // 转存兜底的临时目录：下载完成后删除（失败静默）
                        if let dir = cleanupDir {
                            Task { await Pan115API.shared.cleanupTempDir(dirFid: dir, cookie: cookie) }
                        }
                    }
                case .c139:
                    guard let s = c139Session else { throw QuarkError("会话已失效，请重新解析") }
                    guard let cred = C139API.credential(fromCookie: CookieStore.shared.cookie(for: .c139)) else {
                        throw QuarkError("139 下载需要先登录：点右上角齿轮粘贴 139 网页版登录 Cookie")
                    }
                    let link = try await C139API.shared.getDownloadLink(
                        linkId: s.shareId, file: file, credential: cred)
                    startDownload(link: link, file: file, headers: C139API.downloadHeaders())
                case .guangya:
                    guard let s = guangyaSession else { throw QuarkError("会话已失效，请重新解析") }
                    let token = guangyaAccountToken()
                    let link = try await GuangYaAPI.shared.resolveDownloadLink(
                        session: s, file: file, accountToken: token)
                    let cleanupDir = link.cleanupDirFid
                    startDownload(link: link, file: file, headers: GuangYaAPI.downloadHeaders) {
                        // 受限转存的临时目录：下载完成后删除（失败静默）
                        if let dir = cleanupDir, let token = token {
                            Task { _ = try? await GuangYaAPI.shared.deleteFiles(accessToken: token, fileIds: [dir]) }
                        }
                    }
                case .lanzou:
                    guard let page = lanzouPage else { throw QuarkError("会话已失效，请重新解析") }
                    let (link, headers) = try await LanzouAPI.shared.getShareDownloadLink(
                        page: page, file: file, pwd: parsedPwd)
                    startDownload(link: link, file: file, headers: headers)
                case .ilanzou:
                    let uuid = try await ilanzouUuid()
                    let fileId = file.fid.hasPrefix("f:") ? String(file.fid.dropFirst(2)) : file.fid
                    // 分享取链按匿名通道（userId 传空串，与源码匿名路径一致）
                    let link = try await ILanzouAPI.shared.shareDownload(
                        shareId: ilanzouShareId, fileId: fileId, userId: "", uuid: uuid)
                    startDownload(link: link, file: file, headers: [
                        "User-Agent": ILanzouAPI.webUA,
                        "Referer": ILanzouAPI.downloadReferer,
                        "Origin": ILanzouAPI.downloadOrigin
                    ])
                case .github:
                    guard let browse = githubBrowse else { throw QuarkError("会话已失效，请重新解析") }
                    guard let target = browse.downloadTarget(for: file) else {
                        throw QuarkError("该文件暂无可下载地址")
                    }
                    // GitHub 走镜像直链、无特殊请求头；镜像不可用时可把 target.fallbackUrl 手动重试
                    DownloadCenter.shared.start(
                        urlString: target.url,
                        filename: file.fname,
                        fileKey: file.id,
                        headers: [:]
                    )
                case .starsea:
                    break
                }
    }

    static func message(of error: Error) -> String {
        if let quarkError = error as? QuarkError { return quarkError.message }
        return error.localizedDescription
    }
}

struct ResolveView: View {
    @StateObject private var model = ResolveViewModel()
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField(model.inputPlaceholder, text: $model.inputText, axis: .vertical)
                    Button {
                        model.parse()
                    } label: {
                        HStack {
                            Text("解析")
                            if model.isParsing { ProgressView() }
                        }
                    }
                    .disabled(model.isParsing || model.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if model.isGuest {
                        Text(model.guestHint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = model.errorMessage {
                    Section {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                if model.hasSession {
                    Section {
                        breadcrumb
                        if model.isLoadingDir {
                            HStack {
                                ProgressView()
                                Text("加载中…").foregroundStyle(.secondary)
                            }
                        }
                        ForEach(model.files) { file in
                            fileRow(file)
                        }
                        if !model.isLoadingDir && model.files.isEmpty {
                            Text("这个文件夹是空的")
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text(model.shareTitle.isEmpty ? "文件列表" : model.shareTitle)
                    }
                }
            }
            .navigationTitle("云析 · \(model.effectivePlatform.shortName)解析")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
        }
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button("根目录") { model.navigateToLevel(0) }
                ForEach(Array(model.pathNames.enumerated()), id: \.offset) { idx, name in
                    Text("›").foregroundStyle(.secondary)
                    Button(name) { model.navigateToLevel(idx + 1) }
                }
            }
            .font(.footnote)
        }
    }

    @ViewBuilder
    private func fileRow(_ file: ShareFile) -> some View {
        if file.isdir {
            Button {
                model.enterFolder(file)
            } label: {
                HStack {
                    Image(systemName: "folder.fill").foregroundStyle(.yellow)
                    Text(file.fname).foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            FileRowView(file: file, isBusy: model.busyFileId == file.id) {
                model.download(file)
            }
        }
    }
}

/// 文件行：下载状态（进度 / 完成 / 失败）就地显示在这一行里，全应用没有单独的下载页面。
struct FileRowView: View {
    let file: ShareFile
    let isBusy: Bool
    let onDownload: () -> Void

    @ObservedObject private var downloads = DownloadCenter.shared

    private var item: DownloadItem? {
        downloads.items.first { $0.fileKey == file.id }
    }

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "doc").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.fname)
                Text(formatBytes(file.fsize))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let item {
                    DownloadStatusView(item: item)
                }
            }
            Spacer()
            trailing
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if isBusy {
            ProgressView()
        } else if let item, item.finishedURL != nil {
            ShareLink(item: item.finishedURL!) {
                Text("导出")
            }
            .font(.footnote)
        } else if let item, item.errorText == nil {
            // 正在下载：进度在行内显示，右侧不再放按钮
            EmptyView()
        } else {
            Button("下载") { onDownload() }
                .buttonStyle(.bordered)
        }
    }
}

/// 行内下载状态：观察单个任务，进度实时刷新。
struct DownloadStatusView: View {
    @ObservedObject var item: DownloadItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let error = item.errorText {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(error == "已取消" ? Color.secondary : Color.red)
            } else if item.finishedURL != nil {
                Text("已下载")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                if item.progress >= 0 {
                    ProgressView(value: item.progress)
                } else {
                    ProgressView()
                }
                HStack {
                    Text("\(formatBytes(item.received)) / \(item.total > 0 ? formatBytes(item.total) : "未知大小")")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("取消") { DownloadCenter.shared.cancel(item) }
                        .font(.footnote)
                }
            }
        }
    }
}

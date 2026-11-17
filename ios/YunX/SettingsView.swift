import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                CookieSectionView(platform: .quark)
                CookieSectionView(platform: .baidu)
                CookieSectionView(platform: .uc)
                XunleiSectionView()
                Pan123SectionView()
                CookieSectionView(platform: .pan115)
                CookieSectionView(platform: .c139)
                GuangYaSectionView()
                CookieSectionView(platform: .lanzou)
                ILanzouSectionView()
                GitHubSectionView()

                Section("说明") {
                    Text("云析 iOS 支持夸克、百度、UC、迅雷、123、115、139、光鸭、蓝奏、蓝奏优享、GitHub 共 11 个平台：粘贴分享文案解析文件列表，点文件取直链下载到本机，再通过「导出」保存到「文件」App。也可以直接粘贴迅雷中文口令或星海口令（星海口令会先转换成夸克/UC 分享链接）。各平台凭据各自独立保存、互不影响。游客模式的区别：夸克仅能下载约 50MB 以内的小文件；UC、蓝奏、蓝奏优享、GitHub 可直接下载；百度、迅雷、123 只能浏览列表，下载必须先登录；115、139、光鸭的部分文件下载需要登录。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

/// 单个平台的 Cookie 分区：粘贴框 + 保存/验证/清除 + 账号与空间回显。
/// 三个平台共用同一组件，各自读写 CookieStore 里自己的分区。
struct CookieSectionView: View {
    let platform: SharePlatform

    @State private var cookieText: String
    @State private var nickname: String?
    @State private var quotaText: String?
    @State private var message: String?
    @State private var isChecking = false

    init(platform: SharePlatform) {
        self.platform = platform
        _cookieText = State(initialValue: CookieStore.shared.cookie(for: platform))
    }

    var body: some View {
        Section {
            TextEditor(text: $cookieText)
                .frame(minHeight: 120)
                .font(.footnote)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        } header: {
            Text("\(platform.shortName) Cookie")
        } footer: {
            Text(footerText)
        }

        Section {
            Button("保存") { save() }
            Button {
                verify()
            } label: {
                HStack {
                    Text("验证 Cookie")
                    if isChecking { ProgressView() }
                }
            }
            .disabled(isChecking || cookieText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("清除", role: .destructive) { clear() }
        }

        if let nickname = nickname {
            Section("\(platform.shortName)账号") {
                Text(nickname)
            }
        }
        if let quotaText = quotaText {
            Section("\(platform.shortName)网盘空间") {
                Text(quotaText)
            }
        }
        if let message = message {
            Section {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footerText: String {
        switch platform {
        case .quark:
            return "获取方法：在电脑浏览器登录 pan.quark.cn，打开开发者工具（F12）→「网络」，刷新页面后点任意一条 drive-pc.quark.cn 的请求，复制请求头里的 Cookie 整段粘贴到这里。Cookie 只保存在本机（明文存储），只用于向夸克官方接口发请求；缺少 __pus / __puus 字段的 Cookie 无法取下载直链。"
        case .baidu:
            return "获取方法：在电脑浏览器登录 pan.baidu.com，打开开发者工具（F12）→「网络」，刷新页面后点任意一条 pan.baidu.com 的请求，复制请求头里的 Cookie 整段粘贴到这里。Cookie 只保存在本机（明文存储），只用于向百度官方接口发请求；必须包含 BDUSS 字段。注意：百度游客只能浏览分享列表，下载必须先保存 Cookie。"
        case .uc:
            return "获取方法：在电脑浏览器登录 drive.uc.cn，打开开发者工具（F12）→「网络」，刷新页面后点任意一条 pc-api.uc.cn 的请求，复制请求头里的 Cookie 整段粘贴到这里。Cookie 只保存在本机（明文存储），只用于向 UC 官方接口发请求；缺少 __pus / __puus 字段的 Cookie 无法取下载直链。"
        case .pan115:
            return "获取方法：在电脑浏览器登录 115.com，打开开发者工具（F12）→「网络」，刷新页面后点任意一条 115.com 的请求，复制请求头里的 Cookie 整段粘贴到这里（至少要有 UID、SEID 字段）。Cookie 只保存在本机（明文存储），只用于向 115 官方接口发请求。未保存 Cookie 时可以浏览分享列表、小文件可直接下载，大文件取链需要登录 Cookie。"
        case .c139:
            return "粘贴 139 网页版登录后的 Cookie：电脑浏览器登录 yun.139.com 后，打开开发者工具（F12）→「网络」，刷新页面后点任意一条 yun.139.com 的请求，复制请求头里的 Cookie 整段粘贴到这里（客户端从中提取 authorization 登录凭证）。Cookie 只保存在本机（明文存储）。未保存时可以浏览分享列表，下载必须先登录。"
        case .lanzou:
            return "蓝奏分享解析不需要登录，这份 Cookie 仅供蓝奏个人盘使用：电脑浏览器登录蓝奏云网页版后，打开开发者工具（F12）→「网络」，刷新页面后点任意一条请求，复制请求头里的 Cookie 整段粘贴到这里。Cookie 只保存在本机（明文存储）。"
        case .xunlei, .pan123, .guangya, .ilanzou, .github, .starsea:
            return ""
        }
    }

    private func looksValid(_ cookie: String) -> Bool {
        switch platform {
        case .baidu: return CookieStore.looksValidBaidu(cookie)
        case .pan115: return Pan115API.isValidCookie(cookie)
        case .c139: return C139API.credential(fromCookie: cookie) != nil
        case .lanzou: return !cookie.isEmpty
        default: return CookieStore.looksValid(cookie)
        }
    }

    private func save() {
        var trimmed = cookieText.trimmingCharacters(in: .whitespacesAndNewlines)
        // 115 只保留登录相关字段（与源码 filterLoginCookies 一致）
        if platform == .pan115 && !trimmed.isEmpty {
            trimmed = Pan115API.filterLoginCookies(trimmed)
        }
        CookieStore.shared.setCookie(trimmed, for: platform)
        CookieStore.shared.setLastRefreshMs(Int64(Date().timeIntervalSince1970 * 1000), for: platform)
        // 百度换 Cookie 后要清掉旧账号的 bdstoken/分享信息缓存
        if platform == .baidu { BaiduAPI.shared.clearSessionCache() }
        cookieText = trimmed
        if trimmed.isEmpty {
            message = "已保存（空），当前为游客模式"
        } else if looksValid(trimmed) {
            message = "已保存"
        } else if platform == .baidu {
            message = "已保存，但这份 Cookie 缺少 BDUSS 字段，可能无法下载，请重新复制完整的 Cookie"
        } else if platform == .pan115 {
            message = "已保存，但这份 Cookie 缺少 UID / SEID 字段，可能无法取大文件直链，请重新复制完整的 Cookie"
        } else if platform == .c139 {
            message = "已保存，但这份 Cookie 里没找到 authorization 登录凭证，可能无法下载，请重新复制完整的 Cookie"
        } else {
            message = "已保存，但这份 Cookie 缺少 __pus / __puus 字段，可能无法下载，请重新复制完整的 Cookie"
        }
    }

    private func clear() {
        CookieStore.shared.clear(platform: platform)
        if platform == .baidu { BaiduAPI.shared.clearSessionCache() }
        cookieText = ""
        nickname = nil
        quotaText = nil
        message = "已清除，回到游客模式"
    }

    private func verify() {
        let cookie = cookieText.trimmingCharacters(in: .whitespacesAndNewlines)
        isChecking = true
        message = nil
        Task {
            let nick: String?
            let quota: QuotaInfo?
            switch platform {
            case .quark:
                nick = await QuarkAPI.shared.fetchNickname(cookie: cookie)
                quota = await QuarkAPI.shared.getQuota(cookie: cookie)
            case .baidu:
                nick = await BaiduAPI.shared.fetchNickname(cookie: cookie)
                quota = await BaiduAPI.shared.getQuota(cookie: cookie)
            case .uc:
                nick = await UCAPI.shared.fetchNickname(cookie: cookie)
                quota = await UCAPI.shared.getQuota(cookie: cookie)
            case .pan115:
                nick = await Pan115API.shared.fetchNickname(cookie: cookie)
                quota = await Pan115API.shared.getQuota(cookie: cookie)
            case .c139:
                // 139 没有昵称/空间接口：能从 Cookie 提出 authorization + 账号即视为有效
                if let cred = C139API.credential(fromCookie: cookie) {
                    nick = cred.account.isEmpty ? "已提取登录凭证" : "账号 \(cred.account)"
                } else {
                    nick = nil
                }
                quota = nil
            case .lanzou:
                // 蓝奏 Cookie 验证 = 能从个人盘页提取出登录参数（uid/vei）
                if let params = try? await LanzouAPI.shared.fetchLoginParams(cookie: cookie) {
                    nick = "登录参数已获取（uid \(params.uid)）"
                } else {
                    nick = nil
                }
                quota = nil
            case .xunlei, .pan123, .guangya, .ilanzou, .github, .starsea:
                nick = nil
                quota = nil
            }
            nickname = nick
            if let quota = quota {
                quotaText = "已用 \(formatBytes(quota.used)) / 共 \(formatBytes(quota.total))"
            } else {
                quotaText = nil
            }
            message = nickname != nil ? "Cookie 有效" : "没查到账号信息，Cookie 可能已失效或不完整"
            isChecking = false
        }
    }
}
import SwiftUI

// MARK: - 迅雷（网页凭据粘贴 / 账号密码登录，含短信验证）

struct XunleiSectionView: View {
    @State private var credentialText: String = CookieStore.shared.xunleiCredentialText
    @State private var account = ""
    @State private var password = ""
    @State private var mobile = ""
    @State private var smsCode = ""
    @State private var showSms = false
    @State private var smsCreditKey = ""
    @State private var smsToken = ""
    @State private var smsDeviceId = ""
    @State private var statusText: String? = {
        let store = CookieStore.shared
        if !store.xunleiNickname.isEmpty { return store.xunleiNickname }
        return store.xunleiAccessToken.isEmpty ? nil : "已登录"
    }()
    @State private var message: String?
    @State private var isBusy = false

    private var store: CookieStore { CookieStore.shared }

    private func deviceId() -> String {
        store.xunleiDeviceId.isEmpty ? XunleiAPI.newDeviceId() : store.xunleiDeviceId
    }

    var body: some View {
        Section {
            TextEditor(text: $credentialText)
                .frame(minHeight: 100)
                .font(.footnote)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("保存并解析凭据") { saveCredential() }
        } header: {
            Text("迅雷网页凭据（推荐）")
        } footer: {
            Text("获取方法：在电脑浏览器登录 pan.xunlei.com，打开开发者工具（F12）→「应用（Application）」→「本地存储（Local Storage）」，找到键 credentials_Xqp0kJBXWhwaTpB6，把它的值整段复制粘贴到上面。凭据只保存在本机。迅雷分享列表可游客浏览，下载必须先登录。")
                .font(.footnote)
        }

        Section {
            TextField("迅雷账号（手机号 / 邮箱）", text: $account)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            SecureField("密码", text: $password)
            Button {
                passwordLogin()
            } label: {
                HStack {
                    Text("账号密码登录")
                    if isBusy { ProgressView() }
                }
            }
            .disabled(isBusy || account.isEmpty || password.isEmpty)
            if showSms {
                TextField("手机号", text: $mobile)
                    .keyboardType(.phonePad)
                Button("发送短信验证码") { sendSms() }
                    .disabled(isBusy || mobile.isEmpty)
                TextField("短信验证码", text: $smsCode)
                    .keyboardType(.numberPad)
                Button("提交验证码登录") { smsLogin() }
                    .disabled(isBusy || smsCode.isEmpty)
            }
            Button("验证登录状态") { verify() }
                .disabled(isBusy || store.xunleiAccessToken.isEmpty)
            Button("清除迅雷登录", role: .destructive) { clear() }
        } header: {
            Text("迅雷账号登录")
        }

        if let statusText = statusText {
            Section("迅雷账号") {
                Text(statusText)
            }
        }
        if let message = message {
            Section {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func saveCredential() {
        let text = credentialText.trimmingCharacters(in: .whitespacesAndNewlines)
        store.xunleiCredentialText = text
        guard let tokens = XunleiWebCredential.parse(text) else {
            message = "没从这段内容里解析出有效的迅雷凭据，请确认复制的是 credentials_Xqp0kJBXWhwaTpB6 的完整值"
            return
        }
        store.xunleiAccessToken = tokens.accessToken
        if !tokens.refreshToken.isEmpty { store.xunleiRefreshToken = tokens.refreshToken }
        if !tokens.deviceId.isEmpty { store.xunleiDeviceId = tokens.deviceId }
        if !tokens.captchaToken.isEmpty { store.xunleiCaptchaToken = tokens.captchaToken }
        store.xunleiAuthType = "webToken"
        if !tokens.nickname.isEmpty { store.xunleiNickname = tokens.nickname }
        XunleiAPI.shared.useWebCaptchaChannel = true
        statusText = tokens.nickname.isEmpty ? "已登录（网页凭据）" : tokens.nickname
        message = "凭据已保存"
    }

    private func passwordLogin() {
        isBusy = true
        message = nil
        Task {
            defer { isBusy = false }
            let devId = XunleiAPI.newDeviceId()
            do {
                let step = try await XunleiAPI.shared.loginWithPassword(
                    username: account, password: password, deviceId: devId)
                if !step.sessionId.isEmpty {
                    await finishAppLogin(sessionId: step.sessionId, deviceId: devId, nickname: step.nickname)
                } else if step.needSms {
                    smsDeviceId = devId
                    showSms = true
                    message = "该账号需要短信验证：填手机号点「发送短信验证码」，收到后填验证码提交"
                } else {
                    message = step.message.isEmpty ? "登录失败，请检查账号密码" : step.message
                }
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func sendSms() {
        isBusy = true
        message = nil
        Task {
            defer { isBusy = false }
            do {
                let step = try await XunleiAPI.shared.sendSms(mobile: mobile, deviceId: smsDeviceId)
                smsCreditKey = step.smsCreditKey
                smsToken = step.smsToken
                message = "验证码已发送，请查收短信"
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func smsLogin() {
        isBusy = true
        message = nil
        Task {
            defer { isBusy = false }
            do {
                let step = try await XunleiAPI.shared.smsLogin(
                    mobile: mobile, smsCode: smsCode, creditKey: smsCreditKey,
                    smsToken: smsToken, deviceId: smsDeviceId)
                if !step.sessionId.isEmpty {
                    showSms = false
                    await finishAppLogin(sessionId: step.sessionId, deviceId: smsDeviceId, nickname: step.nickname)
                } else {
                    message = step.message.isEmpty ? "短信登录失败，请重试" : step.message
                }
            } catch {
                message = error.localizedDescription
            }
        }
    }

    /// 密码/短信登录拿到 sessionId 后：换 captcha → 换 token 对 → 落库（App 通道）
    private func finishAppLogin(sessionId: String, deviceId: String, nickname: String) async {
        let captcha = await XunleiAPI.shared.initCaptcha(deviceId: deviceId, username: account) ?? ""
        guard let pair = await XunleiAPI.shared.exchangeToken(
            sessionId: sessionId, deviceId: deviceId, captchaToken: captcha) else {
            message = "登录已通过但换取令牌失败，请重试，或改用粘贴网页凭据"
            return
        }
        store.xunleiAccessToken = pair.access
        store.xunleiRefreshToken = pair.refresh
        store.xunleiAuthType = ""
        store.xunleiDeviceId = deviceId
        if !captcha.isEmpty { store.xunleiCaptchaToken = captcha }
        if !nickname.isEmpty { store.xunleiNickname = nickname }
        XunleiAPI.shared.useWebCaptchaChannel = false
        statusText = nickname.isEmpty ? "已登录（App 通道）" : nickname
        message = "登录成功"
    }

    private func verify() {
        isBusy = true
        message = nil
        Task {
            defer { isBusy = false }
            let ok = await XunleiAPI.shared.verifyAccessToken(
                accessToken: store.xunleiAccessToken,
                deviceId: deviceId(),
                captchaToken: store.xunleiCaptchaToken)
            message = ok ? "登录状态有效" : "登录状态已失效，请重新登录或重新粘贴网页凭据"
        }
    }

    private func clear() {
        store.clearXunlei()
        XunleiAPI.shared.useWebCaptchaChannel = false
        credentialText = ""
        statusText = nil
        showSms = false
        message = "已清除迅雷登录"
    }
}

// MARK: - 123 云盘（账号密码登录 / 粘贴 token）

struct Pan123SectionView: View {
    @State private var account = ""
    @State private var password = ""
    @State private var tokenText: String = CookieStore.shared.pan123Token
    @State private var nickname: String?
    @State private var quotaText: String?
    @State private var message: String?
    @State private var isBusy = false

    private var store: CookieStore { CookieStore.shared }

    var body: some View {
        Section {
            TextField("123 云盘账号", text: $account)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            SecureField("密码", text: $password)
            Button {
                login()
            } label: {
                HStack {
                    Text("账号密码登录")
                    if isBusy { ProgressView() }
                }
            }
            .disabled(isBusy || account.isEmpty || password.isEmpty)
            TextField("或粘贴 token", text: $tokenText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("保存 token") { saveToken() }
            Button("验证登录状态") { verify() }
                .disabled(isBusy || store.pan123Token.isEmpty)
            Button("清除 123 登录", role: .destructive) { clear() }
        } header: {
            Text("123 云盘登录")
        } footer: {
            Text("分享列表可以匿名浏览，下载必须先登录：用账号密码登录，或粘贴已有的 token（二选一）。凭据只保存在本机。")
                .font(.footnote)
        }

        if let nickname = nickname {
            Section("123 账号") {
                Text(nickname)
            }
        }
        if let quotaText = quotaText {
            Section("123 网盘空间") {
                Text(quotaText)
            }
        }
        if let message = message {
            Section {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func login() {
        isBusy = true
        message = nil
        Task {
            defer { isBusy = false }
            switch await Pan123API.shared.passwordLogin(account: account, password: password) {
            case .success(let token):
                store.pan123Token = token
                tokenText = token
                message = "登录成功"
            case .failure(let msg):
                message = msg
            }
        }
    }

    private func saveToken() {
        let token = tokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        store.pan123Token = token
        tokenText = token
        message = token.isEmpty ? "已保存（空），当前为游客模式" : "token 已保存"
    }

    private func verify() {
        isBusy = true
        message = nil
        Task {
            defer { isBusy = false }
            let token = store.pan123Token
            nickname = await Pan123API.shared.fetchNickname(token: token)
            if let quota = await Pan123API.shared.getQuota(token: token) {
                quotaText = "已用 \(formatBytes(quota.used)) / 共 \(formatBytes(quota.total))"
            } else {
                quotaText = nil
            }
            message = nickname != nil ? "登录状态有效" : "没查到账号信息，token 可能已失效"
        }
    }

    private func clear() {
        store.pan123Token = ""
        tokenText = ""
        nickname = nil
        quotaText = nil
        message = "已清除 123 登录"
    }
}

// MARK: - 光鸭（账号密码登录）

struct GuangYaSectionView: View {
    @State private var account = ""
    @State private var password = ""
    @State private var nickname: String? = {
        let n = CookieStore.shared.guangyaNickname
        return n.isEmpty ? nil : n
    }()
    @State private var quotaText: String?
    @State private var message: String?
    @State private var isBusy = false

    private var store: CookieStore { CookieStore.shared }

    var body: some View {
        Section {
            TextField("光鸭账号", text: $account)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            SecureField("密码", text: $password)
            Button {
                login()
            } label: {
                HStack {
                    Text("账号密码登录")
                    if isBusy { ProgressView() }
                }
            }
            .disabled(isBusy || account.isEmpty || password.isEmpty)
            Button("验证登录状态") { verify() }
                .disabled(isBusy || store.guangyaAccessToken.isEmpty)
            Button("清除光鸭登录", role: .destructive) { clear() }
        } header: {
            Text("光鸭登录")
        } footer: {
            Text("普通分享可直接下载；受限分享需要登录并转存后才能下载。用光鸭账号密码登录（不支持粘贴 Cookie）。凭据只保存在本机。")
                .font(.footnote)
        }

        if let nickname = nickname {
            Section("光鸭账号") {
                Text(nickname)
            }
        }
        if let quotaText = quotaText {
            Section("光鸭网盘空间") {
                Text(quotaText)
            }
        }
        if let message = message {
            Section {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func login() {
        isBusy = true
        message = nil
        Task {
            defer { isBusy = false }
            do {
                let device = store.guangyaDevice()
                let tokens = try await GuangYaAPI.shared.signIn(
                    username: account, password: password, device: device)
                store.guangyaAccessToken = tokens.accessToken
                store.guangyaRefreshToken = tokens.refreshToken
                GuangYaAPI.shared.loggedInDeviceId = device.deviceId
                if let info = await GuangYaAPI.shared.fetchAccountInfo(
                    accessToken: tokens.accessToken, device: device) {
                    store.guangyaNickname = info.nickname
                    nickname = info.nickname.isEmpty ? "已登录" : info.nickname
                } else {
                    nickname = "已登录"
                }
                message = "登录成功"
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func verify() {
        isBusy = true
        message = nil
        Task {
            defer { isBusy = false }
            let device = store.guangyaDevice()
            var token = store.guangyaAccessToken
            var info = await GuangYaAPI.shared.fetchAccountInfo(accessToken: token, device: device)
            if info == nil, !store.guangyaRefreshToken.isEmpty,
               let tokens = try? await GuangYaAPI.shared.refreshToken(
                   refreshToken: store.guangyaRefreshToken, device: device) {
                // 刷新成功后落库并重试一次
                store.guangyaAccessToken = tokens.accessToken
                store.guangyaRefreshToken = tokens.refreshToken
                token = tokens.accessToken
                info = await GuangYaAPI.shared.fetchAccountInfo(accessToken: token, device: device)
            }
            nickname = info?.nickname
            if let quota = await GuangYaAPI.shared.getQuota(accessToken: token, device: device) {
                quotaText = "已用 \(formatBytes(quota.used)) / 共 \(formatBytes(quota.total))"
            } else {
                quotaText = nil
            }
            message = info != nil ? "登录状态有效" : "登录状态已失效，请重新登录"
        }
    }

    private func clear() {
        store.clearGuangYa()
        GuangYaAPI.shared.loggedInDeviceId = nil
        nickname = nil
        quotaText = nil
        message = "已清除光鸭登录"
    }
}

// MARK: - 蓝奏优享（账号密码登录）

struct ILanzouSectionView: View {
    @State private var account = ""
    @State private var password = ""
    @State private var nickname: String? = {
        let n = CookieStore.shared.ilanzouNickname
        return n.isEmpty ? nil : n
    }()
    @State private var quotaText: String?
    @State private var message: String?
    @State private var isBusy = false

    private var store: CookieStore { CookieStore.shared }

    var body: some View {
        Section {
            TextField("蓝奏优享账号", text: $account)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            SecureField("密码", text: $password)
            Button {
                login()
            } label: {
                HStack {
                    Text("账号密码登录")
                    if isBusy { ProgressView() }
                }
            }
            .disabled(isBusy || account.isEmpty || password.isEmpty)
            Button("验证登录状态") { verify() }
                .disabled(isBusy || store.ilanzouAppToken.isEmpty)
            Button("清除蓝奏优享登录", role: .destructive) { clear() }
        } header: {
            Text("蓝奏优享登录")
        } footer: {
            Text("分享可以匿名解析下载；登录后可用于个人盘与转存。用蓝奏优享账号密码登录（不支持粘贴 Cookie）。凭据只保存在本机。")
                .font(.footnote)
        }

        if let nickname = nickname {
            Section("蓝奏优享账号") {
                Text(nickname)
            }
        }
        if let quotaText = quotaText {
            Section("蓝奏优享网盘空间") {
                Text(quotaText)
            }
        }
        if let message = message {
            Section {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func uuid() async throws -> String {
        if !store.ilanzouUuid.isEmpty { return store.ilanzouUuid }
        let uuid = try await ILanzouAPI.shared.getUuid()
        store.ilanzouUuid = uuid
        return uuid
    }

    private func login() {
        isBusy = true
        message = nil
        Task {
            defer { isBusy = false }
            do {
                let uuid = try await uuid()
                let token = try await ILanzouAPI.shared.login(
                    loginName: account, loginPwd: password, uuid: uuid)
                store.ilanzouAppToken = token
                if let info = await ILanzouAPI.shared.fetchAccountInfo(appToken: token, uuid: uuid) {
                    store.ilanzouUserId = info.userId
                    store.ilanzouNickname = info.nickname
                    nickname = info.nickname.isEmpty ? info.account : info.nickname
                } else {
                    nickname = "已登录"
                }
                message = "登录成功"
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func verify() {
        isBusy = true
        message = nil
        Task {
            defer { isBusy = false }
            do {
                let uuid = try await uuid()
                let token = store.ilanzouAppToken
                let info = await ILanzouAPI.shared.fetchAccountInfo(appToken: token, uuid: uuid)
                nickname = info?.nickname
                if let info = info { store.ilanzouUserId = info.userId }
                if let quota = await ILanzouAPI.shared.getQuota(appToken: token, uuid: uuid) {
                    quotaText = "已用 \(formatBytes(quota.used)) / 共 \(formatBytes(quota.total))"
                } else {
                    quotaText = nil
                }
                message = info != nil ? "登录状态有效" : "登录状态已失效，请重新登录"
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func clear() {
        store.clearILanzou()
        nickname = nil
        quotaText = nil
        message = "已清除蓝奏优享登录"
    }
}

// MARK: - GitHub（可选 Token 提升限额）

struct GitHubSectionView: View {
    @State private var tokenText: String = CookieStore.shared.githubToken
    @State private var statusText: String?
    @State private var message: String?
    @State private var isBusy = false

    private var store: CookieStore { CookieStore.shared }

    var body: some View {
        Section {
            TextField("Personal Access Token（可选）", text: $tokenText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button {
                save()
            } label: {
                HStack {
                    Text("保存 Token")
                    if isBusy { ProgressView() }
                }
            }
            .disabled(isBusy)
            Button("清除 Token", role: .destructive) { clear() }
        } header: {
            Text("GitHub Token")
        } footer: {
            Text("GitHub 仓库浏览不需要登录。不填 Token 时匿名限额 60 次/小时；粘贴 Personal Access Token 可提升到 5000 次/小时。保存前会先向 GitHub 校验，无效的 Token 不会保存。Token 只保存在本机、只用于 GitHub 官方 API。")
                .font(.footnote)
        }

        if let statusText = statusText {
            Section("GitHub 账号") {
                Text(statusText)
            }
        }
        if let message = message {
            Section {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func save() {
        let token = tokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        tokenText = token
        if token.isEmpty {
            store.githubToken = ""
            GitHubAPI.shared.token = nil
            statusText = nil
            message = "已保存（空），当前为匿名模式"
            return
        }
        isBusy = true
        message = nil
        Task {
            defer { isBusy = false }
            switch await GitHubAPI.shared.validateToken(token) {
            case .valid(let login):
                store.githubToken = token
                GitHubAPI.shared.token = token
                statusText = login
                message = "Token 有效，已保存"
            case .invalid:
                message = "这个 Token 已被 GitHub 拒绝（无效或已过期），没有保存"
            case .unknown:
                store.githubToken = token
                GitHubAPI.shared.token = token
                message = "暂时无法向 GitHub 校验，已先保存；若之后被拒绝会自动清除"
            }
        }
    }

    private func clear() {
        store.githubToken = ""
        GitHubAPI.shared.token = nil
        tokenText = ""
        statusText = nil
        message = "已清除 Token，回到匿名模式"
    }
}

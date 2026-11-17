import Foundation

/// 各平台 Cookie 本地存储（UserDefaults），按平台独立存取。
///
/// 注意：Cookie 在本机以明文保存在 UserDefaults 中，只保存在这台设备上、
/// 只用于向对应网盘官方接口发请求。不要在公共设备上使用。
///
/// 夸克沿用旧 key（quark_cookie / quark_puus_last_refresh_ts），保证升级后已存的夸克 Cookie 不丢；
/// 百度、UC 用各自的新 key。夸克与 UC 同属一套体系，共用 __puus/__pus 合并逻辑
/// （对应 Kotlin QuarkCookieUtil / UCCookieUtil）：__puus 约 3 小时过期，是下载直链签名校验的
/// 关键字段，服务端会通过 Set-Cookie 滚动下发新值。
final class CookieStore {
    static let shared = CookieStore()

    private init() {}

    // MARK: - 按平台存取

    private func cookieKey(for platform: SharePlatform) -> String {
        switch platform {
        case .quark: return "quark_cookie" // 旧 key，保持兼容
        case .baidu: return "baidu_cookie"
        case .uc: return "uc_cookie"
        case .pan115: return "pan115_cookie"
        case .c139: return "c139_cookie"
        case .lanzou: return "lanzou_cookie"
        case .xunlei, .pan123, .guangya, .ilanzou, .github, .starsea:
            // 这些平台不用整串 Cookie，走下方各自的专用存取；此键永不写入
            return "unused_cookie_key"
        }
    }

    private func refreshTsKey(for platform: SharePlatform) -> String {
        switch platform {
        case .quark: return "quark_puus_last_refresh_ts" // 旧 key，保持兼容
        case .baidu: return "baidu_puus_last_refresh_ts"
        case .uc: return "uc_puus_last_refresh_ts"
        case .pan115, .c139, .lanzou, .xunlei, .pan123, .guangya, .ilanzou, .github, .starsea:
            return "unused_refresh_ts_key"
        }
    }

    func cookie(for platform: SharePlatform) -> String {
        UserDefaults.standard.string(forKey: cookieKey(for: platform)) ?? ""
    }

    func setCookie(_ value: String, for platform: SharePlatform) {
        UserDefaults.standard.set(value, forKey: cookieKey(for: platform))
    }

    func hasCookie(for platform: SharePlatform) -> Bool {
        !cookie(for: platform).isEmpty
    }

    /// 上次主动刷新 __puus 的时间（毫秒），对应 Kotlin AccountRepository.lastRefreshTs
    func lastRefreshMs(for platform: SharePlatform) -> Int64 {
        Int64(UserDefaults.standard.double(forKey: refreshTsKey(for: platform)))
    }

    func setLastRefreshMs(_ value: Int64, for platform: SharePlatform) {
        UserDefaults.standard.set(Double(value), forKey: refreshTsKey(for: platform))
    }

    func clear(platform: SharePlatform) {
        setCookie("", for: platform)
        setLastRefreshMs(0, for: platform)
    }

    // MARK: - 夸克兼容访问器（旧调用点继续可用，全部映射到 .quark）

    var cookie: String {
        get { cookie(for: .quark) }
        set { setCookie(newValue, for: .quark) }
    }

    var hasCookie: Bool { hasCookie(for: .quark) }

    var lastRefreshMs: Int64 {
        get { lastRefreshMs(for: .quark) }
        set { setLastRefreshMs(newValue, for: .quark) }
    }

    func clear() { clear(platform: .quark) }

    // MARK: - 有效性判断

    /// 夸克/UC 关键 Cookie 字段是否齐全（对应 Kotlin QuarkConstants/UCConstants.isValidCookie）
    static func looksValid(_ cookie: String) -> Bool {
        cookie.contains("__pus=") && cookie.contains("__puus=")
    }

    /// 百度 Cookie 有效 = 含 BDUSS（对应 Kotlin BaiduConstants）
    static func looksValidBaidu(_ cookie: String) -> Bool {
        cookie.contains("BDUSS=")
    }

    // MARK: - __puus/__pus 合并（对应 Kotlin QuarkCookieUtil，夸克/UC 共用）

    private static let trackedNames: Set<String> = ["__puus", "__pus"]

    /// 把响应 Set-Cookie 里的最新 __puus/__pus 合并回原 Cookie 串
    static func mergeFromSetCookies(original: String, setCookiePairs: [(name: String, value: String)]) -> String {
        var cookie = original
        for pair in setCookiePairs where trackedNames.contains(pair.name) {
            cookie = setOrReplace(cookie, name: pair.name, value: pair.value)
        }
        return cookie
    }

    /// 去掉 __puus，用于触发服务端重新下发（对应 AList refreshPuus）
    static func withoutPuus(_ cookie: String) -> String {
        cookie.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("__puus=") }
            .joined(separator: "; ")
    }

    // MARK: - 第二批平台凭据（token / 账号类，各自独立键，互不冲突）

    private func rawGet(_ key: String) -> String {
        UserDefaults.standard.string(forKey: key) ?? ""
    }

    private func rawSet(_ value: String, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    // 迅雷：网页凭据原文 + token 对 + 通道类型 + 设备号 + captcha
    var xunleiCredentialText: String {
        get { rawGet("xunlei_credential") }
        set { rawSet(newValue, "xunlei_credential") }
    }
    var xunleiAccessToken: String {
        get { rawGet("xunlei_access_token") }
        set { rawSet(newValue, "xunlei_access_token") }
    }
    var xunleiRefreshToken: String {
        get { rawGet("xunlei_refresh_token") }
        set { rawSet(newValue, "xunlei_refresh_token") }
    }
    /// "webToken" = 网页凭据通道；"" = App 通道
    var xunleiAuthType: String {
        get { rawGet("xunlei_auth_type") }
        set { rawSet(newValue, "xunlei_auth_type") }
    }
    var xunleiDeviceId: String {
        get { rawGet("xunlei_device_id") }
        set { rawSet(newValue, "xunlei_device_id") }
    }
    var xunleiCaptchaToken: String {
        get { rawGet("xunlei_captcha_token") }
        set { rawSet(newValue, "xunlei_captcha_token") }
    }
    var xunleiNickname: String {
        get { rawGet("xunlei_nickname") }
        set { rawSet(newValue, "xunlei_nickname") }
    }

    func clearXunlei() {
        xunleiCredentialText = ""
        xunleiAccessToken = ""
        xunleiRefreshToken = ""
        xunleiAuthType = ""
        xunleiDeviceId = ""
        xunleiCaptchaToken = ""
        xunleiNickname = ""
    }

    // 123 云盘：登录 token
    var pan123Token: String {
        get { rawGet("pan123_token") }
        set { rawSet(newValue, "pan123_token") }
    }

    // 光鸭：token 对 + 登录设备（did 必须与登录时一致）+ 账号回显
    var guangyaAccessToken: String {
        get { rawGet("guangya_access_token") }
        set { rawSet(newValue, "guangya_access_token") }
    }
    var guangyaRefreshToken: String {
        get { rawGet("guangya_refresh_token") }
        set { rawSet(newValue, "guangya_refresh_token") }
    }
    var guangyaNickname: String {
        get { rawGet("guangya_nickname") }
        set { rawSet(newValue, "guangya_nickname") }
    }

    /// 光鸭登录设备：首次生成后持久化，登录与刷新共用同一台设备
    func guangyaDevice() -> GuangYaAPI.Device {
        let did = rawGet("guangya_device_id")
        let sign = rawGet("guangya_device_sign")
        if !did.isEmpty && !sign.isEmpty {
            return GuangYaAPI.Device(deviceId: did, deviceSign: sign)
        }
        let device = GuangYaAPI.newDevice()
        rawSet(device.deviceId, "guangya_device_id")
        rawSet(device.deviceSign, "guangya_device_sign")
        return device
    }

    func clearGuangYa() {
        guangyaAccessToken = ""
        guangyaRefreshToken = ""
        guangyaNickname = ""
    }

    // 蓝奏优享：appToken + 设备 uuid（生成一次后全程复用）+ 登录 userId
    var ilanzouAppToken: String {
        get { rawGet("ilanzou_app_token") }
        set { rawSet(newValue, "ilanzou_app_token") }
    }
    var ilanzouUuid: String {
        get { rawGet("ilanzou_uuid") }
        set { rawSet(newValue, "ilanzou_uuid") }
    }
    var ilanzouUserId: String {
        get { rawGet("ilanzou_user_id") }
        set { rawSet(newValue, "ilanzou_user_id") }
    }
    var ilanzouNickname: String {
        get { rawGet("ilanzou_nickname") }
        set { rawSet(newValue, "ilanzou_nickname") }
    }

    func clearILanzou() {
        ilanzouAppToken = ""
        ilanzouUserId = ""
        ilanzouNickname = ""
        // uuid 是设备标识，清除登录态时保留
    }

    // GitHub：可选 Token（仅提升 API 限额）
    var githubToken: String {
        get { rawGet("github_token") }
        set { rawSet(newValue, "github_token") }
    }

    private static func setOrReplace(_ cookie: String, name: String, value: String) -> String {
        var parts = cookie.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        let kv = "\(name)=\(value)"
        if let idx = parts.firstIndex(where: { $0.hasPrefix("\(name)=") }) {
            parts[idx] = kv
        } else {
            parts.append(kv)
        }
        return parts.joined(separator: "; ")
    }
}

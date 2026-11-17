import Foundation

// MARK: - 迅雷常量（对应 Kotlin XunleiConstants）

/// 迅雷网盘常量（依据抓包 + 迅雷网盘 API 文档，两者互相印证）。
enum XunleiConstants {
/// 登录 / 验证码 / Token 主机
static let authBase = "https://xluser-ssl.xunlei.com"
/// 文件 / 分享 / 下载主机
static let panBase = "https://api-pan.xunlei.com"

/// Web 端公开凭据（文档推荐，可正常换 Token）
static let clientId = "Xp6pAdwyJv9sQuoN"
static let clientSecret = "standard_a@api#"

/// App 端凭据（官方 app 抓包，/v1/auth/signin/token 换 token 用）
static let appClientId = "Xp6vsxz_7IYVw2BB"
static let appClientSecret = "Xp6vsy4tN9toTVdMSpomVdXpRmES"

/// Android 端身份（captcha_sign 计算用）
static let appClientVersion = "8.31.0.9726"
static let appPackageName = "com.xunlei.downloadprovider"

/// Android 端 captcha 盐（10 个，alist 源码确认，顺序敏感）
static let captchaSalts = [
"9uJNVj/wLmdwKrJaVj/omlQ",
"Oz64Lp0GigmChHMf/6TNfxx7O9PyopcczMsnf",
"Eb+L7Ce+Ej48u",
"jKY0",
"ASr0zCl6v8W4aidjPK5KHd1Lq3t+vBFf41dqv5+fnOd",
"wQlozdg6r1qxh0eRmt3QgNXOvSZO6q/GXK",
"gmirk+ciAvIgA/cxUUCema47jr/YToixTT+Q6O",
"5IiCoM9B1/788ntB",
"P07JH0h6qoM6TSUAK2aL9T5s2QBVeY9JWvalf",
"+oK0AN"
]

/// App UA（官方 app 抓包）。**下载直链只能带这个 UA**：浏览器 UA 会被 CDN 降级/拒绝
static let appUA =
"ANDROID-com.xunlei.downloadprovider/8.31.0.9726 netWorkType/5G appid/40 " +
"deviceName/Xiaomi_M2004j7ac deviceModel/M2004J7AC OSVersion/12 protocolVersion/301 " +
"platformVersion/10 sdkVersion/512000 Oauth2Client/0.9 (Linux 4_14_186-perf-gddfs8vbb238b) (JAVA 0)"

/// 浏览器 UA（Web 端 pan 请求）
static let webUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"

// 设备标识 fallback（官方抓包指纹；正常由 XunleiDeviceFingerprint 动态生成并持久化）
static let deviceIdFallback = "78a70629a2b17d0b4302317ffa94807a"
static let peerIdFallback = "92df4c42e0926ff55f1c605ebe4c3754"
static let deviceSignFallback = "div101.78a70629a2b17d0b4302317ffa94807a31491e163e795b39e798ed33ae58858b"

// 登录端点
static let captchaInitURL = "\(authBase)/v1/shield/captcha/init"
static let loginURL = "\(authBase)/xluser.core.login/v3/login"
static let sendSmsURL = "\(authBase)/xluser.core.login/v3/sendsms"
static let smsLoginURL = "\(authBase)/xluser.core.login/v3/smslogin"
static let tokenURL = "\(authBase)/v1/auth/signin/token"
static let refreshURL = "\(authBase)/v1/auth/token"

// Pan 端点
static let filesURL = "\(panBase)/drive/v1/files"
static let shareURL = "\(panBase)/drive/v1/share"
static let shareDetailURL = "\(panBase)/drive/v1/share/detail"
static let restoreURL = "\(panBase)/drive/v1/share/restore"
static let tasksURL = "\(panBase)/drive/v1/tasks"

/// 转存目标目录名
static let tempDirName = "YunX临时转存"
}

// MARK: - 设备指纹（对应 Kotlin XunleiDeviceFingerprint）

/// 迅雷设备指纹：首次生成 deviceId/peerId/deviceSign 后持久化（UserDefaults），此后永久复用；
/// 未生成时回退官方抓包指纹。deviceSign = `div101.<deviceId><md5(sha1(deviceId + 包名 + appid + appkey))>`。
enum XunleiDeviceFingerprint {
private static let keyId = "xunlei_fp_device_id"
private static let keyPeer = "xunlei_fp_peer_id"
private static let keySign = "xunlei_fp_device_sign"

private static let packageName = "com.xunlei.downloadprovider"
private static let appId = "40"
private static let appKey = "34a062aaa22f906fca4fefe9fb3a3021"

private static var cached: (id: String, peer: String, sign: String)?

private static func load() -> (id: String, peer: String, sign: String) {
if let cached = cached { return cached}
let defaults = UserDefaults.standard
if let id = defaults.string(forKey: keyId),!id.isEmpty {
let value = (id,
defaults.string(forKey: keyPeer) ?? XunleiConstants.peerIdFallback,
defaults.string(forKey: keySign) ?? XunleiConstants.deviceSignFallback)
cached = value
return value
}
let newId = randomHex(32)
let newPeer = randomHex(32)
let newSign = buildDeviceSign(newId)
defaults.set(newId, forKey: keyId)
defaults.set(newPeer, forKey: keyPeer)
defaults.set(newSign, forKey: keySign)
let value = (newId, newPeer, newSign)
cached = value
return value
}

static func deviceId() -> String { load().id}
static func peerId() -> String { load().peer}
static func deviceSign() -> String { load().sign}

static func buildDeviceSign(_ id: String) -> String {
let sha1 = wSHA1Hex(id + packageName + appId + appKey)
let md5 = wMD5Hex(sha1)
return "div101.\(id)\(md5)"
}

private static func randomHex(_ length: Int) -> String {
let hex = Array("0123456789abcdef")
return (0..<length).map { _ in String(hex[Int.random(in: 0..<16)])}.joined()
}
}

// MARK: - 网页凭据（对应 Kotlin XunleiWebCredential）

/// 迅雷网页登录凭据（pan.xunlei.com 的 localStorage 对象解析结果）
struct XunleiWebTokens {
let accessToken: String
let refreshToken: String
let deviceId: String
let captchaToken: String
let userId: String
let nickname: String
}

/// 迅雷网页凭据解析 + 网页版 captcha 签名（对应 Kotlin XunleiWebCredential）。
/// 网页 token 只能配网页 client_id 刷新，且不需要 client_secret。
enum XunleiWebCredential {
/// 网页版 OAuth client_id（抓包自 pan.xunlei.com，与 App 端不同）
static let clientId = "Xqp0kJBXWhwaTpB6"
/// 登录态在 localStorage 中的键名
static let storageKey = "credentials_\(clientId)"
/// 验证码 token 在 localStorage 中的键名
static let captchaKey = "captcha_\(clientId)"
static let loginURL = "https://pan.xunlei.com/"
/// 落库时写入的认证方式：网页 token 的刷新路径与 App token 不同
static let authType = "webToken"

/// 网页版桌面 UA（网页 token 的刷新请求必须带，否则被风控拒绝）
static let desktopUA =
"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
/// 与 desktopUA 配套的客户端提示头（品牌名带引号是 client hints 规范格式）
static let desktopSecChUa = "\"Google Chrome\";v=\"131\", \"Chromium\";v=\"131\", \"Not_A Brand\";v=\"24\""
static let desktopSecChUaMobile = "?0"
static let desktopSecChUaPlatform = "\"Windows\""

// 网页版 captcha 签名（本地现签）
static let webClientVersion = "1.93.10"
static let webPackageName = "pan.xunlei.com"
private static let webSignHost = "pan.xunlei.com"
private static let webAlgVersion = "1"

/// 9 条盐，顺序敏感（来自网页版 public-key 链，约 20 天轮换一次）
private static let webCaptchaSalts = [
"DVM8BRQfJWDsIE0JbH5GCUM0z0jU1yGymBTj4Eyloazv1F+w0G7ig",
"T",
"a1fUxfjOO1/dW++DpGupRgw9P93L",
"aktKbp+/lQc3MvlMHIupt65LjAgJOL6ttMFvTKK+7+WKubSf9rT",
"SB/ne9FQUnQmWz4Wuv9KqKfGOBOCUubpHpECxOHfD4hNoMclYA2Yq",
"sOZFBQ8IMFy3OFjAIf/eA65iqFvS9TIKzLyrhiT6",
"ZhJdLgL7MGh2GanboB0yk",
"Osf",
"v"
]

/// 网页 captcha_token 的保守有效期（ms）：服务端 300s，提前 30s 视为过期
static let webCaptchaTokenTTLMs: Int64 = 270_000

/// 网页版 captcha_sign：raw = client_id + version + host + device_id + timestamp_ms
/// → 9 层 md5(raw + salt)，前缀 `1.`（与 App 通道的 10 盐/包名版本不是一套）
static func computeCaptchaSign(deviceId: String, timestampMs: Int64) -> String {
var h = clientId + webClientVersion + webSignHost + deviceId + "\(timestampMs)"
for salt in webCaptchaSalts { h = wMD5Hex(h + salt)}
return "\(webAlgVersion).\(h)"
}

/**
* 解析网页登录凭据。支持三种输入：
* 1. 完整 JSON（localStorage 原文 / 抓包复制）；
* 2. 被引号包起来的 JSON 字符串；
* 3. 裸 access_token（没有 refresh_token，过期后只能重新登录）。
* 解析失败（含字段校验不过）一律返回 nil。
*/
static func parse(_ raw: String) -> XunleiWebTokens? {
var text = raw.trimmingCharacters(in:.whitespacesAndNewlines)
if text.isEmpty { return nil}
if let unwrapped = unwrapQuoted(text) { text = unwrapped.trimmingCharacters(in:.whitespacesAndNewlines)}
if text.isEmpty { return nil}
if !text.hasPrefix("{") { return parseRawToken(text)}
guard let root = parseObject(text) else { return nil}
return fieldsFrom(toFieldMap(unwrapNested(root)))
}

/// 裸 token：去掉 `Bearer ` 前缀后过 token 校验
static func parseRawToken(_ text: String) -> XunleiWebTokens? {
let token = stripBearer(text)
return isValidToken(token)
? XunleiWebTokens(accessToken: token, refreshToken: "", deviceId: "",
captchaToken: "", userId: "", nickname: "")
: nil
}

/// 从「键 → 值」映射挑凭据字段：兼容 snake_case 与 camelCase；
/// 任一 token 非法即整体判失败（登录中间态不能当成功）
static func fieldsFrom(_ fields: [String: String]) -> XunleiWebTokens? {
let access = pick(fields, "access_token", "accessToken")
let refresh = pick(fields, "refresh_token", "refreshToken")
if !access.isEmpty && !isValidToken(access) { return nil}
if !refresh.isEmpty && !isValidToken(refresh) { return nil}
if access.isEmpty && refresh.isEmpty { return nil}
let captcha = pick(fields, "captcha_token", "captchaToken")
return XunleiWebTokens(
accessToken: access,
refreshToken: refresh,
deviceId: pick(fields, "device_id", "deviceId"),
captchaToken: isValidToken(captcha) ? captcha : "",
userId: pick(fields, "user_id", "userId", "sub"),
nickname: pick(fields, "nick_name", "nickname", "name", "user_name")
)
}

/// token 合法性：长度 16~16384、仅 JWT/Base64 字符集、且不是 "null"/"undefined"
static func isValidToken(_ value: String) -> Bool {
guard value.count >= 16 && value.count <= 16384 else { return false}
guard value != "null" && value != "undefined" else { return false}
return value.allSatisfy { c in
c.isLetter || c.isNumber || "._~+/=-".contains(c)
} && value.unicodeScalars.allSatisfy { $0.isASCII}
}

/// 去掉 `Bearer ` 前缀与首尾空白（必须先 trim 再匹配前缀）
private static func stripBearer(_ value: String) -> String {
var text = value.trimmingCharacters(in:.whitespacesAndNewlines)
if let range = text.range(of: "^Bearer\\s+", options: [.regularExpression,.caseInsensitive]) {
text.removeSubrange(range)
}
return text.trimmingCharacters(in:.whitespacesAndNewlines)
}

/// 把 JSON 对象拍平成「键 → 字符串值」；非字符串/数字的值丢掉
private static func toFieldMap(_ data: [String: Any]) -> [String: String] {
var map: [String: String] = [:]
for (key, value) in data {
if let s = value as? String { map[key] = s}
else if let n = value as? NSNumber { map[key] = n.stringValue}
}
return map
}

/// 外层是 JSON 字符串字面量时还原内容；不是则返回 nil
private static func unwrapQuoted(_ text: String) -> String? {
guard text.hasPrefix("\""), let data = text.data(using:.utf8) else { return nil}
return (try? JSONSerialization.jsonObject(with: data, options: [.allowFragments])) as? String
}

/// 解析成 JSON 对象；不是对象返回 nil
private static func parseObject(_ text: String) -> [String: Any]? {
guard text.hasPrefix("{"), let data = text.data(using:.utf8) else { return nil}
return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

/// 兼容嵌套包装：token 可能包在 credentials / token / data 里，最多向下找两层
private static func unwrapNested(_ root: [String: Any]) -> [String: Any] {
var current = root
for _ in 0..<2 {
if current["access_token"] != nil || current["accessToken"] != nil ||
current["refresh_token"] != nil || current["refreshToken"] != nil {
return current
}
guard let nested = (current["credentials"] as? [String: Any])
?? (current["token"] as? [String: Any])
?? (current["data"] as? [String: Any]) else { return current}
current = nested
}
return current
}

/// 取第一个非空字符串字段（含控制字符的值跳过）
private static func pick(_ fields: [String: String], _ keys: String...) -> String {
for key in keys {
let text = (fields[key] ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
if text.isEmpty { continue}
if text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f}) { continue}
return text
}
return ""
}
}

// MARK: - 中文口令（对应 Kotlin XunleiKouling）

/// 迅雷中文口令（如「张三丰资源」）→ 分享链接 + 提取码的纯逻辑部分。
/// 口令本质是「分享链接 + 提取码」的打包：打 shoulei 搜索跳转接口，
/// `ext.kouling_type == "share_page"` 时 location 就是带 pwd 的分享页地址（提取码明文）。
enum XunleiKouling {
static let jumpAPI = "https://api-shoulei-ssl.xunlei.com/xlppc.searcher.api/jump"
/// 接口来源标识：服务端按渠道校验，缺了拿不到 share_page
static let origin = "https://sl-m-ssl.xunlei.com"
static let referer = "https://sl-m-ssl.xunlei.com/"
/// UA 需带 Thunder/TBC 标识（普通浏览器 UA 会走到搜索页而非分享页）
static let userAgent =
"Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) " +
"Chrome/108.0.5359.215 Safari/537.36 TBC/1.3.3.999 Thunder/12.4.4.3740"

private static let tn = "15007414_5_dg"
private static let src = "lm"
private static let ls = "sm3016480"
private static let lmExtend = "ctype:31"

/// 口令长度上限：过长说明粘的是整段文案，不该当口令打接口
private static let maxLength = 64
/// 口令两侧常见的装饰符号
private static let decorations = Set("「」『』《》〈〉“”‘’\"'`()（）[]{}<>.,，。;；:：!！?？、|")

/// 去掉两侧空白与装饰符号，得到干净的口令文本
static func normalize(_ text: String) -> String {
var t = text.trimmingCharacters(in:.whitespacesAndNewlines)
while let first = t.first, decorations.contains(first) { t.removeFirst()}
while let last = t.last, decorations.contains(last) { t.removeLast()}
return t.trimmingCharacters(in:.whitespacesAndNewlines)
}

/// 是否值得按口令解析：非空、不太长、只含汉字/字母/数字、且至少有汉字
static func looksLikeKouling(_ text: String) -> Bool {
let t = normalize(text)
if t.isEmpty || t.count > maxLength { return false}
if !t.allSatisfy({ $0.isLetter || $0.isNumber}) { return false}
return t.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF}
}

/// 拼 jump 请求 URL（wd 必须 URL 编码）
static func buildJumpUrl(keyword: String) -> String {
"\(jumpAPI)?noredirect=1&t=20&wd=\(wFormEncode(keyword))&tn=\(tn)&src=\(src)&ls=\(ls)&lm_extend=\(lmExtend)"
}

/// 从响应 location 取干净的分享链接（只保留 share_id + pwd）；不是分享页返回 nil
static func shareUrlFromLocation(_ location: String?) -> String? {
guard let loc = location,!loc.isEmpty else { return nil}
guard let shareId = regexGroup(#"pan\.xunlei\.com/s/([A-Za-z0-9_-]+)"#, in: loc,
options:.caseInsensitive) else { return nil}
let pwd = regexGroup(#"[?&]pwd=([A-Za-z0-9]+)"#, in: loc)
if let pwd = pwd,!pwd.isEmpty {
return "https://pan.xunlei.com/s/\(shareId)?pwd=\(pwd)"
}
return "https://pan.xunlei.com/s/\(shareId)"
}

private static func regexGroup(_ pattern: String, in text: String,
options: NSRegularExpression.Options = []) -> String? {
guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return nil}
let range = NSRange(text.startIndex..., in: text)
guard let m = re.firstMatch(in: text, options: [], range: range),
m.numberOfRanges > 1,
let r = Range(m.range(at: 1), in: text) else { return nil}
return String(text[r])
}
}

// MARK: - 迅雷 API（对应 Kotlin XunleiApi）

/// 迅雷分享解析结果（对应 Kotlin XunleiShareResult）
struct XunleiShareResult {
    let title: String
    let files: [ShareFile]
    let passCodeToken: String
    let shareId: String
    let nextPageToken: String
}

struct XunleiFilePage {
    let files: [ShareFile]
    let nextPageToken: String
}

/// 迅雷登录中间结果（对应 Kotlin XunleiLoginStep）
struct XunleiLoginStep {
    var needSms: Bool = false
    var smsCreditKey: String = ""
    var smsToken: String = ""
    var sessionKey: String = ""
    var sessionId: String = ""
    var nickname: String = ""
    var userID: String = ""
    var reviewUrl: String = ""
    var message: String = ""
}

/// 一次 captcha/init 的结果：token + 过期时间（网页 token 只有 300s，必须带过期时间）
struct XunleiPanCaptcha {
    let token: String
    let expiresAtMs: Int64
    func isValid(nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> Bool {
        !token.isEmpty && expiresAtMs > nowMs
    }
}

/// 网页签名换 captcha 的结果（区分「签名被拒」与「client_id 配错」）
enum XunleiWebCaptchaInit {
    case ok(XunleiPanCaptcha)
    case clientIdMismatch
    case failed
}

/**
 * 迅雷 API 封装：
 * - 登录：captcha/init → v3/login（密码，可能触发短信）→ sendsms → smslogin → v1/auth/signin/token；
 * - Pan：文件列表 / 分享解析 / 转存 / 直链（Bearer 认证，无 x-signature，抓包确认）。
 *
 * 身份三件套必须同源：accessToken + deviceId + captchaToken 必须属于同一账号/同一通道
 * （App 通道与网页通道的 client_id 不同，串用会得到 client_id not match）。
 * 集成层负责注入 refreshTokenProvider / webCaptchaRefresher（见 INTEGRATION-WAVE2.md）。
 */
final class XunleiAPI {
    static let shared = XunleiAPI()
    private init() {}

    /// 分享会话（stoken 即 pass_code_token；平台私有会话，不用 Models 的 ShareSession）
    struct ShareSession {
        let shareId: String
        let stoken: String
        let title: String
        var passCodeToken: String { stoken }
    }

    /// 刷新出的 captcha（按设备号缓存；带过期时间，过期的不再用）
    private var refreshedCaptchas: [String: XunleiPanCaptcha] = [:]
    private let captchaLock = NSLock()

    /// 当前有效 access_token（401 自动刷新后更新；pan 请求优先使用）
    private(set) var currentAccessToken: String = ""
    /// 当前用户 ID（从 access_token JWT 解析，captcha init 的 meta 需要）
    private var currentUserId: String = ""

    /// 401/unauthenticated 时自动刷新：用 refresh_token 换新 token（由集成层注入并负责持久化）
    var refreshTokenProvider: ((String) async -> (access: String, refresh: String)?)?
    /**
     * 网页登录（webToken）captcha 的刷新入口（非网页账号可不注入，panCall 会回退 App 通道重签）。
     * 默认实现 = 本地 9 盐签名（initWebCaptcha）：成功返回带过期时间的 token；
     * clientIdMismatch 时抛错（回退网页会话也救不回来）；签名被拒返回 nil（调用方回退 App 通道）。
     */
    var webCaptchaRefresher: ((String, String) async throws -> XunleiPanCaptcha?)?

    /// 网页账号（webToken）置 true：未注入 webCaptchaRefresher 时，
    /// panCall 内部直接用本地 9 盐签名（initWebCaptcha）换网页 captcha
    var useWebCaptchaChannel: Bool = false

    /// 设备 ID：动态生成的设备指纹（首次生成后持久化）
    static func newDeviceId() -> String { XunleiDeviceFingerprint.deviceId() }

    // MARK: - 验证码盾

    /// 1. 验证码盾初始化（登录换 token 用）：client_id 用 App 凭据，meta 带 captcha_sign（10 盐）
    func initCaptcha(deviceId: String, username: String,
                     action: String = "POST:/auth/signin/token") async -> String? {
        let ts = "\(Int64(Date().timeIntervalSince1970 * 1000))"
        let sign = buildCaptchaSign(deviceId: deviceId, tsMs: ts)
        let body: [String: Any] = [
            "action": action,
            "captcha_token": "",
            "client_id": XunleiConstants.appClientId,
            "device_id": deviceId,
            "meta": [
                "username": username,
                "client_version": XunleiConstants.appClientVersion,
                "package_name": XunleiConstants.appPackageName,
                "timestamp": ts,
                "captcha_sign": sign,
                "user_id": currentUserId
            ],
            "redirect_uri": "xlaccsdk01://xunlei.com/callback?state=harbor"
        ]
        var req = Wave2HTTP.request(url: XunleiConstants.captchaInitURL, headers: [
            "User-Agent": XunleiConstants.appUA,
            "Accept": "application/json;charset=UTF-8",
            "Content-Type": "application/json",
            "X-Client-Id": XunleiConstants.appClientId,
            "X-Device-Id": deviceId,
            "X-Client-Version": "8.31.0.9726"
        ])
        req.httpMethod = "POST"
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let raw = try? await Wave2HTTP.send(req), let json = wJSONObj(raw.data) else { return nil }
        let token = json.wStr("captcha_token")
        return token.isEmpty ? nil : token
    }

    /// pan 专用 captcha/init（action 对应请求 + App 通道 captcha_sign），供 panCall 重试时重签
    private func initPanCaptcha(deviceId: String, action: String, oldToken: String) async -> String? {
        let ts = "\(Int64(Date().timeIntervalSince1970 * 1000))"
        let sign = buildCaptchaSign(deviceId: deviceId, tsMs: ts)
        let body: [String: Any] = [
            "client_id": XunleiConstants.appClientId,
            "action": action,
            "device_id": deviceId,
            "redirect_uri": "xlaccsdk01://xunlei.com/callback?state=harbor",
            "meta": [
                "client_version": XunleiConstants.appClientVersion,
                "package_name": XunleiConstants.appPackageName,
                "timestamp": ts,
                "captcha_sign": sign,
                "user_id": currentUserId
            ],
            "captcha_token": oldToken
        ]
        var req = Wave2HTTP.request(url: XunleiConstants.captchaInitURL, headers: [
            "User-Agent": XunleiConstants.appUA,
            "Accept": "application/json;charset=UTF-8",
            "Content-Type": "application/json",
            "X-Client-Id": XunleiConstants.appClientId,
            "X-Device-Id": deviceId,
            "X-Client-Version": "8.31.0.9726"
        ])
        req.httpMethod = "POST"
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let raw = try? await Wave2HTTP.send(req), let json = wJSONObj(raw.data) else { return nil }
        let token = json.wStr("captcha_token")
        return token.isEmpty ? nil : token
    }

    /**
     * 网页通道 captcha/init：本地用网页 9 盐签名换 token（不依赖网页会话）。
     * token 只有 300s；签名被拒（盐/版本轮换）返回 .failed，client_id 配错单独返回 .clientIdMismatch。
     */
    func initWebCaptcha(deviceId: String, action: String) async -> XunleiWebCaptchaInit {
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        let sign = XunleiWebCredential.computeCaptchaSign(deviceId: deviceId, timestampMs: ts)
        let body: [String: Any] = [
            "client_id": XunleiWebCredential.clientId,
            "action": action,
            "device_id": deviceId,
            "meta": [
                "username": "",
                "phone_number": "",
                "email": "",
                "package_name": XunleiWebCredential.webPackageName,
                "client_version": XunleiWebCredential.webClientVersion,
                "captcha_sign": sign,
                "timestamp": "\(ts)",
                "user_id": currentUserId
            ]
        ]
        var req = Wave2HTTP.request(url: XunleiConstants.captchaInitURL, headers: [
            "Accept": "*/*",
            "Content-Type": "text/plain;charset=UTF-8",
            "Origin": "https://pan.xunlei.com",
            "Referer": "https://pan.xunlei.com/",
            "User-Agent": XunleiWebCredential.desktopUA
        ])
        req.httpMethod = "POST"
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let raw = try? await Wave2HTTP.send(req), let json = wJSONObj(raw.data) else { return .failed }
        if raw.text.contains("client_id not match") { return .clientIdMismatch }
        let token = json.wStr("captcha_token")
        if token.isEmpty { return .failed }
        return .ok(XunleiPanCaptcha(token: token, expiresAtMs: ts + XunleiWebCredential.webCaptchaTokenTTLMs))
    }

    /// captcha_sign（App 通道）：client_id+client_version+package_name+device_id+timestamp_ms
    /// → 10 层 md5(raw+salt)，前缀 "1."
    private func buildCaptchaSign(deviceId: String, tsMs: String) -> String {
        var h = XunleiConstants.appClientId + XunleiConstants.appClientVersion +
            XunleiConstants.appPackageName + deviceId + tsMs
        for salt in XunleiConstants.captchaSalts { h = wMD5Hex(h + salt) }
        return "1.\(h)"
    }

    // MARK: - 登录

    /// 2. 账号密码登录。新客户端第一次登录必然返回 review_panel(1007) → 走短信验证
    func loginWithPassword(username: String, password: String, deviceId: String,
                           checkCode: String = "") async throws -> XunleiLoginStep {
        var body = baseLoginBody(deviceId: deviceId, clientVersion: "25.0.5.25", sdkVersion: "513006")
        body["userName"] = username
        body["passWord"] = password
        body["verifyKey"] = ""
        body["verifyCode"] = checkCode
        body["isMd5Pwd"] = "0"
        let json = try await postLoginJSON(
            url: XunleiConstants.loginURL,
            ua: "android-ok-http-client/xl-acc-sdk/version-5.1.3.513006",
            body: body
        )
        return parseLoginResponse(json)
    }

    /// 3a. 发送短信验证码
    func sendSms(mobile: String, deviceId: String) async throws -> XunleiLoginStep {
        var body = baseLoginBody(deviceId: deviceId, clientVersion: "8.31.0.9726", sdkVersion: "231500")
        body["mobile"] = mobile
        body["register"] = "0"
        let json = try await postLoginJSON(
            url: XunleiConstants.sendSmsURL,
            ua: "android-ok-http-client/xl-acc-sdk/version-5.0.12.512000",
            body: body
        )
        return XunleiLoginStep(
            needSms: true,
            smsCreditKey: json.wStr("creditkey"),
            smsToken: json.wStr("token"),
            message: json.wStr("errorDesc").isEmpty ? "短信已发送" : json.wStr("errorDesc")
        )
    }

    /// 3b. 短信验证码登录
    func smsLogin(mobile: String, smsCode: String, creditKey: String,
                  smsToken: String, deviceId: String) async throws -> XunleiLoginStep {
        var body = baseLoginBody(deviceId: deviceId, clientVersion: "8.31.0.9726",
                                 sdkVersion: "231500", creditKey: creditKey)
        body["mobile"] = mobile
        body["smsCode"] = smsCode
        body["token"] = smsToken
        body["register"] = "0"
        let json = try await postLoginJSON(
            url: XunleiConstants.smsLoginURL,
            ua: "android-ok-http-client/xl-acc-sdk/version-5.0.12.512000",
            body: body
        )
        return parseLoginResponse(json)
    }

    /// 4. 用 smslogin 返回的 sessionID 换 access_token（请求头必须带 X-Captcha-Token）
    func exchangeToken(sessionId: String, deviceId: String, captchaToken: String) async -> (access: String, refresh: String)? {
        let body: [String: Any] = [
            "client_id": XunleiConstants.appClientId,
            "client_secret": XunleiConstants.appClientSecret,
            "provider": "access_end_point_token",
            "signin_token": sessionId
        ]
        var headers = [
            "User-Agent": XunleiConstants.appUA,
            "Accept": "application/json;charset=UTF-8",
            "Content-Type": "application/json",
            "X-Client-Id": XunleiConstants.appClientId,
            "X-Device-Id": deviceId,
            "X-Client-Version": "8.31.0.9726"
        ]
        if !captchaToken.isEmpty { headers["X-Captcha-Token"] = captchaToken }
        var req = Wave2HTTP.request(url: XunleiConstants.tokenURL, headers: headers)
        req.httpMethod = "POST"
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let raw = try? await Wave2HTTP.send(req), let json = wJSONObj(raw.data) else { return nil }
        return tokenPair(json)
    }

    /**
     * 用 refresh_token 刷新 access_token。
     * authType 为网页登录（webToken）时：JSON 体 + 网页 client_id + **不带 secret** + 桌面 UA + Sec-Ch-Ua；
     * 否则 App 通道：表单体 + App client_id/secret。带错通道会被直接拒绝。
     */
    func refreshToken(refreshToken: String, deviceId: String, authType: String = "") async -> (access: String, refresh: String)? {
        var req: URLRequest
        if authType == XunleiWebCredential.authType {
            let body: [String: Any] = [
                "grant_type": "refresh_token",
                "client_id": XunleiWebCredential.clientId,
                "refresh_token": refreshToken
            ]
            req = Wave2HTTP.request(url: XunleiConstants.refreshURL, headers: [
                "Content-Type": "application/json",
                "X-Device-Id": deviceId,
                "X-Client-Id": XunleiWebCredential.clientId,
                "Origin": "https://pan.xunlei.com",
                "Referer": "https://pan.xunlei.com/",
                "User-Agent": XunleiWebCredential.desktopUA,
                "Sec-Ch-Ua": XunleiWebCredential.desktopSecChUa,
                "Sec-Ch-Ua-Mobile": XunleiWebCredential.desktopSecChUaMobile,
                "Sec-Ch-Ua-Platform": XunleiWebCredential.desktopSecChUaPlatform
            ])
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        } else {
            req = Wave2HTTP.request(url: XunleiConstants.refreshURL, headers: [
                "Content-Type": "application/x-www-form-urlencoded",
                "X-Device-Id": deviceId
            ])
            req.httpBody = Wave2HTTP.formBody([
                ("grant_type", "refresh_token"),
                ("client_id", XunleiConstants.appClientId),
                ("client_secret", XunleiConstants.appClientSecret),
                ("refresh_token", refreshToken)
            ])
        }
        req.httpMethod = "POST"
        guard let raw = try? await Wave2HTTP.send(req), let json = wJSONObj(raw.data) else { return nil }
        return tokenPair(json)
    }

    /// 校验 access_token 是否真的能用（GET /drive/v1/about；必须校验传入的这个 token 本身）
    func verifyAccessToken(accessToken: String, deviceId: String, captchaToken: String) async -> Bool {
        if accessToken.isEmpty { return false }
        let req = panRequest(url: "\(XunleiConstants.panBase)/drive/v1/about",
                             accessToken: accessToken, deviceId: deviceId,
                             captchaToken: captchaToken, body: nil, preferCachedToken: false)
        guard let raw = try? await Wave2HTTP.send(req), (200..<300).contains(raw.http.statusCode),
              let json = wJSONObj(raw.data) else { return false }
        // App 通道包在 data 里，网页通道是顶层 kind/quota，两种结构都接受
        return json.wObj("data") != nil || json.wStr("kind") == "drive#about"
    }

    /// 解析 JWT 的 exp（秒）；解析失败返回 0
    func jwtExp(_ token: String) -> Int64 {
        guard let payload = wJWTBody(token) else { return 0 }
        return payload.wLong("exp")
    }

    /// 从 JWT 解析 sub（用户 ID）
    func jwtSub(_ token: String) -> String {
        wJWTBody(token)?.wStr("sub") ?? ""
    }

    /// 缓存当前用户 ID（从 access_token JWT 解析），供 captcha/init 的 meta 使用
    func cacheUserId(accessToken: String) {
        if currentUserId.isEmpty { currentUserId = jwtSub(accessToken) }
    }

    /// 设置当前 access_token（集成层落库恢复时调用）
    func setCurrentAccessToken(_ token: String) {
        currentAccessToken = token
        cacheUserId(accessToken: token)
    }

    private func tokenPair(_ json: [String: Any]) -> (access: String, refresh: String)? {
        let at = json.wStr("access_token").isEmpty ? json.wStr("accessToken") : json.wStr("access_token")
        let rt = json.wStr("refresh_token").isEmpty ? json.wStr("refreshToken") : json.wStr("refresh_token")
        if at.isEmpty { return nil }
        let sub = jwtSub(at)
        if !sub.isEmpty { currentUserId = sub }
        currentAccessToken = at
        return (at, rt)
    }

    private func postLoginJSON(url: String, ua: String, body: [String: Any]) async throws -> [String: Any] {
        var req = Wave2HTTP.request(url: url, headers: [
            "User-Agent": ua,
            "Content-Type": "application/json"
        ])
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let raw = try await Wave2HTTP.send(req)
        guard let json = wJSONObj(raw.data) else {
            throw Wave2Error("登录失败：响应解析失败（HTTP \(raw.http.statusCode)）")
        }
        return json
    }

    /// 解析 v3/login / v3/smslogin 响应
    private func parseLoginResponse(_ json: [String: Any]) -> XunleiLoginStep {
        let errorCode = json.wStr("errorCode")
        if errorCode == "0" || json.wStr("error") == "success" {
            return XunleiLoginStep(
                needSms: false,
                sessionKey: json.wStr("loginKey"),
                sessionId: json.wStr("sessionID"),
                nickname: json.wStr("nickName"),
                userID: json.wStr("userID"),
                message: "登录成功"
            )
        }
        // 触发验证面板（review_panel）→ 需要短信验证
        let error = json.wStr("error")
        let needSms = error == "review_panel" || errorCode == "1007" ||
            json.wStr("verifyType") == "MEA" || !json.wStr("verifyType").isEmpty
        return XunleiLoginStep(
            needSms: needSms,
            reviewUrl: json.wStr("reviewurl"),
            message: json.wStr("errorDesc").isEmpty ? json.wStr("error_description") : json.wStr("errorDesc")
        )
    }

    /// 登录请求公共体（对齐官方 app 抓包字段；peerID/devicesign 用动态设备指纹）
    private func baseLoginBody(deviceId: String, clientVersion: String, sdkVersion: String,
                               creditKey: String = "") -> [String: Any] {
        [
            "protocolVersion": "301",
            "sequenceNo": "\(Int64.random(in: 10000000..<99999999))",
            "platformVersion": "10",
            "isCompressed": "0",
            "appid": "40",
            "clientVersion": clientVersion,
            "peerID": XunleiDeviceFingerprint.peerId(),
            "appName": "ANDROID-com.xunlei.downloadprovider",
            "sdkVersion": sdkVersion,
            "devicesign": XunleiDeviceFingerprint.deviceSign(),
            "netWorkType": "WIFI",
            "providerName": "NONE",
            "deviceModel": "M2004J7AC",
            "deviceName": "Xiaomi_M2004j7ac",
            "OSVersion": "12",
            "creditkey": creditKey,
            "hl": "zh-CN"
        ]
    }

    /// 解析 reviewurl 的查询参数（响应体通常自带 creditkey/token，可优先用于自有短信登录流）
    static func parseReviewUrl(_ reviewUrl: String) -> [String: String] {
        var map: [String: String] = [:]
        guard let q = reviewUrl.split(separator: "?", maxSplits: 1).dropFirst().first else { return map }
        for pair in q.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                map[String(parts[0])] = String(parts[1]).removingPercentEncoding ?? String(parts[1])
            } else if parts.count == 1 && !parts[0].isEmpty {
                map[String(parts[0])] = ""
            }
        }
        return map
    }
}

// MARK: - 迅雷 Pan 接口与编排（XunleiAPI 续）

extension XunleiAPI {

    // MARK: Pan 基础请求

    /**
     * pan 请求（Bearer + 设备 + captcha 头，无 x-signature）。
     * accessToken 为空 = 游客模式：**不写 Authorization 头**——带上失效的 `Bearer ` 反而会被判 unauthenticated。
     * 登录态优先用刷新后的 currentAccessToken；preferCachedToken=false 时只认传入的 token。
     */
    func panRequest(url: String, accessToken: String, deviceId: String, captchaToken: String,
                    body: String? = nil, preferCachedToken: Bool = true) -> URLRequest {
        var headers = [
            "User-Agent": XunleiConstants.webUA,
            "X-Device-Id": deviceId,
            "X-Client-Version": "8.31.0.9726",
            "Content-Type": "application/json",
            "Origin": "https://pan.xunlei.com",
            "Referer": "https://pan.xunlei.com/"
        ]
        if !accessToken.isEmpty {
            let bearer = preferCachedToken && !currentAccessToken.isEmpty ? currentAccessToken : accessToken
            headers["Authorization"] = "Bearer \(bearer)"
        }
        if !captchaToken.isEmpty { headers["X-Captcha-Token"] = captchaToken }
        var req = Wave2HTTP.request(url: url, headers: headers)
        if let body = body {
            req.httpMethod = "POST"
            req.httpBody = Data(body.utf8)
        }
        return req
    }

    /// 集成层未注入 webCaptchaRefresher 且 useWebCaptchaChannel=true 时，
    /// panCall 内部直接用本地 9 盐签名换网页 captcha（对应仓库层的 refreshWebCaptcha 本地路径）
    private func localWebCaptcha(deviceId: String, action: String) async -> XunleiPanCaptcha? {
        guard useWebCaptchaChannel else { return nil }
        switch await initWebCaptcha(deviceId: deviceId, action: action) {
        case .ok(let captcha): return captcha
        case .clientIdMismatch, .failed: return nil
        }
    }

    /// 换新 captcha：注入的 refresher 优先，其次本地网页签名，最后 App 通道 initPanCaptcha
    private func refreshedCaptcha(deviceId: String, action: String, oldToken: String) async -> XunleiPanCaptcha? {
        if let refresher = webCaptchaRefresher, let captcha = try? await refresher(deviceId, action) {
            return captcha
        }
        if let captcha = await localWebCaptcha(deviceId: deviceId, action: action) {
            return captcha
        }
        if let token = await initPanCaptcha(deviceId: deviceId, action: action, oldToken: oldToken) {
            return XunleiPanCaptcha(token: token, expiresAtMs: Int64.max)
        }
        return nil
    }

    private func cachedCaptcha(deviceId: String) -> XunleiPanCaptcha? {
        captchaLock.lock()
        defer { captchaLock.unlock() }
        return refreshedCaptchas[deviceId]
    }

    private func storeCaptcha(deviceId: String, _ captcha: XunleiPanCaptcha) {
        captchaLock.lock()
        refreshedCaptchas[deviceId] = captcha
        captchaLock.unlock()
    }

    /// pan 调用（带验证码自动刷新重试，对应 Kotlin panCall）
    func panCall<T>(captchaToken: String, deviceId: String, action: String,
                    build: (String) -> URLRequest,
                    parse: ([String: Any]) throws -> T) async throws -> T {
        try await panCallInternal(captchaToken: captchaToken, deviceId: deviceId,
                                  action: action, anonymous: false, build: build, parse: parse)
    }

    /// 游客模式 pan 调用：不带验证码、不刷新 token、不重试，服务端真实错误直接抛（对应 panCallAnonymous）
    func panCallAnonymous<T>(captchaToken: String, deviceId: String, action: String,
                             build: (String) -> URLRequest,
                             parse: ([String: Any]) throws -> T) async throws -> T {
        try await panCallInternal(captchaToken: captchaToken, deviceId: deviceId,
                                  action: action, anonymous: true, build: build, parse: parse)
    }

    private func panCallInternal<T>(captchaToken: String, deviceId: String, action: String,
                                    anonymous: Bool,
                                    build: (String) -> URLRequest,
                                    parse: ([String: Any]) throws -> T) async throws -> T {
        // 网页 captcha 只有 300s：缓存里过期的绝不再用，直接换新的
        var token: String
        if anonymous {
            token = captchaToken
        } else if let cached = cachedCaptcha(deviceId: deviceId), cached.isValid() {
            token = cached.token
        } else if let refresher = webCaptchaRefresher, let captcha = try? await refresher(deviceId, action) {
            storeCaptcha(deviceId: deviceId, captcha)
            token = captcha.token
        } else if let captcha = await localWebCaptcha(deviceId: deviceId, action: action) {
            storeCaptcha(deviceId: deviceId, captcha)
            token = captcha.token
        } else {
            token = captchaToken
        }

        for attempt in 0..<2 {
            let raw = try await Wave2HTTP.send(build(token))
            if raw.data.isEmpty { throw Wave2Error("请求失败：响应为空") }
            guard let json = wJSONObj(raw.data) else {
                throw Wave2Error("响应解析失败（HTTP \(raw.http.statusCode)）")
            }
            if !(200..<300).contains(raw.http.statusCode) || json.wHas("error") {
                let err = json.wStr("error")
                // access_token 过期（401/unauthenticated）：refresh_token 换新 → 重新 init captcha → 重试
                if !anonymous && (raw.http.statusCode == 401 || err == "unauthenticated") && attempt == 0 {
                    if let provider = refreshTokenProvider, let refreshed = await provider(deviceId) {
                        currentAccessToken = refreshed.access
                        if let newCaptcha = await refreshedCaptcha(deviceId: deviceId, action: action, oldToken: token) {
                            storeCaptcha(deviceId: deviceId, newCaptcha)
                            token = newCaptcha.token
                        }
                        continue
                    }
                }
                if !anonymous && err == "captcha_invalid" && attempt == 0 {
                    // client_id 配错：回退任何通道都救不回来，直接报错
                    if raw.text.contains("client_id not match") {
                        throw Wave2Error("验证码与当前登录方式不匹配，请重新登录迅雷网页版")
                    }
                    if let newCaptcha = await refreshedCaptcha(deviceId: deviceId, action: action, oldToken: token) {
                        storeCaptcha(deviceId: deviceId, newCaptcha)
                        token = newCaptcha.token
                        continue
                    }
                }
                let msg = json.wStr("error_description").isEmpty
                    ? (json.wStr("message").isEmpty ? (err.isEmpty ? "请求失败" : err) : json.wStr("message"))
                    : json.wStr("error_description")
                throw Wave2Error(msg)
            }
            return try parse(json.wObj("data") ?? json)
        }
        throw Wave2Error("验证码刷新后仍失败")
    }

    // MARK: Token 保活（对应编排层的过期预检）

    /**
     * 取链/列目录前预检 access_token：JWT exp 距过期 >60s 直接用；
     * 否则用 refresh_token 按 authType 通道刷新；刷不动抛「迅雷登录已过期，请重新登录」。
     * 返回最新 (access, refresh)，集成层负责落库。
     */
    func ensureFreshToken(accessToken: String, refreshToken: String,
                          deviceId: String, authType: String) async throws -> (access: String, refresh: String) {
        let now = Int64(Date().timeIntervalSince1970)
        if !accessToken.isEmpty && jwtExp(accessToken) - now > 60 {
            setCurrentAccessToken(accessToken)
            return (accessToken, refreshToken)
        }
        if !refreshToken.isEmpty,
           let pair = await self.refreshToken(refreshToken: refreshToken, deviceId: deviceId, authType: authType) {
            return (pair.access, pair.refresh.isEmpty ? refreshToken : pair.refresh)
        }
        throw Wave2Error("迅雷登录已过期，请重新登录")
    }

    // MARK: 个人盘

    /// 文件列表（个人网盘，parentId 为空=根目录；单页 limit=50，与源码一致）
    func getFiles(parentId: String, accessToken: String, deviceId: String, captchaToken: String) async throws -> [ShareFile] {
        let filters = wFormEncode("{\"trashed\":{\"eq\":false}}")
        let url = "\(XunleiConstants.filesURL)?parent_id=\(parentId)&page_token=&limit=50&with_audit=true&filters=\(filters)"
        return try await panCall(captchaToken: captchaToken, deviceId: deviceId, action: "GET:/drive/v1/files",
                                 build: { t in panRequest(url: url, accessToken: accessToken, deviceId: deviceId, captchaToken: t) },
                                 parse: { data in parseFileArray(data.wObjs("files")) })
    }

    /// 创建文件夹（个人网盘），返回新文件夹 id
    func createFolder(name: String, parentId: String, accessToken: String,
                      deviceId: String, captchaToken: String) async throws -> String {
        let body = jsonBodyString([
            "kind": "drive#folder",
            "name": name,
            "parent_id": parentId,
            "space": "" // 官方 proto 要求字符串，数字会 400
        ])
        return try await panCall(captchaToken: captchaToken, deviceId: deviceId, action: "POST:/drive/v1/files",
                                 build: { t in panRequest(url: XunleiConstants.filesURL, accessToken: accessToken, deviceId: deviceId, captchaToken: t, body: body) },
                                 parse: { data in
                                     let id = data.wStr("id")
                                     if id.isEmpty { throw Wave2Error("新建文件夹失败") }
                                     return id
                                 })
    }

    /// 文件详情（直链在 links["application/octet-stream"].url，回退 web_content_link）
    func getFileDetail(fileId: String, accessToken: String, deviceId: String, captchaToken: String) async throws -> DownloadLink {
        let url = "\(XunleiConstants.filesURL)/\(fileId)?_magic=2021&usage=PLAY&thumbnail_size=SIZE_LARGE&with=hdr10&with=subtitle_files&with=task&with=public_share_tag"
        return try await panCall(captchaToken: captchaToken, deviceId: deviceId, action: "GET:/drive/v1/files/\(fileId)",
                                 build: { t in panRequest(url: url, accessToken: accessToken, deviceId: deviceId, captchaToken: t) },
                                 parse: { data in
                                     let linkUrl = data.wObj("links")?.wObj("application/octet-stream")?.wStr("url") ?? ""
                                     let finalUrl = linkUrl.isEmpty ? data.wStr("web_content_link") : linkUrl
                                     return DownloadLink(
                                         fid: data.wStr("id"),
                                         filename: data.wStr("name"),
                                         downloadUrl: finalUrl,
                                         size: data.wLong("size")
                                     )
                                 })
    }

    /// 批量删除（files:batchDelete；转存临时文件用，直链已自带签名，删除不影响下载）
    func batchDelete(ids: [String], accessToken: String, deviceId: String, captchaToken: String) async throws -> Bool {
        let body = jsonBodyString(["ids": ids, "space": ""])
        return try await panCall(captchaToken: captchaToken, deviceId: deviceId, action: "POST:/drive/v1/files:batchDelete",
                                 build: { t in panRequest(url: "\(XunleiConstants.filesURL):batchDelete", accessToken: accessToken, deviceId: deviceId, captchaToken: t, body: body) },
                                 parse: { _ in true })
    }

    /// 删除到回收站（files:batchTrash）
    func deleteFiles(fileIds: [String], accessToken: String, deviceId: String, captchaToken: String) async throws -> Bool {
        let body = jsonBodyString(["ids": fileIds, "space": ""])
        return try await panCall(captchaToken: captchaToken, deviceId: deviceId, action: "POST:/drive/v1/files:batchTrash",
                                 build: { t in panRequest(url: "\(XunleiConstants.filesURL):batchTrash", accessToken: accessToken, deviceId: deviceId, captchaToken: t, body: body) },
                                 parse: { _ in true })
    }

    /// 网盘空间（GET /drive/v1/about：quota.limit / usage）
    func getQuota(accessToken: String, deviceId: String, captchaToken: String) async -> QuotaInfo? {
        do {
            return try await panCall(captchaToken: captchaToken, deviceId: deviceId, action: "GET:/drive/v1/about",
                                     build: { t in panRequest(url: "\(XunleiConstants.panBase)/drive/v1/about", accessToken: accessToken, deviceId: deviceId, captchaToken: t) },
                                     parse: { data in
                                         let quota = data.wObj("quota")
                                         return QuotaInfo(used: quota?.wLong("usage") ?? 0,
                                                          total: quota?.wLong("limit") ?? 0)
                                     })
        } catch { return nil }
    }

    /// 确保「YunX临时转存」目录存在，返回其 id
    func ensureTempDir(accessToken: String, deviceId: String, captchaToken: String) async throws -> String {
        let root = (try? await getFiles(parentId: "", accessToken: accessToken,
                                        deviceId: deviceId, captchaToken: captchaToken)) ?? []
        if let existing = root.first(where: { $0.isdir && $0.fname == XunleiConstants.tempDirName }) {
            return existing.fid
        }
        return try await createFolder(name: XunleiConstants.tempDirName, parentId: "",
                                      accessToken: accessToken, deviceId: deviceId, captchaToken: captchaToken)
    }

    // MARK: 分享

    /// 分享解析（share_id + 可选 pass_code）；accessToken 为空走匿名通道
    func getShare(shareId: String, passCode: String, accessToken: String, deviceId: String,
                  captchaToken: String, pageToken: String = "") async throws -> XunleiShareResult {
        let url = "\(XunleiConstants.shareURL)?share_id=\(shareId)&pass_code=\(wFormEncode(passCode))&limit=100&page_token=\(wFormEncode(pageToken))&thumbnail_size=SIZE_SMALL"
        let build: (String) -> URLRequest = { t in
            self.panRequest(url: url, accessToken: accessToken, deviceId: deviceId, captchaToken: t)
        }
        let parse: ([String: Any]) throws -> XunleiShareResult = { data in
            // 提取码状态：files 为空且 HTTP 200，不识别会被误判为「此目录为空」
            switch data.wStr("share_status") {
            case "PASS_CODE_EMPTY": throw Wave2Error("请输入提取码")
            case "PASS_CODE_ERROR": throw Wave2Error("提取码错误")
            case "PASS_CODE_NEED": throw Wave2Error("该分享需要提取码")
            default: break
            }
            return XunleiShareResult(
                title: data.wStr("title"),
                files: self.parseFileArray(data.wObjs("files")),
                passCodeToken: data.wStr("pass_code_token"),
                shareId: shareId,
                nextPageToken: data.wStr("next_page_token")
            )
        }
        if accessToken.isEmpty {
            return try await panCallAnonymous(captchaToken: captchaToken, deviceId: deviceId,
                                              action: "GET:/drive/v1/share", build: build, parse: parse)
        }
        return try await panCall(captchaToken: captchaToken, deviceId: deviceId,
                                 action: "GET:/drive/v1/share", build: build, parse: parse)
    }

    /// 分享子目录列表（share/detail，parent_id + pass_code_token）；accessToken 为空走匿名通道
    func getShareDetail(shareId: String, parentId: String, passCodeToken: String,
                        accessToken: String, deviceId: String, captchaToken: String,
                        pageToken: String = "") async throws -> XunleiFilePage {
        let url = "\(XunleiConstants.shareDetailURL)?share_id=\(shareId)&parent_id=\(parentId)&pass_code_token=\(wFormEncode(passCodeToken))&limit=100&page_token=\(wFormEncode(pageToken))&thumbnail_size=SIZE_SMALL"
        let build: (String) -> URLRequest = { t in
            self.panRequest(url: url, accessToken: accessToken, deviceId: deviceId, captchaToken: t)
        }
        let parse: ([String: Any]) -> XunleiFilePage = { data in
            XunleiFilePage(files: self.parseFileArray(data.wObjs("files")),
                           nextPageToken: data.wStr("next_page_token"))
        }
        if accessToken.isEmpty {
            return try await panCallAnonymous(captchaToken: captchaToken, deviceId: deviceId,
                                              action: "GET:/drive/v1/share/detail", build: build, parse: parse)
        }
        return try await panCall(captchaToken: captchaToken, deviceId: deviceId,
                                 action: "GET:/drive/v1/share/detail", build: build, parse: parse)
    }

    /// 转存到指定目录（同步返回 trace_file_ids 映射），返回转存后的新文件 id
    func restore(shareId: String, passCodeToken: String, parentFolderId: String, fileIds: [String],
                 accessToken: String, deviceId: String, captchaToken: String) async throws -> String {
        let body = jsonBodyString([
            "share_id": shareId,
            "pass_code_token": passCodeToken,
            "parent_id": parentFolderId,
            "ancestor_ids": [String](),
            "file_ids": fileIds,
            "specify_parent_id": true
        ])
        return try await panCall(captchaToken: captchaToken, deviceId: deviceId, action: "POST:/drive/v1/share/restore",
                                 build: { t in panRequest(url: XunleiConstants.restoreURL, accessToken: accessToken, deviceId: deviceId, captchaToken: t, body: body) },
                                 parse: { data in
                                     // params.trace_file_ids 是 JSON 字符串：{"分享文件id":"转存后新id"}
                                     let trace = data.wObj("params")?.wStr("trace_file_ids") ?? ""
                                     if let traceData = trace.data(using: .utf8),
                                        let map = wJSONObj(traceData) {
                                         for id in fileIds {
                                             let mapped = map.wStr(id)
                                             if !mapped.isEmpty { return mapped }
                                         }
                                     }
                                     let fallback = data.wStr("file_id")
                                     if fallback.isEmpty { throw Wave2Error("转存失败") }
                                     return fallback
                                 })
    }

    /// 轮询转存任务（最多 15 次 × 1s）
    func pollTask(taskId: String, accessToken: String, deviceId: String, captchaToken: String) async -> Bool {
        let url = "\(XunleiConstants.tasksURL)/\(taskId)?type=share"
        for index in 0..<15 {
            if index > 0 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            let done = (try? await panCall(captchaToken: captchaToken, deviceId: deviceId,
                                           action: "GET:/drive/v1/tasks/\(taskId)",
                                           build: { t in panRequest(url: url, accessToken: accessToken, deviceId: deviceId, captchaToken: t) },
                                           parse: { data in
                                               let status = data.wStr("status").isEmpty ? data.wStr("phase") : data.wStr("status")
                                               return status == "PHASE_TYPE_COMPLETE" || data.wInt("error_code") == 0
                                           })) ?? false
            if done { return true }
        }
        return false
    }

    // MARK: 编排（对应 XunleiResolveRepository）

    /// 创建分享会话：解析根目录第一页（校验提取码 + 拿 pass_code_token 与标题）
    func createSession(shareId: String, passCode: String, accessToken: String,
                       deviceId: String, captchaToken: String) async throws -> ShareSession {
        let result = try await getShare(shareId: shareId, passCode: passCode, accessToken: accessToken,
                                        deviceId: deviceId, captchaToken: captchaToken)
        return ShareSession(
            shareId: shareId,
            stoken: result.passCodeToken,
            title: result.title.isEmpty ? shareId : result.title
        )
    }

    /// 列分享根目录全部文件（page_token 翻页到底）
    func listShareRoot(shareId: String, passCode: String, accessToken: String,
                       deviceId: String, captchaToken: String) async throws -> [ShareFile] {
        var all: [ShareFile] = []
        var pageToken = ""
        while true {
            let page = try await getShare(shareId: shareId, passCode: passCode, accessToken: accessToken,
                                          deviceId: deviceId, captchaToken: captchaToken, pageToken: pageToken)
            all += page.files
            if page.nextPageToken.isEmpty { break }
            pageToken = page.nextPageToken
        }
        return all
    }

    /// 列分享子目录全部文件（page_token 翻页到底）
    func listShareDir(shareId: String, parentId: String, passCodeToken: String,
                      accessToken: String, deviceId: String, captchaToken: String) async throws -> [ShareFile] {
        var all: [ShareFile] = []
        var pageToken = ""
        while true {
            let page = try await getShareDetail(shareId: shareId, parentId: parentId, passCodeToken: passCodeToken,
                                                accessToken: accessToken, deviceId: deviceId,
                                                captchaToken: captchaToken, pageToken: pageToken)
            all += page.files
            if page.nextPageToken.isEmpty { break }
            pageToken = page.nextPageToken
        }
        return all
    }

    /**
     * 分享取链编排（必须登录）：转存到「YunX临时转存」→ 文件详情取直链 → 立即删掉转存文件
     * （直链自带签名，删除不影响下载）。返回 (直链, 下载请求头)：
     * 下载头**只有** App UA——浏览器 UA 会触发 CDN 降级。
     */
    func resolveDownloadLink(shareId: String, passCodeToken: String, file: ShareFile,
                             accessToken: String, deviceId: String,
                             captchaToken: String) async throws -> (link: DownloadLink, headers: [String: String]) {
        if accessToken.isEmpty { throw Wave2Error("迅雷分享下载需要先登录迅雷账号") }
        let tempDir = try await ensureTempDir(accessToken: accessToken, deviceId: deviceId, captchaToken: captchaToken)
        let newId = try await restore(shareId: shareId, passCodeToken: passCodeToken, parentFolderId: tempDir,
                                      fileIds: [file.fid], accessToken: accessToken,
                                      deviceId: deviceId, captchaToken: captchaToken)
        let detail = try await getFileDetail(fileId: newId, accessToken: accessToken,
                                             deviceId: deviceId, captchaToken: captchaToken)
        if detail.downloadUrl.isEmpty {
            _ = try? await batchDelete(ids: [newId], accessToken: accessToken,
                                       deviceId: deviceId, captchaToken: captchaToken)
            throw Wave2Error("获取下载链接失败")
        }
        _ = try? await batchDelete(ids: [newId], accessToken: accessToken,
                                   deviceId: deviceId, captchaToken: captchaToken)
        let link = DownloadLink(
            fid: file.fid,
            filename: file.fname.isEmpty ? detail.filename : file.fname,
            downloadUrl: detail.downloadUrl,
            size: detail.size > 0 ? detail.size : file.fsize
        )
        return (link, XunleiAPI.downloadHeaders())
    }

    /// 下载请求头：只有 App UA（源码实证，浏览器 UA 会被 CDN 降级）
    static func downloadHeaders() -> [String: String] {
        ["User-Agent": XunleiConstants.appUA]
    }

    // MARK: 口令解析（网络部分）

    /// 迅雷中文口令 → 带提取码的分享链接（免登录）；无对应资源抛错
    func parseKouling(keyword: String) async throws -> String {
        let req = Wave2HTTP.request(url: XunleiKouling.buildJumpUrl(keyword: keyword), headers: [
            "User-Agent": XunleiKouling.userAgent,
            "Accept": "*/*",
            "Origin": XunleiKouling.origin,
            "Referer": XunleiKouling.referer,
            "Accept-Language": "zh-CN"
        ])
        let raw = try await Wave2HTTP.send(req)
        if !(200..<300).contains(raw.http.statusCode) { throw Wave2Error("口令解析失败（HTTP \(raw.http.statusCode)）") }
        guard let json = wJSONObj(raw.data) else { throw Wave2Error("口令解析失败：响应格式异常") }
        let type = json.wObj("ext")?.wStr("kouling_type") ?? ""
        guard type == "share_page",
              let url = XunleiKouling.shareUrlFromLocation(json.wStr("location")) else {
            throw Wave2Error("口令「\(keyword)」没有对应的网盘分享")
        }
        return url
    }

    // MARK: 内部工具

    func parseFileArray(_ items: [[String: Any]]) -> [ShareFile] {
        items.map { item in
            ShareFile(
                fid: item.wStr("id"),
                fname: item.wStr("name"),
                fsize: item.wLong("size"),
                isdir: item.wStr("kind") == "drive#folder",
                pdirFid: item.wStr("parent_id"),
                fidToken: "",
                modifyTime: item.wStr("modified_time")
            )
        }
    }

    /// [String: Any] → JSON 字符串（请求体用；失败返回 "{}"）
    func jsonBodyString(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

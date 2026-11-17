import Foundation

/// 夸克 Cookie 本地存储（UserDefaults）。
///
/// 注意：按第一版要求，Cookie 在本机以明文保存在 UserDefaults 中，只保存在这台设备上、
/// 只用于向夸克官方接口发请求。不要在公共设备上使用。
///
/// 同时承担 Kotlin 版 QuarkCookieUtil 的 __puus/__pus 合并逻辑：
/// __puus 约 3 小时过期，是下载直链签名校验的关键字段，服务端会通过 Set-Cookie 滚动下发新值。
final class CookieStore {
    static let shared = CookieStore()

    private let cookieKey = "quark_cookie"
    private let refreshTsKey = "quark_puus_last_refresh_ts"

    private init() {}

    var cookie: String {
        get { UserDefaults.standard.string(forKey: cookieKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: cookieKey) }
    }

    var hasCookie: Bool { !cookie.isEmpty }

    /// 上次主动刷新 __puus 的时间（毫秒），对应 Kotlin QuarkAccountRepository.lastRefreshTs
    var lastRefreshMs: Int64 {
        get { Int64(UserDefaults.standard.double(forKey: refreshTsKey)) }
        set { UserDefaults.standard.set(Double(newValue), forKey: refreshTsKey) }
    }

    func clear() {
        cookie = ""
        lastRefreshMs = 0
    }

    // MARK: - __puus/__pus 合并（对应 Kotlin QuarkCookieUtil）

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

    /// 关键 Cookie 字段是否齐全（对应 Kotlin QuarkConstants.isValidCookie）
    static func looksValid(_ cookie: String) -> Bool {
        cookie.contains("__pus=") && cookie.contains("__puus=")
    }
}

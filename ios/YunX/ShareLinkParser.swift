import Foundation

/// 从整段分享文案中识别平台并提取分享短码与提取码。
/// 逻辑对应 Kotlin ShareLinkParser.parse：先取文中第一个 URL 并剥掉尾部标点，
/// 再按 夸克 → UC → 百度 → 迅雷 → 123 → 115 → 139 → 光鸭 → 蓝奏优享 → 蓝奏 → GitHub
/// 的顺序在 URL 里匹配域名特征（顺序敏感：蓝奏优享必须排在蓝奏之前）。
/// 无 URL 的纯文本再依次判 115 命令式链接、迅雷中文口令、星海口令。
/// 提取码先找 URL 的 ?pwd=（115 是 ?password=、蓝奏优享兼容 pwd/pass/passcode/password），
/// 找不到再找文案里的「提取码：xxxx」。
enum ShareLinkParser {

    struct ParsedShare {
        let platform: SharePlatform
        let shareId: String
        let pwd: String?
        /// 文中提取出的原始 URL（蓝奏/GitHub 等需要整条 URL 的平台用）；纯文本口令时为空串
        var rawUrl: String = ""
        /// 非 URL 口令原文（迅雷口令 / 星海口令）；普通链接分享为 nil
        var command: String? = nil
    }

    /// 返回正则的完整匹配文本（group 0）
    private static func firstMatchText(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let r = Range(match.range, in: text) else { return nil }
        return String(text[r])
    }

    /// 返回正则第 1 捕获组
    private static func firstGroup(_ pattern: String, in text: String, caseInsensitive: Bool = false) -> String? {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    /// 返回正则第 2 捕获组
    private static func secondGroup(_ pattern: String, in text: String, caseInsensitive: Bool = false) -> String? {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 2,
              let r = Range(match.range(at: 2), in: text) else { return nil }
        return String(text[r])
    }

    static func parse(_ rawText: String) -> ParsedShare? {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let rawUrl = firstMatchText(#"https?://[^\s]+"#, in: text) else {
            // 无 URL：115 命令式链接（115.com/swXXXX-提取码）→ 迅雷口令 → 星海口令
            if let sid = firstGroup(#"115(?:cdn|rc)?\.com/(sw[A-Za-z0-9]{8,})-([A-Za-z0-9]{4,8})"#, in: text, caseInsensitive: true) {
                let code = secondGroup(#"115(?:cdn|rc)?\.com/(sw[A-Za-z0-9]{8,})-([A-Za-z0-9]{4,8})"#, in: text, caseInsensitive: true)
                return ParsedShare(platform: .pan115, shareId: sid, pwd: code)
            }
            if XunleiKouling.looksLikeKouling(text) {
                return ParsedShare(platform: .xunlei, shareId: "", pwd: nil, command: text)
            }
            if StarSeaAPI.looksLikeCommand(text) {
                return ParsedShare(platform: .starsea, shareId: "", pwd: nil, command: text)
            }
            return nil
        }
        // 与 Kotlin trimEnd 字符集一致
        let trimChars: Set<Character> = ["。", "，", ",", "；", ";", ")", "]", "}", "\"", "'"]
        var url = rawUrl
        while let last = url.last, trimChars.contains(last) { url.removeLast() }

        let pwd = firstGroup(#"[?&]pwd=([A-Za-z0-9]+)"#, in: url)
            ?? firstGroup(#"(?:提取码|访问码|密码)[：:]\s*([A-Za-z0-9]{4,8})"#, in: text)

        if let sid = firstGroup(#"pan\.quark\.cn/s/([A-Za-z0-9]+)"#, in: url, caseInsensitive: true) {
            return ParsedShare(platform: .quark, shareId: sid, pwd: pwd, rawUrl: url)
        }
        if let sid = firstGroup(#"drive\.uc\.cn/s/([A-Za-z0-9]+)"#, in: url, caseInsensitive: true) {
            return ParsedShare(platform: .uc, shareId: sid, pwd: pwd, rawUrl: url)
        }
        if let raw = firstGroup(#"pan\.baidu\.com/s/(1[A-Za-z0-9_-]+)"#, in: url, caseInsensitive: true) {
            // 百度 surl 要去掉开头的 "1"
            return ParsedShare(platform: .baidu, shareId: String(raw.dropFirst()), pwd: pwd, rawUrl: url)
        }
        if let sid = firstGroup(#"pan\.xunlei\.com/s/([A-Za-z0-9_-]+)"#, in: url, caseInsensitive: true) {
            return ParsedShare(platform: .xunlei, shareId: sid, pwd: pwd, rawUrl: url)
        }
        if let sid = firstGroup(#"123(?:865|pan)\.(?:com|cn)/s/([A-Za-z0-9]+-[A-Za-z0-9]+)"#, in: url, caseInsensitive: true) {
            return ParsedShare(platform: .pan123, shareId: sid, pwd: pwd, rawUrl: url)
        }
        if let sid = firstGroup(#"share\.123pan\.cn/123pan/([A-Za-z0-9-]+)"#, in: url, caseInsensitive: true) {
            return ParsedShare(platform: .pan123, shareId: sid, pwd: pwd, rawUrl: url)
        }
        if let sid = firstGroup(#"api/srr\?sk=([A-Za-z0-9-]+)"#, in: url, caseInsensitive: true) {
            return ParsedShare(platform: .pan123, shareId: sid, pwd: pwd, rawUrl: url)
        }
        if let sid = firstGroup(#"115(?:cdn|rc)?\.com/s/(sw[A-Za-z0-9]+)"#, in: url, caseInsensitive: true) {
            // 115 的提取码参数名是 password=，优先于通用 pwd
            let pwd115 = firstGroup(#"[?&]password=([A-Za-z0-9]+)"#, in: url) ?? pwd
            return ParsedShare(platform: .pan115, shareId: sid, pwd: pwd115, rawUrl: url)
        }
        if let sid = firstGroup(#"115(?:cdn|rc)?\.com/(sw[A-Za-z0-9]{8,})-([A-Za-z0-9]{4,8})"#, in: url, caseInsensitive: true) {
            let code = secondGroup(#"115(?:cdn|rc)?\.com/(sw[A-Za-z0-9]{8,})-([A-Za-z0-9]{4,8})"#, in: url, caseInsensitive: true)
            return ParsedShare(platform: .pan115, shareId: sid, pwd: code, rawUrl: url)
        }
        if let sid = firstGroup(#"yun\.139\.com/shareweb/.*?/w/i/([A-Za-z0-9_-]+)"#, in: url, caseInsensitive: true) {
            return ParsedShare(platform: .c139, shareId: sid, pwd: pwd, rawUrl: url)
        }
        if let sid = firstGroup(#"guangyapan\.com/s/([A-Za-z0-9_-]+)"#, in: url, caseInsensitive: true) {
            return ParsedShare(platform: .guangya, shareId: sid, pwd: pwd, rawUrl: url)
        }
        // 蓝奏优享必须排在蓝奏之前；提取码参数名兼容 pwd/pass/passcode/password
        if let sid = firstGroup(#"(?:^|[/.])ilanzou\.(?:com|net|org|cn)/s/([A-Za-z0-9_-]+)"#, in: url, caseInsensitive: true) {
            let pwdI = firstGroup(#"[?&](?:pwd|pass|passcode|password)=([A-Za-z0-9]+)"#, in: url) ?? pwd
            return ParsedShare(platform: .ilanzou, shareId: sid, pwd: pwdI, rawUrl: url)
        }
        if let sid = firstGroup(#"(?:^|[/.])(?:lanzou[a-z0-9-]*|lan[zs]o[ux])\.(?:com|net|org|cn)/([A-Za-z0-9]+)"#, in: url, caseInsensitive: true) {
            return ParsedShare(platform: .lanzou, shareId: sid, pwd: pwd, rawUrl: url)
        }
        if GitHubLinkParser.parse(text) != nil {
            return ParsedShare(platform: .github, shareId: url, pwd: nil, rawUrl: url)
        }
        return nil
    }
}

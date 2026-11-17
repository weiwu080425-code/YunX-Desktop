import Foundation

/// 从整段分享文案中提取夸克分享短码与提取码。
/// 逻辑对应 Kotlin ShareLinkParser 的夸克分支：先取文中第一个 URL 并剥掉尾部标点，
/// 再在 URL 里匹配 pan.quark.cn/s/<短码>；提取码先找 URL 的 ?pwd=，找不到再找文案里的「提取码：xxxx」。
enum ShareLinkParser {

    struct ParsedShare {
        let shareId: String
        let pwd: String?
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

    static func parseQuark(_ rawText: String) -> ParsedShare? {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rawUrl = firstMatchText(#"https?://[^\s]+"#, in: text) else { return nil }
        // 与 Kotlin trimEnd 字符集一致
        let trimChars: Set<Character> = ["。", "，", ",", "；", ";", ")", "]", "}", "\"", "'"]
        var url = rawUrl
        while let last = url.last, trimChars.contains(last) { url.removeLast() }

        guard let sid = firstGroup(#"pan\.quark\.cn/s/([A-Za-z0-9]+)"#, in: url, caseInsensitive: true) else {
            return nil
        }
        let pwd = firstGroup(#"[?&]pwd=([A-Za-z0-9]+)"#, in: url)
            ?? firstGroup(#"(?:提取码|访问码|密码)[：:]\s*([A-Za-z0-9]{4,8})"#, in: text)
        return ParsedShare(shareId: sid, pwd: pwd)
    }
}

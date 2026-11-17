import Foundation

// MARK: - 最小大整数（115 RSA modPow 专用）

/// 1024 位 RSA 的 modPow 所需的最小无符号大整数：小端 [UInt32]，
/// 只实现 fromBytes / toFixedBytes / mulMod / modPow。数据量极小（≤256 字节），
/// 模约简用逐位长除法，性能足够。
private struct W2BigUInt {
    /// 小端 limbs，尾部零 limb 已裁剪（0 表示为单个 0）
    private(set) var limbs: [UInt32]

    init(limbs: [UInt32]) {
        var l = limbs
        while l.count > 1 && l.last == 0 { l.removeLast() }
        self.limbs = l.isEmpty ? [0] : l
    }

    init(bigEndianBytes bytes: [UInt8]) {
        var l: [UInt32] = []
        var i = bytes.count
        while i > 0 {
            var limb: UInt32 = 0
            for j in 0..<4 {
                limb <<= 8
                if i - 4 + j >= 0 { limb |= UInt32(bytes[i - 4 + j]) }
            }
            l.append(limb)
            i -= 4
        }
        self.init(limbs: l)
    }

    var isZero: Bool { limbs.allSatisfy { $0 == 0 } }

    var bitLength: Int {
        guard let top = limbs.last, top != 0 else { return 0 }
        return (limbs.count - 1) * 32 + (32 - top.leadingZeroBitCount)
    }

    func bit(_ index: Int) -> Bool {
        let limb = index / 32
        guard limb < limbs.count else { return false }
        return (limbs[limb] >> UInt32(index % 32)) & 1 == 1
    }

    /// 转固定长度大端字节（左补 0；超长取低位，对应 Kotlin toFixedLength）
    func toFixedBytes(_ length: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: length)
        for i in 0..<length {
            let byteIndexFromEnd = i
            let limb = byteIndexFromEnd / 4
            guard limb < limbs.count else { break }
            let shift = UInt32((byteIndexFromEnd % 4) * 8)
            out[length - 1 - i] = UInt8((limbs[limb] >> shift) & 0xFF)
        }
        return out
    }

    static func compare(_ a: W2BigUInt, _ b: W2BigUInt) -> Int {
        if a.limbs.count != b.limbs.count { return a.limbs.count < b.limbs.count ? -1 : 1 }
        var i = a.limbs.count - 1
        while i >= 0 {
            if a.limbs[i] != b.limbs[i] { return a.limbs[i] < b.limbs[i] ? -1 : 1 }
            i -= 1
        }
        return 0
    }

    /// self -= other（要求 self >= other）
    mutating func subtract(_ other: W2BigUInt) {
        var borrow: Int64 = 0
        for i in 0..<limbs.count {
            let sub = i < other.limbs.count ? Int64(other.limbs[i]) : 0
            var diff = Int64(limbs[i]) - sub - borrow
            if diff < 0 {
                diff += 1 << 32
                borrow = 1
            } else {
                borrow = 0
            }
            limbs[i] = UInt32(diff)
        }
        while limbs.count > 1 && limbs.last == 0 { limbs.removeLast() }
    }

    /// 左移一位并带入最低位（长除法用）
    mutating func shiftLeftOne(bringIn: Bool) {
        var carry: UInt32 = bringIn ? 1 : 0
        for i in 0..<limbs.count {
            let nextCarry = limbs[i] >> 31
            limbs[i] = (limbs[i] << 1) | carry
            carry = nextCarry
        }
        if carry != 0 { limbs.append(carry) }
    }

    /// 完整乘法（结果可达两倍位宽）
    static func multiply(_ a: W2BigUInt, _ b: W2BigUInt) -> W2BigUInt {
        if a.isZero || b.isZero { return W2BigUInt(limbs: [0]) }
        var out = [UInt32](repeating: 0, count: a.limbs.count + b.limbs.count)
        for i in 0..<a.limbs.count {
            var carry: UInt64 = 0
            let av = UInt64(a.limbs[i])
            for j in 0..<b.limbs.count {
                let idx = i + j
                let total = av * UInt64(b.limbs[j]) + UInt64(out[idx]) + carry
                out[idx] = UInt32(total & 0xFFFFFFFF)
                carry = total >> 32
            }
            var idx = i + b.limbs.count
            while carry > 0 {
                let total = UInt64(out[idx]) + carry
                out[idx] = UInt32(total & 0xFFFFFFFF)
                carry = total >> 32
                idx += 1
            }
        }
        return W2BigUInt(limbs: out)
    }

    /// self mod m（逐位长除法）
    func mod(_ m: W2BigUInt) -> W2BigUInt {
        if W2BigUInt.compare(self, m) < 0 { return self }
        var rem = W2BigUInt(limbs: [0])
        var i = bitLength - 1
        while i >= 0 {
            rem.shiftLeftOne(bringIn: bit(i))
            if W2BigUInt.compare(rem, m) >= 0 { rem.subtract(m) }
            i -= 1
        }
        return rem
    }

    static func mulMod(_ a: W2BigUInt, _ b: W2BigUInt, _ m: W2BigUInt) -> W2BigUInt {
        multiply(a, b).mod(m)
    }

    /// base^exp mod m（exp 位宽小，平方-乘即可）
    static func modPow(base: W2BigUInt, exp: W2BigUInt, modulus: W2BigUInt) -> W2BigUInt {
        var result = W2BigUInt(limbs: [1])
        var b = base.mod(modulus)
        let bits = exp.bitLength
        for i in 0..<bits {
            if exp.bit(i) { result = mulMod(result, b, modulus) }
            if i + 1 < bits { b = mulMod(b, b, modulus) }
        }
        return result
    }
}

// MARK: - 115 电脑端加解密（对应 Kotlin Pan115Crypto）

/// 115「电脑端」下载接口（proapi.115.com/app/chrome/downurl）的请求/响应加解密。
/// - 请求：data = base64( RSA( 我们的16字节key || 密文 ) )，RSA 1024 位、指数 65537、128 字节分块；
/// - 响应：base64( RSA密文 ) → 去掉前 16 字节（服务端 salt）后按 12/4 两段 XOR 解出明文 JSON。
private enum Pan115Crypto {
    /// XOR 密钥表（144 字节，与参考实现的 xorKeySeed / KEY_TABLE 逐字节一致）
    static let keyTable: [UInt8] = [
        0xf0, 0xe5, 0x69, 0xae, 0xbf, 0xdc, 0xbf, 0x8a,
        0x1a, 0x45, 0xe8, 0xbe, 0x7d, 0xa6, 0x73, 0xb8,
        0xde, 0x8f, 0xe7, 0xc4, 0x45, 0xda, 0x86, 0xc4,
        0x9b, 0x64, 0x8b, 0x14, 0x6a, 0xb4, 0xf1, 0xaa,
        0x38, 0x01, 0x35, 0x9e, 0x26, 0x69, 0x2c, 0x86,
        0x00, 0x6b, 0x4f, 0xa5, 0x36, 0x34, 0x62, 0xa6,
        0x2a, 0x96, 0x68, 0x18, 0xf2, 0x4a, 0xfd, 0xbd,
        0x6b, 0x97, 0x8f, 0x4d, 0x8f, 0x89, 0x13, 0xb7,
        0x6c, 0x8e, 0x93, 0xed, 0x0e, 0x0d, 0x48, 0x3e,
        0xd7, 0x2f, 0x88, 0xd8, 0xfe, 0xfe, 0x7e, 0x86,
        0x50, 0x95, 0x4f, 0xd1, 0xeb, 0x83, 0x26, 0x34,
        0xdb, 0x66, 0x7b, 0x9c, 0x7e, 0x9d, 0x7a, 0x81,
        0x32, 0xea, 0xb6, 0x33, 0xde, 0x3a, 0xa9, 0x59,
        0x34, 0x66, 0x3b, 0xaa, 0xba, 0x81, 0x60, 0x48,
        0xb9, 0xd5, 0x81, 0x9c, 0xf8, 0x6c, 0x84, 0x77,
        0xff, 0x54, 0x78, 0x26, 0x5f, 0xbe, 0xe8, 0x1e,
        0x36, 0x9f, 0x34, 0x80, 0x5c, 0x45, 0x2c, 0x9b,
        0x76, 0xd5, 0x1b, 0x8f, 0xcc, 0xc3, 0xb8, 0xf5
    ]

    /// 12 字节长密钥（xorClientKey / LONG_KEY）
    static let longKey: [UInt8] = [
        0x78, 0x06, 0xad, 0x4c, 0x33, 0x86, 0x5d, 0x18, 0x4c, 0x01, 0x3f, 0x46
    ]

    /// 1024 位 RSA 公钥模数（115 电脑端内置公钥）
    static let modulusHex =
        "8686980c0f5a24c4b9d43020cd2c22703ff3f450756529058b1cf88f09b86021" +
        "36477198a6e2683149659bd122c33592fdb5ad47944ad1ea4d36c6b172aad633" +
        "8c3bb6ac6227502d010993ac967d1aef00f0c8e038de2e4d3bc2ec368af2e9f1" +
        "0a6f1eda4f7262f136420c07c331b871bf139f74f3010e3c4fe57df3afb71683"

    static var modulus: W2BigUInt {
        var bytes: [UInt8] = []
        var idx = modulusHex.startIndex
        while idx < modulusHex.endIndex {
            let next = modulusHex.index(idx, offsetBy: 2)
            bytes.append(UInt8(modulusHex[idx..<next], radix: 16) ?? 0)
            idx = next
        }
        return W2BigUInt(bigEndianBytes: bytes)
    }

    /// 公钥指数 65537
    static var exponent: W2BigUInt { W2BigUInt(limbs: [0x10001]) }

    static let rsaEncodeBlock = 117
    static let rsaBlock = 128

    /// 生成一次请求用的 16 字节 key（响应用同一个 key 解）
    static func newKey() -> [UInt8] {
        (0..<16).map { _ in UInt8.random(in: 0...255) }
    }

    /// 明文 payload → 请求体 data 参数值（base64）
    static func encode(payload: String, key: [UInt8]) -> String {
        precondition(key.count == 16, "115 下载协议要求 16 字节 key")
        var body = [UInt8](payload.utf8)
        symmetricEncode(&body, key: key)
        let plain = key + body
        return Data(rsaEncrypt(plain)).base64EncodedString()
    }

    /// 响应 data 字段（base64）→ 明文 JSON；格式异常返回 nil
    static func decode(data: String, key: [UInt8]) -> String? {
        precondition(key.count == 16, "115 下载协议要求 16 字节 key")
        // 对应 Kotlin Base64.getMimeDecoder：忽略换行等非字母表字符
        let cleaned = data.filter { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=" }
        guard let raw = wBase64Decode(cleaned) else { return nil }
        let decrypted = rsaDecrypt([UInt8](raw))
        guard decrypted.count > 16 else { return nil }
        let salt = Array(decrypted[0..<16])
        var body = Array(decrypted[16...])
        symmetricDecode(&body, key: key, salt: salt)
        return String(bytes: body, encoding: .utf8)
    }

    /// XOR → 反转 → 用长密钥再 XOR
    private static func symmetricEncode(_ data: inout [UInt8], key: [UInt8]) {
        xorTransform(&data, key: deriveKey(seed: key, size: 4))
        data.reverse()
        xorTransform(&data, key: longKey)
    }

    /// 用服务端 salt 反 XOR → 反转 → 用我们的 key 再 XOR
    private static func symmetricDecode(_ data: inout [UInt8], key: [UInt8], salt: [UInt8]) {
        xorTransform(&data, key: deriveKey(seed: salt, size: 12))
        data.reverse()
        xorTransform(&data, key: deriveKey(seed: key, size: 4))
    }

    /// deriveKey：key[i] = ((seed[i] + KEY_TABLE[size*i]) & 0xff) ^ KEY_TABLE[size*(size-1-i)]
    private static func deriveKey(seed: [UInt8], size: Int) -> [UInt8] {
        (0..<size).map { i in
            let left = Int(keyTable[size * i])
            let right = Int(keyTable[size * (size - 1 - i)])
            return UInt8(((Int(seed[i % seed.count]) + left) & 0xFF) ^ right)
        }
    }

    /// xorTransform：先处理 len%4 的前缀，其余整体平移
    private static func xorTransform(_ data: inout [UInt8], key: [UInt8]) {
        let offset = data.count % 4
        for i in 0..<offset {
            data[i] = data[i] ^ key[i % key.count]
        }
        for i in offset..<data.count {
            data[i] = data[i] ^ key[(i - offset) % key.count]
        }
    }

    /// RSA 分块「加密」：PKCS#1 v1.5 填充（0x00 0x02 0xFF… 0x00 数据）后按公钥指数做 modPow
    private static func rsaEncrypt(_ input: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var offset = 0
        while offset < input.count {
            let size = min(rsaEncodeBlock, input.count - offset)
            var block = [UInt8](repeating: 0xFF, count: rsaBlock)
            block[0] = 0
            block[1] = 2
            let separator = rsaBlock - size - 1
            block[separator] = 0
            block.replaceSubrange((separator + 1)..<rsaBlock, with: input[offset..<(offset + size)])
            let m = W2BigUInt(bigEndianBytes: block)
            out += W2BigUInt.modPow(base: m, exp: exponent, modulus: modulus).toFixedBytes(rsaBlock)
            offset += size
        }
        return out
    }

    /// RSA 分块「解密」：服务端用私钥加密，这里用公钥指数还原
    private static func rsaDecrypt(_ input: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var offset = 0
        while offset < input.count {
            let size = min(rsaBlock, input.count - offset)
            let block = Array(input[offset..<(offset + size)])
            let plain = W2BigUInt.modPow(base: W2BigUInt(bigEndianBytes: block),
                                         exp: exponent, modulus: modulus).toFixedBytes(rsaBlock)
            // PKCS#1 v1.5：0x00 0x02 <填充> 0x00 <数据>，从第 2 字节起找第一个 0x00
            var start = -1
            for i in 2..<plain.count where plain[i] == 0 {
                start = i + 1
                break
            }
            guard start >= 1 && start < plain.count else { return out }
            out += plain[start...]
            offset += size
        }
        return out
    }
}

// MARK: - 115 API（对应 Kotlin Pan115Api + Pan115Constants）

/// 115 网盘接口（个人盘 + 分享），移植自 Kotlin Pan115Api + Pan115Constants。
/// 全部接口共用同一套请求头：桌面 UA + X-Requested-With + 对应页面 Referer + Cookie。
/// 凭据形态：粘贴登录 Cookie（至少含 UID/SEID；alist 最小可用集 UID/CID/SEID/KID）。
final class Pan115API {
    static let shared = Pan115API()
    private init() {}

    // MARK: 常量

    private static let apiBase = "https://webapi.115.com"
    static let shareHost = "https://115cdn.com"
    static let referer = "https://115.com/"
    /// 直链下载必须携带的 Referer
    static let downloadReferer = "https://115.com/"

    private static let userInfoURL = "\(apiBase)/user/info?ct=json"
    private static let filesURL = "\(apiBase)/files"
    private static let indexInfoURL = "\(apiBase)/files/index_info?count_space_nums=1"
    private static let fileAddURL = "\(apiBase)/files/add"
    private static let fileDownloadURL = "\(apiBase)/files/download"
    private static let appDownloadURL = "https://proapi.115.com/app/chrome/downurl"
    private static let appVersionURL = "https://appversion.115.com/1/web/1.0/api/chrome"
    private static let shareSnapURL = "\(apiBase)/share/snap"
    private static let shareDownloadURL = "\(apiBase)/share/downurl"
    private static let shareReceiveURL = "\(apiBase)/share/receive"

    static let rootCid = "0"
    private static let aidPersonal = "1"
    static let pageLimit = 100
    static let sharePageLimit = 100

    /// 临时转存根目录名（分享直链被拒时，先转存到这里再用电脑端接口取链，下载完删掉子目录）
    static let tempDirName = "YunX临时转存"
    /// 每次转存用的唯一子目录前缀
    private static let tempSubdirPrefix = "tr_"

    static let webUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36"
    private static let xRequestedWith = "XMLHttpRequest"

    /// 下载专用客户端 UA 的版本号兜底值（版本过低取链会被 50029 拒绝）
    private static let clientUAVersionFallback = "36.0.1"
    /// 下载专用客户端 UA（进程级缓存，refreshClientVersion 拉到新版本后刷新）
    private(set) static var clientUA: String = clientUa(clientUAVersionFallback)
    static func clientUa(_ version: String) -> String { "Mozilla/5.0 115Browser/\(version)" }

    /// 用最新的客户端版本号刷新 clientUA（非法值忽略，失败时保留旧值）
    static func applyClientVersion(_ version: String?) {
        let value = (version ?? "").trimmingCharacters(in: .whitespaces)
        if value.isEmpty || value.count > 16 { return }
        guard let first = value.first, first.isNumber else { return }
        if !value.allSatisfy({ $0.isNumber || $0 == "." }) { return }
        if clientUA.hasSuffix("/\(value)") { return }
        clientUA = clientUa(value)
    }

    // 错误码
    private static let errnoLoginTimeout = 990001
    private static let errnoNeedCode = 4100012
    private static let errnoWrongCode = 4100008
    private static let errnoShareGone = 4100026
    private static let errnoEmptyFolder = 4100016
    private static let errnoBusy = 990009
    private static let errnoWebSizeLimit = 50028
    private static let errnoClientTooOld = 50029

    /// 客户端版本号只拉一次（进程级缓存）
    private var clientVersionFetched = false

    /// 分享会话（对应编排层 createSession 的产物）
    struct ShareSession {
        let shareCode: String
        let receiveCode: String
        /// 分享者 UID（取直链必需，只出现在 snap 的 userinfo 里）
        let userId: String
        let title: String
    }

    /// 分享列目录结果：文件列表 + 总数 + 分享者 UID + 标题 + 分享状态
    struct SharePage {
        let files: [ShareFile]
        let total: Int
        let userId: String
        let title: String
        let shareState: Int
    }

    /// 个人盘列表分页结果
    struct FilePage { let files: [ShareFile]; let total: Int }

    // MARK: - Cookie 工具（对应 Kotlin Pan115Constants 的同名函数）

    /// 取 Cookie 中某字段的值（Cookie 形如 `UID=103616022_A1_169; CID=xxx`）
    static func cookieValue(_ cookie: String, _ name: String) -> String? {
        for part in cookie.split(separator: ";") {
            let kv = part.trimmingCharacters(in: .whitespaces)
            if kv.hasPrefix("\(name)=") {
                let v = String(kv.dropFirst(name.count + 1))
                if !v.isEmpty { return v }
            }
        }
        return nil
    }

    /// 登录态 Cookie 是否可用（只校验 UID）
    static func hasLoginCookie(_ cookie: String) -> Bool { cookieValue(cookie, "UID") != nil }

    /// Cookie 里的 UID 形如 `103616022_A1_<时间戳>`，取前面的纯数字部分
    static func extractUserId(_ cookie: String) -> String? {
        guard let uid = cookieValue(cookie, "UID") else { return nil }
        let head = uid.split(separator: "_").first.map(String.init) ?? ""
        return head.isEmpty ? nil : head
    }

    /// 合并多段 Cookie（登录 Cookie + 直链响应下发的 CDN Cookie）
    static func mergeCookies(_ parts: String...) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: "; ")
    }

    /// 需要保留的 Cookie 字段（alist 实测最小可用集 + 其余会话字段）
    static let cookieKeepKeys = ["UID", "CID", "SEID", "KID", "PHPSESSID", "GST", "USERSESSIONID"]

    /// 从整串 Cookie 中只保留 cookieKeepKeys 字段（去重），拼成请求头可直接使用的整串 Cookie
    static func filterLoginCookies(_ raw: String) -> String {
        var out: [(String, String)] = []
        var seen = Set<String>()
        for part in raw.split(separator: ";") {
            let pair = part.trimmingCharacters(in: .whitespaces)
            guard let eq = pair.firstIndex(of: "="), eq != pair.startIndex else { continue }
            let key = String(pair[..<eq])
            let value = String(pair[pair.index(after: eq)...])
            if cookieKeepKeys.contains(key) && !seen.contains(key) {
                seen.insert(key)
                out.append((key, value))
            }
        }
        return out.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
    }

    /// 登录 Cookie 是否形似可用（只要求 UID + SEID；真正有效性由 fetchNickname 校验）
    static func isValidCookie(_ cookie: String?) -> Bool {
        guard let cookie = cookie, !cookie.isEmpty else { return false }
        func has(_ name: String) -> Bool {
            cookie.split(separator: ";").contains { part in
                let pair = part.trimmingCharacters(in: .whitespaces)
                return pair.hasPrefix("\(name)=") && pair.count > name.count + 1
            }
        }
        return has("UID") && has("SEID")
    }

    /// 分享页 Referer（alist 实践：`https://115cdn.com/s/<code>?password=<code>&`）
    static func shareReferer(shareCode: String, receiveCode: String) -> String {
        receiveCode.isEmpty
            ? "\(shareHost)/s/\(shareCode)"
            : "\(shareHost)/s/\(shareCode)?password=\(receiveCode)&"
    }

    // MARK: - 客户端版本（取直链必需）

    /// 刷新客户端版本号（进程内只拉一次）。115 取链接口会校验客户端版本，
    /// UA 里版本过低直接 50029；拉取失败保留兜底值，不影响后续请求。
    func refreshClientVersion() async {
        if clientVersionFetched { return }
        clientVersionFetched = true
        do {
            let (json, _) = try await getJson(url: Pan115API.appVersionURL, cookie: "", referer: Pan115API.referer)
            guard let win = json.wObj("data")?.wObj("win") else { return }
            Pan115API.applyClientVersion(win.wStr("version_code"))
        } catch { /* 保留兜底值 */ }
    }

    // MARK: - 用户信息

    /// 校验登录态并取昵称：GET /user/info?ct=json。已登录时 data 是脱敏手机号；失效返回 nil
    func fetchNickname(cookie: String) async -> String? {
        do {
            let (json, _) = try await getJson(url: Pan115API.userInfoURL, cookie: cookie, referer: Pan115API.referer)
            try checkState(json, fallback: "获取用户信息失败")
            let data = json.wStr("data")
            return data.isEmpty ? nil : data
        } catch { return nil }
    }

    /// 网盘空间：GET /files/index_info?count_space_nums=1；失败返回 nil
    func getQuota(cookie: String) async -> QuotaInfo? {
        do {
            let (json, _) = try await getJson(url: Pan115API.indexInfoURL, cookie: cookie, referer: Pan115API.referer)
            try checkState(json, fallback: "获取空间信息失败")
            guard let space = json.wObj("data")?.wObj("space_info") else { return nil }
            let total = space.wObj("all_total")?.wLong("size") ?? 0
            let used = space.wObj("all_use")?.wLong("size") ?? 0
            return QuotaInfo(used: used, total: total)
        } catch { return nil }
    }

    // MARK: - 个人盘

    /// 列目录：GET /files（offset 为索引分页；文件夹用 cid、文件用 fid）
    func listFiles(cid: String, cookie: String, offset: Int = 0, limit: Int = Pan115API.pageLimit) async throws -> FilePage {
        var url = Pan115API.filesURL
        url += "?aid=\(Pan115API.aidPersonal)"
        url += "&cid=\(wFormEncode(cid.isEmpty ? Pan115API.rootCid : cid))"
        url += "&o=user_ptime&asc=0"
        url += "&offset=\(offset)"
        url += "&show_dir=1"
        url += "&limit=\(limit)"
        url += "&snap=0&natsort=1&record_open_time=1&count_folders=1"
        url += "&format=json"
        let (json, _) = try await getJson(url: url, cookie: cookie, referer: Pan115API.referer)
        try checkState(json, fallback: "获取文件列表失败")
        return FilePage(files: parsePersonalFiles(json), total: json.wInt("count"))
    }

    /**
     * 个人盘直链。先走「电脑端」加密接口：网页端接口对大文件直接拒发（实测 482MB 返回 50028）。
     * 电脑端接口失败时再退回网页端接口，小文件仍可用（它的响应头会下发 CDN Cookie）。
     * 返回的 link.guestCookie 是取链响应下发的 CDN Cookie，下载时必须与登录 Cookie 拼接。
     */
    func getDownloadLink(file: ShareFile, cookie: String) async throws -> DownloadLink {
        let pickCode = file.fidToken
        if pickCode.isEmpty { throw Wave2Error("缺少 pickcode，无法获取下载链接") }
        await refreshClientVersion()
        if let appLink = try? await getAppDownloadLink(pickCode: pickCode, cookie: cookie) {
            return DownloadLink(
                fid: file.fid,
                filename: appLink.filename.isEmpty ? file.fname : appLink.filename,
                downloadUrl: appLink.downloadUrl,
                size: appLink.size > 0 ? appLink.size : file.fsize,
                cleanupDirFid: nil,
                guestCookie: appLink.guestCookie
            )
        }
        return try await getWebDownloadLink(pickCode: pickCode, file: file, cookie: cookie)
    }

    /// 网页端直链：GET /files/download?pickcode=<pc>；大文件会被 115 以 50028 拒绝，仅作兜底
    func getWebDownloadLink(pickCode: String, file: ShareFile, cookie: String) async throws -> DownloadLink {
        await refreshClientVersion()
        let url = "\(Pan115API.fileDownloadURL)?pickcode=\(wFormEncode(pickCode))"
        let req = baseBuilder(url: url, cookie: cookie, referer: Pan115API.downloadReferer,
                              userAgent: Pan115API.clientUA)
        let (json, cdnCookie) = try await executeJson(req)
        try checkState(json, fallback: "获取下载链接失败")
        guard let data = json.wObj("data") else { throw Wave2Error("获取下载链接失败") }
        let fileUrl = data.wStr("file_url")
        if fileUrl.isEmpty { throw Wave2Error("获取下载链接失败") }
        return DownloadLink(
            fid: file.fid,
            filename: data.wStr("file_name").isEmpty ? file.fname : data.wStr("file_name"),
            downloadUrl: fileUrl,
            size: Int64(data.wStr("file_size")) ?? file.fsize,
            cleanupDirFid: nil,
            guestCookie: cdnCookie ?? ""
        )
    }

    /**
     * 「电脑端」直链：POST https://proapi.115.com/app/chrome/downurl?t=<unix秒>。
     * 请求体 data=<加密的 {"pickcode":…}>；响应 data 是同一个 key 加密回来的 JSON。
     * 这是 115 官方电脑端下载大文件的唯一通道。
     */
    func getAppDownloadLink(pickCode: String, cookie: String) async throws -> DownloadLink {
        if pickCode.isEmpty { throw Wave2Error("缺少 pickcode，无法获取下载链接") }
        let key = Pan115Crypto.newKey()
        let payload = "{\"pickcode\":\(jsonStringLiteral(pickCode))}"
        let url = "\(Pan115API.appDownloadURL)?t=\(Int64(Date().timeIntervalSince1970))"
        let (json, cdnCookie) = try await postForm(
            url: url, cookie: cookie, referer: Pan115API.downloadReferer,
            fields: [("data", Pan115Crypto.encode(payload: payload, key: key))],
            userAgent: Pan115API.clientUA
        )
        try checkState(json, fallback: "获取下载链接失败")
        let encrypted = json.wStr("data")
        if encrypted.isEmpty { throw Wave2Error("获取下载链接失败") }
        guard let decodedText = Pan115Crypto.decode(data: encrypted, key: key),
              let decoded = wJSONObj(Data(decodedText.utf8)) else {
            throw Wave2Error("获取下载链接失败")
        }
        // decoded 是 file_id → {file_name, file_size, url.url} 的字典，取第一个带 url 的
        var info: [String: Any]? = nil
        for key in decoded.keys.sorted() {
            if let candidate = decoded.wObj(key), candidate.wObj("url") != nil {
                info = candidate
                break
            }
        }
        guard let info = info else { throw Wave2Error("获取下载链接失败") }
        let fileUrl = info.wObj("url")?.wStr("url") ?? ""
        if fileUrl.isEmpty { throw Wave2Error("获取下载链接失败") }
        let size = Int64(info.wStr("file_size")) ?? info.wLong("file_size", -1)
        return DownloadLink(
            fid: info.wStr("pick_code").isEmpty ? pickCode : info.wStr("pick_code"),
            filename: info.wStr("file_name"),
            downloadUrl: fileUrl,
            size: size,
            cleanupDirFid: nil,
            // 电脑端接口也下发 CDN Cookie（实测缺它直链 403 no cookie value）
            guestCookie: cdnCookie ?? ""
        )
    }

    /// 新建文件夹：POST /files/add → data.cid
    func createDir(pid: String, name: String, cookie: String) async throws -> String {
        let (json, _) = try await postForm(
            url: Pan115API.fileAddURL, cookie: cookie, referer: Pan115API.referer,
            fields: [("pid", pid.isEmpty ? Pan115API.rootCid : pid), ("cname", name)]
        )
        try checkState(json, fallback: "新建文件夹失败")
        let cid = json.wStr("cid").isEmpty ? (json.wObj("data")?.wStr("cid") ?? "") : json.wStr("cid")
        if cid.isEmpty { throw Wave2Error("新建文件夹失败") }
        return cid
    }

    /// 删除（进回收站）：POST /rb/delete
    func delete(fids: [String], pid: String, cookie: String) async throws {
        let ids = fids.filter { !$0.isEmpty }
        if ids.isEmpty { throw Wave2Error("请选择要删除的文件") }
        var fields: [(String, String)] = [("pid", pid.isEmpty ? Pan115API.rootCid : pid)]
        for (index, id) in ids.enumerated() { fields.append(("fid[\(index)]", id)) }
        fields.append(("ignore_warn", "1"))
        // 注：Kotlin 版对 errno=800007（需二次确认）会原样重发一次；此处直接发已带 ignore_warn=1 的请求
        let (json, _) = try await postForm(
            url: "\(Pan115API.apiBase)/rb/delete", cookie: cookie, referer: Pan115API.referer, fields: fields
        )
        try checkState(json, fallback: "删除失败")
    }

    // MARK: - 分享解析

    /// 创建分享会话：先探分享根目录，既校验提取码，又拿到分享者 UID 与分享标题
    func createSession(shareCode: String, receiveCode: String, cookie: String) async throws -> ShareSession {
        let page = try await getSharePage(
            shareCode: shareCode, receiveCode: receiveCode,
            cid: Pan115API.rootCid, cookie: cookie
        )
        return ShareSession(
            shareCode: shareCode,
            receiveCode: receiveCode,
            userId: page.userId,
            title: page.title.isEmpty ? shareCode : page.title
        )
    }

    /// 分享列目录单页：GET /share/snap（cid=0 为分享根）
    func getSharePage(shareCode: String, receiveCode: String, cid: String,
                      cookie: String, offset: Int = 0,
                      limit: Int = Pan115API.sharePageLimit) async throws -> SharePage {
        var url = Pan115API.shareSnapURL
        url += "?share_code=\(wFormEncode(shareCode))"
        url += "&receive_code=\(wFormEncode(receiveCode))"
        url += "&offset=\(offset)"
        url += "&limit=\(limit)"
        url += "&asc=0&cid=\(wFormEncode(cid.isEmpty ? Pan115API.rootCid : cid))"
        url += "&format=json"
        let (json, _) = try await getJson(
            url: url, cookie: cookie,
            referer: Pan115API.shareReferer(shareCode: shareCode, receiveCode: receiveCode)
        )
        try checkState(json, fallback: "获取分享列表失败")
        guard let data = json.wObj("data") else {
            return SharePage(files: [], total: 0, userId: "", title: "", shareState: 0)
        }
        let shareInfo = data.wObj("shareinfo")
        return SharePage(
            files: parseShareFiles(data),
            total: data.wInt("count"),
            userId: data.wObj("userinfo")?.wStr("user_id") ?? "",
            title: shareInfo?.wStr("share_title") ?? "",
            shareState: data.wInt("share_state", shareInfo?.wInt("share_state") ?? 0)
        )
    }

    /// 分享列目录全部（offset 索引分页，对应编排层 listFiles）。dirFid 根目录传 "0"
    func listAllShareFiles(session: ShareSession, dirFid: String, cookie: String) async throws -> [ShareFile] {
        let cid = dirFid.isEmpty ? Pan115API.rootCid : dirFid
        var all: [ShareFile] = []
        var offset = 0
        while true {
            let page = try await getSharePage(
                shareCode: session.shareCode, receiveCode: session.receiveCode,
                cid: cid, cookie: cookie, offset: offset, limit: Pan115API.sharePageLimit
            )
            all += page.files
            offset += page.files.count
            let done = page.files.isEmpty ||
                page.files.count < Pan115API.sharePageLimit ||
                (page.total > 0 && all.count >= page.total)
            if done { break }
        }
        return all
    }

    /**
     * 分享直链（网页端）：GET /share/downurl（user_id 必须是分享者 UID）。
     * 必须用客户端 UA：浏览器 UA 会被判「版本过低」直接拒发直链（50029）。
     */
    func getShareDownloadLink(session: ShareSession, file: ShareFile, cookie: String) async throws -> DownloadLink {
        if session.userId.isEmpty { throw Wave2Error("缺少分享者标识，请重新解析分享链接") }
        await refreshClientVersion()
        var url = Pan115API.shareDownloadURL
        url += "?dl=1"
        url += "&user_id=\(wFormEncode(session.userId))"
        url += "&share_code=\(wFormEncode(session.shareCode))"
        url += "&file_id=\(wFormEncode(file.fid))"
        if !session.receiveCode.isEmpty {
            url += "&receive_code=\(wFormEncode(session.receiveCode))"
        }
        let req = baseBuilder(
            url: url, cookie: cookie,
            referer: Pan115API.shareReferer(shareCode: session.shareCode, receiveCode: session.receiveCode),
            userAgent: Pan115API.clientUA
        )
        let (json, cdnCookie) = try await executeJson(req)
        try checkState(json, fallback: "获取下载链接失败")
        guard let data = json.wObj("data") else { throw Wave2Error("获取下载链接失败") }
        // 网页 JS 取的是 file_url_302 || url.url，三种形态都兜住
        var fileUrl = data.wStr("file_url_302")
        if fileUrl.isEmpty { fileUrl = data.wStr("file_url") }
        if fileUrl.isEmpty { fileUrl = data.wObj("url")?.wStr("url") ?? "" }
        if fileUrl.isEmpty { throw Wave2Error("获取下载链接失败") }
        return DownloadLink(
            fid: file.fid,
            filename: data.wStr("fn").isEmpty ? file.fname : data.wStr("fn"),
            downloadUrl: fileUrl,
            size: Int64(data.wStr("fs")) ?? file.fsize,
            cleanupDirFid: nil,
            guestCookie: cdnCookie ?? ""
        )
    }

    /// 转存到自己的网盘：POST /share/receive（不返回新文件 id）
    func receiveShare(shareCode: String, receiveCode: String, fileId: String, toCid: String, cookie: String) async throws {
        let (json, _) = try await postForm(
            url: Pan115API.shareReceiveURL, cookie: cookie, referer: Pan115API.referer,
            fields: [
                ("share_code", shareCode),
                ("receive_code", receiveCode),
                ("file_id", fileId),
                ("cid", toCid.isEmpty ? Pan115API.rootCid : toCid)
            ]
        )
        try checkState(json, fallback: "转存失败")
    }

    /**
     * 分享取链编排（对应编排层 getShareDownloadLink）：
     * 先走网页端 share/downurl（小文件够用）；失败且已登录时退回
     * 「转存到临时目录 + 电脑端加密接口取链」，link.cleanupDirFid 带回临时子目录，
     * 下载完成后集成层调 cleanupTempDir 清理。
     * 返回 (直链, 下载请求头)：Cookie = 登录 Cookie 与 CDN Cookie 拼接，UA = 客户端 UA，Referer 固定。
     */
    func resolveDownloadLink(session: ShareSession, file: ShareFile,
                             cookie: String) async throws -> (link: DownloadLink, headers: [String: String]) {
        var link: DownloadLink
        do {
            link = try await getShareDownloadLink(session: session, file: file, cookie: cookie)
        } catch {
            if Pan115API.hasLoginCookie(cookie) {
                link = try await downloadViaTempTransfer(session: session, file: file, cookie: cookie)
            } else {
                // 未登录只能走网页端，原样抛出 115 的提示（比如 50029）
                throw error
            }
        }
        // 文件名以列表为准（downurl 的 fn 偶发为空）
        link = DownloadLink(
            fid: link.fid,
            filename: file.fname.isEmpty ? link.filename : file.fname,
            downloadUrl: link.downloadUrl,
            size: link.size,
            cleanupDirFid: link.cleanupDirFid,
            guestCookie: link.guestCookie
        )
        let headers = downloadHeaders(loginCookie: cookie, cdnCookie: link.guestCookie)
        return (link, headers)
    }

    /// 个人盘取链的下载请求头（与分享同规则）
    func downloadHeaders(loginCookie: String, cdnCookie: String) -> [String: String] {
        [
            "Cookie": Pan115API.mergeCookies(loginCookie, cdnCookie),
            "User-Agent": Pan115API.clientUA,
            "Referer": Pan115API.downloadReferer
        ]
    }

    /// 分享文件的「电脑端」通道：转存到临时子目录 → 按文件名认领新文件（拿到 pickcode）→ 电脑端接口取链
    private func downloadViaTempTransfer(session: ShareSession, file: ShareFile, cookie: String) async throws -> DownloadLink {
        if !Pan115API.hasLoginCookie(cookie) {
            throw Wave2Error("该分享文件需要115电脑端才能下载，请先登录115网盘")
        }
        let tempDir = try await ensureTempDir(cookie: cookie)
        try await receiveShare(
            shareCode: session.shareCode, receiveCode: session.receiveCode,
            fileId: file.fid, toCid: tempDir, cookie: cookie
        )
        guard let saved = await waitNewFile(cid: tempDir, name: file.fname, cookie: cookie) else {
            await cleanupTempDir(dirFid: tempDir, cookie: cookie)
            throw Wave2Error("分享文件转存后未取到下载链接，请稍后重试")
        }
        guard let appLink = try? await getAppDownloadLink(pickCode: saved.fidToken, cookie: cookie) else {
            await cleanupTempDir(dirFid: tempDir, cookie: cookie)
            throw Wave2Error("该分享文件暂时无法获取电脑端下载链接，请稍后重试")
        }
        return DownloadLink(
            fid: saved.fid,
            filename: file.fname.isEmpty ? appLink.filename : file.fname,
            downloadUrl: appLink.downloadUrl,
            size: appLink.size > 0 ? appLink.size : saved.fsize,
            cleanupDirFid: tempDir,
            guestCookie: appLink.guestCookie
        )
    }

    /// 确保「YunX临时转存」下的唯一子目录存在，返回子目录 cid
    func ensureTempDir(cookie: String) async throws -> String {
        if !Pan115API.hasLoginCookie(cookie) {
            throw Wave2Error("请先登录115网盘")
        }
        let root = try await listFiles(cid: Pan115API.rootCid, cookie: cookie, offset: 0)
        let existingRoot = root.files.first(where: { $0.isdir && $0.fname == Pan115API.tempDirName })?.fid
        let tempRoot: String
        if let existingRoot {
            tempRoot = existingRoot
        } else {
            tempRoot = try await createDir(pid: Pan115API.rootCid, name: Pan115API.tempDirName, cookie: cookie)
        }
        let subName = "\(Pan115API.tempSubdirPrefix)\(Int(Date().timeIntervalSince1970 * 1_000_000_000))"
        return try await createDir(pid: tempRoot, name: subName, cookie: cookie)
    }

    /// 下载完成后清理：删掉本次转存的唯一子目录，里面的转存文件一并进回收站
    func cleanupTempDir(dirFid: String, cookie: String) async {
        if dirFid.isEmpty || !Pan115API.hasLoginCookie(cookie) { return }
        do {
            let root = try await listFiles(cid: Pan115API.rootCid, cookie: cookie, offset: 0)
            guard let tempRoot = root.files.first(where: { $0.isdir && $0.fname == Pan115API.tempDirName })?.fid else { return }
            try await delete(fids: [dirFid], pid: tempRoot, cookie: cookie)
        } catch { /* 清理失败不阻断 */ }
    }

    /// 转存后列表有延迟，最多重试 5 次、每次间隔 500ms，按文件名找回新文件
    private func waitNewFile(cid: String, name: String, cookie: String) async -> ShareFile? {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for index in 0..<5 {
            if index > 0 { try? await Task.sleep(nanoseconds: 500_000_000) }
            guard let page = try? await listFiles(cid: cid, cookie: cookie, offset: 0, limit: Pan115API.pageLimit) else { continue }
            if let hit = page.files.first(where: { matchesName($0.fname, name: name, base: base, ext: ext) }) {
                return hit
            }
        }
        return nil
    }

    /// 文件名是否为「原名」或重名后的「原名(序号).后缀」
    private func matchesName(_ candidate: String, name: String, base: String, ext: String) -> Bool {
        if candidate == name { return true }
        if !candidate.hasPrefix("\(base)(") { return false }
        return ext.isEmpty ? candidate.hasSuffix(")") : candidate.hasSuffix(".\(ext)")
    }

    // MARK: - 内部实现

    /// 个人盘列表解析：文件夹无 fid（自身 ID 在 cid），文件的 cid 是父目录
    private func parsePersonalFiles(_ json: [String: Any]) -> [ShareFile] {
        json.wObjs("data").compactMap { item in
            let fid = item.wStr("fid")
            let isDir = fid.isEmpty
            let id = isDir ? item.wStr("cid") : fid
            if id.isEmpty { return nil }
            return ShareFile(
                fid: id,
                fname: item.wStr("n"),
                fsize: isDir ? 0 : item.wLong("s"),
                isdir: isDir,
                pdirFid: isDir ? item.wStr("pid") : item.wStr("cid"),
                fidToken: item.wStr("pc"),
                modifyTime: item.wStr("t")
            )
        }
    }

    /// 分享列表解析：fc == 0 为目录，目录 ID 取 cid、文件 ID 取 fid
    private func parseShareFiles(_ data: [String: Any]) -> [ShareFile] {
        data.wObjs("list").compactMap { item in
            let fid = item.wStr("fid")
            let isDir = item.wInt("fc", fid.isEmpty ? 0 : 1) == 0
            let id = isDir ? item.wStr("cid") : fid
            if id.isEmpty { return nil }
            return ShareFile(
                fid: id,
                fname: item.wStr("n"),
                fsize: isDir ? 0 : item.wLong("s"),
                isdir: isDir,
                pdirFid: isDir ? item.wStr("pid") : item.wStr("cid"),
                fidToken: "",
                modifyTime: item.wStr("t")
            )
        }
    }

    private func baseBuilder(url: String, cookie: String, referer: String,
                             userAgent: String = Pan115API.webUA) -> URLRequest {
        var headers: [String: String] = [
            "User-Agent": userAgent,
            "Accept": "application/json, text/plain, */*",
            "X-Requested-With": Pan115API.xRequestedWith,
            "Referer": referer
        ]
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        return Wave2HTTP.request(url: url, headers: headers)
    }

    private func getJson(url: String, cookie: String, referer: String) async throws -> (json: [String: Any], cdnCookie: String?) {
        try await executeJson(baseBuilder(url: url, cookie: cookie, referer: referer))
    }

    private func postForm(url: String, cookie: String, referer: String,
                          fields: [(String, String)],
                          userAgent: String = Pan115API.webUA) async throws -> (json: [String: Any], cdnCookie: String?) {
        var req = baseBuilder(url: url, cookie: cookie, referer: referer, userAgent: userAgent)
        req.httpMethod = "POST"
        // 与网页版一致（抓到的是 application/x-www-form-urlencoded; charset=utf-8）
        req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = Wave2HTTP.formBody(fields)
        return try await executeJson(req)
    }

    /// 执行请求：返回响应 JSON 与响应头里下发的「下载专用 Cookie」
    private func executeJson(_ request: URLRequest) async throws -> (json: [String: Any], cdnCookie: String?) {
        let raw = try await Wave2HTTP.send(request)
        let cdn = downloadCookie(raw.setCookieHeaders)
        if raw.data.isEmpty {
            throw Wave2Error("请求失败：响应为空（\(raw.http.statusCode)）")
        }
        guard let json = wJSONObj(raw.data) else {
            throw Wave2Error("请求失败：响应解析失败（HTTP \(raw.http.statusCode)）")
        }
        return (json, cdn)
    }

    /// 从 Set-Cookie 里取第一个 `name=value`；优先 path 绑定的那条（CDN 只认它）
    private func downloadCookie(_ headers: [String]) -> String? {
        var fallback: String? = nil
        for raw in headers {
            let pair = (raw.split(separator: ";").first ?? "").trimmingCharacters(in: .whitespaces)
            guard let eq = pair.firstIndex(of: "="), eq != pair.startIndex else { continue }
            let name = String(pair[..<eq])
            if name.isEmpty { continue }
            let lower = name.lowercased()
            if lower == "expires" || lower == "path" || lower == "domain" { continue }
            if fallback == nil { fallback = pair }
            // 直链 CDN 只认 path 绑定的那条（path=/<对象路径>/），其余（如 WAF 的 acw_tc）不是它
            if let pathMatch = Pan115API.regexGroup(#"[;\s]path=([^;]+)"#, in: raw, options: .caseInsensitive) {
                let path = pathMatch.trimmingCharacters(in: .whitespaces)
                if !path.isEmpty && path != "/" { return pair }
            }
        }
        return fallback
    }

    private static func regexGroup(_ pattern: String, in text: String,
                                   options: NSRegularExpression.Options = []) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, options: [], range: range),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private func errnoOf(_ json: [String: Any]) -> Int {
        json.wHas("errno") ? json.wInt("errno") : json.wInt("errNo")
    }

    /// 成功判定：state == true；失败按抓包错误码给出可读提示
    private func checkState(_ json: [String: Any], fallback: String) throws {
        if json.wBool("state") { return }
        let errno = errnoOf(json)
        let raw = json.wStr("error").isEmpty ? json.wStr("msg") : json.wStr("error")
        let message: String
        switch errno {
        case Pan115API.errnoLoginTimeout: message = "登录已过期，请重新登录115网盘"
        case Pan115API.errnoNeedCode: message = "该分享需要访问码，请填写访问码后重试"
        case Pan115API.errnoWrongCode: message = "访问码错误，请检查后重试"
        case Pan115API.errnoShareGone: message = "分享链接不存在或已被删除"
        case Pan115API.errnoEmptyFolder: message = "不允许分享空文件夹"
        case Pan115API.errnoBusy: message = "上一次操作还没完成，请稍后再试"
        case Pan115API.errnoWebSizeLimit: message = "115 拒绝向网页端下发该文件的直链（文件过大），请改用115电脑端/手机客户端下载"
        case Pan115API.errnoClientTooOld: message = "115 判定当前标识版本过低、拒绝下发直链，请改用115电脑端/手机客户端下载"
        default: message = raw.isEmpty ? fallback : raw
        }
        let suffix = (errno != 0 && !message.contains("\(errno)")) ? "（errno=\(errno)）" : ""
        throw Wave2Error(message + suffix)
    }

    /// JSON 字符串字面量（含引号与转义），拼 {"pickcode": "..."} 用
    private func jsonStringLiteral(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        // ["..."] → 剥掉外层方括号即单个字符串字面量
        return String(text.dropFirst().dropLast())
    }
}

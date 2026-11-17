import Foundation
import CommonCrypto
import Compression

/// 第二批平台（迅雷 / 123 / 115 / 139 / 光鸭 / 蓝奏 / 蓝奏优享 / GitHub / 星海）共用的
/// 基础设施：HTTP、JSON 小工具、编码与加解密。全部带 Wave2 前缀自包含，
/// 不依赖第一批（夸克）与并行批次（百度 / UC）文件里的任何符号。
///
/// 设计与 QuarkAPI 对齐：禁用系统 Cookie 存储，Cookie 全部手工管理（对应 OkHttp 无 CookieJar）。

// MARK: - 错误

/// 第二批平台统一业务异常：透传服务端 message（与 Kotlin 各 Api 抛 IllegalStateException 等价）
struct Wave2Error: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - HTTP

/// 禁止自动重定向用的 delegate（蓝奏探测直链、蓝奏优享取 302 Location 时需要手动处理跳转）
private final class Wave2RedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum Wave2HTTP {
    private static func makeSession(delegate: URLSessionTaskDelegate?) -> URLSession {
        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    /// 跟随重定向的会话
    static let follow = makeSession(delegate: nil)
    /// 不跟随重定向的会话（响应原样返回，含 3xx 与 Location）
    static let noRedirect = makeSession(delegate: Wave2RedirectBlocker())

    struct Response {
        let data: Data
        let http: HTTPURLResponse

        /// 响应 Set-Cookie 解析出的 (name, value) 列表
        var cookiePairs: [(name: String, value: String)] {
            guard let url = http.url else { return [] }
            var fields: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let k = key as? String, let v = value as? String { fields[k] = v }
            }
            return HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
                .map { (name: $0.name, value: $0.value) }
        }

        /// 原始 Set-Cookie 头（115 需要按 path 属性挑 CDN Cookie，必须看原文）
        var setCookieHeaders: [String] {
            var out: [String] = []
            for (key, value) in http.allHeaderFields {
                if let k = key as? String, k.lowercased() == "set-cookie", let v = value as? String {
                    out.append(v)
                }
            }
            return out
        }

        var text: String { String(data: data, encoding: .utf8) ?? "" }
    }

    static func send(_ request: URLRequest, noRedirect: Bool = false) async throws -> Response {
        let session = noRedirect ? Wave2HTTP.noRedirect : Wave2HTTP.follow
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Wave2Error("请求失败：无响应")
        }
        return Response(data: data, http: http)
    }

    static func request(url: String, method: String = "GET",
                        headers: [String: String] = [:], body: Data? = nil) -> URLRequest {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        return req
    }

    /// 表单 POST（application/x-www-form-urlencoded），字段按给定顺序编码
    static func formBody(_ fields: [(String, String)]) -> Data {
        let s = fields.map { "\(wFormEncode($0.0))=\(wFormEncode($0.1))" }.joined(separator: "&")
        return Data(s.utf8)
    }

    static func jsonBody(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }
}

// MARK: - JSON 小工具（对应 org.json 的 opt* 语义）

func wJSONObj(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func wJSONArr(_ data: Data) -> [[String: Any]]? {
    ((try? JSONSerialization.jsonObject(with: data)) as? [Any])?.compactMap { $0 as? [String: Any] }
}

extension Dictionary where Key == String, Value == Any {
    /// optString：字符串原样；数字转字符串；其余/缺失为空串
    func wStr(_ key: String) -> String {
        if let s = self[key] as? String { return s }
        if let n = self[key] as? NSNumber { return n.stringValue }
        return ""
    }

    func wInt(_ key: String, _ def: Int = 0) -> Int {
        if let n = self[key] as? NSNumber { return n.intValue }
        if let s = self[key] as? String { return Int(s) ?? def }
        return def
    }

    func wLong(_ key: String, _ def: Int64 = 0) -> Int64 {
        if let n = self[key] as? NSNumber { return n.int64Value }
        if let s = self[key] as? String { return Int64(s) ?? def }
        return def
    }

    func wBool(_ key: String, _ def: Bool = false) -> Bool {
        if let n = self[key] as? NSNumber { return n.boolValue }
        if let s = self[key] as? String { return s == "true" ? true : (s == "false" ? false : def) }
        return def
    }

    /// 字段是否存在且非 null（对应 JSONObject.has 且非 NULL）
    func wHas(_ key: String) -> Bool {
        guard let v = self[key] else { return false }
        return !(v is NSNull)
    }

    func wObj(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }

    func wArr(_ key: String) -> [Any]? { self[key] as? [Any] }

    /// 对象数组（元素不是对象的跳过）
    func wObjs(_ key: String) -> [[String: Any]] {
        (self[key] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    func wStrs(_ key: String) -> [String] {
        (self[key] as? [Any])?.compactMap { $0 as? String } ?? []
    }
}

/// 第一个非空白值（对应 Kotlin firstNonBlank(...).trim()）
func wFirstNonBlank(_ values: String...) -> String {
    for v in values {
        let t = v.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { return t }
    }
    return ""
}

// MARK: - 编码

/// java.net.URLEncoder.encode(s, "UTF-8") 等价：保留 [A-Za-z0-9.-*_]，空格→+，其余 %XX（大写）
func wFormEncode(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.utf8.count)
    for byte in s.utf8 {
        let isAlnum = (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
        if isAlnum || byte == 0x2E || byte == 0x2D || byte == 0x2A || byte == 0x5F { // . - * _
            out.append(Character(UnicodeScalar(byte)))
        } else if byte == 0x20 {
            out.append("+")
        } else {
            out += String(format: "%%%02X", byte)
        }
    }
    return out
}

/// encodeURIComponent 等价（139 签名用）：URLEncoder 后 +→%20，并还原 ! ' ( ) *
func wURIComponentEncode(_ s: String) -> String {
    wFormEncode(s)
        .replacingOccurrences(of: "+", with: "%20")
        .replacingOccurrences(of: "%21", with: "!")
        .replacingOccurrences(of: "%27", with: "'")
        .replacingOccurrences(of: "%28", with: "(")
        .replacingOccurrences(of: "%29", with: ")")
        .replacingOccurrences(of: "%2A", with: "*")
}

/// 严格百分号编码（保留 [A-Za-z0-9-._~]），用于 query 参数里的 token 类值
func wStrictEncode(_ s: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
}

/// 蓝奏优享 appToken 编码：标准表单编码后把 %3A 还原为字面冒号（对应 Kotlin encodeToken）
func wTokenEncode(_ s: String) -> String {
    wFormEncode(s).replacingOccurrences(of: "%3A", with: ":")
}

/// Base64 解码（兼容 URL-safe 与缺省填充；123 的 params 解码前会先做字符替换，由调用方处理）
func wBase64Decode(_ s: String) -> Data? {
    var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    let rem = t.count % 4
    if rem > 0 { t += String(repeating: "=", count: 4 - rem) }
    return Data(base64Encoded: t)
}

/// JWT payload 解码（base64url → JSON 对象）
func wJWTBody(_ token: String) -> [String: Any]? {
    let parts = token.split(separator: ".")
    guard parts.count >= 2, let data = wBase64Decode(String(parts[1])) else { return nil }
    return wJSONObj(data)
}

// MARK: - 摘要与 CRC32

func wMD5(_ data: Data) -> Data {
    var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
    data.withUnsafeBytes { buf in
        _ = CC_MD5(buf.baseAddress, CC_LONG(data.count), &digest)
    }
    return Data(digest)
}

func wMD5Hex(_ s: String) -> String {
    wMD5(Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
}

func wSHA1Hex(_ s: String) -> String {
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
    Data(s.utf8).withUnsafeBytes { buf in
        _ = CC_SHA1(buf.baseAddress, CC_LONG(buf.count), &digest)
    }
    return digest.map { String(format: "%02x", $0) }.joined()
}

/// 标准 CRC-32（IEEE 802.3）→ 8 位小写十六进制（123 签名用，与 java.util.zip.CRC32 一致）
func wCRC32Hex(_ s: String) -> String {
    var table: [UInt32] = []
    if table.isEmpty {
        table = (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
            return c
        }
    }
    var crc: UInt32 = 0xFFFFFFFF
    for byte in s.utf8 {
        crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
    }
    return String(format: "%08x", crc ^ 0xFFFFFFFF)
}

// MARK: - AES（CommonCrypto，PKCS7 填充）

/// AES 加密/解密：iv 为 nil 走 ECB，否则 CBC。key 长度 16/24/32 均可。
func wAES(key: Data, iv: Data?, encrypt: Bool, data: Data) -> Data? {
    let operation: CCOperation = encrypt ? CCOperation(kCCEncrypt) : CCOperation(kCCDecrypt)
    var options = CCOptions(kCCOptionPKCS7Padding)
    if iv == nil { options |= CCOptions(kCCOptionECBMode) }
    let outCapacity = data.count + kCCBlockSizeAES128
    var out = Data(count: outCapacity)
    var outLength = 0
    let status = out.withUnsafeMutableBytes { outBuf in
        data.withUnsafeBytes { inBuf in
            key.withUnsafeBytes { keyBuf in
                if let iv = iv {
                    return iv.withUnsafeBytes { ivBuf in
                        CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), options,
                                keyBuf.baseAddress, key.count, ivBuf.baseAddress,
                                inBuf.baseAddress, data.count,
                                outBuf.baseAddress, outCapacity, &outLength)
                    }
                }
                return CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), options,
                               keyBuf.baseAddress, key.count, nil,
                               inBuf.baseAddress, data.count,
                               outBuf.baseAddress, outCapacity, &outLength)
            }
        }
    }
    guard status == kCCSuccess else { return nil }
    out.count = outLength
    return out
}

/// AES/ECB/PKCS7 加密 → 小写十六进制（蓝奏优享 auth / downloadId / timestamp）
func wAESECBHex(key: String, plain: String) -> String {
    guard let out = wAES(key: Data(key.utf8), iv: nil, encrypt: true, data: Data(plain.utf8)) else { return "" }
    return out.map { String(format: "%02x", $0) }.joined()
}

/// gzip 解压（139 分享接口解密后可能是 gzip）：解析 gzip 头后用 Compression 解 raw deflate
func wGunzip(_ data: Data) -> Data? {
    guard data.count > 18, data[0] == 0x1F, data[1] == 0x8B, data[2] == 8 else { return nil }
    let flags = data[3]
    var offset = 10
    if flags & 0x04 != 0 { // FEXTRA
        guard offset + 2 <= data.count else { return nil }
        let xlen = Int(data[offset]) | (Int(data[offset + 1]) << 8)
        offset += 2 + xlen
    }
    if flags & 0x08 != 0 { // FNAME
        while offset < data.count, data[offset] != 0 { offset += 1 }
        offset += 1
    }
    if flags & 0x10 != 0 { // FCOMMENT
        while offset < data.count, data[offset] != 0 { offset += 1 }
        offset += 1
    }
    if flags & 0x02 != 0 { offset += 2 } // FHCRC
    guard offset < data.count - 8 else { return nil }
    let deflate = data.subdata(in: offset..<(data.count - 8))
    // 输出大小未知：从 256KB 起翻倍重试
    var capacity = 256 * 1024
    while capacity <= 64 * 1024 * 1024 {
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { outBuf in
            deflate.withUnsafeBytes { inBuf in
                compression_decode_buffer(outBuf.baseAddress!.assumingMemoryBound(to: UInt8.self), capacity,
                                          inBuf.baseAddress!.assumingMemoryBound(to: UInt8.self), deflate.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        if written > 0 {
            out.count = written
            return out
        }
        capacity *= 4
    }
    return nil
}

/// 当前毫秒时间戳
func wNowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

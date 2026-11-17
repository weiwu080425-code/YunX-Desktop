import Foundation

/// 星海「中文口令解析」客户端（夸克 / UC），移植自 Kotlin StarSeaApi + StarSeaConstants。
///
/// 中文口令不是分享链接（如「绝对有效 咐置松君杂货铺叩苓」），本地解析不出来，
/// 这里问一次星海接口拿到 pwdId，再合成应用现有链路认得的分享链接
/// （`pan.quark.cn/s/<pwdId>` / `drive.uc.cn/s/<pwdId>`）——后续提取码、登录态、列表、
/// 取链全部走夸克 / UC 既有逻辑，本文件只做「口令 → pwdId」这一步。
///
/// 只走 step=parse：只拿 pwdId，不索取 stoken、不消耗用户 Cookie，取链全在本地完成。
/// 隐私：口令原文会发往第三方服务（服务端会把完整口令写进访问日志），本文件不打印口令本体。
final class StarSeaAPI {
    static let shared = StarSeaAPI()
    private init() {}

    // MARK: - 常量（对应 Kotlin StarSeaConstants）

    static let baseURL = "https://starsea-api.qwq.pics"
    static let resolveURL = "\(baseURL)/api/resolve"
    /// 鉴权头 X-API-Key 的值（服务端 60 次/分钟/IP 限流，超限 429；Key 轮换时同步改这里）
    static let apiKey = "8bfbe163c670ae500aca5f3b2f060ecc8463e1eb1691ba8d"
    /// 认为是「中文口令」的最大长度：超过多半是整段文案，不该拿去打第三方接口
    static let maxCommandLength = 120

    private static let stepParse = "parse"

    /// 口令解析结果（只保留应用需要的两个字段）
    struct CommandResolve {
        /// `qk` / `uc`
        let platform: String
        /// 分享 ID，可直接喂给现有夸克/UC 链路
        let pwdId: String
    }

    // MARK: - 纯逻辑

    /// 该不该把这段文本按「中文口令」去问星海：
    /// 非空、不超过最大长度、且自身不是 URL（是 URL 说明本地解析没认出来，那不是口令）。
    static func looksLikeCommand(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.count > maxCommandLength { return false }
        if t.range(of: "http://", options: .caseInsensitive) != nil ||
            t.range(of: "https://", options: .caseInsensitive) != nil { return false }
        return true
    }

    /// pwdId → 分享链接：合成出来的就是该分享真实存在的地址，可照常被重新解析
    static func shareLink(platform: String, pwdId: String) -> String {
        platform.lowercased() == "uc"
            ? "https://drive.uc.cn/s/\(pwdId)"
            : "https://pan.quark.cn/s/\(pwdId)"
    }

    // MARK: - 网络

    /// 中文口令 → 分享链接（夸克/UC）；失败抛 Wave2Error，message 可直接展示
    func resolveToShareLink(command: String, passcode: String? = nil) async throws -> String {
        let resolved = try await resolve(command: command, passcode: passcode)
        return StarSeaAPI.shareLink(platform: resolved.platform, pwdId: resolved.pwdId)
    }

    /// 调 RESOLVE_URL 取 pwd_id
    func resolve(command: String, passcode: String? = nil, step: String = StarSeaAPI.stepParse) async throws -> CommandResolve {
        var payload: [String: Any] = [
            "clipboard": command,
            "platform": "auto", // 服务端按机器码/标记词自动判定夸克还是 UC
            "step": step
        ]
        if let passcode = passcode, !passcode.isEmpty { payload["passcode"] = passcode }
        let req = Wave2HTTP.request(
            url: StarSeaAPI.resolveURL, method: "POST",
            headers: [
                "X-API-Key": StarSeaAPI.apiKey,
                "Accept": "application/json",
                "Content-Type": "application/json"
            ],
            body: try Wave2HTTP.jsonBody(payload)
        )
        let raw = try await Wave2HTTP.send(req)
        // 先读 body 再判成败：业务失败与 HTTP 状态码是分离的（非 2xx 也可能带合法 JSON 的原因）
        let json = wJSONObj(raw.data)
        let serverMsg = json?.wStr("msg") ?? ""
        guard let json = json, json.wBool("success") else {
            throw Wave2Error(StarSeaAPI.describeFailure(code: raw.http.statusCode, serverMsg: serverMsg))
        }
        guard let data = json.wObj("data") else {
            throw Wave2Error("口令解析失败：响应缺少 data")
        }
        let pwdId = data.wStr("pwdId")
        if pwdId.isEmpty { throw Wave2Error("口令解析失败：未取到分享 ID") }
        return CommandResolve(platform: data.wStr("platform"), pwdId: pwdId)
    }

    /// 把「HTTP 码 + 服务端 msg」翻译成给用户看的中文原因：服务端有话说就用它的
    private static func describeFailure(code: Int, serverMsg: String) -> String {
        if !serverMsg.isEmpty { return serverMsg }
        switch code {
        case 400: return "口令为空或格式不对"
        case 401: return "口令解析服务鉴权失败（Key 无效或已轮换）"
        case 413: return "口令过长"
        case 429: return "口令解析服务限流，请稍后再试"
        case 404: return "口令解析服务地址不可用"
        default: return "口令解析失败（HTTP \(code)）"
        }
    }
}

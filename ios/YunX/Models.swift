import Foundation

/// 分享解析会话（一次解析流程的凭证），对应 Kotlin ShareSession
struct ShareSession {
    let shareId: String
    let stoken: String
    let title: String
}

/// 分享 Token 响应，对应 Kotlin ShareToken
struct ShareToken {
    let stoken: String
    let title: String
    let firstFid: String
}

/// 分享文件/目录项，对应 Kotlin ShareFile
struct ShareFile: Identifiable {
    let fid: String
    let fname: String
    let fsize: Int64
    let isdir: Bool
    let pdirFid: String
    let fidToken: String
    let modifyTime: String

    var id: String { fid.isEmpty ? "\(pdirFid)/\(fname)" : fid }
}

/// 下载直链，对应 Kotlin DownloadLink（仅保留 iOS 版用到的字段）
struct DownloadLink {
    let fid: String
    let filename: String
    let downloadUrl: String
    let size: Int64
    /// 转存流程下，下载完成后要删除的临时子目录 fid；免转存/游客为 nil
    var cleanupDirFid: String? = nil
    /// 游客直链专用的游客态 Cookie（`__pugs=...`）；登录态为空串
    var guestCookie: String = ""
}

/// 网盘空间（字节），对应 Kotlin QuotaInfo
struct QuotaInfo {
    let used: Int64
    let total: Int64
}

/// 夸克 API 业务异常：透传服务端 message 与 code，对应 Kotlin QuarkApiException
struct QuarkError: Error, LocalizedError {
    let message: String
    let code: Int

    init(_ message: String, code: Int = 0) {
        self.message = message
        self.code = code
    }

    var errorDescription: String? { message }
}

/// 字节数格式化（与 Kotlin TransferSpaceGuard.formatBytes 同风格）
func formatBytes(_ bytes: Int64) -> String {
    if bytes <= 0 { return "0 B" }
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(bytes)
    var unit = 0
    while value >= 1024 && unit < units.count - 1 {
        value /= 1024
        unit += 1
    }
    if unit == 0 { return "\(bytes) B" }
    return String(format: "%.1f %@", value, units[unit])
}

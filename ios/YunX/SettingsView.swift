import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var cookieText: String = CookieStore.shared.cookie
    @State private var nickname: String?
    @State private var quotaText: String?
    @State private var message: String?
    @State private var isChecking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $cookieText)
                        .frame(minHeight: 120)
                        .font(.footnote)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("夸克 Cookie")
                } footer: {
                    Text("获取方法：在电脑浏览器登录 pan.quark.cn，打开开发者工具（F12）→「网络」，刷新页面后点任意一条 drive-pc.quark.cn 的请求，复制请求头里的 Cookie 整段粘贴到这里。Cookie 只保存在本机（明文存储），只用于向夸克官方接口发请求；缺少 __pus / __puus 字段的 Cookie 无法取下载直链。")
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
                    Button("清除", role: .destructive) {
                        CookieStore.shared.clear()
                        cookieText = ""
                        nickname = nil
                        quotaText = nil
                        message = "已清除，回到游客模式"
                    }
                }

                if let nickname = nickname {
                    Section("账号") {
                        Text(nickname)
                    }
                }
                if let quotaText = quotaText {
                    Section("网盘空间") {
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

                Section("说明") {
                    Text("云析 iOS 第一版仅支持夸克网盘：粘贴分享文案解析文件列表，点文件取直链下载到本机，再通过「导出到『文件』」保存到「文件」App。下载的文件也会出现在「文件」App 的「云析」文件夹里。未保存 Cookie 时为游客模式，仅能下载约 50MB 以内的小文件。")
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

    private func save() {
        let trimmed = cookieText.trimmingCharacters(in: .whitespacesAndNewlines)
        CookieStore.shared.cookie = trimmed
        CookieStore.shared.lastRefreshMs = Int64(Date().timeIntervalSince1970 * 1000)
        cookieText = trimmed
        if trimmed.isEmpty {
            message = "已保存（空），当前为游客模式"
        } else if CookieStore.looksValid(trimmed) {
            message = "已保存"
        } else {
            message = "已保存，但这份 Cookie 缺少 __pus / __puus 字段，可能无法下载，请重新复制完整的 Cookie"
        }
    }

    private func verify() {
        let cookie = cookieText.trimmingCharacters(in: .whitespacesAndNewlines)
        isChecking = true
        message = nil
        Task {
            let api = QuarkAPI.shared
            nickname = await api.fetchNickname(cookie: cookie)
            if let quota = await api.getQuota(cookie: cookie) {
                quotaText = "已用 \(formatBytes(quota.used)) / 共 \(formatBytes(quota.total))"
            } else {
                quotaText = nil
            }
            message = nickname != nil ? "Cookie 有效" : "没查到账号信息，Cookie 可能已失效或不完整"
            isChecking = false
        }
    }
}

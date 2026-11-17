import SwiftUI

@MainActor
final class ResolveViewModel: ObservableObject {
    @Published var inputText = ""
    @Published var shareTitle = ""
    @Published var files: [ShareFile] = []
    @Published var isParsing = false
    @Published var isLoadingDir = false
    /// 正在取链的文件 id（取链含转存轮询，可能要几秒）
    @Published var busyFileId: String?
    @Published var errorMessage: String?
    /// 面包屑目录名（不含根目录）
    @Published var pathNames: [String] = []

    private var session: ShareSession?
    private var dirStack: [String] = []
    private var currentDirFid = "0"

    private let api = QuarkAPI.shared

    var isGuest: Bool { CookieStore.shared.cookie.isEmpty }
    var hasSession: Bool { session != nil }

    func parse() {
        let text = inputText
        isParsing = true
        errorMessage = nil
        Task {
            do {
                let s = try await api.createSession(linkText: text, pwdOverride: nil)
                session = s
                shareTitle = s.title
                dirStack = []
                pathNames = []
                currentDirFid = "0"
                files = try await api.listAllShareFiles(session: s, pdirFid: currentDirFid)
            } catch {
                errorMessage = ResolveViewModel.message(of: error)
            }
            isParsing = false
        }
    }

    func enterFolder(_ file: ShareFile) {
        dirStack.append(file.fid)
        pathNames.append(file.fname)
        currentDirFid = file.fid
        reload()
    }

    /// 面包屑回退：level 0 = 分享根目录；当前层（level == pathNames.count）无需操作
    /// （对应 Kotlin ResolveViewModel.navigateToLevel）
    func navigateToLevel(_ level: Int) {
        if level < 0 || level >= pathNames.count { return }
        dirStack = Array(dirStack.prefix(level))
        pathNames = Array(pathNames.prefix(level))
        currentDirFid = dirStack.last ?? "0"
        reload()
    }

    private func reload() {
        guard let s = session else { return }
        isLoadingDir = true
        errorMessage = nil
        Task {
            do {
                files = try await api.listAllShareFiles(session: s, pdirFid: currentDirFid)
            } catch {
                errorMessage = ResolveViewModel.message(of: error)
            }
            isLoadingDir = false
        }
    }

    func download(_ file: ShareFile) {
        guard let s = session else { return }
        busyFileId = file.id
        errorMessage = nil
        Task {
            do {
                let (link, cookie) = try await api.resolveDownloadLink(file: file, session: s)
                // 夸克下载请求头（对应 Kotlin ResolveViewModel.enqueueDownload 的夸克分支）：
                // Cookie 必须是取链用的同一份；游客链用直链自带的 __pugs。
                var headers: [String: String] = [
                    "User-Agent": QuarkAPI.apiUserAgent,
                    "Referer": QuarkAPI.downloadReferer
                ]
                if !cookie.isEmpty { headers["Cookie"] = cookie }
                let cleanupDirFid = link.cleanupDirFid
                let downloadCookie = cookie
                let apiRef = api
                DownloadCenter.shared.start(
                    urlString: link.downloadUrl,
                    filename: link.filename.isEmpty ? file.fname : link.filename,
                    headers: headers
                ) {
                    // 下载完成才删临时转存子目录（下载期间 fid 必须存活）；失败静默
                    if let dirFid = cleanupDirFid {
                        Task { await apiRef.deleteFile(fid: dirFid, cookie: downloadCookie) }
                    }
                }
            } catch {
                errorMessage = ResolveViewModel.message(of: error)
            }
            busyFileId = nil
        }
    }

    static func message(of error: Error) -> String {
        if let quarkError = error as? QuarkError { return quarkError.message }
        return error.localizedDescription
    }
}

struct ResolveView: View {
    @StateObject private var model = ResolveViewModel()
    @ObservedObject private var downloads = DownloadCenter.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("粘贴夸克分享文案（含链接和提取码）", text: $model.inputText, axis: .vertical)
                    Button {
                        model.parse()
                    } label: {
                        HStack {
                            Text("解析")
                            if model.isParsing { ProgressView() }
                        }
                    }
                    .disabled(model.isParsing || model.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if model.isGuest {
                        Text("未设置 Cookie：当前是游客模式，只能下载约 50MB 以内的小文件。去「设置」页粘贴 Cookie 后可下大文件。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = model.errorMessage {
                    Section {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                if model.hasSession {
                    Section {
                        breadcrumb
                        if model.isLoadingDir {
                            HStack {
                                ProgressView()
                                Text("加载中…").foregroundStyle(.secondary)
                            }
                        }
                        ForEach(model.files) { file in
                            fileRow(file)
                        }
                        if !model.isLoadingDir && model.files.isEmpty {
                            Text("这个文件夹是空的")
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text(model.shareTitle.isEmpty ? "文件列表" : model.shareTitle)
                    }
                }

                if !downloads.items.isEmpty {
                    Section("下载") {
                        ForEach(downloads.items) { item in
                            DownloadRow(item: item)
                        }
                    }
                }
            }
            .navigationTitle("云析 · 夸克解析")
        }
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button("根目录") { model.navigateToLevel(0) }
                ForEach(Array(model.pathNames.enumerated()), id: \.offset) { idx, name in
                    Text("›").foregroundStyle(.secondary)
                    Button(name) { model.navigateToLevel(idx + 1) }
                }
            }
            .font(.footnote)
        }
    }

    @ViewBuilder
    private func fileRow(_ file: ShareFile) -> some View {
        if file.isdir {
            Button {
                model.enterFolder(file)
            } label: {
                HStack {
                    Image(systemName: "folder.fill").foregroundStyle(.yellow)
                    Text(file.fname).foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            HStack {
                Image(systemName: "doc").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.fname)
                    Text(formatBytes(file.fsize))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.busyFileId == file.id {
                    ProgressView()
                } else {
                    Button("下载") { model.download(file) }
                        .buttonStyle(.bordered)
                }
            }
        }
    }
}

/// 下载列表里的一行：进度 / 完成后的导出按钮 / 错误提示
struct DownloadRow: View {
    @ObservedObject var item: DownloadItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.filename).lineLimit(1)
            if let error = item.errorText {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else if let url = item.finishedURL {
                HStack {
                    Text("已下载")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    ShareLink(item: url) {
                        Text("导出到「文件」")
                    }
                    .font(.footnote)
                }
            } else {
                if item.progress >= 0 {
                    ProgressView(value: item.progress)
                } else {
                    ProgressView()
                }
                HStack {
                    Text("\(formatBytes(item.received)) / \(item.total > 0 ? formatBytes(item.total) : "未知大小")")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("取消") { DownloadCenter.shared.cancel(item) }
                        .font(.footnote)
                }
            }
        }
    }
}

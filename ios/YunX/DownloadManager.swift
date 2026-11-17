import Foundation

/// 一个下载任务的 UI 状态
final class DownloadItem: ObservableObject, Identifiable {
    let id = UUID()
    let filename: String
    /// 发起下载的分享文件 id，文件行靠它就地显示本文件的下载状态
    let fileKey: String
    /// 进度 0...1；-1 表示服务端未给出总大小
    @Published var progress: Double = 0
    @Published var received: Int64 = 0
    @Published var total: Int64 = 0
    /// 下载完成并落盘后的本地文件 URL
    @Published var finishedURL: URL?
    @Published var errorText: String?

    /// 下载成功后执行一次的收尾回调（转存流程删临时目录用）
    var cleanup: (() -> Void)?
    var task: URLSessionDownloadTask?

    init(filename: String, fileKey: String) {
        self.filename = filename
        self.fileKey = fileKey
    }
}

/// 基于后台 URLSession 的下载中心：
/// 请求带上取链时那份 Cookie + 固定 UA + Referer（夸克直链防盗链要求，缺 Cookie 时 CDN 返回 412）；
/// 直链原样使用、不改写 host（改写会命中节点绑定的签名 → 412，对应 Kotlin QuarkCdn 的结论）。
/// 下载在 App 切后台/被系统挂起后仍可继续，完成后文件落在应用 Documents/Downloads 下。
final class DownloadCenter: NSObject, ObservableObject {
    static let shared = DownloadCenter()

    @Published var items: [DownloadItem] = []
    /// 状态代号：单个任务内部的变化不会触发中心的订阅者重渲染，
    /// 任务完成/失败时 bump 一次，文件行据此切换按钮（下载 ↔ 导出）。
    @Published var revision = 0

    func touch() {
        DispatchQueue.main.async { self.revision += 1 }
    }

    private var session: URLSession!
    private var itemsByTaskId: [Int: DownloadItem] = [:]
    private let lock = NSLock()

    override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: "com.weiwu.yunx.downloads")
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// 开始一个下载。headers 必须包含取链同款的 Cookie / User-Agent / Referer。
    func start(urlString: String, filename: String, fileKey: String, headers: [String: String], cleanup: (() -> Void)? = nil) {
        guard let url = URL(string: urlString) else { return }
        var req = URLRequest(url: url)
        for (key, value) in headers { req.setValue(value, forHTTPHeaderField: key) }
        let item = DownloadItem(filename: filename, fileKey: fileKey)
        item.cleanup = cleanup
        let task = session.downloadTask(with: req)
        item.task = task
        lock.lock()
        itemsByTaskId[task.taskIdentifier] = item
        lock.unlock()
        DispatchQueue.main.async { self.items.insert(item, at: 0) }
        task.resume()
    }

    func cancel(_ item: DownloadItem) {
        item.task?.cancel()
    }

    private func item(for task: URLSessionTask) -> DownloadItem? {
        lock.lock()
        defer { lock.unlock() }
        return itemsByTaskId[task.taskIdentifier]
    }

    private func unregister(_ task: URLSessionTask) {
        lock.lock()
        itemsByTaskId.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
    }

    /// 落盘目标：Documents/Downloads/<文件名>（同名覆盖）
    static func destinationURL(for filename: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = filename.replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent(safe.isEmpty ? "file" : safe)
    }
}

extension DownloadCenter: URLSessionDownloadDelegate {

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let item = item(for: downloadTask) else { return }
        DispatchQueue.main.async {
            item.received = totalBytesWritten
            item.total = totalBytesExpectedToWrite
            item.progress = totalBytesExpectedToWrite > 0
                ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
                : -1
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let item = item(for: downloadTask) else { return }
        // HTTP 非 2xx 时 body 是错误页，不能当文件保存（夸克签名失效时是 412）
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            DispatchQueue.main.async {
                item.errorText = "下载失败（HTTP \(http.statusCode)），直链可能已过期，请重新点下载"
            }
            touch()
            return
        }
        // location 指向的临时文件在本回调返回后会被系统删除，必须同步移动
        let dest = DownloadCenter.destinationURL(for: item.filename)
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: location, to: dest)
            DispatchQueue.main.async { item.finishedURL = dest }
            touch()
            let cleanup = item.cleanup
            item.cleanup = nil
            cleanup?()
        } catch {
            DispatchQueue.main.async {
                item.errorText = "保存文件失败：\(error.localizedDescription)"
            }
            touch()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let item = item(for: task) else { return }
        unregister(task)
        if let error = error {
            let nsError = error as NSError
            // 用户主动取消（-999）不算失败提示
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                DispatchQueue.main.async { item.errorText = "已取消" }
            } else {
                DispatchQueue.main.async { item.errorText = error.localizedDescription }
            }
        }
        touch()
    }
}

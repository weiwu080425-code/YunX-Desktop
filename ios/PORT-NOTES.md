# 云析 YunX · iOS 移植说明（第一版，仅夸克网盘）

从桌面版 YunX-Desktop 的 Kotlin 源码（QuarkApi.kt 等）逐行研读后，用纯 Swift 重写的 iOS 版。
只做一条链路：粘贴夸克分享文案 → 解析文件列表 → 点文件取真实直链 → 带请求头下载到本机 → 导出到「文件」App。

## 仓库布局

- 本地目录 `~/workspace/yunx-ios/` 对应仓库 `weiwu080425-code/YunX-Desktop` 的 **ios-port 分支**下的 **ios/ 子目录**。
- `project.yml`（XcodeGen）、`YunX/` 源码目录、`YunX/Info.plist` 都在 ios/ 内。
- `build-ios.yml` 是工作流源文件，由主助手放到仓库根的 `.github/workflows/build-ios.yml`；
  触发：workflow_dispatch + push 到 ios-port 分支；步骤全部 `working-directory: ios`；
  产物未签名 IPA 发到本仓库 Release，tag 为 `ios-build-<run_number>`。
- 构建：macos-15 运行器 → brew install xcodegen → xcodegen generate →
  xcodebuild（iphoneos / Release / CODE_SIGNING_ALLOWED=NO）→ .app 打成 Payload 结构的 YunX-iOS.ipa。
- 安装：未签名 IPA 需用 SideStore / AltStore 侧载（用自己的 Apple ID 重签，免费证书 7 天有效，到期在 SideStore 里续签）。

## 移植的接口（全部来自 Kotlin QuarkApi.kt / QuarkConstants.kt）

| # | 方法与端点 | 用途 | 对应 Kotlin |
|---|---|---|---|
| 1 | GET `https://pan.quark.cn/account/info` | 验证 Cookie、取昵称（设置页「验证 Cookie」） | fetchNickname |
| 2 | POST `https://drive-pc.quark.cn/1/clouddrive/share/sharepage/token?pr=ucpro&fr=pc`，body: pwd_id / passcode / support_visit_limit_private_share=true | 用分享短码+提取码换 stoken | getShareToken |
| 3 | GET `.../1/clouddrive/share/sharepage/detail?pr=ucpro&fr=pc&pwd_id&stoken&pdir_fid&ver=2&force=0&_page&_size&_fetch_banner=0&_fetch_share=0&fetch_relate_conversation=0&_fetch_total=1&_sort=file_type:asc,file_name:asc`（带 Origin/Referer 头） | 分享文件列表，自动翻页（单页 50、按 fid 去重、无新增即停、上限 200 页）；字段 file_name/size/dir/share_fid_token | getShareFiles + 仓库层 listFiles |
| 4 | POST `.../1/clouddrive/file/download?pr=ucpro&fr=pc&sys=win32&ve=3.23.2`，body: fids / fids_token / pwd_id / stoken / speedup_session="" / token="" | **免转存取链**（登录态首选）：不转存直接换直链 | getShareDownloadLinkWithoutSave |
| 5 | 同 4 端点，body 同 4 但不带登录 Cookie（只回带缓存的 __pugs） | **游客取链**（未登录）：约 50MB 上限，响应 Set-Cookie 的 __pugs 捕获后供下载使用 | getGuestShareDownloadLink |
| 6 | GET `.../1/clouddrive/file?pr=ucpro&fr=pc&pdir_fid&page&size` | 个人网盘文件列表（找「YunX临时转存」目录） | getFileList |
| 7 | POST `.../1/clouddrive/file?pr=ucpro&fr=pc`，body: pdir_fid / file_name / dir_path="" / dir_init_lock=false | 创建目录（临时目录及其唯一子目录） | createFolder |
| 8 | POST `.../1/clouddrive/share/sharepage/save?pr=ucpro&fr=pc`，body: pwd_id / stoken / pdir_fid / to_pdir_fid / fid_list / fid_token_list / scene="link" | 转存分享文件（回退流程） | saveShareFile |
| 9 | GET `.../1/clouddrive/task?pr=ucpro&fr=pc&task_id&retry_index=0` | 轮询转存任务（10 次×1 秒；finished_at>0 或 status/task_status==2 为完成；新 fid 在 save_as.save_as_top_fids[0]） | pollTask |
| 10 | POST `.../1/clouddrive/file/download?...`，body: fids=[转存后新 fid] | 转存后取直链（失败响应无 status 字段、用 code 识别，如 21001） | getDownloadLink |
| 11 | GET `.../1/clouddrive/member?pr=ucpro&fr=pc&fetch_subscribe=true&_ch=home` | 空间配额（转存前校验 + 设置页展示） | getQuota |
| 12 | GET `.../1/clouddrive/config?pr=ucpro&fr=pc`（带剥掉 __puus 的 Cookie） | 刷新 __puus/__pus 会话（取链前惰性刷新，90 分钟节流） | refreshSession |
| 13 | POST `.../1/clouddrive/file/delete?pr=ucpro&fr=pc&uc_param_str=`，body: action_type=2 / filelist / exclude_fids | 下载完成后删除临时转存子目录 | deleteFile |

链接识别（ShareLinkParser.swift）只移植了夸克分支：文中第一个 URL 剥尾部标点 →
`pan.quark.cn/s/([A-Za-z0-9]+)` 取短码；提取码先找 URL 的 `?pwd=`，再找文案「提取码/访问码/密码：xxxx」。

下载请求头（对齐 Kotlin ResolveViewModel.enqueueDownload 的夸克分支）：

- `Cookie`：取链用的同一份 Cookie（登录态=刷新后的登录 Cookie；游客=直链自带的 `__pugs=...`），缺了 CDN 返回 412；
- `User-Agent`：与 API 相同的夸克 PC 客户端串（QuarkConstants.API_USER_AGENT）；
- `Referer`：`https://pan.quark.cn/`；
- 直链**原样使用**，不做 CDN 节点改写/探测（QuarkCdn.kt 的结论：改写 host 会命中节点绑定签名 → 412）。

## 取链流程（与 Kotlin 版一致）

1. **登录态**：取链前先按 90 分钟节流刷新 __puus → 优先免转存取链（接口 4）→ 失败自动回退转存：
   空间校验（接口 11，不足直接报「剩余空间不足」）→ 确保「YunX临时转存」目录存在（接口 6/7）→
   建唯一子目录 `tr_<纳秒>_<随机>`（绕开夸克转存去重，避免二次转存返回已删除 fid 导致 21001）→
   转存（接口 8）→ 轮询（接口 9）→ 用新 fid 取链（接口 10）→ 下载完成后删子目录（接口 13）。
2. **游客态**（没存 Cookie）：接口 5 直接取链，仅约 50MB 以内小文件；错误码 23018/31001 有中文提示引导去设置页贴 Cookie。

## 与 Kotlin 版的差异 / 简化

- **Cookie 存储**：Kotlin 桌面版用加密数据库 + 多账号；iOS 版按需求用 UserDefaults **明文**单账号保存，设置页和本说明都已注明。cookieSink 的「按请求 Cookie 找对应账号行回写」简化为单账号直接回写。
- **下载引擎**：Kotlin 版是自研分片并发下载器（Range 分片 + 断点续传 + 多账号多源）；iOS 版用系统后台 URLSession 单连接下载任务——切后台可继续、系统级可靠，但没有分片加速和断点续传（任务失败需重新下载）。这是第一版有意的取舍。
- **__puus 定时刷新**：Kotlin 版有 90 分钟惰性刷新（已移植到取链前）＋响应回写双保险（已移植）；没有移植后台定时器（iOS 后台限制，惰性刷新已够）。
- **空间校验**：只移植了单文件校验（TransferSpaceGuard.ensureEnoughSpace）；批量校验未移植（iOS 版无批量下载）。
- **未移植**：多账号轮换取链/多源分片（实验性 C1/C2）、个人网盘浏览页、创建分享、重命名/移动、视频解析、其他 10 个网盘平台、UC 的同套逻辑（UC 与夸克共用 __puus 体系，本版未做）。
- **错误文案微调**：31001 在 Kotlin 版提示「到网盘页重新登录」，iOS 版改为「到『设置』页重新粘贴 Cookie」（iOS 版无网盘页、无内嵌登录浏览器——JCEF/WebView 登录在 Mac 精简版就已砍掉，iOS 版同样靠手动粘贴 Cookie）。
- **网络错误**：Kotlin 版把 IOException 多包成业务异常；iOS 版直接透传 URLSession 的系统错误描述（断网等场景文案是系统英文/本地化串）。
- 文件落盘同名覆盖（Kotlin 分片下载器是写临时文件再合并，行为近似）。

## 预见的编译风险点（本地无 Xcode，未编译验证）

1. **project.yml / XcodeGen**：`info.path` 指向已存在的 Info.plist 且顶层设了 `GENERATE_INFOPLIST_FILE: NO`——这是常见组合，但不同 XcodeGen 版本对已有 plist 的合并行为略有差异；若生成后 Info.plist 被改写异常，备选是去掉 `GENERATE_INFOPLIST_FILE` 一行让 XcodeGen 全权管理。另外云端默认 Xcode 版本（macos-15 运行器）若变化，`xcodebuild -sdk iphoneos` 一般不受影响。
2. **HTTPCookie 解析 Set-Cookie**：`HTTPCookie.cookies(withResponseHeaderFields:for:)` 要求字段字典是 `[String: String]`，代码里已从 `allHeaderFields` 转换；若服务端把多条 Set-Cookie 合并成一条逗号拼接串，个别 Cookie（Expires 带逗号日期）可能解析不全——__puus/__pus 本身无 Expires 逗号问题，预计可正常捕获，但这是未经真机验证的推断。
3. **后台 URLSession 的完成事件**：未实现 `urlSessionDidFinishEvents(forBackgroundURLSession:)`（需要 UIApplicationDelegate 承接系统回调句柄，SwiftUI 纯 App 结构下未接）。影响：App 被系统杀死后下载在后台完成，重新打开 App 时才会收到完成回调并落盘/更新 UI；下载本身由系统继续执行，不受影响。
4. **Swift 5 模式**：project.yml 固定 `SWIFT_VERSION: 5.0`，规避 Swift 6 严格并发检查；若云端 Xcode 默认新建工程策略变化导致该设置未生效，`DownloadCenter` 的跨线程字典访问（已用 NSLock）与 @Published 主线程更新（已切 main 队列）仍可能触发并发警告（仅警告非错误）。
5. **ShareLink(item:)**：iOS 16 的 Transferable API，URL 直接 conforms；部署目标已定 16.0，无低版本兼容问题。
6. **TextField(axis: .vertical)**：iOS 16 API，部署目标 16.0 可用。

## 文件清单

- `project.yml` — XcodeGen 工程描述（应用名 YunX、bundle id com.weiwu.yunx、iOS 16.0、Swift 5）
- `YunX/Info.plist` — 显示名「云析」、开启文件共享（下载文件在「文件」App 的「云析」文件夹可见）
- `YunX/YunXApp.swift` — @main 入口
- `YunX/ContentView.swift` — 两个 Tab：解析 / 设置
- `YunX/Models.swift` — ShareSession / ShareToken / ShareFile / DownloadLink / QuotaInfo / QuarkError / formatBytes
- `YunX/ShareLinkParser.swift` — 分享文案 → 夸克短码 + 提取码
- `YunX/CookieStore.swift` — Cookie 的 UserDefaults 存储 + __puus/__pus 合并工具
- `YunX/QuarkAPI.swift` — 全部接口 + 取链编排（免转存优先、回退转存、游客）
- `YunX/DownloadManager.swift` — 后台 URLSession 下载中心（进度、落盘、清理回调）
- `YunX/ResolveView.swift` — 解析页（粘贴 → 列表 → 面包屑进文件夹 → 下载 → 导出）
- `YunX/SettingsView.swift` — 设置页（粘贴/保存/验证 Cookie、空间展示）
- `build-ios.yml` — 工作流源文件（放仓库根 .github/workflows/ 用）
- `PORT-NOTES.md` — 本说明

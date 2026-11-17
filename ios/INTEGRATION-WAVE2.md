# 云析 iOS「最终版」第二批平台客户端 — 集成说明（INTEGRATION-WAVE2）

> 本批交付：9 个平台的 Swift 接口客户端（预写，未接 UI），逐行移植自 Kotlin 源码
> `~/workspace/yunx-mac-port/YunX-Desktop/desktop/src/main/kotlin/com/yunx/app/data/network/`。
> 本批**只新建文件、未改任何现有文件、未推送 GitHub**。

## 0. 文件清单

| 文件 | 内容 |
|---|---|
| `YunX/Wave2Common.swift` | 本批共用基础设施（带 `Wave2`/`w` 前缀自包含）：`Wave2Error`、`Wave2HTTP`（跟随/不跟随重定向两套会话，Cookie 全手工）、JSON `opt*` 语义辅助（`wStr/wInt/wLong/wBool/wHas/wObj/wObjs`）、编码（`wFormEncode`=java URLEncoder、`wURIComponentEncode`、`wBase64Decode`、`wJWTBody`）、摘要（`wMD5Hex/wSHA1Hex/wCRC32Hex`）、`wAES`（CommonCrypto，iv=nil→ECB、否则 CBC，PKCS7）、`wGunzip`（gzip 头解析 + Compression 解 deflate） |
| `YunX/XunleiAPI.swift` | 迅雷：常量、设备指纹、网页凭据解析、网页/App 两套 captcha 签名、登录全流程、panCall 重试状态机、分享解析与转存取链编排、中文口令 |
| `YunX/Pan123API.swift` | 123 云盘：签名算法（crc32 + 数字替换表）、账号密码登录、分享列表/取链、个人盘 |
| `YunX/Pan115API.swift` | 115：纯 Swift 大整数 modPow + RSA/XOR 电脑端加解密、分享 snap/downurl、转存兜底、个人盘 |
| `YunX/C139API.swift` | 139 移动云盘：外链详情（匿名）、AES-CBC + mcloud-sign 取链、Cookie 提取授权 |
| `YunX/GuangYaAPI.swift` | 光鸭：设备生成、账号登录/刷新、分享（密码校验/游标分页）、207 受限转存编排、个人盘 |
| `YunX/LanzouAPI.swift` | 蓝奏：acw_sc__v2 挑战、个人盘（粘贴 Cookie）、匿名分享页解析全链路 |
| `YunX/ILanzouAPI.swift` | 蓝奏优享：AES/ECB hex 签名、账号登录、个人盘、匿名分享、转存 |
| `YunX/GitHubAPI.swift` | GitHub：链接解析、REST API（可选 Token）、镜像测速、fid 浏览层（GitHubBrowse） |
| `YunX/StarSeaAPI.swift` | 星海：口令 → 夸克/UC 分享链接（仅 parse 步） |

## 1. 集成层必须先做的事（本批未动这些文件）

1. **Models.swift**：`SharePlatform` 需新增 case：`xunlei / pan123 / pan115 / c139 / guangya / lanzou / ilanzou / github / starsea`（含 displayName/shortName/rootDirKey）。注意 `Models.ShareSession` 带必填 `platform` 字段，所以本批各客户端**各自带平台私有会话结构体**（如 `Pan115API.ShareSession`、`C139API.ShareSession`、`XunleiAPI.ShareSession`、`GitHubSession`），集成层在 ResolveView 里把它们映射成 `Models.ShareSession`。
2. **ShareLinkParser.swift**：现仅识别夸克/UC/百度。按第 2 节的规则表扩展（**顺序敏感：蓝奏优享必须排在蓝奏之前**；GitHub 走独立的 `GitHubLinkParser.parse`；星海/迅雷口令是非 URL 文本，走启发式判定）。
3. **CookieStore**：为新平台加凭据键（建议）：`xunlei`（网页凭据 JSON 或 token 对 + authType + deviceId）、`pan115`（登录 Cookie 整串）、`c139`（登录 Cookie 整串）、`lanzou`（登录 Cookie 整串）、`ilanzou`（appToken + uuid）、`guangya`（access/refresh token + device）、`pan123`（token）、`github`（可选 Token）。
4. **ResolveView / DownloadManager**：取链后把各平台的下载请求头（第 3~11 节逐个列明）传给 `DownloadCenter.start(urlString:filename:fileKey:headers:cleanup:)`；115/光鸭/迅雷转存类直链要在下载完成回调里执行清理（115 调 `cleanupTempDir`、光鸭删临时目录、迅雷已在取链时即时删除无需清理）。
5. **project.yml**：新文件都在 `YunX/` 目录下，若用 XcodeGen 的 sources 目录扫描则自动纳入；逐文件列举时需补这 10 个文件。

## 2. 链接识别规则（源自 Kotlin ShareLinkParser，集成到 ShareLinkParser 时用）

通用：取文中第一个 `https?://[^\s]+`，剥尾部 `。，,；;)]}"'`；提取码先取 URL 的 `?pwd=`，否则匹配文案 `(?:提取码|访问码|密码)[：:]\s*([A-Za-z0-9]{4,8})`。

| 平台 | 正则 / 规则 | 备注 |
|---|---|---|
| 迅雷 | `pan\.xunlei\.com/s/([A-Za-z0-9_-]+)` | 提取码参数名 `pwd` |
| 123 | `123(?:865\|pan)\.(?:com\|cn)/s/([A-Za-z0-9]+-[A-Za-z0-9]+)`；另 `share\.123pan\.cn/123pan/([A-Za-z0-9-]+)`、`api/srr\?sk=([A-Za-z0-9-]+)` | shareKey 含连字符 |
| 115 | `115(?:cdn\|rc)?\.com/s/(sw[A-Za-z0-9]+)`；命令式 `115(?:cdn\|rc)?\.com/(sw[A-Za-z0-9]{8,})-([A-Za-z0-9]{4,8})` | 提取码参数名是 `password=`，不是 `pwd` |
| 139 | `yun\.139\.com/shareweb/.*?/w/i/([A-Za-z0-9_-]+)` | linkId |
| 光鸭 | `guangyapan\.com/s/([A-Za-z0-9_-]+)` | |
| 蓝奏优享 | `(?:^|[/.])ilanzou\.(?:com\|net\|org\|cn)/s/([A-Za-z0-9_-]+)` | **必须排在蓝奏之前**；提取码参数名可为 pwd/pass/passcode/password |
| 蓝奏 | `(?:^|[/.])(?:lanzou[a-z0-9-]*\|lan[zs]o[ux])\.(?:com\|net\|org\|cn)/([A-Za-z0-9]+)` | 前导边界强制（防 ilanzou 误判）；镜像域名很多，靠域名特征而非固定 host |
| GitHub | 独立解析器 `GitHubLinkParser.parse`（见第 10 节） | 不在 ShareLinkParser 主链 |
| 星海 | 非链接：文本非空、≤120 字、且不含 `http://`/`https://` | `StarSeaAPI.looksLikeCommand` |
| 迅雷口令 | 非链接文本：`XunleiKouling.looksLikeKouling`（≤64 字、仅汉字/字母/数字、至少 1 个汉字） | 与星海冲突时先判迅雷口令还是星海由集成层定序（两者都是纯文本口令，建议先迅雷口令、失败再星海，或给用户平台选择） |

---

## 3. 迅雷（XunleiAPI.swift）

**凭据要求（用户要提供什么）**：两种通道，二选一——
- **网页凭据（推荐）**：用户在电脑浏览器登录 pan.xunlei.com 后，从 localStorage 复制 `credentials_Xqp0kJBXWhwaTpB6` 的整段 JSON 粘贴进来（也支持被引号包起的 JSON 字符串、或裸 access_token 兜底）。用 `XunleiWebCredential.parse(_:) -> XunleiWebTokens?` 解析；落库时记 `authType = "webToken"`，并把 `useWebCaptchaChannel = true`。
- **App 通道**：应用内账号密码登录（`loginWithPassword` → 多半触发短信 → `sendSms`/`smsLogin` → `initCaptcha` + `exchangeToken`），得到 (access, refresh) token 对。
- 身份三件套必须同源：accessToken + deviceId + captchaToken 必须同账号同通道。deviceId 用 `XunleiAPI.newDeviceId()`（首次生成 32-hex 后持久化在 UserDefaults，集成层也可以把网页凭据里的 device_id 存下来优先用）。
- Token 保活：调用前用 `ensureFreshToken(accessToken:refreshToken:deviceId:authType:)` 预检（JWT exp <60s 自动按通道刷新，刷不动抛「迅雷登录已过期，请重新登录」）；panCall 内部另有 401/captcha_invalid 自动重试，靠集成层注入 `refreshTokenProvider`（刷新成功后集成层负责落库新 token 对）。

**入口签名**：
- 会话：`createSession(shareId:passCode:accessToken:deviceId:captchaToken:) async throws -> XunleiAPI.ShareSession`（stoken = pass_code_token）
- 列根：`listShareRoot(shareId:passCode:accessToken:deviceId:captchaToken:) async throws -> [ShareFile]`（page_token 内部翻完）
- 列子目录：`listShareDir(shareId:parentId:passCodeToken:accessToken:deviceId:captchaToken:) async throws -> [ShareFile]`
- 取链：`resolveDownloadLink(shareId:passCodeToken:file:accessToken:deviceId:captchaToken:) async throws -> (link: DownloadLink, headers: [String: String])`（必须登录：转存到「YunX临时转存」→ getFileDetail → 立即 batchDelete 转存文件）
- 口令：`XunleiKouling.looksLikeKouling(_:)` + `parseKouling(keyword:) async throws -> String`（返回带 pwd 的分享链接，再走普通分享流程）
- 游客列目录可不登录（accessToken 传 ""，走 panCallAnonymous）；**下载必须登录**。

**下载请求头**：只有 `User-Agent: <APP_UA>`（`XunleiAPI.downloadHeaders()`）。浏览器 UA 会触发 CDN 降级，切勿附加其他头。

**与 Kotlin 的差异/简化**：
- 未移植个人盘管理类接口：renameFile / moveFile / createShare（分享解析用不到；getFiles/createFolder/getFileDetail/batchDelete/deleteFiles/getQuota/ensureTempDir/pollTask 已移植）。
- Kotlin 的 `webCaptchaRefresher` 由账号仓库实现（本地签名失败回退无头网页会话）；iOS 无无头浏览器回退，改为：注入 refresher 优先，否则 `useWebCaptchaChannel=true` 时直接本地 9 盐签名（`initWebCaptcha`），再否则 App 通道 `initPanCaptcha`。盐/版本轮换导致签名被拒时，只能让用户重新粘贴网页凭据（captcha_token 在凭据 JSON 里有就先用它）。

**编译/运行风险点**：
- panCall 是泛型 + 闭包重演 Kotlin 的重试状态机（401 刷新、captcha_invalid 重签各只重试 1 次），集成时注意 `refreshTokenProvider` 必须是 async 闭包且内部落库，否则每次请求都会先吃一次 401。
- captcha 签名盐（App 10 条、网页 9 条）与版本号（App `8.31.0.9726`、网页 `1.93.10`）逐字复制自源码；网页盐约 20 天轮换一次，失效表现是 captcha_invalid 循环，此时需更新源码盐值。
- `XunleiDeviceFingerprint` 的 deviceSign 公式 `div101.<id><md5(sha1(id+包名+40+appkey))>` 已按源码实现；fallback 官方指纹只在 UserDefaults 读不到时用。

## 4. 123 云盘（Pan123API.swift）

**凭据要求**：列表（分享）**匿名可用**；**取直链必须登录 token**。登录方式：应用内账号+密码（`passwordLogin(account:password:) async -> LoginResult`，密码不 trim、账号 trim，与源码一致），或粘贴 token。设置页放「账号/密码」或「粘贴 token」二选一即可（源码没有 Cookie 登录形态）。

**入口签名**：
- 会话：`createSession(shareKey: String, pwd: String?) async throws -> Pan123API.ShareSession`
- 列目录：`listAllShareFiles(session: ShareSession, dirFid: String) async throws -> [ShareFile]`（根 dirFid 传 "0"；单页 `getShareFiles(shareKey:sharePwd:parentFileId:next:)`）
- 取链：`getShareDownloadLink(shareKey: String, file: ShareFile, token: String) async throws -> DownloadLink`（DownloadURL 可能是整段 base64 或 download-v2 的 `?params=` 形态，内部已处理 ≤5 跳 redirect_url 跟随）
- fidToken 编码 `S3KeyFlag|Etag|StorageNode`，`decodeToken(_:)` 可拆。

**下载请求头**：`User-Agent: Pan123API.webUA`（Chrome/127）+ `Referer: Pan123API.downloadReferer`（`https://yun.123pan.cn/`）。

**与 Kotlin 的差异/简化**：loginuuid 持久化在 UserDefaults 键 `pan123_loginuuid`（Kotlin 是本地文件）；登录失败文案走 `Pan123LoginSupport` 等价映射（`describeLoginFailure`），不回显服务端原文。

**风险点**：签名 `makeSign(path:ts:)` 的时间基准是 `ts + 57600` 后取 UTC `YYYYMMDDHHmm` 再做 crc32 与数字→字母替换（SIGN_TABLE），集成时不要改成本地时区；sign 的 path 含 `/b` 前缀、不含 host/query。

## 5. 115（Pan115API.swift）

**凭据要求**：**粘贴登录 Cookie**（浏览器登录 115.com 后整串 Cookie 粘贴；至少含 `UID`、`SEID`，最小可用集 UID/CID/SEID/KID）。用 `Pan115API.filterLoginCookies(_:)` 过滤、`isValidCookie(_:)` 粗检、`fetchNickname(cookie:)` 真校验。分享列表匿名可看（cookie 传 ""），但大文件取链要靠登录 Cookie 走电脑端接口。

**入口签名**：
- 会话：`createSession(shareCode: String, receiveCode: String, cookie: String) async throws -> Pan115API.ShareSession`（含分享者 userId、receiveCode、title）
- 列目录：`listAllShareFiles(session: ShareSession, dirFid: String, cookie: String) async throws -> [ShareFile]`（根 dirFid "0"，offset 分页内部翻完）
- 取链：`resolveDownloadLink(session: ShareSession, file: ShareFile, cookie: String) async throws -> (link: DownloadLink, headers: [String: String])`（先网页 share/downurl；失败且有登录 Cookie → 临时转存 + 电脑端加密接口；link.cleanupDirFid 非空时下载完成后调 `cleanupTempDir(dirFid:cookie:)`）
- 个人盘：`listFiles(cid:cookie:offset:limit:) -> FilePage`、`getDownloadLink(file:cookie:)`（电脑端优先、网页兜底）

**下载请求头**：`Cookie: mergeCookies(登录Cookie, link.guestCookie)`、`User-Agent: Pan115API.clientUA`（115Browser 版本号，进程内自动从 appversion 接口刷新一次，兜底 36.0.1）、`Referer: https://115.com/`。guestCookie 是取链响应 Set-Cookie 里 path≠/ 的那条 CDN Cookie，**缺它直链 403**，resolveDownloadLink 已拼好 headers，集成层原样透传即可。

**与 Kotlin 的差异/简化**：
- 会话用结构体（Kotlin 编排层把 receiveCode 与 userId 拼成一个字符串 stoken，这里拆开存字段，语义更清晰）。
- `delete` 对 errno=800007 的二次确认重发未做（直接带 `ignore_warn=1` 发一次）；若实测删除失败再补。
- 客户端版本只在进程内拉一次（Kotlin 同）。

**编译/运行风险点（本批最高风险）**：
- **RSA modPow 是纯 Swift 手写大整数**（`W2BigUInt`，Foundation 无 BigInt）：逐位长除法模约简，1024 位 × 128 字节分块，功能正确性**必须在真机/模拟器上用 Kotlin 的已知向量对拍**（拿一段 Kotlin `Pan115Crypto.encode` 的输入输出比对 Swift 版 encode/decode 往返）。性能：单块 modPow 约 1024 次 mulMod（2048 位长除法），毫秒~十毫秒级，一次取链 1~2 块，可接受；批量取链多文件时会叠加。
- PKCS#1 v1.5 填充按 Kotlin 复刻：整块先填 0xFF、block[0]=0、block[1]=2、分隔 0x00 在 `128-size-1` 处（注意 Kotlin 用的是 0xFF 填充而非随机数，与标准 PS 随机填充不同，照抄即可，服务端按同法解）。
- 对称层 deriveKey/xorTransform 有 `len % 4` 前缀怪癖，已逐行对照 Kotlin；响应先剥前 16 字节 salt 再解，顺序勿改。
- `clientUA` 是 `static var`（刷新后全局生效），并发下无锁——与 Kotlin 的 @Volatile 语义近似，iOS 侧可接受。

## 6. 139 移动云盘（C139API.swift）

**凭据要求**：列表**匿名可用**；取直链需登录态。用户提供：**粘贴登录 Cookie**（yun.139.com 网页登录后的整串 Cookie），客户端从中提取 `authorization=` 的 Basic 值（`C139API.credential(fromCookie:)`），账号从 `ORCHES-I-ACCOUNT-ENCRYPT`（base64）或 `Login_UserNumber=` 解。提取不到 authorization 即视为未登录。设置页说明文案：「粘贴 139 网页版登录后的 Cookie」。

**入口签名**：
- 会话：`createSession(linkId: String, passwd: String) async throws -> C139API.ShareSession`（stoken = passwd）
- 列目录：`listShareFiles(linkId: String, passwd: String, parentId: String, account: String = "") async throws -> [ShareFile]`（根 parentId 传 `"root"`；内部 200 条步进翻完；文件夹 fid 来自 caLst、文件来自 coLst，coType==2 也是文件夹）
- 取链：`getDownloadLink(linkId: String, file: ShareFile, credential: C139API.Credential) async throws -> DownloadLink`（OBS 预签名链，900 秒有效，过期重取）
- 标题/提取码兜底：`getShareGeneral(linkId:)`（匿名，能拿到 lkName 与明文 passwd）

**下载请求头**：只有 `User-Agent: C139API.pcUA`（Chrome/120）。注意与接口调用的移动端 UA 不是一个，别混用。

**与 Kotlin 的差异/简化**：个人盘接口（personal-kd-njs 的 hcy/file/list 等，带全套 x-yun-* 渠道头）未移植——分享解析用不到；转存任务接口（IBatchOprTask 转存类）未移植，139 分享是直链直下、不需要转存。

**风险点**：
- mcloud-sign 的随机数在一次签名内必须同值（md5 输入与拼头共用），已按此实现；签名对象是**加密后的 base64 文本**、先 encodeURIComponent 再按字符排序，顺序勿改。
- 响应解密后可能还要 gunzip（密文后追加 gzip 段）：已处理魔数判定；`wGunzip` 对超大响应有 64MB 上限，139 响应是小 JSON，无碍。
- 时间戳格式 `yyyy-MM-dd HH:mm:ss` 用本机时区（与源码一致，源码就是本地时间），集成时别改成 UTC。

## 7. 光鸭（GuangYaAPI.swift）

**凭据要求**：分享列表/取链的主路径需要**分享 accessToken**（由分享码+提取码换，`getShareAccessToken`）；受限文件（207）兜底转存需要**账号登录态**。登录方式：应用内账号+密码（`signIn(username:password:device:)`，含 captcha 重试 ≤2 次），token 对（access/refresh）由集成层落库；设备 `Device` 用 `GuangYaAPI.newDevice()` 生成一次后持久化（did 必须与登录时一致）。设置页放「光鸭账号/密码」登录表单，不支持粘贴 Cookie（源码无此形态）。

**入口签名**：
- 会话：`createSession(shareId: String, pwd: String?) async throws -> GuangYaAPI.ShareSession`（内含分享 accessToken；提取码错误 code 209 在 getShareAccessToken 抛）
- 列目录：`listAllShareFiles(session: ShareSession, parentId: String) async throws -> [ShareFile]`（游标分页，单页 `listShareFiles(accessToken:parentId:cursor:) -> (files, nextCursor)`）
- 取链：`resolveDownloadLink(session: ShareSession, file: ShareFile, accountToken: String?) async throws -> DownloadLink`（207 受限且有账号 token 时：建临时目录 `AsterLink临时转存_<UUID>` → restoreShare → 轮询新文件 → 个人盘取链，link.cleanupDirFid = 临时目录，下载完集成层调 `deleteFiles` 清理）
- 个人盘：`listCloudFiles(accessToken:parentId:)`、`getDownloadLink(accessToken:file:)`

**下载请求头**：`User-Agent: GuangYaAPI.webUA` + `Referer: GuangYaAPI.downloadReferer`（`https://www.guangyapan.com/`）。不带 Authorization/Cookie（源码实证）。

**与 Kotlin 的差异/简化**：短信登录全流程（sendSmsCode/verify/smsSignIn/smsSignUp）未移植（账号密码登录够用）；签到等杂项接口未移植。

**风险点**：业务请求头 did/dt=4/traceparent 必带，did 取登录设备 → 注入的 `loggedInDeviceId` → 进程级匿名 `publicDeviceId` 的回退链别打乱；deviceSign 是 `wdi10.<id><32hex>` 形态，`deviceIdFromSign` 反解已移植。

## 8. 蓝奏（LanzouAPI.swift）

**凭据要求**：匿名分享**不需要凭据**。个人盘需要**粘贴登录 Cookie**（lanzou 网页登录后整串 Cookie），再调 `fetchLoginParams(cookie:) -> LoginParams`（从 mydisk.php 正则提取 uid/vei）。⚠️ 与 Kotlin 的差异：Kotlin 还有账号密码原生登录（accounts.woozooo.com），**本批未移植**——iOS 侧只支持粘贴 Cookie，设置页文案要写清「粘贴蓝奏网页登录 Cookie」。

**入口签名**：
- 分享：`resolveShare(shareUrl: String, pwd: String?) async throws -> LanzouAPI.SharePage` → 文件夹用 `listShareFolder(page: SharePage, pwd: String?) async throws -> [ShareFile]`（fid 前缀 `d:`=文件夹、`f:`=文件，根文件夹 id 为 `-1`）
- 取链：`getShareDownloadLink(page: SharePage, file: ShareFile, pwd: String?) async throws -> (link: DownloadLink, headers: [String: String])`（内部含 iframe/wp_sign/ajaxm 全链路、acw 挑战重试、「验证并下载」提交，含 2 秒等待）
- 个人盘：`listCloudFiles(cookie:uid:vei:folderId:) async throws -> [ShareFile]`；个人文件取链 `getPersonalDownloadLink(cookie:uid:vei:fileId:fileName:)`（先 task=22 生成分享再走匿名链路，与源码同策略）

**下载请求头**（getShareDownloadLink 已拼好，集成层透传）：`User-Agent: LanzouAPI.webUA`（Chrome/131）、`Referer: <直链域名 origin>/`、`Cookie: down_ip=1`（并合并流程中 jar 里的 Cookie）。

**与 Kotlin 的差异/简化**：见上（无账号密码登录）。acw_sc__v2 挑战算法（POS 表 + MASK）已逐字移植，cookie jar 为进程内按 host 隔离的内存实现（Kotlin 是 OkHttp CookieJar 等价物）。

**风险点（本批第二高风险）**：
- 蓝奏全靠 **HTML 页面正则刮取**（NSRegularExpression 与 Kotlin Regex 在贪婪/懒惰与 Unicode 语义上大体一致，但个别模式如 iframe src、wp_sign 提取需真机对真实分享页验证）；域名镜像众多（lanzou*、lanzo* 变体），host 判定用 `isLanzouHost`/`normalizeShareUrl`，勿写死单一域名。
- 分享文件夹分页 zt 语义（1 成功/2 空/3 无权限/4 失败）在 `listShareFolder` 内已映射错误文案。
- 取链末段有 HEAD 探测 + Range 兜底 + acw 挑战三段回退，耗时可达数秒，UI 需给加载态。

## 9. 蓝奏优享（ILanzouAPI.swift）

**凭据要求**：分享**匿名可用**；个人盘/转存需登录。登录方式：应用内账号+密码（`getUuid()` → `login(loginName:loginPwd:uuid:) async throws -> String` 返回 appToken）。uuid 是设备标识（格式 `^[A-Za-z0-9_-]{8,128}$`），集成层生成一次后持久化并全程复用。设置页放「蓝奏优享账号/密码」表单，不支持粘贴 Cookie（源码登录形态如此）。

**入口签名**：
- 分享列目录：`shareList(shareId: String, folderId: String?, uuid: String) async throws -> [ShareFile]`（根 folderId 传 nil；fid 前缀 `d:`/`f:`，根目录 id 语义为 `0`；分页 PAGE_SIZE=60 内部处理）
- 分享取链：`shareDownload(shareId: String, fileId: String, userId: String, uuid: String) async throws -> DownloadLink`（未登录 userId 传 ""；内部处理 302 Location 或 JSON url）
- 个人盘：`listFiles(appToken:uuid:folderId:)`、`getDownloadLink(appToken:uuid:fileId:userId:)`、转存 `transferShare/transferCount`

**下载请求头**：`User-Agent: ILanzouAPI.webUA`（Chrome/131）+ `Referer: ILanzouAPI.downloadReferer`（`https://www.ilanzou.com/`）+ `Origin: https://www.ilanzou.com`。

**与 Kotlin 的差异/简化**：无功能删减（分享/个人盘/转存/配额都在）。⚠️ **源码里 ILanzou 的分享接口根本不传提取码**——ShareLinkParser 能解析出 pwd，但 shareList/shareDownload 没有 pwd 参数；遇到带密码的优享分享若接口报错，需回查 Kotlin 后续版本，本批按源码如实实现并在此标注。

**风险点**：auth/downloadId/timestamp 用 AES/ECB/PKCS7（key `lanZouY-disk-app`）加密后转小写 hex，已用 `wAESECBHex` 实现；请求必须带全套 Chrome client-hints 头（sec-ch-ua 等），缺了 WAF 返回空列表——已在客户端内固定带上，集成层勿覆盖 UA；409+text/html 是访问挑战，客户端内自动重试 1 次。

## 10. GitHub（GitHubAPI.swift）

**凭据要求**：**无需登录**。可选粘贴 Personal Access Token 提升限额（匿名 60 次/时 → 5000 次/时）：设置页一个 token 输入框，保存前先 `validateToken(_:) async -> GitHubTokenCheck` 校验（401=无效别落库），运行时 `GitHubAPI.shared.token = ...` 注入；若使用中被 401，`onUnauthorized` 回调触发一次，集成层应清掉 token 恢复匿名。

**链接识别**：独立 `GitHubLinkParser.parse(_:) -> GitHubLinkType?`，优先级 DirectFile > Repository > Account：
- DirectFile：`raw.githubusercontent.com/{o}/{r}/{branch}/{path}`、`github.com/{o}/{r}/releases/download/{tag}/{file}`、`github.com/{o}/{r}/raw/{branch}/{path}`
- Repository：`github.com/{o}/{r}`（含子路径；subPath 与源码一致被忽略、统一进仓库根）
- Account：`github.com/{o}`；owner 在功能页集合（features/topics/trending/…/resources，共 25 个）时返回 nil

**入口签名**（浏览层 `GitHubBrowse`，fid 方案与 Kotlin 编排层逐字一致）：
- 打开：`open(link: GitHubLinkType) async throws -> OpenResult`（session/rootFid/directLink；直链直接给 DownloadLink 不进列表）
- 列层：`listDir(fid: String) async throws -> [ShareFile]`——`github:root`（代码+Releases 两项）、`github:code:<sha|默认分支>`、`github:releases`、`github:release:<tag>`、`github:more_rel:<页>`、`github:account_root`、`github:more_acct:<页>`、`github:repo:<fullName>`（切换仓库回根）
- 取链：`downloadTarget(for file: ShareFile) -> (url: String, fallbackUrl: String)?`——url 已拼镜像前缀，fallback 是未镜像原链（镜像挂了集成层回退）；`github:zip`→codeload、`github:file:<path>`→raw.githubusercontent（路径逐段 wFormEncode）、`github:asset:<url>`→原样
- 批量收集：`collectAllFiles(sha:) async -> [(path, size)]`（递归 tree，深度上限 32）

**下载请求头**：无特殊头（镜像 URL 直下）。

**与 Kotlin 的差异/简化**：
- **缓存简化**：Kotlin 是 GitHubResponseCache/GitHubCommitDateCache（带 token 指纹 key、失败短 TTL、401 清缓存）；这里是进程内内存缓存（成功 120 秒、key 含 token 的 md5 指纹、401 清空并回调），失败不缓存。影响：重复进出目录会多打几次 API，匿名 60 次/时限额下批量补时间（getLastCommitDate）要节流——Kotlin 编排层有 Semaphore(8) 限流，集成层若做「每项补提交时间」需同样限流，或干脆不补（本批浏览层未自动补时间，modifyTime 用仓库 pushedAt/资产 updatedAt 等已有字段）。
- **镜像测速无 ping**：Kotlin 用 OkHttp EventListener 量 TCP 建连耗时作展示，URLSession 无等价回调；`GitHubMirror.refresh()` 只测吞吐（Range 拉 256KB 样本、响应头到达后计时），`Probe` 只有 speedBps。生效规则不变：用户固定前缀（`GitHubMirror.userFixedPrefix`，存 UserDefaults）> 测速最快（持久化）> 预选池第一个（`https://v4.gh-proxy.org/`）。
- README（`getReadme`）已移植但浏览层未自动加载，集成层按需调。

**风险点**：`encodePath` 用 URLEncoder 语义逐段编码，空格会变 `+`（与 Kotlin 的已知怪癖一致，raw 域名下 `+` 在路径里会被当字面加号——源码如此，勿擅自改成 %20，除非真机验证出问题再两边一起改）。

## 11. 星海（StarSeaAPI.swift）

**凭据要求**：无（用的是上游开源 App 自带的公开 API Key，已按源码内置；该 Key 出现在公开源码中，此处仅随移植带入，不在 UI 展示）。

**形态说明**：星海不是网盘，是「口令 → 分享链接」的转换器（夸克/UC 二选一）。流程：粘贴文本若 `looksLikeCommand(_:)`（非空、≤120 字、无 http 链接）→ `resolveToShareLink(command:passcode:) async throws -> String` 得到 `pan.quark.cn/s/...` 或 `drive.uc.cn/s/...` 链接 → 交回夸克/UC 既有解析流程。失败文案按 HTTP 状态码映射（400/401/413/429/404）在客户端内完成；命令原文不打日志（源码要求）。

**下载请求头**：不适用（最终走夸克/UC 的下载头）。

**与 Kotlin 的差异**：无（只实现了源码的 step=parse；源码本身没有更多步）。

---

## 12. 全局编译风险清单（集成时优先处理）

1. **115 大整数 modPow**（`W2BigUInt`）：无第三方库可比对，上线前必须做 Kotlin↔Swift 向量对拍（encode 往返 + 一次真实大文件取链）。
2. **CommonCrypto 桥接**：`Wave2Common` 用 `import CommonCrypto`——Swift 在 iOS SDK 下可直接 import；若 Xcode 版本较老需桥接头，报错时改走模块映射。Compression 同理（`import Compression` 为系统模块）。
3. **蓝奏 HTML 正则**：NSRegularExpression 与 Kotlin Regex 的细微差异（尤其 `.` 是否匹配换行、懒惰量词边界），需用真实分享页（单文件/文件夹/带密码/需验证四种）逐一真机验证。
4. **迅雷 panCall 泛型闭包**：`panCall<T>(build:parse:)` 的 build 闭包捕获 token 参数重建请求，集成层若在闭包里捕获了会变的 token 值会绕过刷新机制——务必用闭包参数 `t` 构造请求（客户端内部方法已按此写）。
5. **并发**：各 API 的 `shared` 单例含少量可变状态（115 clientUA、迅雷 captcha 缓存/token、蓝奏 cookie jar、GitHub 缓存），都用了锁或串行假设；Swift 6 严格并发模式下可能报 Sendable 警告，必要时给这些类加 `@unchecked Sendable` 或改 actor（功能不受影响）。
6. **URL 构造**：多处用字符串拼 URL 且 `Wave2HTTP.request` 内部对 URL(string:) 强解包——shareId/路径等已按源码做 form 编码，但集成层传入未经解析的原始用户文本前，必须先过 ShareLinkParser 提取短码，不要整段 URL 直传客户端（GitHub 除外，走 GitHubLinkParser）。
7. **超时**：`Wave2HTTP` 45s/60s；蓝奏取链含 2s 服务端等待、139 直链 900 秒有效期、迅雷 pollTask 最长 15s，UI 层超时提示按平台放宽。

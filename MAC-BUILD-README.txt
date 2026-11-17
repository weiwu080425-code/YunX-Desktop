云析 YunX-Desktop —— Mac 精简版本地构建步骤（macOS arm64）
========================================================

这个源码包已经改过 Mac 适配（官方原版只有 Windows 版）。
精简版保留：粘贴网盘分享链接 → 解析 → 内置下载器高速下载。
精简版没有：内嵌浏览器登录（改用手动粘贴 Cookie）、视频预览、
Gopeed 下载引擎、一键导入浏览器 Cookie。

第 0 步：装 JDK 17
------------------
打开「终端」（启动台 → 其他 → 终端），先敲：
    java -version
如果显示 17.x 就跳过这步。否则去下载 Temurin 17 的 macOS aarch64 版 .pkg 安装包：
    https://adoptium.net/temurin/releases/?version=17
选 Operating System = macOS，Architecture = aarch64，Package Type = JDK，
下载 .pkg 后双击安装。装完重新开一个终端窗口，再敲 java -version 确认是 17。

第 1 步：解压源码
----------------
把 YunX-mac-source.zip 放到桌面，双击解压，得到文件夹 YunX-Desktop。

第 2 步：构建（第一次会下载很多依赖，耐心等，别关终端）
------------------------------------------------------
在终端里依次敲（每行回车）：
    cd ~/Desktop/YunX-Desktop
    chmod +x gradlew
    ./gradlew :desktop:createDistributable

看到 BUILD SUCCESSFUL 就是构建成功。
中途如果报错，把终端里最后 20 行原样拍下来/复制发给 Muse。

第 3 步：把应用放到桌面
------------------------
构建产物在：
    YunX-Desktop/desktop/build/compose/binaries/main/app/YunX-Desktop.app
在访达里找到它，把 YunX-Desktop.app 拖到桌面（或应用程序文件夹）。

第 4 步：第一次打开
------------------
双击如果提示“无法验证开发者”，不要点取消：
右键点 YunX-Desktop.app → 打开 → 在弹窗里再点“打开”。
只需要这样做第一次。

第 5 步：实测三件事（测完告诉 Muse 结果）
------------------------------------------
1. 粘贴一条夸克或百度网盘分享链接，能不能解析出文件列表
2. 选一个文件，能不能开始下载、速度怎么样
3. 需要登录的网盘，用“手动粘贴 Cookie”的方式登录能不能进

# YunX macOS 移植

本仓库新增原生 SwiftUI macOS 客户端，来源于 [CYQawa/YunX Android 项目](https://github.com/CYQawa/YunX)，并继续按 GNU AGPL-3.0 发布。上游版权与许可证文本保留在仓库根目录。

## 当前状态

这是早期移植版本，不是 Android 版的功能等价替代品。当前可用范围：

- 粘贴夸克或 UC 网盘分享链接（支持链接 `pwd` 或附带“提取码：xxxx”文案），解析分享文件列表并浏览子目录
- 逐个选择分享文件获取下载地址并加入本机下载队列
- 夸克游客态可尝试下载小文件；服务端有大小/频率限制（上游观察约 50 MB，实际以服务端响应为准）
- UC 支持匿名解析/列目录及尝试游客取链；个别文件可能要求登录或受服务端限制
- 分别通过应用内临时 WebKit 窗口登录夸克或 UC；Cookie 独立保存到 macOS 钥匙串，并用于登录态取链/下载
- 网盘签名下载地址及其请求头存入钥匙串，不写入普通下载任务 JSON；带鉴权信息或签名地址的任务暂停后会从头重试，以免将 URLSession 恢复数据中的会话信息写入明文任务文件
- 查看下载进度、暂停/继续、失败后重试和从队列移除
- 完成后在 Finder 中定位文件
- HTTPS 直链下载（拒绝明文 HTTP 与 HTTPS 降级重定向）

尚未移植：迅雷、百度、123、115、139、光鸭、蓝奏云/蓝奏云优享版等网盘的分享解析与账号流程；视频/图集解析与预览、Range 分片、可靠的跨进程恢复未完成下载、Android 专属服务及 Gopeed 集成。下载服务器也可能不支持 URLSession 的续传数据，因此暂停后是否能从断点继续取决于服务器响应。夸克与 UC 流程均依据上游接口重写，平台接口变化可能导致解析失效；当前使用离线 API 冒烟测试验证，尚未用真实账号/分享链接完成端到端验收。

## 构建与运行

要求：macOS 13 或更新版本、Xcode Command Line Tools、Swift 6 工具链。

在仓库根目录执行：

```bash
swift build
swift run YunXMac
```

构建 `.app` 包：

```bash
bash Scripts/package-macos.sh
open macos-build/YunX.app
```

当前产物未签名、公证；首次打开时 macOS 可能显示安全提示。下载文件默认保存到 `~/Downloads/YunX Downloads`，可在应用中更改。下载任务元数据保存在 `~/Library/Application Support/YunX/downloads.json`；夸克/UC 账号 Cookie、签名下载地址和鉴权请求头放在 macOS 钥匙串中，避免写入此 JSON。

离线冒烟测试（夸克与 UC 分别覆盖链接/提取码解析、模拟 API 响应映射、Cookie 刷新/访客态与 HTTPS 直链校验；夸克另验证签名 URL 不写入任务 JSON）：

```bash
swiftc -swift-version 5 Sources/YunXMac/DownloadJob.swift Sources/YunXMac/QuarkAPI.swift Tests/QuarkShareParserSmoke.swift -o /tmp/yunx-quark-smoke
/tmp/yunx-quark-smoke
swiftc -swift-version 5 Sources/YunXMac/UCAPI.swift Tests/UCShareParserSmoke.swift -o /tmp/yunx-uc-smoke
/tmp/yunx-uc-smoke
```

## 项目关系与许可

本仓库从 Android 上游项目派生，未修改上游所有者的仓库。README 中提到的 `tidain/YunX-Desktop` 是独立维护的 Windows 桌面版，本移植与该项目无隶属或发布关系。适用许可为 [GNU AGPL-3.0](./LICENSE)。

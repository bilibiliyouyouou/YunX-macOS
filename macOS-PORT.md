# YunX macOS 移植

本仓库新增原生 SwiftUI macOS 客户端，来源于 [CYQawa/YunX Android 项目](https://github.com/CYQawa/YunX)，并继续按 GNU AGPL-3.0 发布。上游版权与许可证文本保留在仓库根目录。

## 当前状态

这是早期移植版本，不是 Android 版的功能等价替代品。当前可用范围：

- 粘贴 HTTP/HTTPS 文件直链并下载到选择的文件夹
- 查看下载进度、暂停/继续、失败后重试和从队列移除
- 将下载队列与状态保存在本机
- 完成后在 Finder 中定位文件
- 识别部分已知分享站点，并明确提示这些站点的登录和解析功能尚未迁移

尚未移植：网盘/视频平台账号登录、分享链接解析、视频/图集解析与预览、Range 分片、跨进程恢复未完成下载、Android 专属服务及 Gopeed 集成。下载服务器也可能不支持 URLSession 的续传数据，因此暂停后是否能从断点继续取决于服务器响应。

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

当前产物未签名、公证；首次打开时 macOS 可能显示安全提示。下载文件默认保存到 `~/Downloads/YunX Downloads`，可在应用中更改。下载任务元数据保存在 `~/Library/Application Support/YunX/downloads.json`。

## 项目关系与许可

本仓库从 Android 上游项目派生，未修改上游所有者的仓库。README 中提到的 `tidain/YunX-Desktop` 是独立维护的 Windows 桌面版，本移植与该项目无隶属或发布关系。适用许可为 [GNU AGPL-3.0](./LICENSE)。

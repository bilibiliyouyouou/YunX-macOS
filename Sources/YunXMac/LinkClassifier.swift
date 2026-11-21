// macOS adaptation for YunX; see the repository LICENSE for AGPL-3.0 terms.
import Foundation

enum LinkClassification: Equatable {
    case directDownload
    case sharePlatform(String)
}

enum LinkClassifier {
    private static let platforms: [(String, [String])] = [
        ("夸克网盘", ["pan.quark.cn", "drive-m.quark.cn"]),
        ("UC 网盘", ["drive.uc.cn", "pan.uc.cn"]),
        ("百度网盘", ["pan.baidu.com", "yun.baidu.com"]),
        ("迅雷网盘", ["pan.xunlei.com", "cloud.xunlei.com"]),
        ("115 网盘", ["115.com", "115cdn.com"]),
        ("123 云盘", ["123pan.com", "123684.com"]),
        ("和彩云", ["caiyun.139.com", "yun.139.com"]),
        ("蓝奏云", ["lanzou.com", "lanzoux.com", "lanzoui.com", "lanzoub.com"]),
        ("Pixiv", ["pixiv.net"]),
        ("哔哩哔哩", ["bilibili.com", "b23.tv"]),
        ("抖音", ["douyin.com", "iesdouyin.com"]),
        ("小红书", ["xiaohongshu.com", "xhslink.com"]),
        ("快手", ["kuaishou.com", "chenzhongtech.com"]),
        ("微博", ["weibo.com", "weibo.cn"]),
        ("AcFun", ["acfun.cn", "acfun.com"])
    ]

    static func classify(_ url: URL) -> LinkClassification {
        let host = (url.host ?? "").lowercased()
        if let match = platforms.first(where: { _, domains in
            domains.contains(where: { host == $0 || host.hasSuffix("." + $0) })
        }) {
            return .sharePlatform(match.0)
        }
        return .directDownload
    }

    static func safeFileName(from url: URL) -> String {
        let candidate = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        return sanitizedFileName(candidate)
    }

    static func sanitizedFileName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let separators = CharacterSet(charactersIn: "/\\:").union(.controlCharacters)
        let cleaned = trimmed.components(separatedBy: separators).filter { !$0.isEmpty }.joined(separator: "-")
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "download" : cleaned
    }
}

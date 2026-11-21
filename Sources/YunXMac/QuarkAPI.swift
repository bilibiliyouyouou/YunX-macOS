// macOS adaptation for YunX; based on CYQawa/YunX Quark API integration.
// See the repository LICENSE for AGPL-3.0 terms.
import Foundation

struct ParsedQuarkShare: Equatable {
    let shareID: String
    let passcode: String?
}

enum QuarkShareParser {
    static func parse(_ text: String) -> ParsedQuarkShare? {
        let sharePattern = #"(?i)(?<![A-Za-z0-9.-])(?:https?://)?(?:www\.)?pan\.quark\.cn/s/([a-z0-9]+)(?=[/?#\s)\]}>，,。;]|$)"#
        guard let match = firstMatch(sharePattern, in: text),
              let idRange = Range(match.range(at: 1), in: text) else { return nil }
        let shareID = String(text[idRange])

        let linkPattern = #"(?i)https?://[^\s]+pan\.quark\.cn/s/[a-z0-9]+[^\s]*"#
        let link = firstMatch(linkPattern, in: text).flatMap { Range($0.range, in: text).map { String(text[$0]) } } ?? text
        let queryPattern = #"(?i)(?:[?&](?:pwd|passcode|password)=)([a-z0-9]{4,8})"#
        let textPattern = #"(?:提取码|访问码|密码)[：:]\s*([a-zA-Z0-9]{4,8})"#
        let password = firstCapture(queryPattern, in: link) ?? firstCapture(textPattern, in: text)
        return ParsedQuarkShare(shareID: shareID, passcode: password)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let match = firstMatch(pattern, in: text),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

struct QuarkShareSession: Equatable {
    let shareID: String
    let shareToken: String
    let title: String
}

struct QuarkShareFile: Identifiable, Equatable {
    var id: String { fid }
    let fid: String
    let name: String
    let size: Int64
    let isDirectory: Bool
    let parentFID: String
    let shareFIDToken: String
    let modifiedAt: String
}

struct QuarkResolvedDownload {
    let url: URL
    let fileName: String
    let size: Int64
    let headers: [String: String]
    let updatedCookie: String?
}

enum QuarkAPIError: LocalizedError {
    case invalidShare
    case malformedResponse(Int)
    case apiFailure(String, Int?)
    case missingField(String)
    case insecureDownloadURL
    case guestLimit

    var errorDescription: String? {
        switch self {
        case .invalidShare:
            return "无法识别夸克分享链接，请粘贴 pan.quark.cn/s/... 格式的链接。"
        case let .malformedResponse(status):
            return "夸克网盘返回了无法识别的响应（HTTP \(status)）。请稍后重试，或检查网络/登录状态。"
        case let .apiFailure(message, code):
            if code == 23018 { return "夸克游客下载有文件大小限制。请登录夸克账号后重试。" }
            if code == 31001 { return "夸克要求登录后才能下载此文件。请登录夸克账号后重试。" }
            return code.map { "夸克网盘错误（\($0)）：\(message)" } ?? "夸克网盘错误：\(message)"
        case let .missingField(field):
            return "夸克网盘响应缺少必要字段：\(field)"
        case .insecureDownloadURL:
            return "夸克返回了非 HTTPS 下载地址。为保护登录 Cookie，已拒绝此下载链接。"
        case .guestLimit:
            return "该分享文件无法以游客身份下载，请登录夸克账号后重试。"
        }
    }
}

final class QuarkAPIClient {
    static let shared = QuarkAPIClient()

    private let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.12-a038f7b798 Safari/537.36 Channel/pckk_other_ch"
    private let referer = "https://pan.quark.cn/"
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60
            self.session = URLSession(configuration: configuration)
        }
    }

    func createShareSession(for share: ParsedQuarkShare, passcode: String?, cookie: String?) async throws -> QuarkShareSession {
        let url = endpoint("/1/clouddrive/share/sharepage/token", items: [
            ("pr", "ucpro"), ("fr", "pc")
        ])
        let body: [String: Any] = [
            "pwd_id": share.shareID,
            "passcode": (passcode?.isEmpty == false ? passcode : share.passcode) ?? "",
            "support_visit_limit_private_share": true
        ]
        let (json, response) = try await requestJSON(url: url, method: "POST", cookie: cookie, body: body)
        let data = try checkedData(json, response: response)
        guard let token = data["stoken"] as? String, !token.isEmpty else { throw QuarkAPIError.missingField("stoken") }
        return QuarkShareSession(shareID: share.shareID, shareToken: token, title: data["title"] as? String ?? "夸克分享")
    }

    func listShareFiles(session share: QuarkShareSession, directoryFID: String = "0", cookie: String?) async throws -> [QuarkShareFile] {
        let pageSize = 100
        var page = 1
        var result: [QuarkShareFile] = []

        while page <= 100 {
            let items: [(String, String)] = [
                ("pr", "ucpro"), ("fr", "pc"),
                ("pwd_id", share.shareID), ("stoken", share.shareToken),
                ("pdir_fid", directoryFID), ("ver", "2"), ("force", "0"),
                ("_page", String(page)), ("_size", String(pageSize)),
                ("_fetch_banner", "0"), ("_fetch_share", "0"),
                ("fetch_relate_conversation", "0"), ("_fetch_total", "1"),
                ("_sort", "file_type:asc,file_name:asc")
            ]
            // Keep query ordering aligned with the Android upstream request.
            let url = endpoint("/1/clouddrive/share/sharepage/detail", items: items)
            let (json, response) = try await requestJSON(url: url, method: "GET", cookie: cookie, body: nil)
            let data = try checkedData(json, response: response)
            guard let rawRows = data["list"], let rows = rawRows as? [[String: Any]] else {
                throw QuarkAPIError.missingField("data.list")
            }
            let files = rows.compactMap { row -> QuarkShareFile? in
                guard let fid = row["fid"] as? String, !fid.isEmpty else { return nil }
                return QuarkShareFile(
                    fid: fid,
                    name: row["file_name"] as? String ?? "未命名文件",
                    size: integer(row["size"]),
                    isDirectory: row["dir"] as? Bool ?? false,
                    parentFID: row["pdir_fid"] as? String ?? directoryFID,
                    shareFIDToken: row["share_fid_token"] as? String ?? "",
                    modifiedAt: row["updated_at"] as? String ?? ""
                )
            }
            result.append(contentsOf: files)
            if files.count < pageSize { break }
            page += 1
        }
        return result
    }

    func resolveDownload(session share: QuarkShareSession, file: QuarkShareFile, cookie: String?) async throws -> QuarkResolvedDownload {
        guard !file.shareFIDToken.isEmpty else { throw QuarkAPIError.missingField("share_fid_token") }
        let activeCookie: String?
        if let cookie, !cookie.isEmpty {
            activeCookie = await refreshCookie(cookie) ?? cookie
        } else {
            activeCookie = nil
        }

        let url = endpoint("/1/clouddrive/file/download", items: [
            ("pr", "ucpro"), ("fr", "pc"), ("sys", "win32"), ("ve", "3.23.2")
        ])
        let body: [String: Any] = [
            "fids": [file.fid],
            "fids_token": [file.shareFIDToken],
            "pwd_id": share.shareID,
            "stoken": share.shareToken,
            "speedup_session": "",
            "token": ""
        ]
        let (json, response) = try await requestJSON(url: url, method: "POST", cookie: activeCookie, body: body)
        try checkedDownload(json, response: response)
        guard let entries = json["data"] as? [[String: Any]],
              let first = entries.first else { throw QuarkAPIError.missingField("data[0]") }
        guard let rawURL = first["download_url"] as? String,
              let downloadURL = URL(string: rawURL), downloadURL.host != nil else {
            throw QuarkAPIError.missingField("download_url")
        }
        guard downloadURL.scheme?.lowercased() == "https" else {
            throw QuarkAPIError.insecureDownloadURL
        }

        let setCookie = setCookieHeader(response)
        let returnedPugs = cookieValue("__pugs", in: setCookie)
        let mergedCookie = activeCookie.map { mergeTrackedCookies($0, setCookie: setCookie) }
        let downloadCookie: String?
        if let mergedCookie, !mergedCookie.isEmpty {
            downloadCookie = mergedCookie
        } else {
            downloadCookie = returnedPugs.map { "__pugs=\($0)" }
        }

        var headers = [
            "User-Agent": userAgent,
            "Referer": referer
        ]
        if let downloadCookie, !downloadCookie.isEmpty,
           let host = downloadURL.host?.lowercased(),
           host == "quark.cn" || host.hasSuffix(".quark.cn") {
            headers["Cookie"] = downloadCookie
        }

        let name = (first["file_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (first["filename"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? file.name
        let updatedCookie = mergedCookie.flatMap { $0 == cookie ? nil : $0 }
        return QuarkResolvedDownload(
            url: downloadURL,
            fileName: name,
            size: integer(first["size"]),
            headers: headers,
            updatedCookie: updatedCookie
        )
    }

    private func refreshCookie(_ cookie: String) async -> String? {
        let url = endpoint("/1/clouddrive/config", items: [("pr", "ucpro"), ("fr", "pc")])
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(withoutPuus(cookie), forHTTPHeaderField: "Cookie")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        do {
            let (_, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { return nil }
            let setCookie = setCookieHeader(response)
            let updated = mergeTrackedCookies(cookie, setCookie: setCookie)
            return updated == cookie ? nil : updated
        } catch {
            return nil
        }
    }

    private func requestJSON(url: URL, method: String, cookie: String?, body: [String: Any]?) async throws -> ([String: Any], HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://pan.quark.cn", forHTTPHeaderField: "Origin")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        if let cookie, !cookie.isEmpty { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, rawResponse) = try await session.data(for: request)
        guard let response = rawResponse as? HTTPURLResponse,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let status = (rawResponse as? HTTPURLResponse)?.statusCode ?? 0
            throw QuarkAPIError.malformedResponse(status)
        }
        return (json, response)
    }

    private func checkedData(_ json: [String: Any], response: HTTPURLResponse) throws -> [String: Any] {
        let status = integer(json["status"])
        let code = Int(integer(json["code"]))
        guard (200...299).contains(response.statusCode), status == 200 else {
            let message = (json["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (json["msg"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            throw QuarkAPIError.apiFailure(message, code == 0 ? nil : code)
        }
        guard let data = json["data"] as? [String: Any] else { throw QuarkAPIError.missingField("data") }
        return data
    }

    private func checkedDownload(_ json: [String: Any], response: HTTPURLResponse) throws {
        let status = integer(json["status"])
        let code = Int(integer(json["code"]))
        guard (200...299).contains(response.statusCode), status == 200 || code == 0 else {
            let message = (json["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (json["msg"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            throw QuarkAPIError.apiFailure(message, code == 0 ? nil : code)
        }
    }

    private func endpoint(_ path: String, items: [(String, String)]) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "drive-pc.quark.cn"
        components.path = path
        components.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        return components.url!
    }

    private func setCookieHeader(_ response: HTTPURLResponse) -> String {
        if let entry = response.allHeaderFields.first(where: {
            String(describing: $0.key).caseInsensitiveCompare("Set-Cookie") == .orderedSame
        }) {
            if let value = entry.value as? String { return value }
            if let values = entry.value as? [String] { return values.joined(separator: ", ") }
        }
        return response.value(forHTTPHeaderField: "Set-Cookie") ?? ""
    }

    private func integer(_ value: Any?) -> Int64 {
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String { return Int64(string) ?? 0 }
        return 0
    }

    private func withoutPuus(_ cookie: String) -> String {
        cookie.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("__puus=") }
            .joined(separator: "; ")
    }

    private func mergeTrackedCookies(_ original: String, setCookie: String) -> String {
        var components = original.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        for name in ["__pus", "__puus"] {
            guard let value = cookieValue(name, in: setCookie) else { continue }
            let replacement = "\(name)=\(value)"
            if let index = components.firstIndex(where: { $0.hasPrefix("\(name)=") }) {
                components[index] = replacement
            } else {
                components.append(replacement)
            }
        }
        return components.joined(separator: "; ")
    }

    private func cookieValue(_ name: String, in header: String) -> String? {
        let pattern = #"(?:^|,\s*)"# + NSRegularExpression.escapedPattern(for: name) + #"=([^;,\s]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
              let range = Range(match.range(at: 1), in: header) else { return nil }
        return String(header[range])
    }
}

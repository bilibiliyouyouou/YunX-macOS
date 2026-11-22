// macOS adaptation for YunX; based on CYQawa/YunX UC share flow.
// See the repository LICENSE for AGPL-3.0 terms.
import Foundation

struct ParsedUCShare: Equatable {
    let shareID: String
    let passcode: String?
}

enum UCShareParser {
    static func parse(_ text: String) -> ParsedUCShare? {
        let sharePattern = #"(?i)(?<![A-Za-z0-9.-])(?:https?://)?(?:www\.)?drive\.uc\.cn/s/([a-z0-9]+)(?=[/?#\s)\]}>，,。;]|$)"#
        guard let match = firstMatch(sharePattern, in: text),
              let idRange = Range(match.range(at: 1), in: text) else { return nil }
        let shareID = String(text[idRange])

        let linkPattern = #"(?i)https?://[^\s]*drive\.uc\.cn/s/[a-z0-9]+[^\s]*"#
        let link = firstMatch(linkPattern, in: text).flatMap { Range($0.range, in: text).map { String(text[$0]) } } ?? text
        let queryPattern = #"(?i)(?:[?&]pwd=)([a-z0-9]{4,8})"#
        let textPattern = #"(?:提取码|访问码|密码)[：:]\s*([a-zA-Z0-9]{4,8})"#
        let passcode = firstCapture(queryPattern, in: link) ?? firstCapture(textPattern, in: text)
        return ParsedUCShare(shareID: shareID, passcode: passcode)
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

struct UCShareSession: Equatable {
    let shareID: String
    let shareToken: String
    let title: String
}

struct UCShareFile: Identifiable, Equatable {
    var id: String { fid }
    let fid: String
    let name: String
    let size: Int64
    let isDirectory: Bool
    let parentFID: String
    let shareFIDToken: String
    let modifiedAt: String
}

struct UCResolvedDownload {
    let url: URL
    let fileName: String
    let size: Int64
    let headers: [String: String]
    let updatedCookie: String?
}

enum UCAPIError: LocalizedError {
    case invalidShare
    case malformedResponse(Int)
    case apiFailure(String, Int?)
    case missingField(String)
    case insecureDownloadURL

    var errorDescription: String? {
        switch self {
        case .invalidShare:
            return "无法识别 UC 网盘分享链接，请粘贴 drive.uc.cn/s/... 格式的链接。"
        case let .malformedResponse(status):
            return "UC 网盘返回了无法识别的响应（HTTP \(status)）。请稍后重试，或检查网络/登录状态。"
        case let .apiFailure(message, code):
            switch code {
            case 31001: return "UC 网盘要求登录后才能下载此文件。请登录 UC 账号后重试。"
            case 23018: return "UC 网盘游客下载受到服务端大小限制。请登录 UC 账号后重试。"
            case 14001: return "UC 分享链接或提取码无效。"
            case 41020: return "UC 分享凭证已过期，请重新解析分享链接。"
            default: break
            }
            return code.map { "UC 网盘错误（\($0)）：\(message)" } ?? "UC 网盘错误：\(message)"
        case let .missingField(field):
            return "UC 网盘响应缺少必要字段：\(field)"
        case .insecureDownloadURL:
            return "UC 返回了非 HTTPS 下载地址。为保护凭证，已拒绝此下载链接。"
        }
    }
}

final class UCAPIClient {
    static let shared = UCAPIClient()

    private let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    private let guestUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) uc-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch"
    private let guestSecCHUA = "\"Not=A?Brand\";v=\"99\", \"Chromium\";v=\"100\", \"Google Chrome\";v=\"100\""
    private let referer = "https://drive.uc.cn/"
    private let origin = "https://drive.uc.cn"
    private let transferReferer = "https://fast.uc.cn/"
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

    func createShareSession(for share: ParsedUCShare, passcode: String?, cookie: String?) async throws -> UCShareSession {
        let url = endpoint("/1/clouddrive/share/sharepage/token", items: [("pr", "UCBrowser"), ("fr", "pc")])
        let body: [String: Any] = [
            "pwd_id": share.shareID,
            "passcode": (passcode?.isEmpty == false ? passcode : share.passcode) ?? "",
            "share_for_transfer": true
        ]
        let (json, response) = try await requestJSON(url: url, method: "POST", cookie: cookie, body: body, referer: referer, origin: origin)
        let data = try checkedData(json, response: response)
        guard let token = data["stoken"] as? String, !token.isEmpty else { throw UCAPIError.missingField("stoken") }
        return UCShareSession(shareID: share.shareID, shareToken: token, title: data["title"] as? String ?? "UC 分享")
    }

    func listShareFiles(session share: UCShareSession, directoryFID: String = "0", cookie: String?) async throws -> [UCShareFile] {
        let pageSize = 50
        var result: [UCShareFile] = []

        for page in 1...100 {
            let url = endpoint("/1/clouddrive/transfer_share/detail", items: [
                ("entry", "ft"), ("fr", "pc"), ("pr", "UCBrowser"),
                ("pwd_id", share.shareID), ("pdir_fid", directoryFID),
                ("fetch_file_list", "1"), ("passcode", ""),
                ("_page", String(page)), ("_size", String(pageSize)),
                ("_fetch_total", "1"), ("_fetch_task", "1"),
                ("_fetch_share", "1"), ("_sort", ""), ("stoken", share.shareToken)
            ])
            let (json, response) = try await requestJSON(url: url, method: "GET", cookie: cookie, body: nil, referer: transferReferer, origin: "https://fast.uc.cn")
            let data = try checkedData(json, response: response)
            let rawRows = data["list"] ?? (data["detail_info"] as? [String: Any])?["list"]
            guard let rows = rawRows as? [[String: Any]] else { throw UCAPIError.missingField("data.list") }
            let files = rows.compactMap { row -> UCShareFile? in
                guard let fid = row["fid"] as? String, !fid.isEmpty else { return nil }
                return UCShareFile(
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
        }
        return result
    }

    func resolveDownload(session share: UCShareSession, file: UCShareFile, cookie: String?) async throws -> UCResolvedDownload {
        guard !file.shareFIDToken.isEmpty else { throw UCAPIError.missingField("share_fid_token") }

        let activeCookie: String?
        if let cookie, !cookie.isEmpty {
            activeCookie = await refreshCookie(cookie) ?? cookie
        } else {
            activeCookie = nil
        }

        let url = endpoint("/1/clouddrive/file/download", items: [("entry", "ft"), ("fr", "pc"), ("pr", "UCBrowser")])
        let body: [String: Any] = [
            "fids": [file.fid],
            "pwd_id": share.shareID,
            "stoken": share.shareToken,
            "fids_token": [file.shareFIDToken]
        ]
        var request = makeRequest(url: url, method: "POST", cookie: activeCookie, body: body, userAgent: activeCookie == nil ? guestUserAgent : userAgent, referer: referer, origin: origin)
        if activeCookie == nil {
            request.setValue(guestSecCHUA, forHTTPHeaderField: "Sec-Ch-Ua")
        }
        let (data, rawResponse) = try await session.data(for: request)
        guard let response = rawResponse as? HTTPURLResponse,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UCAPIError.malformedResponse((rawResponse as? HTTPURLResponse)?.statusCode ?? 0)
        }
        try checkedDownload(json, response: response)
        guard let entries = json["data"] as? [[String: Any]], let first = entries.first else {
            throw UCAPIError.missingField("data[0]")
        }
        guard let rawURL = first["download_url"] as? String, let downloadURL = URL(string: rawURL), downloadURL.host != nil else {
            throw UCAPIError.missingField("download_url")
        }
        guard downloadURL.scheme?.lowercased() == "https" else { throw UCAPIError.insecureDownloadURL }

        var headers: [String: String] = ["User-Agent": activeCookie == nil ? guestUserAgent : userAgent, "Referer": referer, "Origin": origin]
        if activeCookie == nil {
            headers["Sec-Ch-Ua"] = guestSecCHUA
            if let pugs = cookieValue("__pugs", in: setCookieHeader(response)), !pugs.isEmpty {
                headers["Cookie"] = "__pugs=\(pugs)"
            }
        } else if let activeCookie {
            headers["Cookie"] = activeCookie
        }

        let updatedCookie = activeCookie.flatMap { current in current == cookie ? nil : current }
        let name = (first["file_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (first["filename"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? file.name
        return UCResolvedDownload(url: downloadURL, fileName: name, size: integer(first["size"]), headers: headers, updatedCookie: updatedCookie)
    }

    private func refreshCookie(_ cookie: String) async -> String? {
        let url = endpoint("/1/clouddrive/config", items: [("pr", "UCBrowser"), ("fr", "pc")])
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(withoutPuus(cookie), forHTTPHeaderField: "Cookie")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        do {
            let (_, rawResponse) = try await session.data(for: request)
            guard let response = rawResponse as? HTTPURLResponse else { return nil }
            let updated = mergeTrackedCookies(cookie, setCookie: setCookieHeader(response))
            return updated == cookie ? nil : updated
        } catch {
            return nil
        }
    }

    private func requestJSON(url: URL, method: String, cookie: String?, body: [String: Any]?, referer: String, origin: String) async throws -> ([String: Any], HTTPURLResponse) {
        let request = makeRequest(url: url, method: method, cookie: cookie, body: body, userAgent: userAgent, referer: referer, origin: origin)
        let (data, rawResponse) = try await session.data(for: request)
        guard let response = rawResponse as? HTTPURLResponse,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UCAPIError.malformedResponse((rawResponse as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return (json, response)
    }

    private func makeRequest(url: URL, method: String, cookie: String?, body: [String: Any]?, userAgent: String, referer: String, origin: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        if let cookie, !cookie.isEmpty { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        if let body {
            request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private func checkedData(_ json: [String: Any], response: HTTPURLResponse) throws -> [String: Any] {
        let status = integer(json["status"])
        let code = Int(integer(json["code"]))
        guard (200...299).contains(response.statusCode), status == 200 else {
            let message = (json["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (json["msg"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            throw UCAPIError.apiFailure(message, code == 0 ? nil : code)
        }
        guard let data = json["data"] as? [String: Any] else { throw UCAPIError.missingField("data") }
        return data
    }

    private func checkedDownload(_ json: [String: Any], response: HTTPURLResponse) throws {
        let status = integer(json["status"])
        let code = Int(integer(json["code"]))
        guard (200...299).contains(response.statusCode), status == 200 else {
            let message = (json["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (json["msg"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            throw UCAPIError.apiFailure(message, code == 0 ? nil : code)
        }
    }

    private func endpoint(_ path: String, items: [(String, String)]) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "pc-api.uc.cn"
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
        cookie.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("__puus=") }.joined(separator: "; ")
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

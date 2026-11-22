// Run with: swiftc -swift-version 5 Sources/YunXMac/UCAPI.swift Tests/UCShareParserSmoke.swift -o /tmp/yunx-uc-smoke && /tmp/yunx-uc-smoke
import Foundation

@main
struct UCShareParserSmoke {
    static func main() async throws {
        precondition(UCShareParser.parse("https://drive.uc.cn/s/AbC123?pwd=9x8y") == ParsedUCShare(shareID: "AbC123", passcode: "9x8y"))
        precondition(UCShareParser.parse("https://drive.uc.cn/s/shareKey，提取码：Qwer") == ParsedUCShare(shareID: "shareKey", passcode: "Qwer"))
        precondition(UCShareParser.parse("DRIVE.UC.CN/S/ZXCVBN") == ParsedUCShare(shareID: "ZXCVBN", passcode: nil))
        precondition(UCShareParser.parse("https://drive.uc.cn.evil.test/s/not-uc") == nil)
        precondition(UCShareParser.parse("https://example.com/s/not-uc") == nil)

        try await exerciseOfflineAPIFlow()
        print("UC parser and API smoke tests passed.")
    }

    private static func exerciseOfflineAPIFlow() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UCStubURLProtocol.self]
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        var omitList = false
        var responseScheme = "https"
        UCStubURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            switch path {
            case "/1/clouddrive/config":
                precondition(request.value(forHTTPHeaderField: "Cookie")?.contains("__puus=") == false)
                return (200, ["Set-Cookie": "__puus=renewed-session; Path=/; Domain=.uc.cn"], Self.json(["status": 200, "data": [:]]))
            case "/1/clouddrive/share/sharepage/token":
                precondition(request.httpMethod == "POST")
                precondition(request.url?.query?.contains("pr=UCBrowser") == true)
                if let body = Self.requestBody(request),
                   let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                    precondition(object["pwd_id"] as? String == "test-share")
                    precondition(object["passcode"] as? String == "4321")
                    precondition(object["share_for_transfer"] as? Bool == true)
                } else {
                    preconditionFailure("Expected token request body.")
                }
                return (200, [:], Self.json(["status": 200, "data": ["stoken": "test-stoken", "title": "UC Demo"]]))
            case "/1/clouddrive/transfer_share/detail":
                precondition(request.httpMethod == "GET")
                precondition(request.url?.query?.contains("stoken=test-stoken") == true)
                precondition(request.value(forHTTPHeaderField: "Origin") == "https://fast.uc.cn")
                if omitList { return (200, [:], Self.json(["status": 200, "data": [:]])) }
                return (200, [:], Self.json(["status": 200, "data": ["detail_info": ["list": [[
                    "fid": "uc-file-1", "file_name": "uc-demo.zip", "size": 4096,
                    "dir": false, "pdir_fid": "0", "share_fid_token": "uc-file-token"
                ]]]]]))
            case "/1/clouddrive/file/download":
                precondition(request.httpMethod == "POST")
                if let body = Self.requestBody(request),
                   let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                    precondition(object["pwd_id"] as? String == "test-share")
                    precondition(object["stoken"] as? String == "test-stoken")
                    precondition((object["fids"] as? [String]) == ["uc-file-1"])
                    precondition((object["fids_token"] as? [String]) == ["uc-file-token"])
                } else {
                    preconditionFailure("Expected share download request body.")
                }
                if request.value(forHTTPHeaderField: "Cookie")?.contains("__puus=renewed-session") == true {
                    precondition(request.value(forHTTPHeaderField: "User-Agent")?.contains("Chrome/120") == true)
                } else {
                    precondition(request.value(forHTTPHeaderField: "Cookie") == nil)
                    precondition(request.value(forHTTPHeaderField: "Sec-Ch-Ua") != nil)
                    precondition(request.value(forHTTPHeaderField: "User-Agent")?.contains("uc-cloud-drive") == true)
                }
                return (200, ["Set-Cookie": "__pugs=guest-token; Path=/; Domain=.uc.cn"], Self.json([
                    "status": 200,
                    "data": [[
                        "fid": "uc-file-1", "file_name": "uc-demo.zip", "size": 4096,
                        "download_url": "\(responseScheme)://download.uc.cn/files/uc-demo.zip?sign=temporary"
                    ]]
                ]))
            default:
                return (404, [:], Self.json(["status": 404, "message": "unexpected endpoint"]))
            }
        }

        let api = UCAPIClient(session: URLSession(configuration: configuration))
        let share = try await api.createShareSession(
            for: ParsedUCShare(shareID: "test-share", passcode: nil),
            passcode: "4321",
            cookie: nil
        )
        precondition(share.shareToken == "test-stoken" && share.title == "UC Demo")
        let files = try await api.listShareFiles(session: share, cookie: nil)
        precondition(files.count == 1)
        precondition(files[0].fid == "uc-file-1" && files[0].shareFIDToken == "uc-file-token")

        omitList = true
        do {
            _ = try await api.listShareFiles(session: share, cookie: nil)
            preconditionFailure("Missing data.list must be reported, not treated as empty.")
        } catch let error as UCAPIError {
            guard case let .missingField(field) = error else { throw error }
            precondition(field == "data.list")
        }
        omitList = false

        let guestLink = try await api.resolveDownload(session: share, file: files[0], cookie: nil)
        precondition(guestLink.fileName == "uc-demo.zip" && guestLink.size == 4096)
        precondition(guestLink.headers["Cookie"] == "__pugs=guest-token")
        precondition(guestLink.headers["Referer"] == "https://drive.uc.cn/")
        precondition(guestLink.headers["Origin"] == "https://drive.uc.cn")

        let loggedInLink = try await api.resolveDownload(
            session: share,
            file: files[0],
            cookie: "__pus=account; __puus=old-session"
        )
        precondition(loggedInLink.updatedCookie?.contains("__puus=renewed-session") == true)
        precondition(loggedInLink.headers["Cookie"]?.contains("__puus=renewed-session") == true)

        responseScheme = "http"
        do {
            _ = try await api.resolveDownload(session: share, file: files[0], cookie: nil)
            preconditionFailure("An HTTP download URL must be rejected.")
        } catch UCAPIError.insecureDownloadURL {
            // 预期：下载直链必须使用 HTTPS。
        }
    }

    private static func requestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4096)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data.isEmpty ? nil : data
    }

    private static func json(_ value: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: value)) ?? Data()
    }
}

private final class UCStubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, [String: String], Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let result = Self.handler?(request), let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: result.0, httpVersion: "HTTP/1.1", headerFields: result.1) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.2)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

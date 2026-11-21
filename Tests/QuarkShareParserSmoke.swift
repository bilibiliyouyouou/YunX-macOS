// Run with: swiftc -swift-version 5 Sources/YunXMac/QuarkAPI.swift Tests/QuarkShareParserSmoke.swift -o /tmp/yunx-quark-smoke && /tmp/yunx-quark-smoke
import Foundation

@main
struct QuarkShareParserSmoke {
    static func main() async throws {
        let queryPasscode = QuarkShareParser.parse("https://pan.quark.cn/s/AbC123?pwd=9x8y")
        precondition(queryPasscode == ParsedQuarkShare(shareID: "AbC123", passcode: "9x8y"))

        let textPasscode = QuarkShareParser.parse("分享文件 https://pan.quark.cn/s/shareKey，提取码：Qwer")
        precondition(textPasscode == ParsedQuarkShare(shareID: "shareKey", passcode: "Qwer"))

        let caseInsensitive = QuarkShareParser.parse("PAN.QUARK.CN/S/ZXCVBN")
        precondition(caseInsensitive == ParsedQuarkShare(shareID: "ZXCVBN", passcode: nil))
        precondition(QuarkShareParser.parse("https://example.com/s/not-quark") == nil)
        precondition(QuarkShareParser.parse("https://evilpan.quark.cn/s/not-quark") == nil)

        try await exerciseOfflineAPIFlow()
        try checkSignedURLPersistencePrivacy()
        print("Quark parser, API, and persistence smoke tests passed.")
    }

    private static func exerciseOfflineAPIFlow() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        var omitListResponse = false
        var downloadScheme = "https"
        StubURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            switch path {
            case "/1/clouddrive/config":
                return (200, ["Set-Cookie": "__puus=refreshed-session; Path=/; Domain=.quark.cn"], Self.json(["status": 200, "data": [:]]))
            case "/1/clouddrive/share/sharepage/token":
                return (200, [:], Self.json(["status": 200, "data": ["stoken": "test-stoken", "title": "Demo"]]))
            case "/1/clouddrive/share/sharepage/detail":
                if omitListResponse {
                    return (200, [:], Self.json(["status": 200, "data": [:]]))
                }
                return (200, [:], Self.json(["status": 200, "data": ["list": [[
                    "fid": "file-1", "file_name": "demo.zip", "size": 1024,
                    "dir": false, "pdir_fid": "0", "share_fid_token": "share-file-token"
                ]]]]))
            case "/1/clouddrive/file/download":
                precondition(request.httpMethod == "POST")
                if let body = Self.requestBody(request),
                   let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                    precondition(object["pwd_id"] as? String == "test-share")
                    precondition(object["stoken"] as? String == "test-stoken")
                    precondition((object["fids_token"] as? [String]) == ["share-file-token"])
                }
                return (200, ["Set-Cookie": "__pugs=guest-token; Path=/; Domain=.quark.cn"], Self.json([
                    "status": 200,
                    "code": 0,
                    "data": [[
                        "fid": "file-1", "file_name": "demo.zip", "size": 1024,
                        "download_url": "\(downloadScheme)://\(StubURLProtocol.downloadHost)/files/demo.zip?sign=temporary"
                    ]]
                ]))
            default:
                return (404, [:], Self.json(["status": 404, "message": "unexpected endpoint"] ))
            }
        }

        let api = QuarkAPIClient(session: URLSession(configuration: configuration))
        let parsed = ParsedQuarkShare(shareID: "test-share", passcode: nil)
        let share = try await api.createShareSession(for: parsed, passcode: nil, cookie: nil)
        precondition(share.shareToken == "test-stoken" && share.title == "Demo")

        let files = try await api.listShareFiles(session: share, cookie: nil)
        precondition(files.count == 1 && files[0].name == "demo.zip" && !files[0].isDirectory)

        omitListResponse = true
        do {
            _ = try await api.listShareFiles(session: share, cookie: nil)
            preconditionFailure("A missing data.list field must not look like an empty directory.")
        } catch let error as QuarkAPIError {
            guard case let .missingField(field) = error else { throw error }
            precondition(field == "data.list")
        }
        omitListResponse = false

        let missingTokenFile = QuarkShareFile(
            fid: "file-1", name: "demo.zip", size: 1024, isDirectory: false,
            parentFID: "0", shareFIDToken: "", modifiedAt: ""
        )
        do {
            _ = try await api.resolveDownload(session: share, file: missingTokenFile, cookie: nil)
            preconditionFailure("A missing share_fid_token must be rejected.")
        } catch let error as QuarkAPIError {
            guard case let .missingField(field) = error else { throw error }
            precondition(field == "share_fid_token")
        }

        let link = try await api.resolveDownload(session: share, file: files[0], cookie: nil)
        precondition(link.fileName == "demo.zip" && link.size == 1024)
        precondition(link.headers["Cookie"] == "__pugs=guest-token")
        precondition(link.headers["Referer"] == "https://pan.quark.cn/")

        let refreshed = try await api.resolveDownload(
            session: share,
            file: files[0],
            cookie: "__pus=account-token; __puus=old-session"
        )
        precondition(refreshed.updatedCookie?.contains("__puus=refreshed-session") == true)

        downloadScheme = "http"
        do {
            _ = try await api.resolveDownload(session: share, file: files[0], cookie: nil)
            preconditionFailure("An HTTP download URL must be rejected.")
        } catch QuarkAPIError.insecureDownloadURL {
            // 预期：鉴权下载链接必须使用 HTTPS。
        }
        downloadScheme = "https"

        StubURLProtocol.downloadHost = "external.example"
        let untrustedLink = try await api.resolveDownload(session: share, file: files[0], cookie: nil)
        precondition(untrustedLink.headers["Cookie"] == nil)
    }

    private static func checkSignedURLPersistencePrivacy() throws {
        let signed = URL(string: "https://cdn.quark.cn/files/item.zip?sign=private-signature")!
        let job = DownloadJob(
            sourceURL: signed,
            fileName: "item.zip",
            destinationPath: "/tmp",
            protectSourceURL: true
        )
        let encoded = String(data: try JSONEncoder().encode(job), encoding: .utf8) ?? ""
        precondition(!encoded.contains("private-signature"))
        precondition(encoded.contains("钥匙串"))
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

private final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, [String: String], Data))?
    static var downloadHost = "cdn.quark.cn"

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let response = Self.handler?(request), let url = request.url,
              let httpResponse = HTTPURLResponse(
                url: url,
                statusCode: response.0,
                httpVersion: "HTTP/1.1",
                headerFields: response.1
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.2)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

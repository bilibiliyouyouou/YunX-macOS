// macOS adaptation for YunX; based on CYQawa/YunX Quark share flow.
// See the repository LICENSE for AGPL-3.0 terms.
import AppKit
import SwiftUI
import WebKit

private struct QuarkDirectoryBreadcrumb: Identifiable {
    let id: String
    let name: String
}

struct QuarkDriveView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @StateObject private var credentials = QuarkCredentialStore.shared
    @State private var shareText = ""
    @State private var passcode = ""
    @State private var shareSession: QuarkShareSession?
    @State private var files: [QuarkShareFile] = []
    @State private var directoryStack: [QuarkDirectoryBreadcrumb] = []
    @State private var currentDirectoryFID = "0"
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var showingLogin = false

    private let api = QuarkAPIClient.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 26)
                .padding(.bottom, 18)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    shareEntry
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 2)
                    }
                    if let statusMessage {
                        Label(statusMessage, systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.green)
                    }
                    if shareSession != nil {
                        fileBrowser
                    }
                }
                .padding(24)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .sheet(isPresented: $showingLogin) {
            QuarkLoginView { cookie in
                do {
                    try credentials.save(cookie: cookie)
                    showingLogin = false
                    errorMessage = nil
                    statusMessage = "夸克账号凭证已安全保存到此 Mac 的钥匙串。"
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            .frame(minWidth: 760, minHeight: 620)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "externaldrive.badge.person.crop")
                .font(.system(size: 27, weight: .medium))
                .foregroundStyle(.blue)
                .frame(width: 44, height: 44)
                .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text("夸克网盘分享下载")
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                Text("解析分享目录，选择文件加入下载队列")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if credentials.isSignedIn {
                Label("夸克已登录", systemImage: "checkmark.shield.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
                Button("退出") { credentials.clear() }
                    .buttonStyle(.bordered)
            } else {
                Button {
                    showingLogin = true
                } label: {
                    Label("登录夸克", systemImage: "person.crop.circle.badge.checkmark")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var shareEntry: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("分享链接", systemImage: "link")
                    .font(.headline)
                Spacer()
                Button {
                    if let text = NSPasteboard.general.string(forType: .string) {
                        shareText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        errorMessage = nil
                        statusMessage = nil
                    }
                } label: {
                    Label("粘贴", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
            }

            TextField("https://pan.quark.cn/s/…", text: $shareText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1...3)
                .padding(12)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
                }
                .onSubmit { Task { await resolveShare() } }

            HStack(spacing: 12) {
                TextField("提取码（如有）", text: $passcode)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                Spacer()
                Button {
                    Task { await resolveShare() }
                } label: {
                    if isLoading {
                        ProgressView().controlSize(.small)
                            .frame(width: 88)
                    } else {
                        Label("解析分享", systemImage: "sparkle.magnifyingglass")
                            .frame(minWidth: 105)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLoading || shareText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Label(
                credentials.isSignedIn
                    ? "已登录下载不受游客文件大小限制；凭证仅保存在 macOS 钥匙串。"
                    : "支持游客解析与小文件下载；夸克游客直链可能有约 50 MB 限制。",
                systemImage: credentials.isSignedIn ? "lock.shield" : "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
        }
    }

    private var fileBrowser: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Button("分享根目录") {
                    Task { await openRoot() }
                }
                .buttonStyle(.link)
                .disabled(directoryStack.isEmpty || isLoading)

                ForEach(directoryStack.indices, id: \.self) { index in
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Button(directoryStack[index].name) {
                        Task { await openBreadcrumb(at: index) }
                    }
                    .buttonStyle(.link)
                    .disabled(index == directoryStack.count - 1 || isLoading)
                    .lineLimit(1)
                }
                Spacer()
                Button {
                    Task { await reloadCurrentDirectory() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(isLoading)
            }

            if isLoading {
                ProgressView("正在读取夸克网盘…")
                    .frame(maxWidth: .infinity, minHeight: 110)
            } else if files.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "folder")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text("目录为空")
                        .font(.headline)
                    Text("当前分享目录中没有文件。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                VStack(spacing: 0) {
                    ForEach(files) { file in
                        fileRow(file)
                        if file.id != files.last?.id { Divider().padding(.leading, 48) }
                    }
                }
                .padding(.horizontal, 12)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
                }
            }
        }
    }

    private func fileRow(_ file: QuarkShareFile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: file.isDirectory ? "folder.fill" : fileIcon(for: file.name))
                .font(.title3)
                .foregroundStyle(file.isDirectory ? .blue : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(file.isDirectory ? "文件夹" : ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if file.isDirectory {
                Button {
                    Task { await openDirectory(file) }
                } label: {
                    Label("打开", systemImage: "chevron.right")
                }
                .buttonStyle(.bordered)
                .disabled(isLoading)
            } else {
                Button {
                    Task { await download(file) }
                } label: {
                    Label("下载", systemImage: "arrow.down.to.line")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLoading)
            }
        }
        .padding(.vertical, 11)
    }

    @MainActor
    private func resolveShare() async {
        guard !isLoading else { return }
        errorMessage = nil
        statusMessage = nil
        guard let parsed = QuarkShareParser.parse(shareText) else {
            errorMessage = QuarkAPIError.invalidShare.localizedDescription
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let cookie = credentials.cookie()
            let share = try await api.createShareSession(for: parsed, passcode: passcode, cookie: cookie)
            let initialFiles = try await api.listShareFiles(session: share, cookie: cookie)
            shareSession = share
            currentDirectoryFID = "0"
            directoryStack = []
            files = initialFiles.sorted(by: fileOrder)
            statusMessage = "已解析“\(share.title)”，共列出 \(initialFiles.count) 项。"
        } catch {
            errorMessage = error.localizedDescription
            shareSession = nil
            files = []
        }
    }

    @MainActor
    private func openDirectory(_ file: QuarkShareFile) async {
        guard let shareSession else { return }
        isLoading = true
        errorMessage = nil
        statusMessage = nil
        defer { isLoading = false }
        do {
            let next = try await api.listShareFiles(session: shareSession, directoryFID: file.fid, cookie: credentials.cookie())
            directoryStack.append(QuarkDirectoryBreadcrumb(id: file.fid, name: file.name))
            currentDirectoryFID = file.fid
            files = next.sorted(by: fileOrder)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func openRoot() async {
        guard let shareSession else { return }
        await loadDirectory(shareSession: shareSession, fid: "0", stack: [])
    }

    @MainActor
    private func openBreadcrumb(at index: Int) async {
        guard let shareSession else { return }
        let nextStack = Array(directoryStack.prefix(index + 1))
        let fid = nextStack.last?.id ?? "0"
        await loadDirectory(shareSession: shareSession, fid: fid, stack: nextStack)
    }

    @MainActor
    private func reloadCurrentDirectory() async {
        guard let shareSession else { return }
        await loadDirectory(shareSession: shareSession, fid: currentDirectoryFID, stack: directoryStack)
    }

    @MainActor
    private func loadDirectory(shareSession: QuarkShareSession, fid: String, stack: [QuarkDirectoryBreadcrumb]) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            files = try await api.listShareFiles(session: shareSession, directoryFID: fid, cookie: credentials.cookie())
                .sorted(by: fileOrder)
            currentDirectoryFID = fid
            directoryStack = stack
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func download(_ file: QuarkShareFile) async {
        guard let shareSession else { return }
        isLoading = true
        errorMessage = nil
        statusMessage = nil
        defer { isLoading = false }
        do {
            let cookie = credentials.cookie()
            let link = try await api.resolveDownload(session: shareSession, file: file, cookie: cookie)
            if let updated = link.updatedCookie { try credentials.save(cookie: updated) }
            try downloads.addResolvedDownload(
                url: link.url,
                fileName: link.fileName,
                headers: link.headers,
                protectSourceURL: true
            )
            statusMessage = "“\(link.fileName)”已加入下载队列。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func fileOrder(_ lhs: QuarkShareFile, _ rhs: QuarkShareFile) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private func fileIcon(for name: String) -> String {
        switch URL(fileURLWithPath: name).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "webp", "heic": "photo"
        case "mp4", "mov", "mkv", "avi": "film"
        case "mp3", "m4a", "wav", "flac": "music.note"
        case "zip", "7z", "rar", "tar", "gz": "archivebox"
        case "pdf": "doc.richtext"
        default: "doc"
        }
    }
}

private struct QuarkLoginView: View {
    let onCookieCaptured: (String) -> Void

    @State private var webView: WKWebView
    @State private var message: String?

    init(onCookieCaptured: @escaping (String) -> Void) {
        self.onCookieCaptured = onCookieCaptured
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        _webView = State(initialValue: WKWebView(frame: .zero, configuration: configuration))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("登录夸克网盘")
                        .font(.title2.weight(.bold))
                    Text("登录过程在本机 WebKit 窗口中完成；会话 Cookie 仅保存到 macOS 钥匙串。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("重新载入") {
                    webView.load(URLRequest(url: URL(string: "https://pan.quark.cn/?fr=pc&platform=pc")!))
                }
                .buttonStyle(.bordered)
            }
            .padding(18)

            Divider()
            QuarkLoginBrowser(webView: webView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack(spacing: 12) {
                if let message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text("请先在网页中完成夸克账号登录，再点击保存登录状态。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("保存登录状态") { captureCookies() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
    }

    private func captureCookies() {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            let values = cookies
                .filter { cookie in
                    let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    return domain == "quark.cn" || domain.hasSuffix(".quark.cn")
                }
                .map { "\($0.name)=\($0.value)" }
            let cookieHeader = values.joined(separator: "; ")
            DispatchQueue.main.async {
                guard cookieHeader.contains("__pus="), cookieHeader.contains("__puus=") else {
                    message = "尚未检测到完整登录状态。请确认已登录夸克网盘并稍等片刻后重试。"
                    return
                }
                onCookieCaptured(cookieHeader)
            }
        }
    }
}

private struct QuarkLoginBrowser: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        if webView.url == nil {
            webView.load(URLRequest(url: URL(string: "https://pan.quark.cn/?fr=pc&platform=pc")!))
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

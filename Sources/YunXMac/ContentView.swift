// macOS adaptation for YunX; see the repository LICENSE for AGPL-3.0 terms.
import AppKit
import SwiftUI

private enum AppSection: String, CaseIterable, Identifiable {
    case cloudDrives = "网盘分享"
    case resolve = "直链下载"
    case downloads = "下载管理"
    case about = "关于 YunX"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .cloudDrives: "externaldrive.badge.person.crop"
        case .resolve: "link"
        case .downloads: "arrow.down.circle"
        case .about: "info.circle"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var manager: DownloadManager
    @State private var selection: AppSection? = .resolve

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("云析 YunX") {
                    ForEach(AppSection.allCases) { section in
                        Label(section.rawValue, systemImage: section.symbol)
                            .tag(section as AppSection?)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("macOS 移植进行中")
                        .font(.caption.weight(.semibold))
                    Text("夸克网盘分享 + HTTPS 直链")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        } detail: {
            Group {
                switch selection ?? .cloudDrives {
                case .cloudDrives:
                    QuarkDriveView()
                case .resolve:
                    ResolverView()
                case .downloads:
                    DownloadsView()
                case .about:
                    AboutView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
    }
}

private struct ResolverView: View {
    @EnvironmentObject private var manager: DownloadManager
    @State private var input = ""
    @State private var errorMessage: String?
    @State private var showSuccess = false

    private var parsedURL: URL? {
        URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var classification: LinkClassification? {
        guard let url = parsedURL, url.host != nil else { return nil }
        return LinkClassifier.classify(url)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("把链接交给云析")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("粘贴文件直链，保存到 Mac 并在下载管理中查看进度。")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 32)

                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Label("下载地址", systemImage: "link")
                            .font(.headline)
                        Spacer()
                        Button {
                            if let text = NSPasteboard.general.string(forType: .string) {
                                input = text.trimmingCharacters(in: .whitespacesAndNewlines)
                                errorMessage = nil
                            }
                        } label: {
                            Label("粘贴", systemImage: "doc.on.clipboard")
                        }
                        .buttonStyle(.bordered)
                    }

                    TextField("https://example.com/file.zip", text: $input, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1...3)
                        .padding(12)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9)
                                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
                        }
                        .onSubmit(startDownload)

                    if case let .sharePlatform(name) = classification {
                        Label("识别到\(name)分享链接", systemImage: "sparkle.magnifyingglass")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.orange)
                        Text(name == "夸克网盘" ? "夸克分享解析已移植。请在侧边栏打开“网盘分享”，浏览文件并加入下载队列。" : "此 macOS 移植版尚未迁移该平台的登录与解析接口。为避免把分享网页错误地保存成文件，请先使用原版解析出下载直链。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if parsedURL?.scheme?.lowercased() == "http" {
                        Label("出于安全考虑，仅支持 HTTPS 下载地址", systemImage: "lock.fill")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.orange)
                    } else {
                        Label("支持 HTTPS 文件直链", systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.green)
                    }

                    Divider()

                    HStack(spacing: 12) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("保存位置")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(manager.downloadFolder.path)
                                .font(.callout.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        Button("选择文件夹…", action: chooseFolder)
                            .buttonStyle(.bordered)
                    }

                    HStack {
                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if showSuccess {
                            Label("任务已加入下载队列", systemImage: "checkmark.circle.fill")
                                .font(.callout)
                                .foregroundStyle(.green)
                        }
                        Spacer()
                        Button(action: startDownload) {
                            Label("开始下载", systemImage: "arrow.down.to.line")
                                .frame(minWidth: 120)
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(!canStart)
                    }
                }
                .padding(22)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
                }

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("功能迁移说明")
                            .font(.subheadline.weight(.semibold))
                        Text("Android 版支持的网盘账号、分享链接解析、视频/图集解析、在线预览及分片下载尚未完成 macOS 移植。此构建不宣称与 Android 版功能等同。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var canStart: Bool {
        guard let url = parsedURL, url.host != nil,
              url.scheme?.lowercased() == "https" else { return false }
        return classification == .directDownload
    }

    private func startDownload() {
        errorMessage = nil
        showSuccess = false
        do {
            try manager.addDirectDownload(input)
            input = ""
            showSuccess = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择下载文件夹"
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            manager.setDownloadFolder(url)
        }
    }
}

private struct DownloadsView: View {
    @EnvironmentObject private var manager: DownloadManager

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("下载管理")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("任务保存在本机；退出应用后未完成的任务会显示为暂停。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(manager.jobs.count) 个任务")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if manager.jobs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 42))
                        .foregroundStyle(.secondary)
                    Text("暂无下载任务")
                        .font(.title3.weight(.semibold))
                    Text("在“直链下载”中粘贴 HTTPS 文件直链。")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(manager.jobs) { job in
                            DownloadRow(job: job)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(28)
    }
}

private struct DownloadRow: View {
    @EnvironmentObject private var manager: DownloadManager
    let job: DownloadJob

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: statusSymbol)
                    .font(.title2)
                    .foregroundStyle(statusColor)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 5) {
                    Text(job.fileName)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(job.sourceURL)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let error = job.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                Text(job.status.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(statusColor.opacity(0.12), in: Capsule())
            }

            if job.status == .downloading {
                ProgressView(value: job.progress)
                HStack {
                    Text(progressDescription)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: job.bytesWritten, countStyle: .file))
                        .monospacedDigit()
                    if job.expectedBytes > 0 {
                        Text("/ \(ByteCountFormatter.string(fromByteCount: job.expectedBytes, countStyle: .file))")
                            .monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if job.status == .completed {
                Text(job.destinationPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack {
                Text(job.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                if job.status == .downloading {
                    Button("暂停") { manager.pause(job) }
                        .buttonStyle(.bordered)
                } else if job.status == .paused || job.status == .failed {
                    Button("继续") { manager.resume(job) }
                        .buttonStyle(.bordered)
                }
                if job.status == .completed {
                    Button("在 Finder 中显示") {
                        let url = URL(fileURLWithPath: job.destinationPath).appendingPathComponent(job.fileName)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .buttonStyle(.bordered)
                }
                Button(role: .destructive) {
                    manager.remove(job)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("从列表移除")
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
        }
    }

    private var progressDescription: String {
        job.expectedBytes > 0 ? "\(Int(job.progress * 100))%" : "正在接收数据…"
    }

    private var statusSymbol: String {
        switch job.status {
        case .queued: "clock"
        case .downloading: "arrow.down.circle.fill"
        case .paused: "pause.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch job.status {
        case .queued, .paused: .secondary
        case .downloading: .blue
        case .completed: .green
        case .failed: .red
        }
    }
}

private struct AboutView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("关于云析 YunX")
                .font(.system(size: 28, weight: .bold, design: .rounded))
            Text("YunX macOS 是基于 CYQawa/YunX Android 项目开展的原生 SwiftUI 移植。当前开发版本提供 HTTPS 直链下载、夸克网盘分享下载、下载队列、暂停/继续、任务状态本机持久化与 Finder 定位。")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            Text("平台解析与登录等功能仍在迁移中；此版本不是 Android 版的完整替代品。项目仍遵循 GNU AGPL-3.0，完整协议见仓库根目录 LICENSE。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Link("Android 上游仓库", destination: URL(string: "https://github.com/CYQawa/YunX")!)
            Link("GNU AGPL-3.0", destination: URL(string: "https://www.gnu.org/licenses/agpl-3.0.html")!)
            Spacer()
        }
        .padding(32)
        .frame(maxWidth: 760, maxHeight: .infinity, alignment: .topLeading)
    }
}

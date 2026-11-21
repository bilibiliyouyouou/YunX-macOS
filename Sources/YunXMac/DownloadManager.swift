// macOS adaptation for YunX; see the repository LICENSE for AGPL-3.0 terms.
import Foundation
import Combine

@MainActor
final class DownloadManager: NSObject, ObservableObject {
    @Published private(set) var jobs: [DownloadJob] = []
    @Published private(set) var downloadFolder: URL

    private var session: URLSession!
    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    private var lastProgressPersist: [UUID: Date] = [:]
    private let stateFile: URL

    override init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("YunX", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        self.stateFile = support.appendingPathComponent("downloads.json")
        let defaultFolder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            .appendingPathComponent("YunX Downloads", isDirectory: true)
        if let savedPath = UserDefaults.standard.string(forKey: "YunX.downloadFolder") {
            self.downloadFolder = URL(fileURLWithPath: savedPath, isDirectory: true)
        } else {
            self.downloadFolder = defaultFolder
        }
        super.init()

        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = 8
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        loadJobs()
    }

    func setDownloadFolder(_ url: URL) {
        downloadFolder = url
        UserDefaults.standard.set(url.path, forKey: "YunX.downloadFolder")
        persistJobs()
    }

    func addDirectDownload(_ rawValue: String) throws {
        guard let url = URL(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              url.host != nil else {
            throw DownloadError.invalidURL
        }
        guard LinkClassifier.classify(url) == .directDownload else {
            throw DownloadError.shareLink
        }
        try addResolvedDownload(url: url, fileName: LinkClassifier.safeFileName(from: url), headers: [:])
    }

    func addResolvedDownload(url: URL, fileName: String, headers: [String: String], protectSourceURL: Bool = false) throws {
        guard url.scheme?.lowercased() == "https", url.host != nil else {
            throw DownloadError.invalidURL
        }
        let job = DownloadJob(
            sourceURL: url,
            fileName: fileName,
            destinationPath: downloadFolder.path,
            protectSourceURL: protectSourceURL
        )
        if !headers.isEmpty || protectSourceURL {
            do {
                try DownloadHeaderVault.save(headers, sourceURL: protectSourceURL ? url.absoluteString : nil, for: job.id)
            } catch {
                throw DownloadError.credentialStorage(error.localizedDescription)
            }
        }
        jobs.insert(job, at: 0)
        persistJobs()
        start(jobID: job.id)
    }

    func pause(_ job: DownloadJob) {
        guard let task = tasks[job.id] else { return }
        let headers = DownloadHeaderVault.headers(for: job.id)
        let canPersistResumeData = !DownloadHeaderVault.hasSensitiveHeaders(headers)
            && !DownloadHeaderVault.hasProtectedSourceURL(for: job.id)
        task.cancel(byProducingResumeData: { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                self.tasks.removeValue(forKey: job.id)
                self.update(job.id) {
                    // URLSession 恢复数据可能包含请求头；Cookie/Auth 绝不写入 downloads.json。
                    $0.resumeData = canPersistResumeData ? data : nil
                    $0.status = .paused
                    $0.errorMessage = nil
                }
            }
        })
    }

    func resume(_ job: DownloadJob) {
        guard job.status == .paused || job.status == .failed else { return }
        start(jobID: job.id)
    }

    func remove(_ job: DownloadJob) {
        tasks.removeValue(forKey: job.id)?.cancel()
        DownloadHeaderVault.remove(for: job.id)
        jobs.removeAll { $0.id == job.id }
        persistJobs()
    }

    private func start(jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        let storedURL = DownloadHeaderVault.sourceURL(for: jobID) ?? jobs[index].sourceURL
        guard let url = URL(string: storedURL),
              url.scheme?.lowercased() == "https", url.host != nil else {
            markFailed(jobID, message: "下载地址无效或不是 HTTPS。请重新解析分享链接。")
            return
        }

        let resumeData = jobs[index].resumeData
        jobs[index].resumeData = nil
        jobs[index].status = .downloading
        jobs[index].errorMessage = nil
        if resumeData == nil {
            jobs[index].progress = 0
            jobs[index].bytesWritten = 0
            jobs[index].expectedBytes = 0
        }
        persistJobs()

        let headers = DownloadHeaderVault.headers(for: jobID)
        let task: URLSessionDownloadTask
        if let resumeData,
           !DownloadHeaderVault.hasSensitiveHeaders(headers),
           !DownloadHeaderVault.hasProtectedSourceURL(for: jobID) {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            var request = URLRequest(url: url)
            for (name, value) in headers {
                request.setValue(value, forHTTPHeaderField: name)
            }
            task = session.downloadTask(with: request)
        }
        task.taskDescription = jobID.uuidString
        tasks[jobID] = task
        task.resume()
    }

    private func loadJobs() {
        guard let data = try? Data(contentsOf: stateFile),
              let stored = try? JSONDecoder().decode([DownloadJob].self, from: data) else { return }
        jobs = stored.map { old in
            var job = old
            if job.status == .downloading {
                job.status = .paused
                job.resumeData = nil
            } else if job.status == .queued {
                job.status = .paused
            }
            return job
        }
        persistJobs()
    }

    private func persistJobs() {
        do {
            let data = try JSONEncoder().encode(jobs)
            try data.write(to: stateFile, options: .atomic)
        } catch {
            NSLog("YunX: unable to persist download queue: %@", error.localizedDescription)
        }
    }

    private func update(_ id: UUID, change: (inout DownloadJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
        persistJobs()
    }

    private func finishDownload(id: UUID, stagedFile: URL, suggestedName: String?) {
        guard let job = jobs.first(where: { $0.id == id }) else {
            try? FileManager.default.removeItem(at: stagedFile)
            return
        }

        do {
            let folder = URL(fileURLWithPath: job.destinationPath, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let preferred = suggestedName.flatMap { $0.isEmpty ? nil : $0 } ?? job.fileName
            let target = uniqueDestination(in: folder, fileName: preferred)
            try FileManager.default.moveItem(at: stagedFile, to: target)
            tasks.removeValue(forKey: id)
            DownloadHeaderVault.remove(for: id)
            update(id) {
                $0.fileName = target.lastPathComponent
                $0.status = .completed
                $0.progress = 1
                $0.resumeData = nil
                $0.errorMessage = nil
            }
        } catch {
            try? FileManager.default.removeItem(at: stagedFile)
            tasks.removeValue(forKey: id)
            update(id) {
                $0.status = .failed
                $0.errorMessage = error.localizedDescription
            }
        }
    }

    private func uniqueDestination(in folder: URL, fileName: String) -> URL {
        let safeName = LinkClassifier.sanitizedFileName(fileName)
        var candidate = folder.appendingPathComponent(safeName)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

        let ext = candidate.pathExtension
        let base = candidate.deletingPathExtension().lastPathComponent
        var suffix = 2
        repeat {
            let name = ext.isEmpty ? "\(base) (\(suffix))" : "\(base) (\(suffix)).\(ext)"
            candidate = folder.appendingPathComponent(name)
            suffix += 1
        } while FileManager.default.fileExists(atPath: candidate.path)
        return candidate
    }

    private func updateProgress(_ id: UUID, written: Int64, expected: Int64) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        let previousProgress = jobs[index].progress
        jobs[index].bytesWritten = written
        jobs[index].expectedBytes = expected
        jobs[index].progress = expected > 0 ? min(1, Double(written) / Double(expected)) : 0

        let now = Date()
        if jobs[index].progress - previousProgress >= 0.01
            || now.timeIntervalSince(lastProgressPersist[id] ?? .distantPast) >= 1 {
            lastProgressPersist[id] = now
            persistJobs()
        }
    }

    private func markFailed(_ id: UUID, message: String) {
        tasks.removeValue(forKey: id)
        update(id) {
            $0.status = .failed
            $0.errorMessage = message
        }
    }
}

private enum DownloadError: LocalizedError {
    case invalidURL
    case shareLink
    case credentialStorage(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "请输入有效的 HTTPS 下载地址。"
        case .shareLink:
            "分享链接需先在对应平台完成解析，再将下载直链加入队列。"
        case let .credentialStorage(message):
            "无法安全保存下载凭证：\(message)"
        }
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let destinationURL = request.url,
              destinationURL.scheme?.lowercased() == "https" else {
            completionHandler(nil)
            return
        }

        var safeRequest = request
        let sourceURL = task.currentRequest?.url ?? task.originalRequest?.url
        let sourceOrigin = sourceURL.map(Self.originKey)
        let destinationOrigin = Self.originKey(destinationURL)
        if sourceOrigin != destinationOrigin {
            safeRequest.setValue(nil, forHTTPHeaderField: "Cookie")
            safeRequest.setValue(nil, forHTTPHeaderField: "Authorization")
            safeRequest.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
        }
        completionHandler(safeRequest)
    }

    private nonisolated static func originKey(_ url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host?.lowercased() ?? ""
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let id = downloadTask.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        Task { @MainActor [weak self] in
            self?.updateProgress(id, written: totalBytesWritten, expected: totalBytesExpectedToWrite)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let id = downloadTask.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(response.statusCode) {
            Task { @MainActor [weak self] in
                self?.markFailed(id, message: "服务器返回 HTTP \(response.statusCode)。")
            }
            return
        }
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("YunX-\(id.uuidString).download")
        do {
            if FileManager.default.fileExists(atPath: staged.path) {
                try FileManager.default.removeItem(at: staged)
            }
            try FileManager.default.copyItem(at: location, to: staged)
        } catch {
            Task { @MainActor [weak self] in
                self?.markFailed(id, message: error.localizedDescription)
            }
            return
        }
        let suggestedName = downloadTask.response?.suggestedFilename
        Task { @MainActor [weak self] in
            self?.finishDownload(id: id, stagedFile: staged, suggestedName: suggestedName)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error,
              (error as? URLError)?.code != .cancelled,
              let id = task.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        Task { @MainActor [weak self] in
            self?.markFailed(id, message: error.localizedDescription)
        }
    }
}

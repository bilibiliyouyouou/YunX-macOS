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
              let scheme = url.scheme?.lowercased(),
              ["https", "http"].contains(scheme),
              url.host != nil else {
            throw DownloadError.invalidURL
        }
        guard LinkClassifier.classify(url) == .directDownload else {
            throw DownloadError.shareLink
        }

        let job = DownloadJob(
            sourceURL: url,
            fileName: LinkClassifier.safeFileName(from: url),
            destinationPath: downloadFolder.path
        )
        jobs.insert(job, at: 0)
        persistJobs()
        start(jobID: job.id)
    }

    func pause(_ job: DownloadJob) {
        guard let task = tasks[job.id] else { return }
        task.cancel(byProducingResumeData: { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                self.tasks.removeValue(forKey: job.id)
                self.update(job.id) {
                    $0.resumeData = data
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
        jobs.removeAll { $0.id == job.id }
        persistJobs()
    }

    private func start(jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }),
              let url = URL(string: jobs[index].sourceURL) else { return }

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

        let task: URLSessionDownloadTask
        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            task = session.downloadTask(with: url)
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

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "请输入有效的 HTTP 或 HTTPS 下载地址。"
        case .shareLink:
            "这是网盘或内容平台分享链接。平台解析功能尚未移植；请先粘贴解析后的直链。"
        }
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
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

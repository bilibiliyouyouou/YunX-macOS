// macOS adaptation for YunX; see the repository LICENSE for AGPL-3.0 terms.
import Foundation

enum DownloadStatus: String, Codable {
    case queued
    case downloading
    case paused
    case completed
    case failed

    var title: String {
        switch self {
        case .queued: "等待中"
        case .downloading: "下载中"
        case .paused: "已暂停"
        case .completed: "已完成"
        case .failed: "失败"
        }
    }
}

struct DownloadJob: Identifiable, Codable, Equatable {
    let id: UUID
    let sourceURL: String
    var fileName: String
    var destinationPath: String
    var status: DownloadStatus
    var progress: Double
    var bytesWritten: Int64
    var expectedBytes: Int64
    var createdAt: Date
    var errorMessage: String?
    var resumeData: Data?

    init(sourceURL: URL, fileName: String, destinationPath: String, protectSourceURL: Bool = false) {
        self.id = UUID()
        self.sourceURL = protectSourceURL ? "网盘签名直链（已安全保存在钥匙串）" : sourceURL.absoluteString
        self.fileName = fileName
        self.destinationPath = destinationPath
        self.status = .queued
        self.progress = 0
        self.bytesWritten = 0
        self.expectedBytes = 0
        self.createdAt = Date()
        self.errorMessage = nil
        self.resumeData = nil
    }
}

// macOS adaptation for YunX; see the repository LICENSE for AGPL-3.0 terms.
import SwiftUI

@main
struct YunXMacApp: App {
    @StateObject private var downloads = DownloadManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(downloads)
                .frame(minWidth: 900, minHeight: 620)
        }
        .windowStyle(.titleBar)
    }
}

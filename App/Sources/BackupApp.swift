import SwiftUI

@main
struct BackupApp: App {
    @StateObject private var urlHandler = URLActionHandler()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(urlHandler)
                .onOpenURL { url in
                    urlHandler.handle(url)
                }
        }
    }
}

// URL Scheme 处理：backupapp://zip?name=文件夹名
// 快捷指令用「打开 URL」调用，无需 App Intent，不存在元数据缓存问题
class URLActionHandler: ObservableObject {
    @Published var lastResult: String = ""
    @Published var showResult = false

    func handle(_ url: URL) {
        guard url.scheme == "backupapp" else { return }

        if url.host == "zip" {
            let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "name" })?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if name.isEmpty {
                show("请指定文件夹名：backupapp://zip?name=文件夹名")
                return
            }

            // 后台压缩，完成后弹窗提示
            DispatchQueue.global(qos: .userInitiated).async {
                let result = self.zipFolder(named: name)
                DispatchQueue.main.async {
                    self.show(result)
                }
            }
        }
    }

    private func zipFolder(named name: String) -> String {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let src = docs.appendingPathComponent(name, isDirectory: true)

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: src.path, isDirectory: &isDir), isDir.boolValue else {
            return "找不到「\(name)」，请先用快捷指令「存储文件」存到备份助手目录"
        }

        // 诊断：列出实际看到的内容
        let contents = (try? fm.contentsOfDirectory(atPath: src.path)) ?? []
        if contents.isEmpty {
            return "打包失败：「\(name)」在App里看是空的（文件App里有\(name)/Application？可能是存的位置不对，请确认存到「我的iPhone→备份助手→\(name)」）"
        }

        let backupDir = docs.appendingPathComponent("备份", isDirectory: true)
        try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)

        let df = DateFormatter()
        df.dateFormat = "MMdd-HHmm"
        let zipName = "\(name)-\(df.string(from: Date())).zip"
        let zipURL = backupDir.appendingPathComponent(zipName)

        do {
            try zipDirectory(at: src, to: zipURL)
            return "已打包：\(zipName)"
        } catch {
            return "打包失败：\(error.localizedDescription)（看到\(contents.count)项：\(contents.prefix(3).joined(separator: "、"))）"
        }
    }

    private func show(_ msg: String) {
        lastResult = msg
        showResult = true
    }
}

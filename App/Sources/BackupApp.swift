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
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            let name = items?.first(where: { $0.name == "name" })?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // as= 指定 zip 文件名（不含日期后缀），不填就用文件夹名
            let asName = items?.first(where: { $0.name == "as" })?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if name.isEmpty {
                show("请指定文件夹名：backupapp://zip?name=文件夹名")
                return
            }

            // 后台压缩，完成后弹窗提示
            DispatchQueue.global(qos: .userInitiated).async {
                let result = self.zipFolder(named: name, asName: asName.isEmpty ? nil : asName)
                DispatchQueue.main.async {
                    self.show(result)
                }
            }
        }
    }

    private func zipFolder(named name: String, asName: String? = nil) -> String {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let src = docs.appendingPathComponent(name, isDirectory: true)

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: src.path, isDirectory: &isDir), isDir.boolValue else {
            return "找不到「\(name)」，请先用快捷指令「存储文件」存到备份助手目录"
        }

        // 等待文件写完：最多等30秒，每2秒查一次
        var contents: [String] = []
        for _ in 0..<15 {
            contents = (try? fm.contentsOfDirectory(atPath: src.path)) ?? []
            if !contents.isEmpty { break }
            Thread.sleep(forTimeInterval: 2)
        }
        if contents.isEmpty {
            return "打包失败：「\(name)」在App里看是空的（等了30秒还是空，请确认快捷指令「存储文件」的目的地是「我的iPhone→备份助手→\(name)」）"
        }

        let backupDir = docs.appendingPathComponent("备份", isDirectory: true)
        try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)

        let df = DateFormatter()
        df.dateFormat = "MMdd-HHmm"
        let baseName = asName ?? name
        let zipName = "\(baseName)-\(df.string(from: Date())).zip"
        let zipURL = backupDir.appendingPathComponent(zipName)

        do {
            try zipDirectory(at: src, to: zipURL)
            // 压完清空待打包，下次直接用
            try? fm.removeItem(at: src)
            try? fm.createDirectory(at: src, withIntermediateDirectories: true)
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

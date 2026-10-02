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
            // v45: src= 绑定的源文件夹名，直接从原位置压缩，不用先复制
            let srcName = items?.first(where: { $0.name == "src" })?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // as= 指定 zip 文件名（不含日期后缀），不填就用文件夹名
            let asName = items?.first(where: { $0.name == "as" })?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            // 后台压缩，完成后弹窗提示
            DispatchQueue.global(qos: .userInitiated).async {
                let result: String
                if !srcName.isEmpty {
                    result = self.zipBoundFolder(srcName: srcName, asName: asName.isEmpty ? nil : asName)
                } else if !name.isEmpty {
                    result = self.zipFolder(named: name, asName: asName.isEmpty ? nil : asName)
                } else {
                    result = "请指定文件夹：backupapp://zip?name=文件夹名 或 backupapp://zip?src=绑定名"
                }
                DispatchQueue.main.async {
                    self.show(result)
                }
            }
        }
    }

    // v45: 压缩绑定的源文件夹（直接从原位置读，不用先复制）
    private func zipBoundFolder(srcName: String, asName: String?) -> String {
        let fm = FileManager.default
        let dict = UserDefaults.standard.dictionary(forKey: "v45_boundFolders") as? [String: String] ?? [:]
        guard let b64 = dict[srcName], let data = Data(base64Encoded: b64) else {
            return "没绑定「\(srcName)」，请先在 App 里「自动备份」绑定"
        }
        var stale = false
        guard let srcURL = try? URL(resolvingBookmarkData: data, options: .withoutUI,
                                    relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return "绑定「\(srcName)」已失效，请重新绑定"
        }
        guard srcURL.startAccessingSecurityScopedResource() else {
            return "无法访问「\(srcName)」"
        }
        defer { srcURL.stopAccessingSecurityScopedResource() }

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: srcURL.path, isDirectory: &isDir), isDir.boolValue else {
            return "「\(srcName)」不存在或不是文件夹"
        }

        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let backupDir = docs.appendingPathComponent("备份", isDirectory: true)
        try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)

        let baseName = asName ?? srcName
        let zipName = "\(baseName).zip"
        let zipURL = backupDir.appendingPathComponent(zipName)
        try? fm.removeItem(at: zipURL)

        do {
            try zipDirectory(at: srcURL, to: zipURL)
            return "已打包：\(zipName)"
        } catch {
            return "打包失败：\(error.localizedDescription)"
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

        let baseName = asName ?? name
        let zipName = "\(baseName).zip"
        let zipURL = backupDir.appendingPathComponent(zipName)
        // 同名直接覆盖
        try? FileManager.default.removeItem(at: zipURL)

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

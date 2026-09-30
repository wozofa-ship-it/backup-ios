import Foundation
import Combine

struct BackupRecord: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var date: Date
    var sourceName: String
    var destName: String
}

class BackupManager: ObservableObject {
    @Published var isWorking = false
    @Published var progress: Double = 0
    @Published var status: String = ""
    @Published var records: [BackupRecord] = []

    private let recordsKey = "backup_records"

    init() {
        loadRecords()
    }

    // MARK: - 历史记录

    func loadRecords() {
        if let data = UserDefaults.standard.data(forKey: recordsKey),
           let arr = try? JSONDecoder().decode([BackupRecord].self, from: data) {
            records = arr
        }
    }

    func saveRecords() {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: recordsKey)
        }
    }

    func addRecord(name: String, sourceName: String, destName: String) {
        records.insert(BackupRecord(name: name, date: Date(), sourceName: sourceName, destName: destName), at: 0)
        if records.count > 50 {
            records = Array(records.prefix(50))
        }
        saveRecords()
    }

    func deleteRecord(at offsets: IndexSet) {
        records.remove(atOffsets: offsets)
        saveRecords()
    }

    // MARK: - 备份：把 src 整个复制到 dstParent 下面新建的 name 目录里

    func backupFolder(from src: URL, toParent dstParent: URL, name: String, completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.main.async {
            self.isWorking = true
            self.progress = 0
            self.status = "准备中…"
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let scoped1 = src.startAccessingSecurityScopedResource()
            let scoped2 = dstParent.startAccessingSecurityScopedResource()
            defer {
                if scoped1 { src.stopAccessingSecurityScopedResource() }
                if scoped2 { dstParent.stopAccessingSecurityScopedResource() }
            }

            let fm = FileManager.default
            let dst = dstParent.appendingPathComponent(name, isDirectory: true)

            do {
                if fm.fileExists(atPath: dst.path) {
                    throw NSError(domain: "BackupApp", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "目标位置已存在同名文件夹，换个备份名称再试"])
                }
                let files = self.relativePaths(under: src)
                if files.isEmpty {
                    throw NSError(domain: "BackupApp", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "源文件夹是空的"])
                }
                try fm.createDirectory(at: dst, withIntermediateDirectories: true)

                for (i, rel) in files.enumerated() {
                    let s = src.appendingPathComponent(rel)
                    let d = dst.appendingPathComponent(rel)
                    var isDir: ObjCBool = false
                    _ = fm.fileExists(atPath: s.path, isDirectory: &isDir)
                    if isDir.boolValue {
                        try fm.createDirectory(at: d, withIntermediateDirectories: true)
                    } else {
                        try fm.createDirectory(at: d.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try fm.copyItem(at: s, to: d)
                    }
                    let p = Double(i + 1) / Double(files.count)
                    let done = i + 1
                    let total = files.count
                    DispatchQueue.main.async {
                        self.progress = p
                        self.status = "正在备份 \(done)/\(total)"
                    }
                }

                DispatchQueue.main.async {
                    self.isWorking = false
                    self.progress = 1
                    self.status = "备份完成"
                    completion(true, name)
                }
            } catch {
                try? fm.removeItem(at: dst)
                let msg = (error as NSError).localizedDescription
                DispatchQueue.main.async {
                    self.isWorking = false
                    self.status = "失败"
                    completion(false, msg)
                }
            }
        }
    }

    // MARK: - 恢复：把备份文件夹整个复制到目标目录下（新建同名目录）

    func restoreFolder(from backupDir: URL, toParent restoreParent: URL, completion: @escaping (Bool, String) -> Void) {
        backupFolder(from: backupDir, toParent: restoreParent, name: backupDir.lastPathComponent, completion: completion)
    }

    // MARK: - 工具

    /// 本机备份根目录：App 的 Documents/备份（在“文件”App 中可见）
    func localBackupRoot() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("备份", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func relativePaths(under root: URL) -> [String] {
        var result: [String] = []
        let fm = FileManager.default
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let u as URL in enumerator {
                if u.lastPathComponent == ".DS_Store" { continue }
                let rel = u.path.replacingOccurrences(of: prefix, with: "")
                if !rel.isEmpty {
                    result.append(rel)
                }
            }
        }
        return result
    }
}

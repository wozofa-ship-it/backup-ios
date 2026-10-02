import AppIntents
import Foundation
import UniformTypeIdentifiers

// v38: 定时备份 —— 接收快捷指令传进来的文件/文件夹（沙盒外也可），复制到 App 内再打 zip
// 用法：快捷指令里"获取文件"选好文件夹 → 传给"定时备份文件夹"

enum ScheduledBackupError: Error, LocalizedError {
    case noInput
    case copyFailed(String)
    case zipFailed(String)

    var errorDescription: String? {
        switch self {
        case .noInput: return "没有收到文件，请在快捷指令里先用「获取文件」选中文件夹再传入"
        case .copyFailed(let s): return "复制文件失败：\(s)"
        case .zipFailed(let s): return "备份失败：\(s)"
        }
    }
}

struct ScheduledBackupIntent: AppIntent {
    static var title: LocalizedStringResource = "定时备份文件夹"
    static var description = IntentDescription("把传入的文件夹打成 zip，存到备份目录")

    @Parameter(title: "文件夹", description: "要备份的文件夹（从快捷指令传入）")
    var folder: URL?

    @Parameter(title: "文件夹名称", description: "已在备份助手目录里的文件夹名（老用法，不传文件时用）")
    var folderName: String?

    static var parameterSummary: some ParameterSummary {
        Summary("备份文件夹 \(\.$folder)") {
            \.$folderName
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let backupDir = docs.appendingPathComponent("备份", isDirectory: true)
        try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)

        let df = DateFormatter()
        df.dateFormat = "MMdd-HHmm"

        // 模式1：收到了快捷指令传进来的文件/文件夹 URL
        if let src = folder {
            let accessing = src.startAccessingSecurityScopedResource()
            defer { if accessing { src.stopAccessingSecurityScopedResource() } }

            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: src.path, isDirectory: &isDir) else {
                throw ScheduledBackupError.noInput
            }

            // 复制到 App 沙盒内的临时目录再压缩（避免跨沙盒直接读大文件）
            let tmp = fm.temporaryDirectory.appendingPathComponent("backup-\(UUID().uuidString)", isDirectory: true)
            try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            let staged = tmp.appendingPathComponent(src.lastPathComponent, isDirectory: true)
            do {
                try fm.copyItem(at: src, to: staged)
            } catch {
                throw ScheduledBackupError.copyFailed(error.localizedDescription)
            }

            let zipName = "\(src.lastPathComponent)-自动-\(df.string(from: Date())).zip"
            let zipURL = backupDir.appendingPathComponent(zipName)
            do {
                try zipDirectory(at: staged, to: zipURL)
            } catch {
                throw ScheduledBackupError.zipFailed(error.localizedDescription)
            }
            try? fm.removeItem(at: tmp)
            return .result(value: "已备份：\(zipName)")
        }

        // 模式2：老用法，传文件夹名字符串，找 App 自己目录里的
        if let name = folderName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            let src = docs.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: src.path, isDirectory: &isDir), isDir.boolValue else {
                throw ScheduledBackupError.copyFailed("找不到文件夹：\(name)")
            }
            let zipName = "\(name)-自动-\(df.string(from: Date())).zip"
            let zipURL = backupDir.appendingPathComponent(zipName)
            do {
                try zipDirectory(at: src, to: zipURL)
            } catch {
                throw ScheduledBackupError.zipFailed(error.localizedDescription)
            }
            return .result(value: "已备份：\(zipName)")
        }

        throw ScheduledBackupError.noInput
    }
}

import AppIntents
import Foundation

// v34: 定时备份 —— 暴露给捷径 App 的动作，用户在"捷径→自动化→时间"里调用
// 只能备份 App 自己 Documents 目录里的文件夹（沙盒限制）

enum ScheduledBackupError: Error, LocalizedError {
    case folderNotFound(String)
    case zipFailed(String)

    var errorDescription: String? {
        switch self {
        case .folderNotFound(let n): return "找不到文件夹：\(n)"
        case .zipFailed(let s): return "备份失败：\(s)"
        }
    }
}

struct ScheduledBackupIntent: AppIntent {
    static var title: LocalizedStringResource = "定时备份文件夹"
    static var description = IntentDescription("把备份助手目录里的指定文件夹打成 zip，存到备份目录")

    @Parameter(title: "文件夹名称", description: "备份助手 Documents 目录里的文件夹名")
    var folderName: String

    static var parameterSummary: some ParameterSummary {
        Summary("备份文件夹 \(\.$folderName)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let src = docs.appendingPathComponent(folderName, isDirectory: true)

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: src.path, isDirectory: &isDir), isDir.boolValue else {
            throw ScheduledBackupError.folderNotFound(folderName)
        }

        let backupDir = docs.appendingPathComponent("备份", isDirectory: true)
        try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)

        let df = DateFormatter()
        df.dateFormat = "MMdd-HHmm"
        let zipName = "\(folderName)-自动-\(df.string(from: Date())).zip"
        let zipURL = backupDir.appendingPathComponent(zipName)

        do {
            try zipDirectory(at: src, to: zipURL)
        } catch {
            throw ScheduledBackupError.zipFailed(error.localizedDescription)
        }

        return .result(value: "已备份：\(zipName)")
    }
}

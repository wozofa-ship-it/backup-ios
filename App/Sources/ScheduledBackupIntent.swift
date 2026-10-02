import AppIntents
import Foundation

// v39: 定时备份 —— 只收文件夹"名称"字符串（Shortcuts 传文件夹 URL 有系统限制，走不通）
// 配合自动化：快捷指令先用"存储文件"把文件夹拷进备份助手目录，再调这个动作传名称

enum ScheduledBackupError: Error, LocalizedError {
    case folderNotFound(String)
    case zipFailed(String)

    var errorDescription: String? {
        switch self {
        case .folderNotFound(let n): return "备份助手目录里找不到文件夹：\(n)，请先用快捷指令的「存储文件」把它拷进来"
        case .zipFailed(let s): return "备份失败：\(s)"
        }
    }
}

struct ScheduledBackupIntent: AppIntent {
    static var title: LocalizedStringResource = "定时备份文件夹"
    static var description = IntentDescription("把备份助手目录里的指定文件夹打成 zip，存到备份目录")

    @Parameter(title: "文件夹名称", description: "备份助手目录里的文件夹名")
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

import AppIntents
import Foundation

// v43: 全新动作「打包文件夹」—— 与旧「压缩成 Zip」完全不同的身份，避开 iOS 缓存的旧定义
// 用法：快捷指令「存储文件」把内容存到 备份助手/待打包 → 打包文件夹（名称=待打包）

enum ZipFolderError: Error, LocalizedError {
    case notFound(String)
    case zipFailed(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let n): return "备份助手里找不到「\(n)」文件夹，请先用快捷指令「存储文件」存进来"
        case .zipFailed(let s): return "打包失败：\(s)"
        }
    }
}

struct ZipFolderIntent: AppIntent {
    static var title: LocalizedStringResource = "打包文件夹"
    static var description = IntentDescription("把备份助手目录里的文件夹打成 zip 包，存到备份目录")

    @Parameter(title: "文件夹名", description: "备份助手目录里的文件夹名，例如：待打包")
    var folderName: String

    static var parameterSummary: some ParameterSummary {
        Summary("打包文件夹 \(\.$folderName)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let src = docs.appendingPathComponent(folderName, isDirectory: true)

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: src.path, isDirectory: &isDir), isDir.boolValue else {
            throw ZipFolderError.notFound(folderName)
        }

        let backupDir = docs.appendingPathComponent("备份", isDirectory: true)
        try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)

        let df = DateFormatter()
        df.dateFormat = "MMdd-HHmm"
        let zipName = "\(folderName)-\(df.string(from: Date())).zip"
        let zipURL = backupDir.appendingPathComponent(zipName)

        do {
            try zipDirectory(at: src, to: zipURL)
        } catch {
            throw ZipFolderError.zipFailed(error.localizedDescription)
        }

        return .result(value: "已打包：\(zipName)")
    }
}

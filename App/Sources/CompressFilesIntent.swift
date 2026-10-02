import AppIntents
import Foundation

// v37: 压缩成 Zip —— 暴露给捷径 App 的动作
// 把备份助手 Documents 目录里的指定文件夹/文件打成 zip，存到备份目录
// 快捷指令里直接搜"压缩"就能找到，当普通命令用

enum CompressError: Error, LocalizedError {
    case notFound(String)
    case zipFailed(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let n): return "找不到：\(n)"
        case .zipFailed(let s): return "压缩失败：\(s)"
        }
    }
}

struct CompressFilesIntent: AppIntent {
    static var title: LocalizedStringResource = "压缩成 Zip"
    static var description = IntentDescription("把备份助手目录里的文件夹或文件打成 zip 包")

    @Parameter(title: "名称", description: "Documents 目录里的文件夹或文件名")
    var name: String

    @Parameter(title: "输出文件名", description: "zip 包名，不填则自动生成（可省略）")
    var outputName: String?

    static var parameterSummary: some ParameterSummary {
        Summary("压缩 \(\.$name) 成 Zip")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let src = docs.appendingPathComponent(name)

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: src.path, isDirectory: &isDir) else {
            throw CompressError.notFound(name)
        }

        let backupDir = docs.appendingPathComponent("备份", isDirectory: true)
        try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)

        let zipBase: String
        if let out = outputName?.trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty {
            zipBase = out.hasSuffix(".zip") ? out : out + ".zip"
        } else {
            let df = DateFormatter()
            df.dateFormat = "MMdd-HHmm"
            zipBase = "\(src.lastPathComponent)-\(df.string(from: Date())).zip"
        }
        let zipURL = backupDir.appendingPathComponent(zipBase)

        do {
            if isDir.boolValue {
                try zipDirectory(at: src, to: zipURL)
            } else {
                // 单个文件：建临时目录装进去再压，保证 zip 内结构干净
                let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
                try fm.copyItem(at: src, to: tmp.appendingPathComponent(src.lastPathComponent))
                try zipDirectory(at: tmp, to: zipURL)
                try? fm.removeItem(at: tmp)
            }
        } catch {
            throw CompressError.zipFailed(error.localizedDescription)
        }

        return .result(value: "已压缩：\(zipBase)")
    }
}

import AppIntents
import Foundation

// v39: 压缩成 Zip —— 只收文件夹"名称"字符串（Shortcuts 传文件夹 URL 有系统限制，走不通）
// 配合自动化：快捷指令先用"存储文件"把文件夹拷进备份助手目录，再调这个动作传名称

enum CompressError: Error, LocalizedError {
    case notFound(String)
    case zipFailed(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let n): return "备份助手目录里找不到：\(n)，请先用快捷指令的「存储文件」把它拷进来"
        case .zipFailed(let s): return "压缩失败：\(s)"
        }
    }
}

struct CompressFilesIntent: AppIntent {
    static var title: LocalizedStringResource = "压缩成 Zip"
    static var description = IntentDescription("把备份助手目录里的文件夹或文件打成 zip 包")

    @Parameter(title: "名称", description: "备份助手目录里的文件夹或文件名")
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

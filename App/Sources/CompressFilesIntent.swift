import AppIntents
import Foundation

// v42: 压缩成 Zip —— 只收文件夹名称字符串，不接收文件
// 架构：快捷指令用自带「存储文件」把内容拷进 App 目录，App 只压自己目录里的东西
// 快捷指令流程：获取文件夹内容 → 存储到"备份助手/待压缩" → 压缩成Zip(名称=待压缩) → 移动zip

enum CompressError: Error, LocalizedError {
    case notFound(String)
    case zipFailed(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let n): return "找不到「\(n)」，请先用快捷指令「存储文件」把内容存到备份助手目录"
        case .zipFailed(let s): return "压缩失败：\(s)"
        }
    }
}

struct CompressFilesIntent: AppIntent {
    static var title: LocalizedStringResource = "压缩成 Zip"
    static var description = IntentDescription("把备份助手目录里的文件夹打成 zip")

    @Parameter(title: "名称", description: "备份助手目录里的文件夹名，如：待压缩")
    var name: String

    @Parameter(title: "输出文件名", description: "zip 包名，不填则自动生成")
    var outputName: String?

    static var parameterSummary: some ParameterSummary {
        Summary("压缩 \(\.$name) 成 Zip")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let src = docs.appendingPathComponent(name, isDirectory: true)

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: src.path, isDirectory: &isDir), isDir.boolValue else {
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
            zipBase = "\(name)-\(df.string(from: Date())).zip"
        }
        let zipURL = backupDir.appendingPathComponent(zipBase)

        do {
            try zipDirectory(at: src, to: zipURL)
        } catch {
            throw CompressError.zipFailed(error.localizedDescription)
        }

        return .result(value: "已压缩：\(zipBase)")
    }
}

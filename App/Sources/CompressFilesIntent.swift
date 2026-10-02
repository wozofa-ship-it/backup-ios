import AppIntents
import Foundation
import UniformTypeIdentifiers

// v38: 压缩成 Zip —— 接收快捷指令传进来的文件/文件夹（沙盒外也可），复制到 App 内再打 zip
// 快捷指令里直接搜"压缩"就能找到，当普通命令用

enum CompressError: Error, LocalizedError {
    case noInput
    case copyFailed(String)
    case zipFailed(String)

    var errorDescription: String? {
        switch self {
        case .noInput: return "没有收到文件，请在快捷指令里先用「获取文件」选中再传入"
        case .copyFailed(let s): return "复制文件失败：\(s)"
        case .zipFailed(let s): return "压缩失败：\(s)"
        }
    }
}

struct CompressFilesIntent: AppIntent {
    static var title: LocalizedStringResource = "压缩成 Zip"
    static var description = IntentDescription("把传入的文件或文件夹打成 zip 包")

    @Parameter(title: "文件", description: "要压缩的文件或文件夹（从快捷指令传入）")
    var file: URL?

    @Parameter(title: "名称", description: "已在备份助手目录里的文件/文件夹名（老用法，不传文件时用）")
    var name: String?

    @Parameter(title: "输出文件名", description: "zip 包名，不填则自动生成（可省略）")
    var outputName: String?

    static var parameterSummary: some ParameterSummary {
        Summary("压缩 \(\.$file) 成 Zip") {
            \.$name
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let backupDir = docs.appendingPathComponent("备份", isDirectory: true)
        try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)

        // 确定源：优先用传入的文件 URL
        var src: URL
        var srcIsDir = false
        if let url = file {
            src = url
            var isDir: ObjCBool = false
            let accessing = src.startAccessingSecurityScopedResource()
            defer { if accessing { src.stopAccessingSecurityScopedResource() } }
            guard fm.fileExists(atPath: src.path, isDirectory: &isDir) else {
                throw CompressError.noInput
            }
            srcIsDir = isDir.boolValue
            // 复制到沙盒内再压
            let tmp = fm.temporaryDirectory.appendingPathComponent("compress-\(UUID().uuidString)", isDirectory: true)
            try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            let staged = tmp.appendingPathComponent(src.lastPathComponent)
            do {
                try fm.copyItem(at: src, to: staged)
            } catch {
                throw CompressError.copyFailed(error.localizedDescription)
            }
            src = staged
        } else if let n = name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
            let candidate = docs.appendingPathComponent(n)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: candidate.path, isDirectory: &isDir) else {
                throw CompressError.copyFailed("找不到：\(n)")
            }
            src = candidate
            srcIsDir = isDir.boolValue
        } else {
            throw CompressError.noInput
        }

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
            if srcIsDir {
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
        // 清理 staging（如果是从外部复制进来的）
        if src.path.contains(fm.temporaryDirectory.path) {
            try? fm.removeItem(at: src.deletingLastPathComponent())
        }

        return .result(value: "已压缩：\(zipBase)")
    }
}

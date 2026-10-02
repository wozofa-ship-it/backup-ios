import AppIntents
import Foundation

// v41: 压缩成 Zip —— 接收快捷指令"获取文件夹内容"传来的文件数组
// 修复 v40 错误2：fileURL 为空时改用 data 写入；加计数诊断

enum CompressError: Error, LocalizedError {
    case noInput
    case copyFailed(String)
    case zipFailed(String)

    var errorDescription: String? {
        switch self {
        case .noInput: return "没有收到文件，请在前面加「获取文件夹内容」"
        case .copyFailed(let s): return "复制文件失败：\(s)"
        case .zipFailed(let s): return "压缩失败：\(s)"
        }
    }
}

struct CompressFilesIntent: AppIntent {
    static var title: LocalizedStringResource = "压缩成 Zip"
    static var description = IntentDescription("把快捷指令传来的文件打成 zip 包")

    @Parameter(title: "文件", description: "要压缩的文件（从「获取文件夹内容」传入）")
    var files: [IntentFile]

    @Parameter(title: "输出文件名", description: "zip 包名，不填则自动生成（可省略）")
    var outputName: String?

    static var parameterSummary: some ParameterSummary {
        Summary("压缩 \(\.$files) 成 Zip")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard !files.isEmpty else { throw CompressError.noInput }

        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let backupDir = docs.appendingPathComponent("备份", isDirectory: true)
        try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)

        let staging = fm.temporaryDirectory.appendingPathComponent("zipin-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        var copied = 0
        var skipped: [String] = []
        for f in files {
            let name = f.filename.isEmpty ? "未命名文件\(copied)" : f.filename
            let dest = staging.appendingPathComponent(name)
            // 通道1：fileURL 直接复制（大文件走这里，不占内存）
            if let src = f.fileURL {
                let accessing = src.startAccessingSecurityScopedResource()
                defer { if accessing { src.stopAccessingSecurityScopedResource() } }
                do {
                    if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                    try fm.copyItem(at: src, to: dest)
                    copied += 1
                    continue
                } catch {
                    // 复制失败则尝试通道2
                }
            }
            // 通道2：用 data 写入（小文件兜底）
            do {
                let data = try f.data
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try data.write(to: dest)
                copied += 1
            } catch {
                skipped.append(name)
            }
        }

        guard copied > 0 else {
            throw CompressError.copyFailed("收到 \(files.count) 个文件，但一个都没能读取（跳过：\(skipped.joined(separator: "、"))）")
        }

        let zipBase: String
        if let out = outputName?.trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty {
            zipBase = out.hasSuffix(".zip") ? out : out + ".zip"
        } else {
            let df = DateFormatter()
            df.dateFormat = "MMdd-HHmm"
            zipBase = "快捷指令-\(df.string(from: Date())).zip"
        }
        let zipURL = backupDir.appendingPathComponent(zipBase)

        do {
            try zipDirectory(at: staging, to: zipURL)
        } catch {
            throw CompressError.zipFailed(error.localizedDescription)
        }

        let msg = skipped.isEmpty
            ? "已压缩：\(zipBase)（\(copied) 个文件）"
            : "已压缩：\(zipBase)（\(copied) 个文件，跳过 \(skipped.count) 个）"
        return .result(value: msg)
    }
}

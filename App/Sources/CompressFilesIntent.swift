import AppIntents
import Foundation

// v40: 压缩成 Zip —— 接收快捷指令"获取文件夹内容"传来的文件数组，原地打成 zip
// 用法：获取 Data 的内容 → 压缩成 Zip（文件数组自动传入）

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

        // 把传进来的文件全部拷到临时 staging 目录
        let staging = fm.temporaryDirectory.appendingPathComponent("zipin-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        for f in files {
            guard let src = f.fileURL else { continue }
            let accessing = src.startAccessingSecurityScopedResource()
            defer { if accessing { src.stopAccessingSecurityScopedResource() } }
            let dest = staging.appendingPathComponent(src.lastPathComponent)
            do {
                if fm.fileExists(atPath: dest.path) {
                    try fm.removeItem(at: dest)
                }
                try fm.copyItem(at: src, to: dest)
            } catch {
                throw CompressError.copyFailed("\(src.lastPathComponent): \(error.localizedDescription)")
            }
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

        return .result(value: "已压缩：\(zipBase)")
    }
}

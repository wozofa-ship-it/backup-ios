import AppIntents
import Foundation

// v36: 定时解压 —— 暴露给捷径 App 的动作，用户在"捷径→自动化→时间"里调用
// 把备份目录里的 zip 解压到 App Documents 下的指定文件夹（沙盒内，解压用 App 自带流式解压器，大文件不卡死）
// 解压完如需搬到 LiveContainer/微信，在自动化里再加一步"移动文件"即可

enum ScheduledUnzipError: Error, LocalizedError {
    case zipNotFound(String)
    case unzipFailed(String)

    var errorDescription: String? {
        switch self {
        case .zipNotFound(let n): return "找不到 zip：\(n)"
        case .unzipFailed(let s): return "解压失败：\(s)"
        }
    }
}

struct ScheduledUnzipIntent: AppIntent {
    static var title: LocalizedStringResource = "定时解压文件"
    static var description = IntentDescription("把备份目录里的 zip 解压到指定文件夹")

    @Parameter(title: "Zip 文件名", description: "备份目录里的 zip 文件名（不用填 .zip 也行）")
    var zipName: String

    @Parameter(title: "目标文件夹", description: "解压到 Documents 下的哪个文件夹，不存在自动创建")
    var destFolder: String

    static var parameterSummary: some ParameterSummary {
        Summary("解压 \(\.$zipName) 到 \(\.$destFolder)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let backupDir = docs.appendingPathComponent("备份", isDirectory: true)

        // 找 zip：兼容带/不带 .zip 后缀
        var zipURL = backupDir.appendingPathComponent(zipName)
        if zipURL.pathExtension.lowercased() != "zip" {
            zipURL = backupDir.appendingPathComponent(zipName + ".zip")
        }
        // 也试试 Documents 根目录
        if !fm.fileExists(atPath: zipURL.path) {
            let alt = docs.appendingPathComponent(zipName)
            let alt2 = docs.appendingPathComponent(zipName + ".zip")
            if fm.fileExists(atPath: alt.path) { zipURL = alt }
            else if fm.fileExists(atPath: alt2.path) { zipURL = alt2 }
        }
        guard fm.fileExists(atPath: zipURL.path) else {
            throw ScheduledUnzipError.zipNotFound(zipName)
        }

        let destDir = docs.appendingPathComponent(destFolder, isDirectory: true)
        do {
            try unzipFile(at: zipURL, to: destDir)
        } catch {
            throw ScheduledUnzipError.unzipFailed(error.localizedDescription)
        }

        return .result(value: "已解压到：\(destFolder)")
    }
}

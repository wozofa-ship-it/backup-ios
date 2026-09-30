import SwiftUI
import UIKit

func defaultBackupName(for folderName: String? = nil) -> String {
    let f = DateFormatter()
    f.dateFormat = "MMdd-HHmm"
    let dateStr = f.string(from: Date())
    if let name = folderName, !name.isEmpty {
        return "\(name)-\(dateStr)"
    }
    return "备份-" + dateStr
}

func documentsDir() -> URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
}

// v7.0：分享扩展用的 App Group
let shareGroupID = "group.com.quseqi.backup.shared"

/// v7.0：把分享扩展导入的项目搬到 App 内。文件夹进 Documents（可备份），zip 进"备份"目录（可恢复）
/// 返回成功导入的数量
func importFromShareExtension(backupRoot: URL) -> Int {
    let fm = FileManager.default
    guard let container = fm.containerURL(forSecurityApplicationGroupIdentifier: shareGroupID) else { return 0 }
    let incoming = container.appendingPathComponent("Incoming", isDirectory: true)
    guard let items = try? fm.contentsOfDirectory(at: incoming, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]),
          !items.isEmpty else { return 0 }
    let docs = documentsDir()
    var count = 0
    for src in items {
        // zip 包直接进备份目录，其他进 Documents
        let targetDir = src.pathExtension.lowercased() == "zip" ? backupRoot : docs
        var dest = targetDir.appendingPathComponent(src.lastPathComponent)
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            let base = src.deletingPathExtension().lastPathComponent
            let ext = src.pathExtension
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            dest = targetDir.appendingPathComponent(name)
            n += 1
        }
        if (try? fm.moveItem(at: src, to: dest)) != nil {
            count += 1
        }
    }
    return count
}

func listFolders(in dir: URL, excluding: Set<String> = []) -> [URL] {
    let fm = FileManager.default
    guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
        return []
    }
    return items.filter { url in
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir)
            && isDir.boolValue
            && !excluding.contains(url.lastPathComponent)
    }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
}

func listZips(in dir: URL) -> [URL] {
    let fm = FileManager.default
    guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
        return []
    }
    return items.filter { $0.pathExtension.lowercased() == "zip" }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
}

func topVC() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow }
        ?? scenes.flatMap { $0.windows }.first
    var vc = window?.rootViewController
    while let presented = vc?.presentedViewController {
        vc = presented
    }
    return vc
}

// v9.1: 系统选择器诊断。排查结论：
// - v3.0 用 allowsMultipleSelection=true，撞上 iOS 已知 bug（多选模式下进文件夹点"打开"无响应，delegate 不触发）
// - v3.1 改单选但用了独立 UIWindow 弹出，UIDocumentPickerViewController 是远程视图，自定义窗口可能破坏其触摸/展示
// - 从没试过"单选 + 主窗口常规弹出"，这次单独测试验证
class TestPickerDelegate: NSObject, UIDocumentPickerDelegate {
    static let shared = TestPickerDelegate()
    var onResult: ((Bool, String) -> Void)?

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let name = urls.first?.lastPathComponent ?? "?"
        let path = urls.first?.path ?? ""
        controller.dismiss(animated: true) { [weak self] in
            DispatchQueue.main.async { self?.onResult?(true, "\(name)||\(path)") }
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        controller.dismiss(animated: true) { [weak self] in
            DispatchQueue.main.async { self?.onResult?(false, "用户取消了选择") }
        }
    }
}

// 检查剪贴板是否有文件 URL（iOS 不允许直接读取，只能检测到）
func pasteboardHasFiles() -> Bool {
    let pb = UIPasteboard.general
    return pb.hasURLs || pb.hasStrings
}

struct ContentView: View {
    @StateObject private var manager = BackupManager()

    // 备份
    @State private var backupName: String = defaultBackupName()
    @State private var sourceFolders: [URL] = []
    @State private var pendingSource: URL?
    @State private var showBackupConfirm = false
    @State private var lastBackupURL: URL?
    @State private var lastBackupSource: URL?

    // 恢复
    @State private var backupZips: [URL] = []
    @State private var selectedZip: URL?
    @State private var showUnzipDestPicker = false

    @State private var alertText = ""
    @State private var showAlert = false

    // 剪贴板提示
    @State private var showPasteboardHint = false
    // v9.0: 备份完成弹窗（保存位置+分享+清理三合一）
    @State private var showBackupDone = false
    @State private var backupDoneText = ""
    // v9.1: 系统选择器诊断测试
    @State private var testPickerStatus = ""
    @State private var testPickedPath = ""


    var body: some View {
        NavigationView {
            List {
                // 剪贴板提示条
                if showPasteboardHint {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("📋 检测到剪贴板有内容")
                                .font(.headline)
                            Text("iOS 不允许 App 直接读取剪贴板的文件。请去“文件”App，把拷贝的内容粘贴到“备份助手”文件夹，回来这里会自动识别。")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                            Button("去“文件”App 粘贴") { openFilesApp() }
                                .font(.subheadline)
                        }
                        .padding(.vertical, 4)
                    }
                }

                // MARK: 备份（压缩成 zip）
                Section(header: Text("备份")) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("① 在“文件”App 拷贝文件夹 → 粘贴到“备份助手”")
                        Text("② 回到这里，点文件夹一键压缩成 .zip")
                        Text("③ 点“分享”存到 iCloud 云盘")
                    }
                    .font(.footnote)
                    .foregroundColor(.secondary)

                    Button("去“文件”App 拷贝文件夹") { openFilesApp() }
                        .font(.headline)

                    TextField("备份名称（可改）", text: $backupName)

                    if sourceFolders.isEmpty {
                        Text("还没有文件夹：去“文件”App 粘贴进来，回来自动刷新")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(sourceFolders, id: \.path) { url in
                            Button {
                                pendingSource = url
                                // 智能默认名：文件夹名+日期
                                backupName = defaultBackupName(for: url.lastPathComponent)
                                showBackupConfirm = true
                            } label: {
                                HStack {
                                    Image(systemName: "folder.fill").foregroundColor(.blue)
                                    Text(url.lastPathComponent).foregroundColor(.primary)
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundColor(.secondary).font(.footnote)
                                }
                            }
                        }
                    }

                    if let done = lastBackupURL {
                        Button("分享备份文件（存到 iCloud 云盘）") { shareURL(done) }
                            .font(.headline)
                    }
                }
                .alert("压缩备份这个文件夹？", isPresented: $showBackupConfirm, presenting: pendingSource) { url in
                    Button("取消", role: .cancel) {}
                    Button("开始压缩备份") { startZipBackup(from: url) }
                } message: { url in
                    Text("将把「\(url.lastPathComponent)」打包成 .zip 存到本机。")
                }

                if manager.isWorking || !manager.status.isEmpty {
                    Section {
                        ProgressView(value: manager.progress)
                        Text(manager.status).font(.footnote).foregroundColor(.secondary)
                    }
                }

                // MARK: 恢复（解压 zip）
                Section(header: Text("恢复")) {
                    Text("选一个 .zip 备份，再选解压到哪个文件夹。")
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    if backupZips.isEmpty {
                        Text("暂无 zip 备份").font(.footnote).foregroundColor(.secondary)
                    } else {
                        ForEach(backupZips, id: \.path) { url in
                            Button {
                                selectedZip = url
                                showUnzipDestPicker = true
                            } label: {
                                HStack {
                                    Image(systemName: "doc.zipper.fill").foregroundColor(.orange)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(url.lastPathComponent).foregroundColor(.primary)
                                        Text(zipLocation(url)).font(.caption).foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundColor(.secondary).font(.footnote)
                                }
                            }
                        }
                    }
                }
                .sheet(isPresented: $showUnzipDestPicker) {
                    UnzipDestView(
                        zipURL: selectedZip,
                        folders: listFolders(in: documentsDir(), excluding: ["备份"]),
                        onPick: { dest in
                            showUnzipDestPicker = false
                            if let zip = selectedZip { startUnzip(zip: zip, to: dest) }
                        },
                        onCancel: { showUnzipDestPicker = false }
                    )
                }

                // MARK: 记录
                Section(header: Text("备份记录")) {
                    if manager.records.isEmpty {
                        Text("暂无记录").foregroundColor(.secondary)
                    } else {
                        ForEach(manager.records) { r in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.name).font(.headline)
                                Text("\(formatDate(r.date)) · \(r.sourceName) → \(r.destName)")
                                    .font(.caption).foregroundColor(.secondary)
                                // v9.0: 显示备份文件是否存在、大小，方便查看
                                if let url = backupZips.first(where: { $0.lastPathComponent == r.name }) {
                                    Text("✅ 文件存在 · \(fileSizeString(url)) · 去“恢复”区可解压")
                                        .font(.caption).foregroundColor(.green)
                                } else {
                                    Text("⚠️ 备份文件已不在（可能已删除或移动）")
                                        .font(.caption).foregroundColor(.orange)
                                }
                            }
                        }
                        .onDelete(perform: manager.deleteRecord)
                    }
                }

                // v9.1: 系统选择器诊断测试
                Section(header: Text("诊断")) {
                    Text("测试系统文件夹选择器能不能用（单选模式）。点按钮 → 进任意文件夹 → 点右上角“打开”，看下面显示什么。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Button("🧪 测试系统文件夹选择器") { testSystemPicker() }
                    if !testPickerStatus.isEmpty {
                        Text(testPickerStatus).font(.footnote)
                        if !testPickedPath.isEmpty {
                            Text(testPickedPath).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("备份助手")
            .onAppear {
                refresh()
                checkPasteboard()
            }
            // v6.0：回到前台自动刷新 + 检查剪贴板
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                refresh()
                checkPasteboard()
            }
            .alert("提示", isPresented: $showAlert) { Button("好") {} } message: { Text(alertText) }
            // v9.0: 备份完成弹窗——明确保存位置，可分享，可清理源文件夹
            .alert("备份完成", isPresented: $showBackupDone, presenting: lastBackupSource) { src in
                Button("分享到 iCloud") { if let u = lastBackupURL { shareURL(u) } }
                Button("删除源文件夹", role: .destructive) {
                    try? FileManager.default.removeItem(at: src)
                    refresh()
                }
                Button("保留", role: .cancel) {}
            } message: { _ in
                Text(backupDoneText)
            }
        }
    }

    // MARK: - 逻辑

    func refresh() {
        // v7.0：先把分享扩展导入的内容搬进来
        let imported = importFromShareExtension(backupRoot: manager.localBackupRoot())
        sourceFolders = listFolders(in: documentsDir(), excluding: ["备份"])
        // v9.0: 备份/子目录和Documents根目录的zip都列出来（扩展存过来的也在根目录）
        let allZips = listZips(in: manager.localBackupRoot()) + listZips(in: documentsDir())
        backupZips = allZips.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        if imported > 0 {
            alertText = "已从分享导入 \(imported) 个项目，可直接备份/恢复"
            showAlert = true
        }
    }

    // v9.0: 显示zip所在位置
    func zipLocation(_ url: URL) -> String {
        url.deletingLastPathComponent().lastPathComponent == "备份" ? "备份助手/备份/" : "备份助手/"
    }

    // v9.0: 文件大小显示
    func fileSizeString(_ url: URL) -> String {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) else { return "" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: size)
    }

    func checkPasteboard() {
        // 只在没有文件夹时提示，避免打扰
        showPasteboardHint = pasteboardHasFiles() && sourceFolders.isEmpty
    }

    func formatDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: d)
    }

    func openFilesApp() {
        if let url = URL(string: "shareddocuments://") {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }

    // v9.1: 系统文件夹选择器诊断测试（单选+主窗口常规弹出）
    func testSystemPicker() {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder])
        // 注意：故意不设 allowsMultipleSelection，单选模式，避开已知多选 bug
        TestPickerDelegate.shared.onResult = { ok, result in
            if ok {
                let parts = result.components(separatedBy: "||")
                self.testPickerStatus = "✅ 选到了：\(parts[0])"
                self.testPickedPath = parts.count > 1 ? parts[1] : ""
            } else {
                self.testPickerStatus = "🚫 \(result)"
                self.testPickedPath = ""
            }
            TestPickerDelegate.shared.onResult = nil
        }
        vc.delegate = TestPickerDelegate.shared
        testPickerStatus = "选择器已弹出：进文件夹 → 点右上角“打开”…"
        testPickedPath = ""
        topVC()?.present(vc, animated: true)
    }

    func startZipBackup(from src: URL) {
        let name = backupName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = name.isEmpty ? defaultBackupName(for: src.lastPathComponent) : name
        manager.isWorking = true
        manager.progress = 0
        manager.status = "正在压缩…"
        showPasteboardHint = false
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let zipURL = manager.localBackupRoot().appendingPathComponent(finalName + ".zip")
                if FileManager.default.fileExists(atPath: zipURL.path) {
                    try FileManager.default.removeItem(at: zipURL)
                }
                try zipDirectory(at: src, to: zipURL)
                DispatchQueue.main.async {
                    manager.isWorking = false
                    manager.progress = 1
                    manager.status = "压缩完成"
                    manager.addRecord(name: finalName + ".zip", sourceName: src.lastPathComponent, destName: "本机")
                    lastBackupURL = zipURL
                    lastBackupSource = src
                    backupName = defaultBackupName()
                    refresh()
                    // v9.0: 备份完成弹窗，明确告诉用户zip存哪了
                    backupDoneText = "「\(finalName).zip」\n已保存到 备份助手/备份/\n\n在“文件”App的备份助手文件夹中可以找到。"
                    showBackupDone = true
                }
            } catch {
                DispatchQueue.main.async {
                    manager.isWorking = false
                    manager.status = "失败"
                    alertText = "压缩失败：\(error.localizedDescription)"
                    showAlert = true
                }
            }
        }
    }

    func startUnzip(zip: URL, to dest: URL) {
        manager.isWorking = true
        manager.progress = 0
        manager.status = "正在解压…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try unzipFile(at: zip, to: dest)
                DispatchQueue.main.async {
                    manager.isWorking = false
                    manager.progress = 1
                    manager.status = "解压完成"
                    alertText = "已解压到「\(dest.lastPathComponent)」"
                    showAlert = true
                }
            } catch {
                DispatchQueue.main.async {
                    manager.isWorking = false
                    manager.status = "失败"
                    alertText = "解压失败：\(error.localizedDescription)"
                    showAlert = true
                }
            }
        }
    }

    func shareURL(_ url: URL) {
        let avc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let pop = avc.popoverPresentationController {
            pop.sourceView = topVC()?.view
            pop.sourceRect = CGRect(x: 200, y: 200, width: 1, height: 1)
        }
        topVC()?.present(avc, animated: true)
    }
}

// MARK: - 选择解压目标
struct UnzipDestView: View {
    let zipURL: URL?
    let folders: [URL]
    let onPick: (URL) -> Void
    let onCancel: () -> Void
    @State private var newFolderName = ""

    var body: some View {
        NavigationView {
            List {
                // v9.0: 可新建文件夹作为解压目标
                Section(header: Text("新建文件夹")) {
                    HStack {
                        TextField("输入新文件夹名", text: $newFolderName)
                        Button("创建并解压") {
                            let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                            let dest = documentsDir().appendingPathComponent(name, isDirectory: true)
                            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                            newFolderName = ""
                            onPick(dest)
                        }
                        .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                Section(header: Text("解压「\(zipURL?.lastPathComponent ?? "")」到…")) {
                    Button {
                        onPick(documentsDir())
                    } label: {
                        HStack {
                            Image(systemName: "folder.fill").foregroundColor(.blue)
                            Text("备份助手根目录").foregroundColor(.primary)
                            Spacer()
                        }
                    }
                    ForEach(folders, id: \.path) { url in
                        Button { onPick(url) } label: {
                            HStack {
                                Image(systemName: "folder.fill").foregroundColor(.blue)
                                Text(url.lastPathComponent).foregroundColor(.primary)
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle("选择解压位置")
            .navigationBarItems(trailing: Button("取消") { onCancel() })
        }
    }
}

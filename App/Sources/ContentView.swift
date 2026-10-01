import SwiftUI
import UIKit
import UniformTypeIdentifiers

// v12: 文件夹选择器（老式 API + 强持有 delegate），解压目标可选任意文件夹
// v18: FolderPickerDelegate 已删除（系统文件夹选择器不可用）

// v12: 文件选择器（老式 API + 强持有 delegate）
class ZipPickerDelegate: NSObject, UIDocumentPickerDelegate {
    var onPick: ((URL) -> Void)?
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if let url = urls.first { onPick?(url) }
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
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

// v9.2: 系统选择器已确认在此设备上不可用（v1.5/v3.0/v3.1/v9.1 四种写法：fileImporter、多选、单选+独立窗口、单选+常规弹出，
// 点"打开"均无响应，delegate 不触发）。改走"文件App分享到备份助手"扩展导入，不再保留诊断代码。

struct ContentView: View {
    // v27: 备份到 iCloud 分享表
    @State private var showICloudShare = false
    @StateObject private var manager = BackupManager()

    // 恢复
    @State private var backupZips: [URL] = []
    @State private var selectedZip: URL?
    @State private var showUnzipDestPicker = false

    @State private var alertText = ""
    @State private var showAlert = false
    // v12: 选择器强持有（防止 delegate 被释放导致无回调）
    @State private var zipPickerDelegate: ZipPickerDelegate?


    var body: some View {
        NavigationView {
            List {
                // v11: 备份功能已去掉，只留恢复

                if manager.isWorking || !manager.status.isEmpty {
                    Section {
                        ProgressView(value: manager.progress)
                        Text(manager.status).font(.footnote).foregroundColor(.secondary)
                    }
                }

                // MARK: 备份（压缩成 zip）
                // v17: 回到原版——文件App长按文件夹→共享→备份助手，扩展压好自动存，打开App就能看到
                Section(header: Text("备份")) {
                    Text("去“文件”App 长按文件夹 → 共享 → 备份助手，压好后选“存到本机”（App 里直接恢复）或“存到 iCloud”（分享菜单里选 iCloud 云盘 → Shortcuts）。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    HStack {
                        Button("去文件 App") { openFilesApp() }
                            .font(.footnote)
                        Spacer()
                        // v27: 一键分享本机 zip，手动存到 iCloud 云盘/Shortcuts
                        Button {
                            showICloudShare = true
                        } label: {
                            HStack {
                                Image(systemName: "cloud.fill")
                                Text("备份到 iCloud")
                            }.font(.footnote)
                        }
                        .disabled(backupZips.isEmpty)
                    }
                    if backupZips.isEmpty {
                        Text("本机还没有 zip，先去文件 App 分享一个文件夹过来。")
                            .font(.footnote).foregroundColor(.secondary)
                    }
                }

                // MARK: 恢复（解压 zip）
                // v10: 只留一句话说明，不再放导入按钮（按钮跳文件App后用户直接在那点zip，系统就地解压）
                Section(header: Text("恢复")) {
                    // v12: 直接选 zip 文件，不用先复制
                    // v27: 改回单个按钮（v26 双按钮容易误解；选择器里本来就能进 iCloud 云盘）
                    Button {
                        pickZipFile()
                    } label: {
                        HStack {
                            Image(systemName: "folder.badge.plus").foregroundColor(.blue)
                            Text("选择 zip 文件").foregroundColor(.primary).font(.headline)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundColor(.secondary).font(.footnote)
                        }
                    }

                    Text("点上面选个 zip，再选解压到哪个文件夹。选择器里点“浏览”可进 iCloud 云盘。")
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    if backupZips.isEmpty {
                        Text("还没有选过 zip，点上面“选择 zip 文件”")
                            .font(.footnote).foregroundColor(.secondary)
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
                // v27: 备份到 iCloud 分享表
                .sheet(isPresented: $showICloudShare) {
                    ShareSheet(items: backupZips)
                }

                // MARK: 记录
                // v9.5: refresh() 已自动给无记录 zip 建档，这里只显示正式记录
                Section(header: Text("恢复记录")) {
                    if manager.records.isEmpty {
                        Text("暂无记录：完成一次备份/恢复后这里会显示")
                            .font(.footnote).foregroundColor(.secondary)
                    } else {
                        ForEach(manager.records) { r in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    // v9.4: 备份/恢复标识
                                    Text(r.kind == "restore" ? "恢复" : "备份")
                                        .font(.caption2)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(r.kind == "restore" ? Color.green.opacity(0.2) : Color.blue.opacity(0.2))
                                        .cornerRadius(4)
                                    Text(r.name).font(.headline)
                                }
                                Text("\(formatDate(r.date)) · \(r.sourceName) → \(r.destName)")
                                    .font(.caption).foregroundColor(.secondary)
                                // v9.0: 显示备份文件是否存在、大小，方便查看
                                // v9.4: 恢复记录不查文件（zip 可能已删），只给备份记录查
                                if r.kind == "backup", let url = backupZips.first(where: { $0.lastPathComponent == r.name }) {
                                    Text("✅ 文件存在 · \(fileSizeString(url))")
                                        .font(.caption).foregroundColor(.green)
                                    Button("恢复此备份") {
                                        selectedZip = url
                                        showUnzipDestPicker = true
                                    }
                                    .font(.footnote)
                                } else if r.kind == "backup" {
                                    Text("⚠️ 备份文件已不在（可能已删除或移动）")
                                        .font(.caption).foregroundColor(.orange)
                                }
                            }
                        }
                        .onDelete(perform: manager.deleteRecord)
                    }
                }

                // v10: 版本号
                Section {
                    Text("版本 v27.1").font(.caption).foregroundColor(.secondary)
                }
            }
            .navigationTitle("备份助手")
            .onAppear {
                refresh()
            }
            // v6.0：回到前台自动刷新
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                refresh()
            }
            .alert("提示", isPresented: $showAlert) { Button("好") {} } message: { Text(alertText) }
        }
    }

    // MARK: - 逻辑

    func refresh() {
        // v7.0：先把分享扩展导入的内容搬进来
        let imported = importFromShareExtension(backupRoot: manager.localBackupRoot())
        // v9.0: 备份/子目录和Documents根目录的zip都列出来（扩展存过来的也在根目录）
        let allZips = listZips(in: manager.localBackupRoot()) + listZips(in: documentsDir())
        backupZips = allZips.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        // v9.5: 给无记录的 zip 自动建备份记录（分享扩展打出来的包）
        let fm = FileManager.default
        for zip in backupZips {
            let attrs = try? fm.attributesOfItem(atPath: zip.path)
            let mdate = (attrs?[.modificationDate] as? Date) ?? Date()
            manager.ensureRecordForZip(name: zip.lastPathComponent, fileDate: mdate)
        }
        if imported > 0 {
            alertText = "已从分享导入 \(imported) 个项目，可直接恢复"
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

    // v12: 老式 API 选择 zip（单选），delegate 强持有
    func pickZipFile() {
        let delegate = ZipPickerDelegate()
        // 先拷到本机 Documents，选完直接进解压目标选择
        delegate.onPick = { url in
            let needStop = url.startAccessingSecurityScopedResource()
            defer { if needStop { url.stopAccessingSecurityScopedResource() } }
            let dest = documentsDir().appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.copyItem(at: url, to: dest)
                DispatchQueue.main.async {
                    self.refresh()
                    self.selectedZip = dest
                    self.showUnzipDestPicker = true
                }
            } catch {
                DispatchQueue.main.async {
                    self.alertText = "读取失败：\(error.localizedDescription)"
                    self.showAlert = true
                }
            }
        }
        zipPickerDelegate = delegate
        // 老式初始化方法，兼容性最好
        let picker = UIDocumentPickerViewController(documentTypes: ["public.zip-archive", "com.pkware.zip-archive"], in: .import)
        picker.delegate = delegate
        picker.allowsMultipleSelection = false
        picker.modalPresentationStyle = .formSheet
        if let root = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow })?.rootViewController {
            var top = root
            while let p = top.presentedViewController { top = p }
            top.present(picker, animated: true)
        }
    }

    // v16: pickBackupFolder 已删除（系统选择器不可用），备份走分享扩展排队

    // v14: 把选中的文件夹打包成 zip 存到备份助手文件夹
    // v16: startBackup 已删除（备份走分享扩展排队）

    // v9.2: 系统选择器诊断函数已删除（确认不可用），改走分享扩展导入

    // v11: 备份功能已去掉，startZipBackup 删除

    func startUnzip(zip: URL, to dest: URL) {
        manager.isWorking = true
        manager.progress = 0
        manager.status = "正在解压…"
        DispatchQueue.global(qos: .userInitiated).async {
            // v13: 外部选的文件夹需要 security-scoped 访问
            let needStop = dest.startAccessingSecurityScopedResource()
            defer { if needStop { dest.stopAccessingSecurityScopedResource() } }
            do {
                // v19: 流式解压，带进度；v26: 进度条按总数算
                try unzipFile(at: zip, to: dest) { done, total, name in
                    DispatchQueue.main.async {
                        self.manager.status = "正在解压 \(done)/\(total)…\(name)"
                        if total > 0 {
                            self.manager.progress = Double(done) / Double(total)
                        }
                    }
                }
                DispatchQueue.main.async {
                    manager.isWorking = false
                    manager.progress = 1
                    manager.status = "解压完成"
                    // v9.4: 恢复也要存记录
                    manager.addRestoreRecord(zipName: zip.lastPathComponent, destName: dest.lastPathComponent)
                    alertText = "已解压到「\(dest.path)」"
                    showAlert = true
                    refresh()
                }
            } catch {
                // v25: 部分成功也算成功，记恢复记录
                let isPartial = (error as? ZipError).map {
                    if case .partialFailure = $0 { return true }
                    return false
                } ?? false
                DispatchQueue.main.async {
                    manager.isWorking = false
                    if isPartial {
                        manager.progress = 1
                        manager.status = "部分解压完成"
                        manager.addRestoreRecord(zipName: zip.lastPathComponent, destName: dest.lastPathComponent)
                        alertText = "\(error.localizedDescription)，已解压到「\(dest.path)」"
                    } else {
                        manager.status = "失败"
                        alertText = "解压失败：\(error.localizedDescription)"
                    }
                    showAlert = true
                    refresh()
                }
            }
        }
    }

    // v11: 备份功能已去掉，shareURL 删除
}

// MARK: - 选择解压目标
struct UnzipDestView: View {
    let zipURL: URL?
    let folders: [URL]
    let onPick: (URL) -> Void
    let onCancel: () -> Void
    @State private var newFolderName = ""
    // v9.4: 选目标后先确认，让"自己选择"更明确，不直接解压
    @State private var confirmDest: URL?
    @State private var showConfirm = false
    // v19: 剪贴板路径；v22: 存 URL，解压时 startUnzip 会拿 security-scoped 访问
    @State private var clipboardPath: String?
    @State private var clipboardURL: URL?

    func choose(_ dest: URL) {
        confirmDest = dest
        showConfirm = true
    }

    // v18: pickFolder 已删除（系统文件夹选择器不可用），外部恢复走分享扩展

    var body: some View {
        NavigationView {
            List {
                // v9.0: 可新建文件夹作为解压目标
                // v9.2: 去掉禁用逻辑，空名自动生成，按钮永远可点
                Section(header: Text("新建文件夹")) {
                    HStack {
                        TextField("输入新文件夹名（可空，自动生成）", text: $newFolderName)
                        Button("创建并解压") {
                            var name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                            if name.isEmpty {
                                let f = DateFormatter()
                                f.dateFormat = "MMdd-HHmm"
                                name = "恢复-" + f.string(from: Date())
                            }
                            let dest = documentsDir().appendingPathComponent(name, isDirectory: true)
                            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                            newFolderName = ""
                            choose(dest)
                        }
                    }
                }
                Section(header: Text("解压「\(zipURL?.lastPathComponent ?? "")」到…")) {
                    // v19: 剪贴板有路径就显示，问用户要不要解压到那
                    if let cp = clipboardPath {
                        Button {
                            if let u = clipboardURL {
                                choose(u)
                            } else {
                                choose(URL(fileURLWithPath: cp, isDirectory: true))
                            }
                        } label: {
                            HStack {
                                Image(systemName: "doc.on.clipboard").foregroundColor(.orange)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("解压到剪贴板路径").foregroundColor(.primary).font(.headline)
                                    Text(cp).font(.caption).foregroundColor(.secondary).lineLimit(1)
                                }
                                Spacer()
                            }
                        }
                    }
                    // v18: 系统文件夹选择器不可用已删；要恢复到其他 App 的位置（如 LiveContainer），
                    // 去文件 App 长按 zip → 共享 → 备份助手，扩展解压后选位置保存（可覆盖）
                    Button {
                        choose(documentsDir())
                    } label: {
                        HStack {
                            Image(systemName: "folder.fill").foregroundColor(.blue)
                            Text("备份助手根目录").foregroundColor(.primary)
                            Spacer()
                        }
                    }
                    ForEach(folders, id: \.path) { url in
                        Button { choose(url) } label: {
                            HStack {
                                Image(systemName: "folder.fill").foregroundColor(.blue)
                                Text(url.lastPathComponent).foregroundColor(.primary)
                                Spacer()
                            }
                        }
                    }
                }
                Section {
                    Text("恢复到 LiveContainer 等外部文件夹：先去“文件”App 长按目标文件夹→拷贝，再回来这里选 zip，会多出“解压到剪贴板路径”选项，有同名直接覆盖。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("选择解压位置")
            .navigationBarItems(trailing: Button("取消") { onCancel() })
            .onAppear { checkClipboardPath() }
            .alert("解压到这个文件夹？", isPresented: $showConfirm, presenting: confirmDest) { dest in
                Button("取消", role: .cancel) {}
                Button("开始解压") { onPick(dest) }
            } message: { dest in
                Text("将「\(zipURL?.lastPathComponent ?? "")」解压到「\(dest.path)」")
            }
        }
    }

    // v22: 文件 App 里长按文件夹→拷贝，粘贴板会有 security-scoped 的文件 URL
    // 验证时临时 startAccessing，否则外部路径 fileExists 直接返回 false；
    // 真正解压时 startUnzip 会再拿一次访问
    func checkClipboardPath() {
        clipboardURL = nil
        clipboardPath = nil

        let pb = UIPasteboard.general
        if let urls = pb.urls {
            for url in urls {
                let accessing = url.startAccessingSecurityScopedResource()
                var isDir: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                let ok = exists && isDir.boolValue
                if accessing { url.stopAccessingSecurityScopedResource() }
                if ok {
                    clipboardURL = url
                    clipboardPath = url.path
                    return
                }
            }
        }
        // 路径文本：只能验证 App 沙盒内的
        if let str = pb.string?.trimmingCharacters(in: .whitespacesAndNewlines),
           !str.isEmpty, str.hasPrefix("/"),
           FileManager.default.fileExists(atPath: str) {
            clipboardPath = str
        }
    }
}

// MARK: - v27: UIActivityViewController 包装
struct ShareSheet: UIViewControllerRepresentable {
    let items: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        return vc
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

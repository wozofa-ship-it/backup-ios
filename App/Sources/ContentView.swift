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
    // v28: 解压取消
    @State private var unzipCancelled = false
    // v30: 捷径备份选 zip
    @State private var showShortcutPicker = false
    // v31: 捷径解压缩选 zip
    @State private var showShortcutUnzipPicker = false
    @StateObject private var manager = BackupManager()

    // 恢复
    @State private var backupZips: [URL] = []
    @State private var selectedZip: URL?
    @State private var showUnzipDestPicker = false

    @State private var alertText = ""
    @State private var showAlert = false
    // v12: 选择器强持有（防止 delegate 被释放导致无回调）
    @State private var zipPickerDelegate: ZipPickerDelegate?

    // v35: iCloud 备份指定文件夹
    @State private var iCloudBackingUp = false
    // v35: 移动文件
    @State private var moveSource: URL?
    @State private var moveDest: URL?
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""

    // v34: 可定时备份的文件夹（Documents 下除"备份"外的子文件夹）
    var schedulableFolders: [URL] {
        listFolders(in: documentsDir(), excluding: ["备份"])
    }


    var body: some View {
        NavigationView {
            List {
                // v11: 备份功能已去掉，只留恢复

                if manager.isWorking || !manager.status.isEmpty {
                    Section {
                        ProgressView(value: manager.progress)
                        HStack {
                            Text(manager.status).font(.footnote).foregroundColor(.secondary)
                            Spacer()
                            // v28: 解压停止按钮
                            if manager.isWorking {
                                Button("停止") { unzipCancelled = true }
                                    .font(.footnote)
                                    .foregroundColor(.red)
                            }
                        }
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
                        // v30: 捷径一键备份到 iCloud/Shortcuts
                        Button {
                            showShortcutPicker = true
                        } label: {
                            HStack {
                                Image(systemName: "bolt.fill")
                                Text("一键备份到 iCloud")
                            }.font(.footnote)
                        }
                        .disabled(backupZips.isEmpty)
                    }
                    HStack {
                        Spacer()
                        // v27: 分享菜单手动存
                        Button {
                            showICloudShare = true
                        } label: {
                            HStack {
                                Image(systemName: "square.and.arrow.up")
                                Text("分享菜单存 iCloud")
                            }.font(.footnote)
                        }
                        .disabled(backupZips.isEmpty)
                    }
                    if backupZips.isEmpty {
                        Text("本机还没有 zip，先去文件 App 分享一个文件夹过来。")
                            .font(.footnote).foregroundColor(.secondary)
                    }
                }

                // MARK: v34 定时备份（捷径自动化调用 App 动作）
                Section(header: Text("定时备份")) {
                    Text("去“捷径”App → 自动化 → 新建 → 到达时间（选每周/每月）→ 运行“备份助手”的“定时备份文件夹”动作，填下面要备份的文件夹名。到点自动打 zip 存到备份目录。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    ForEach(schedulableFolders, id: \.lastPathComponent) { folder in
                        HStack {
                            Image(systemName: "folder").foregroundColor(.blue).font(.footnote)
                            Text(folder.lastPathComponent).font(.footnote)
                            Spacer()
                            Button("复制名称") {
                                UIPasteboard.general.string = folder.lastPathComponent
                            }.font(.footnote)
                        }
                    }
                    if schedulableFolders.isEmpty {
                        Text("备份助手目录里还没有文件夹。")
                            .font(.footnote).foregroundColor(.secondary)
                    }
                }

                // MARK: v35 iCloud 备份指定文件夹
                Section(header: Text("iCloud 备份文件夹")) {
                    Text("选一个文件夹，打包成 zip 后一键存到 iCloud 云盘 ▸ Shortcuts。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    ForEach(schedulableFolders, id: \.lastPathComponent) { folder in
                        HStack {
                            Image(systemName: "folder").foregroundColor(.blue).font(.footnote)
                            Text(folder.lastPathComponent).font(.footnote)
                            Spacer()
                            Button {
                                backupFolderToICloud(folder)
                            } label: {
                                HStack {
                                    Image(systemName: "icloud.and.arrow.up")
                                    Text("备份到 iCloud")
                                }.font(.footnote)
                            }
                            .disabled(iCloudBackingUp)
                        }
                    }
                    if schedulableFolders.isEmpty {
                        Text("备份助手目录里还没有文件夹。")
                            .font(.footnote).foregroundColor(.secondary)
                    }
                    if iCloudBackingUp {
                        HStack {
                            ProgressView().scaleEffect(0.8)
                            Text("正在打包…").font(.footnote).foregroundColor(.secondary)
                        }
                    }
                }

                // MARK: v35 移动文件到指定文件夹
                Section(header: Text("移动文件")) {
                    Text("把文件或文件夹移动到指定位置。先选要移动的，再选目标文件夹。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    // 源选择
                    Text("1. 要移动的").font(.footnote).foregroundColor(.secondary)
                    ForEach(moveableItems, id: \.lastPathComponent) { item in
                        Button {
                            moveSource = item
                        } label: {
                            HStack {
                                Image(systemName: isDirectory(item) ? "folder" : "doc")
                                    .foregroundColor(.blue).font(.footnote)
                                Text(item.lastPathComponent).font(.footnote)
                                    .foregroundColor(.primary)
                                Spacer()
                                if moveSource?.lastPathComponent == item.lastPathComponent {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.blue).font(.footnote)
                                }
                            }
                        }
                    }
                    // 目标选择
                    Text("2. 移动到").font(.footnote).foregroundColor(.secondary)
                    ForEach(moveDestFolders, id: \.lastPathComponent) { folder in
                        Button {
                            moveDest = folder
                        } label: {
                            HStack {
                                Image(systemName: "folder").foregroundColor(.green).font(.footnote)
                                Text(folder.lastPathComponent).font(.footnote)
                                    .foregroundColor(.primary)
                                Spacer()
                                if moveDest?.lastPathComponent == folder.lastPathComponent {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green).font(.footnote)
                                }
                            }
                        }
                    }
                    HStack {
                        Button {
                            showNewFolderAlert = true
                        } label: {
                            HStack {
                                Image(systemName: "folder.badge.plus")
                                Text("新建文件夹")
                            }.font(.footnote)
                        }
                        Spacer()
                        Button {
                            executeMove()
                        } label: {
                            HStack {
                                Image(systemName: "arrow.right.circle.fill")
                                Text("执行移动")
                            }.font(.headline)
                        }
                        .disabled(moveSource == nil || moveDest == nil)
                    }
                    .alert("新建文件夹", isPresented: $showNewFolderAlert) {
                        TextField("文件夹名称", text: $newFolderName)
                        Button("取消", role: .cancel) { newFolderName = "" }
                        Button("创建") { createMoveDestFolder() }
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
                    // v31: 捷径解压（系统权限，可写 LiveContainer/微信）
                    Button {
                        showShortcutUnzipPicker = true
                    } label: {
                        HStack {
                            Image(systemName: "bolt.fill").foregroundColor(.orange)
                            Text("捷径解压到 LiveContainer/微信").foregroundColor(.primary).font(.headline)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundColor(.secondary).font(.footnote)
                        }
                    }

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
                // v30: 捷径备份选 zip
                .sheet(isPresented: $showShortcutPicker) {
                    ShortcutZipPicker(zips: backupZips, onPick: { url in
                        showShortcutPicker = false
                        runBackupShortcut(zipName: url.lastPathComponent)
                    }, onCancel: { showShortcutPicker = false })
                }
                // v31: 捷径解压选 zip + 目的地
                .sheet(isPresented: $showShortcutUnzipPicker) {
                    ShortcutUnzipPicker(zips: backupZips, onPick: { url, dest in
                        showShortcutUnzipPicker = false
                        runUnzipShortcut(zipName: url.lastPathComponent, dest: dest)
                    }, onCancel: { showShortcutUnzipPicker = false })
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
                    Text("版本 v34").font(.caption).foregroundColor(.secondary)
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
        unzipCancelled = false
        DispatchQueue.global(qos: .userInitiated).async {
            // v13: 外部选的文件夹需要 security-scoped 访问
            let needStop = dest.startAccessingSecurityScopedResource()
            defer { if needStop { dest.stopAccessingSecurityScopedResource() } }
            do {
                // v19: 流式解压，带进度；v26: 进度条按总数算；v28: 支持取消
                try unzipFile(at: zip, to: dest, progress: { done, total, name in
                    DispatchQueue.main.async {
                        self.manager.status = "正在解压 \(done)/\(total)…\(name)"
                        if total > 0 {
                            self.manager.progress = Double(done) / Double(total)
                        }
                    }
                }, shouldCancel: { self.unzipCancelled })
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
                    } else if unzipCancelled {
                        manager.status = "已取消"
                        alertText = "已取消解压"
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
    // v28: 手动输入路径
    @State private var customPath = ""
    @State private var pathError: String?

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
                // v28: 手动输入/粘贴目标路径
                Section(header: Text("指定路径解压")) {
                    HStack {
                        TextField("粘贴或输入目标文件夹路径", text: $customPath)
                            .textFieldStyle(.roundedBorder)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        Button("粘贴") {
                            if let str = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !str.isEmpty {
                                customPath = str
                            }
                        }.font(.footnote)
                    }
                    Button {
                        let p = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !p.isEmpty else { return }
                        // v29.1: 先校验——必须是 / 开头的真实路径，不能是文件App里显示的名字
                        guard p.hasPrefix("/") else {
                            pathError = "这不是系统路径（别粘文件App里显示的名字）。如需解压到 LiveContainer/微信，请用“捷径解压”。"
                            return
                        }
                        var isDir: ObjCBool = false
                        let exists = FileManager.default.fileExists(atPath: p, isDirectory: &isDir)
                        if exists && isDir.boolValue {
                            pathError = nil
                            choose(URL(fileURLWithPath: p, isDirectory: true))
                        } else if !exists {
                            // 路径不存在，尝试创建（仅 App 沙盒内有效）
                            do {
                                try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
                                pathError = nil
                                choose(URL(fileURLWithPath: p, isDirectory: true))
                            } catch {
                                pathError = "无法使用此路径：\(error.localizedDescription)"
                            }
                        } else {
                            pathError = "这不是一个文件夹路径"
                        }
                    } label: {
                        HStack {
                            Image(systemName: "folder.badge.gearshape").foregroundColor(.orange)
                            Text("解压到此路径").foregroundColor(.primary).font(.headline)
                            Spacer()
                        }
                    }
                    if let err = pathError {
                        Text(err).font(.footnote).foregroundColor(.red)
                    }
                    Text("从文件 App 复制文件夹路径后点“粘贴”。注意：其他 App 的沙盒目录可能无权限写入。")
                        .font(.footnote).foregroundColor(.secondary)
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


// MARK: - v31: 捷径解压（两个固定目的地，各调各的捷径，只传文件名）
extension ContentView {
    func runUnzipShortcut(zipName: String, dest: String) {
        // v33: 简化——LiveContainer 和微信各一个捷径，不用拆分不用判断
        let shortcutName = dest == "微信" ? "备份助手解压到微信" : "备份助手解压到LC"
        let name = shortcutName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let text = zipName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlStr = "shortcuts://run-shortcut?name=\(name)&input=text&text=\(text)"
        if let url = URL(string: urlStr), UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        } else {
            alertText = "没找到“\(shortcutName)”快捷指令，先在捷径 App 里创建"
            showAlert = true
        }
    }
}

// MARK: - v35: iCloud 备份指定文件夹 + 移动文件
extension ContentView {
    /// 可移动的项：Documents 下的文件和文件夹（排除"备份"）
    var moveableItems: [URL] {
        let fm = FileManager.default
        let docs = documentsDir()
        guard let items = try? fm.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return []
        }
        return items.filter { $0.lastPathComponent != "备份" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// 移动目标文件夹：Documents 下的文件夹（排除"备份"）
    var moveDestFolders: [URL] {
        listFolders(in: documentsDir(), excluding: ["备份"])
    }

    func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return isDir.boolValue
    }

    /// v35: 把指定文件夹打成 zip，然后调"备份助手存iCloud"快捷指令存到 iCloud
    func backupFolderToICloud(_ folder: URL) {
        iCloudBackingUp = true
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let docs = documentsDir()
            let backupDir = docs.appendingPathComponent("备份", isDirectory: true)
            try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
            let df = DateFormatter()
            df.dateFormat = "MMdd-HHmm"
            let zipName = "\(folder.lastPathComponent)-\(df.string(from: Date())).zip"
            let zipURL = backupDir.appendingPathComponent(zipName)
            do {
                try zipDirectory(at: folder, to: zipURL)
                DispatchQueue.main.async {
                    iCloudBackingUp = false
                    refresh()
                    // 打包成功，直接调快捷指令存 iCloud
                    runBackupShortcut(zipName: zipName)
                }
            } catch {
                DispatchQueue.main.async {
                    iCloudBackingUp = false
                    alertText = "打包失败：\(error.localizedDescription)"
                    showAlert = true
                }
            }
        }
    }

    /// v35: 执行移动
    func executeMove() {
        guard let src = moveSource, let destFolder = moveDest else { return }
        // 不能移动到自己里面
        if isDirectory(src) && destFolder.path.hasPrefix(src.path) {
            alertText = "不能把文件夹移动到自己里面"
            showAlert = true
            return
        }
        let fm = FileManager.default
        var dest = destFolder.appendingPathComponent(src.lastPathComponent)
        // 同名自动加后缀
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            let base = src.deletingPathExtension().lastPathComponent
            let ext = src.pathExtension
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            dest = destFolder.appendingPathComponent(name)
            n += 1
        }
        do {
            try fm.moveItem(at: src, to: dest)
            alertText = "已移动到“\(destFolder.lastPathComponent)”"
            showAlert = true
            moveSource = nil
            // moveDest 保留，方便连续移动
        } catch {
            alertText = "移动失败：\(error.localizedDescription)"
            showAlert = true
        }
    }

    /// v35: 在 Documents 下新建目标文件夹
    func createMoveDestFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        newFolderName = ""
        guard !name.isEmpty else { return }
        let fm = FileManager.default
        let dest = documentsDir().appendingPathComponent(name, isDirectory: true)
        if fm.fileExists(atPath: dest.path) {
            alertText = "已存在同名文件夹"
            showAlert = true
            return
        }
        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            moveDest = dest
        } catch {
            alertText = "创建失败：\(error.localizedDescription)"
            showAlert = true
        }
    }
}

// MARK: - v30: 捷径一键备份
extension ContentView {
    func runBackupShortcut(zipName: String) {
        // 捷径名：备份助手存iCloud；input 传文件名，捷径里按"备份助手/<文件名>"取文件
        let name = "备份助手存iCloud".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let text = zipName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlStr = "shortcuts://run-shortcut?name=\(name)&input=text&text=\(text)"
        if let url = URL(string: urlStr) {
            if UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
            } else {
                alertText = "没装“捷径”App 或快捷指令不存在，先按下面的教程创建“备份助手存iCloud”"
                showAlert = true
            }
        }
    }
}

// v30: 选要备份的 zip
struct ShortcutZipPicker: View {
    let zips: [URL]
    var title = "一键备份到 iCloud"
    var headerText = "选一个 zip 一键备份到 iCloud 云盘 ▸ Shortcuts"
    let onPick: (URL) -> Void
    let onCancel: () -> Void
    var body: some View {
        NavigationView {
            List {
                Section(header: Text(headerText)) {
                    ForEach(zips, id: \.self) { url in
                        Button {
                            onPick(url)
                        } label: {
                            HStack {
                                Image(systemName: "doc.zipper").foregroundColor(.orange)
                                Text(url.lastPathComponent).foregroundColor(.primary)
                                Spacer()
                                Image(systemName: "bolt.fill").foregroundColor(.blue).font(.footnote)
                            }
                        }
                    }
                }
                Section {
                    Text("需要先在“捷径”App 里创建一个叫“备份助手存iCloud”的快捷指令：接收文本输入 → 获取文件“备份助手/输入的文本”（位置：我的iPhone）→ 存储文件到“iCloud 云盘/Shortcuts”（覆盖打开，不询问）。建一次以后一键直达。")
                        .font(.footnote).foregroundColor(.secondary)
                }
            }
            .navigationTitle(title)
            .navigationBarItems(trailing: Button("取消", action: onCancel))
        }
    }
}

// MARK: - v31: 捷径解压选 zip + 目的地
struct ShortcutUnzipPicker: View {
    let zips: [URL]
    let onPick: (URL, String) -> Void
    let onCancel: () -> Void
    @State private var selectedZip: URL?
    var body: some View {
        NavigationView {
            List {
                if selectedZip == nil {
                    Section(header: Text("第 1 步：选一个 zip")) {
                        ForEach(zips, id: \.self) { url in
                            Button {
                                selectedZip = url
                            } label: {
                                HStack {
                                    Image(systemName: "doc.zipper").foregroundColor(.orange)
                                    Text(url.lastPathComponent).foregroundColor(.primary)
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundColor(.secondary).font(.footnote)
                                }
                            }
                        }
                    }
                } else {
                    Section(header: Text("第 2 步：解压到哪里")) {
                        Button {
                            onPick(selectedZip!, "LiveContainer")
                        } label: {
                            HStack {
                                Image(systemName: "folder.fill").foregroundColor(.blue)
                                Text("我的iPhone ▸ LiveContainer").foregroundColor(.primary).font(.headline)
                                Spacer()
                            }
                        }
                        Button {
                            onPick(selectedZip!, "微信")
                        } label: {
                            HStack {
                                Image(systemName: "folder.fill").foregroundColor(.green)
                                Text("我的iPhone ▸ 微信").foregroundColor(.primary).font(.headline)
                                Spacer()
                            }
                        }
                        Button("重选 zip") { selectedZip = nil }.font(.footnote)
                    }
                    Section {
                        Text("需要两个快捷指令：“备份助手解压到LC”（存到我的iPhone/LiveContainer）和“备份助手解压到微信”（存到我的iPhone/微信）。每个都是：接收文本 → 获取文件（备份助手/输入）→ 解压缩 → 保存到固定位置。")
                            .font(.footnote).foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("捷径解压")
            .navigationBarItems(trailing: Button("取消", action: onCancel))
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

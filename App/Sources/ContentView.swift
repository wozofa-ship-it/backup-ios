import SwiftUI
import UIKit

func defaultBackupName() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    return "备份-" + f.string(from: Date())
}

func documentsDir() -> URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
}

/// 列出 dir 下的文件夹（排除 reserved）
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

struct ContentView: View {
    @StateObject private var manager = BackupManager()

    // 备份
    @State private var backupName: String = defaultBackupName()
    @State private var sourceFolders: [URL] = []
    @State private var pendingSource: URL?
    @State private var showBackupConfirm = false
    @State private var lastBackupURL: URL?

    // 恢复
    @State private var backups: [URL] = []
    @State private var selectedBackup: URL?
    @State private var restoreName: String = ""

    @State private var alertText = ""
    @State private var showAlert = false

    var body: some View {
        NavigationView {
            List {
                // MARK: 备份
                Section(header: Text("备份")) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("① 点下面按钮去“文件”App，把要备份的文件夹拷进“备份助手”")
                        Text("② 回到这里点“刷新”，点文件夹确认备份")
                        Text("③ 备份完点“分享”，可存到 iCloud 云盘")
                    }
                    .font(.footnote)
                    .foregroundColor(.secondary)

                    Button("去“文件”App 拷贝文件夹") {
                        openFilesApp()
                    }
                    .font(.headline)

                    TextField("备份名称", text: $backupName)

                    if sourceFolders.isEmpty {
                        Text("还没有文件夹：先去“文件”App 拷贝进来，再点“刷新”")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(sourceFolders, id: \.path) { url in
                            Button {
                                pendingSource = url
                                showBackupConfirm = true
                            } label: {
                                HStack {
                                    Image(systemName: "folder.fill")
                                        .foregroundColor(.blue)
                                    Text(url.lastPathComponent)
                                        .foregroundColor(.primary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundColor(.secondary)
                                        .font(.footnote)
                                }
                            }
                        }
                    }

                    Button("刷新列表") { refresh() }
                        .font(.footnote)

                    if let done = lastBackupURL {
                        Button("分享备份（存到 iCloud 云盘）") {
                            shareURL(done)
                        }
                        .font(.headline)
                    }
                }
                .alert("备份这个文件夹？", isPresented: $showBackupConfirm, presenting: pendingSource) { url in
                    Button("取消", role: .cancel) {}
                    Button("开始备份") { startBackup(from: url) }
                } message: { url in
                    Text("将把「\(url.lastPathComponent)」备份到本机。")
                }

                if manager.isWorking || !manager.status.isEmpty {
                    Section {
                        ProgressView(value: manager.progress)
                        Text(manager.status)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }

                // MARK: 恢复
                Section(header: Text("恢复")) {
                    Text("选一个备份，输入新文件夹名，恢复到“备份助手”内，再去“文件”App 里移动。")
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    if backups.isEmpty {
                        Text("暂无备份")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(backups, id: \.path) { url in
                            Button {
                                selectedBackup = url
                                if restoreName.isEmpty {
                                    restoreName = url.lastPathComponent + "-恢复"
                                }
                            } label: {
                                HStack {
                                    Image(systemName: selectedBackup?.path == url.path ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(.blue)
                                    Text(url.lastPathComponent)
                                        .foregroundColor(.primary)
                                    Spacer()
                                }
                            }
                        }
                    }

                    TextField("恢复成新文件夹名", text: $restoreName)

                    Button("开始恢复") { startRestore() }
                        .disabled(manager.isWorking || selectedBackup == nil || restoreName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("刷新列表") { refresh() }
                        .font(.footnote)
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
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .onDelete(perform: manager.deleteRecord)
                    }
                }
            }
            .navigationTitle("备份助手")
            .onAppear { refresh() }
            .alert("提示", isPresented: $showAlert) {
                Button("好") {}
            } message: {
                Text(alertText)
            }
        }
    }

    // MARK: - 逻辑

    func refresh() {
        sourceFolders = listFolders(in: documentsDir(), excluding: ["备份"])
        backups = listFolders(in: manager.localBackupRoot())
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

    func startBackup(from src: URL) {
        let name = backupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            alertText = "请先输入备份名称"
            showAlert = true
            return
        }
        manager.backupFolder(from: src, toParent: manager.localBackupRoot(), name: name) { ok, msg in
            if ok {
                manager.addRecord(name: name, sourceName: src.lastPathComponent, destName: "本机")
                lastBackupURL = manager.localBackupRoot().appendingPathComponent(name, isDirectory: true)
                backupName = defaultBackupName()
                refresh()
                alertText = "备份成功！点“分享备份”可存到 iCloud 云盘。"
            } else {
                alertText = msg
            }
            showAlert = true
        }
    }

    func startRestore() {
        guard let src = selectedBackup else { return }
        let name = restoreName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        manager.backupFolder(from: src, toParent: documentsDir(), name: name) { ok, msg in
            if ok {
                refresh()
                alertText = "恢复成功：已恢复到“备份助手/\(name)”"
            } else {
                alertText = msg
            }
            showAlert = true
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

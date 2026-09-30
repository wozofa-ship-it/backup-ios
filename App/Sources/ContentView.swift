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

struct ContentView: View {
    @StateObject private var manager = BackupManager()

    // 备份
    @State private var backupName: String = defaultBackupName()
    @State private var sourceFolders: [URL] = []
    @State private var pendingSource: URL?
    @State private var showBackupConfirm = false
    @State private var lastBackupURL: URL?

    // 恢复
    @State private var backupZips: [URL] = []
    @State private var selectedZip: URL?
    @State private var unzipDest: URL?
    @State private var showUnzipDestPicker = false

    @State private var alertText = ""
    @State private var showAlert = false

    var body: some View {
        NavigationView {
            List {
                // MARK: 备份（压缩成 zip）
                Section(header: Text("备份")) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("① 点下面按钮去“文件”App，把要备份的文件夹拷进“备份助手”")
                        Text("② 回到这里点“刷新”，点文件夹确认压缩备份成 .zip")
                        Text("③ 点“分享”可把 .zip 存到 iCloud 云盘")
                    }
                    .font(.footnote)
                    .foregroundColor(.secondary)

                    Button("去“文件”App 拷贝文件夹") { openFilesApp() }
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
                                    Image(systemName: "folder.fill").foregroundColor(.blue)
                                    Text(url.lastPathComponent).foregroundColor(.primary)
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundColor(.secondary).font(.footnote)
                                }
                            }
                        }
                    }

                    Button("刷新列表") { refresh() }.font(.footnote)

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
                                    Text(url.lastPathComponent).foregroundColor(.primary)
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundColor(.secondary).font(.footnote)
                                }
                            }
                        }
                    }
                    Button("刷新列表") { refresh() }.font(.footnote)
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
                            }
                        }
                        .onDelete(perform: manager.deleteRecord)
                    }
                }
            }
            .navigationTitle("备份助手")
            .onAppear { refresh() }
            .alert("提示", isPresented: $showAlert) { Button("好") {} } message: { Text(alertText) }
        }
    }

    // MARK: - 逻辑

    func refresh() {
        sourceFolders = listFolders(in: documentsDir(), excluding: ["备份"])
        backupZips = listZips(in: manager.localBackupRoot())
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

    func startZipBackup(from src: URL) {
        let name = backupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            alertText = "请先输入备份名称"
            showAlert = true
            return
        }
        manager.isWorking = true
        manager.progress = 0
        manager.status = "正在压缩…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let zipURL = manager.localBackupRoot().appendingPathComponent(name + ".zip")
                if FileManager.default.fileExists(atPath: zipURL.path) {
                    try FileManager.default.removeItem(at: zipURL)
                }
                try zipDirectory(at: src, to: zipURL)
                DispatchQueue.main.async {
                    manager.isWorking = false
                    manager.progress = 1
                    manager.status = "压缩完成"
                    manager.addRecord(name: name + ".zip", sourceName: src.lastPathComponent, destName: "本机")
                    lastBackupURL = zipURL
                    backupName = defaultBackupName()
                    refresh()
                    alertText = "已打包成 \(name).zip，点“分享”可存到 iCloud 云盘。"
                    showAlert = true
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

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("解压「\(zipURL?.lastPathComponent ?? "")」到…")) {
                    // 解压到备份助手根目录
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

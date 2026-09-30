import SwiftUI
import UniformTypeIdentifiers
import UIKit

enum PickerTarget {
    case backupSource, backupDest, restoreSource, restoreDest
}

enum DestMode: Hashable {
    case local, custom
}

func defaultBackupName() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    return "备份-" + f.string(from: Date())
}

struct ContentView: View {
    @StateObject private var manager = BackupManager()

    @State private var backupName: String = defaultBackupName()
    @State private var backupSource: URL?
    @State private var backupDest: URL?
    @State private var destMode: DestMode = .local
    @State private var restoreSource: URL?
    @State private var restoreDest: URL?

    @State private var importTarget: PickerTarget?
    @State private var showImporter = false
    @State private var showFileTestImporter = false
    @State private var debugStatus = ""
    @State private var lastBackupURL: URL?
    @State private var exportCoordinator: ExportPickerCoordinator?

    @State private var alertText = ""
    @State private var showAlert = false

    var canBackup: Bool {
        guard !manager.isWorking,
              backupSource != nil,
              !backupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        if destMode == .custom {
            return backupDest != nil
        }
        return true
    }

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("备份")) {
                    TextField("备份名称", text: $backupName)

                    folderRow(title: "要备份的文件夹", url: backupSource) {
                        pick(.backupSource)
                    }

                    Picker("保存位置", selection: $destMode) {
                        Text("本机").tag(DestMode.local)
                        Text("选文件夹").tag(DestMode.custom)
                    }
                    .pickerStyle(.segmented)

                    if destMode == .local {
                        Text("保存在本 App 的「备份」文件夹，可在“文件”App 中查看。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } else {
                        folderRow(title: "目标文件夹", url: backupDest) {
                            pick(.backupDest)
                        }
                    }

                    Button("开始备份") {
                        startBackup()
                    }
                    .disabled(!canBackup)

                    if lastBackupURL != nil {
                        Button("导出到 iCloud 云盘") {
                            exportBackup()
                        }
                    }
                }

                if manager.isWorking || !manager.status.isEmpty {
                    Section {
                        ProgressView(value: manager.progress)
                        Text(manager.status)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }

                Section(header: Text("恢复")) {
                    folderRow(title: "选择备份文件夹", url: restoreSource) {
                        pick(.restoreSource)
                    }
                    folderRow(title: "恢复到哪个目录", url: restoreDest) {
                        pick(.restoreDest)
                    }
                    Button("开始恢复") {
                        startRestore()
                    }
                    .disabled(manager.isWorking || restoreSource == nil || restoreDest == nil)
                }

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

                Section(header: Text("诊断 v1.5")) {
                    Text(debugStatus.isEmpty ? "选择器状态：等待操作" : debugStatus)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Button("测试：选个文件") {
                        showFileTestImporter = true
                    }
                    .fileImporter(isPresented: $showFileTestImporter, allowedContentTypes: [.item]) { result in
                        switch result {
                        case .success(let url):
                            debugStatus = "文件选择成功：\(url.lastPathComponent)"
                        case .failure(let error):
                            debugStatus = "文件选择失败：\(error.localizedDescription)"
                        }
                    }
                }
            }
            .navigationTitle("备份助手")
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.folder]) { result in
                handleFolderResult(result)
            }
            .alert("提示", isPresented: $showAlert) {
                Button("好") {}
            } message: {
                Text(alertText)
            }
        }
    }

    // MARK: - UI helpers

    func folderRow(title: String, url: URL?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text(url?.lastPathComponent ?? "选择")
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
    }

    func formatDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: d)
    }

    // MARK: - 选择器（SwiftUI 原生 fileImporter）

    func pick(_ target: PickerTarget) {
        importTarget = target
        debugStatus = "选择器已弹出，请选文件夹后点“打开”…"
        showImporter = true
    }

    func handleFolderResult(_ result: Result<URL, Error>) {
        guard let target = importTarget else {
            debugStatus = "回调异常：target 为空"
            return
        }
        importTarget = nil
        switch result {
        case .success(let url):
            debugStatus = "文件夹选择成功：\(url.lastPathComponent)"
            assignPicked(url, target: target)
        case .failure(let error):
            debugStatus = "文件夹选择失败/取消：\(error.localizedDescription)"
        }
    }

    func assignPicked(_ url: URL, target: PickerTarget) {
        switch target {
        case .backupSource:
            backupSource = url
        case .backupDest:
            backupDest = url
        case .restoreSource:
            restoreSource = url
        case .restoreDest:
            restoreDest = url
        }
    }

    // MARK: - 导出（系统保存面板）

    func exportBackup() {
        guard let u = lastBackupURL else { return }
        let vc = UIDocumentPickerViewController(forExporting: [u], asCopy: true)
        let coordinator = ExportPickerCoordinator(onDone: {
            self.exportCoordinator = nil
        })
        vc.delegate = coordinator
        exportCoordinator = coordinator
        topVC()?.present(vc, animated: true)
    }

    // MARK: - 备份 / 恢复

    func startBackup() {
        guard let src = backupSource else { return }
        let name = backupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let dstParent: URL
        let destLabel: String
        if destMode == .local {
            dstParent = manager.localBackupRoot()
            destLabel = "本机"
        } else {
            guard let d = backupDest else { return }
            dstParent = d
            destLabel = d.lastPathComponent
        }

        manager.backupFolder(from: src, toParent: dstParent, name: name) { ok, msg in
            if ok {
                manager.addRecord(name: name, sourceName: src.lastPathComponent, destName: destLabel)
                lastBackupURL = dstParent.appendingPathComponent(name, isDirectory: true)
                backupName = defaultBackupName()
                alertText = "备份成功：\(msg)"
            } else {
                alertText = msg
            }
            showAlert = true
        }
    }

    func startRestore() {
        guard let src = restoreSource, let dst = restoreDest else { return }
        manager.restoreFolder(from: src, toParent: dst) { ok, msg in
            alertText = ok ? "恢复成功：\(msg)" : msg
            showAlert = true
        }
    }
}

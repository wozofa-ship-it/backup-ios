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

    @State private var folderCoordinator: FolderPickerCoordinator?
    @State private var exportCoordinator: ExportPickerCoordinator?
    @State private var lastBackupURL: URL?

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
                    Text("进入文件夹后，点右上角「打开」即选中。")
                        .font(.footnote)
                        .foregroundColor(.secondary)

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
                        Text("进入目标文件夹后，点右上角「打开」即选中；也可选 iCloud 云盘。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
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
                    Text("进入文件夹后，点右上角「打开」即选中。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
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
            }
            .navigationTitle("备份助手")
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

    // MARK: - Actions

    func pick(_ target: PickerTarget) {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder])
        let coordinator = FolderPickerCoordinator(
            onPick: { [target] url in
                self.assignPicked(url, target: target)
                self.folderCoordinator = nil
            },
            onCancel: {
                self.folderCoordinator = nil
            }
        )
        vc.delegate = coordinator
        folderCoordinator = coordinator
        topVC()?.present(vc, animated: true)
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

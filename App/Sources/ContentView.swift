import SwiftUI

enum PickerTarget {
    case backupSource, backupDest, restoreSource, restoreDest
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
    @State private var restoreSource: URL?
    @State private var restoreDest: URL?

    @State private var pickerTarget: PickerTarget?
    @State private var showPicker = false

    @State private var alertText = ""
    @State private var showAlert = false

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("备份")) {
                    TextField("备份名称", text: $backupName)

                    folderRow(title: "要备份的文件夹", url: backupSource) {
                        pick(.backupSource)
                    }

                    folderRow(title: "保存位置（可选 iCloud 云盘）", url: backupDest) {
                        pick(.backupDest)
                    }

                    Button("开始备份") {
                        startBackup()
                    }
                    .disabled(manager.isWorking || backupSource == nil || backupDest == nil || backupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

                Section {
                    Text("提示：在文件选择器里可以进入“iCloud 云盘”，备份到 iCloud 需要联网同步。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("备份助手")
            .sheet(isPresented: $showPicker) {
                FolderPicker { url in
                    assignPicked(url)
                    showPicker = false
                }
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

    // MARK: - Actions

    func pick(_ target: PickerTarget) {
        pickerTarget = target
        showPicker = true
    }

    func assignPicked(_ url: URL) {
        switch pickerTarget {
        case .backupSource:
            backupSource = url
        case .backupDest:
            backupDest = url
        case .restoreSource:
            restoreSource = url
        case .restoreDest:
            restoreDest = url
        case .none:
            break
        }
    }

    func startBackup() {
        guard let src = backupSource, let dst = backupDest else { return }
        let name = backupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        manager.backupFolder(from: src, toParent: dst, name: name) { ok, msg in
            if ok {
                manager.addRecord(name: name, sourceName: src.lastPathComponent, destName: dst.lastPathComponent)
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

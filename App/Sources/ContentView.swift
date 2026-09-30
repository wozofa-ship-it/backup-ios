import SwiftUI
import UniformTypeIdentifiers
import UIKit

enum PickerTarget {
    case backupSource, backupDest, restoreSource, restoreDest
}

func defaultBackupName() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    return "备份-" + f.string(from: Date())
}

/// 多选文件夹选择器代理：取第一个选中的 URL，主动关闭
class MultiFolderPickerCoordinator: NSObject, UIDocumentPickerDelegate {
    var onPick: ([URL]) -> Void
    var onCancel: () -> Void

    init(onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void = {}) {
        self.onPick = onPick
        self.onCancel = onCancel
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        controller.dismiss(animated: true)
        let urls = urls
        DispatchQueue.main.async { self.onPick(urls) }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        controller.dismiss(animated: true)
        DispatchQueue.main.async { self.onCancel() }
    }
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

    @State private var backupName: String = defaultBackupName()
    @State private var backupSource: URL?
    @State private var backupDest: URL?
    @State private var restoreSource: URL?
    @State private var restoreDest: URL?

    @State private var pickerCoordinator: MultiFolderPickerCoordinator?
    @State private var debugStatus = ""

    @State private var alertText = ""
    @State private var showAlert = false

    var canBackup: Bool {
        !manager.isWorking
            && backupSource != nil
            && backupDest != nil
            && !backupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("备份")) {
                    Text("点“选择”后，在文件列表里点选文件夹（打勾），再点右上角确认。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    TextField("备份名称", text: $backupName)

                    folderRow(title: "要备份的文件夹", url: backupSource) {
                        pick(.backupSource)
                    }
                    folderRow(title: "备份到哪里", url: backupDest) {
                        pick(.backupDest)
                    }

                    Button("开始备份") { startBackup() }
                        .disabled(!canBackup)

                    if !debugStatus.isEmpty {
                        Text(debugStatus)
                            .font(.footnote)
                            .foregroundColor(.secondary)
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
                    Text("点“选择”后，在文件列表里点选文件夹（打勾），再点右上角确认。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    folderRow(title: "选择备份文件夹", url: restoreSource) {
                        pick(.restoreSource)
                    }
                    folderRow(title: "恢复到哪个目录", url: restoreDest) {
                        pick(.restoreDest)
                    }
                    Button("开始恢复") { startRestore() }
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

    // MARK: - 多选文件夹选择器

    func pick(_ target: PickerTarget) {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder])
        vc.allowsMultipleSelection = true
        let coordinator = MultiFolderPickerCoordinator(
            onPick: { urls in
                self.pickerCoordinator = nil
                if let url = urls.first {
                    self.debugStatus = "已选择：\(url.lastPathComponent)"
                    self.assignPicked(url, target: target)
                } else {
                    self.debugStatus = "没有选中任何文件夹"
                }
            },
            onCancel: {
                self.pickerCoordinator = nil
                self.debugStatus = "已取消选择"
            }
        )
        vc.delegate = coordinator
        pickerCoordinator = coordinator
        debugStatus = "选择器已弹出，请点选文件夹…"
        topVC()?.present(vc, animated: true)
    }

    func assignPicked(_ url: URL, target: PickerTarget) {
        switch target {
        case .backupSource: backupSource = url
        case .backupDest: backupDest = url
        case .restoreSource: restoreSource = url
        case .restoreDest: restoreDest = url
        }
    }

    // MARK: - 备份 / 恢复

    func startBackup() {
        guard let src = backupSource, let dstParent = backupDest else { return }
        let name = backupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        manager.backupFolder(from: src, toParent: dstParent, name: name) { ok, msg in
            if ok {
                manager.addRecord(name: name, sourceName: src.lastPathComponent, destName: dstParent.lastPathComponent)
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

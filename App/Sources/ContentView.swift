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

/// 文件夹选择器：用独立 UIWindow 弹出，避免主窗口拦截选择器的触摸事件
/// （UIDocumentPickerViewController 是远程视图，触摸需直达其远程 UI）
class FolderPickerPresenter: NSObject, UIDocumentPickerDelegate {
    static let shared = FolderPickerPresenter()

    private var window: UIWindow?
    private var onPick: ((URL) -> Void)?
    private var onCancel: (() -> Void)?

    func present(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void = {}) {
        self.onPick = onPick
        self.onCancel = onCancel

        let vc = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder])
        vc.delegate = self

        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            onCancel()
            return
        }

        let window = UIWindow(windowScene: scene)
        window.windowLevel = UIWindow.Level.alert + 1
        let rootVC = UIViewController()
        rootVC.view.backgroundColor = .clear
        window.rootViewController = rootVC
        window.makeKeyAndVisible()
        self.window = window

        rootVC.present(vc, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let cb = onPick
        let url = urls.first
        controller.dismiss(animated: true) { [weak self] in
            self?.cleanup()
            if let url = url {
                DispatchQueue.main.async { cb?(url) }
            }
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        let cb = onCancel
        controller.dismiss(animated: true) { [weak self] in
            self?.cleanup()
            DispatchQueue.main.async { cb?() }
        }
    }

    private func cleanup() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        onPick = nil
        onCancel = nil
    }
}

struct ContentView: View {
    @StateObject private var manager = BackupManager()

    @State private var backupName: String = defaultBackupName()
    @State private var backupSource: URL?
    @State private var backupDest: URL?
    @State private var restoreSource: URL?
    @State private var restoreDest: URL?

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
                    Text("点“选择”→ 进入要备份的文件夹 → 点右上角“打开”即选中它。")
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
                    Text("点“选择”→ 进入文件夹 → 点右上角“打开”即选中它。")
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

    // MARK: - 选择器（独立窗口弹出）

    func pick(_ target: PickerTarget) {
        debugStatus = "选择器已弹出…"
        FolderPickerPresenter.shared.present(
            onPick: { url in
                self.debugStatus = "已选择：\(url.lastPathComponent)"
                self.assignPicked(url, target: target)
            },
            onCancel: {
                self.debugStatus = "已取消选择"
            }
        )
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

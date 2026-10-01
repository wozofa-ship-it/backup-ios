import UIKit
import UniformTypeIdentifiers

/// v8.0 分享扩展：不依赖 App Group。
/// 流程：文件App长按文件夹 → 发送副本 → 备份助手 → 扩展打成zip →
/// 弹出系统分享菜单 → 用户选"存储到文件"存进 iCloud 云盘。
/// 恢复：在文件App里直接点zip包，系统自动解压。
class ShareViewController: UIViewController {

    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        statusLabel.text = "准备中…"
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.font = .systemFont(ofSize: 15)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()

        view.addSubview(statusLabel)
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -24),
            statusLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 16),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])

        preferredContentSize = CGSize(width: 340, height: 220)
        processItems()
    }

    private func processItems() {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem],
              !extensionItems.isEmpty else {
            return fail("没有可备份的内容")
        }

        // v9.3: 不再预过滤 fileURL（某些来源如 LiveContainer 分享的类型对不上），
        // 全部尝试加载，成功几个算几个，失败的如实报告
        var providers: [NSItemProvider] = []
        for item in extensionItems {
            if let atts = item.attachments {
                providers.append(contentsOf: atts)
            }
        }
        guard !providers.isEmpty else {
            return fail("没有可备份的文件")
        }

        statusLabel.text = "正在读取 \(providers.count) 个项目…"
        let group = DispatchGroup()
        var sourceURLs: [URL] = []
        var failedCount = 0
        let lock = NSLock()

        for provider in providers {
            group.enter()
            // 先试 fileURL，不行再试 public.item/data
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                    defer { group.leave() }
                    lock.lock()
                    if let url = data as? URL { sourceURLs.append(url) } else { failedCount += 1 }
                    lock.unlock()
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.data.identifier, options: nil) { data, _ in
                    defer { group.leave() }
                    lock.lock()
                    if let url = data as? URL {
                        sourceURLs.append(url)
                    } else {
                        failedCount += 1
                    }
                    lock.unlock()
                }
            } else {
                // 类型不支持：列出它实际支持的类型，方便排查
                let types = provider.registeredTypeIdentifiers.joined(separator: ", ")
                print("[BackupShare] 不支持的类型: \(types)")
                lock.lock()
                failedCount += 1
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .global(qos: .userInitiated)) {
            if !sourceURLs.isEmpty && failedCount > 0 {
                DispatchQueue.main.async {
                    self.statusLabel.text = "读取到 \(sourceURLs.count) 个，\(failedCount) 个类型不支持已跳过…"
                }
            }
            self.zipAndShare(urls: sourceURLs)
        }
    }

    // v15.1: iOS 不支持 withSecurityScope bookmark，扩展把文件夹拷到共享目录，主 App 从那压缩
    private func queueBackupTask(folderURL: URL) -> Bool {
        let fm = FileManager.default
        guard let container = fm.containerURL(forSecurityApplicationGroupIdentifier: "group.com.quseqi.backup.shared") else { return false }
        let queueDir = container.appendingPathComponent("Incoming/BackupQueue", isDirectory: true)
        try? fm.createDirectory(at: queueDir, withIntermediateDirectories: true)
        let didAccess = folderURL.startAccessingSecurityScopedResource()
        defer { if didAccess { folderURL.stopAccessingSecurityScopedResource() } }
        var dest = queueDir.appendingPathComponent(folderURL.lastPathComponent, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = queueDir.appendingPathComponent("\(folderURL.lastPathComponent) \(n)", isDirectory: true)
            n += 1
        }
        var coordError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folderURL, options: [], error: &coordError) { readURL in
            do {
                try fm.copyItem(at: readURL, to: dest)
            } catch {
                copyError = error
            }
        }
        return copyError == nil && coordError == nil && fm.fileExists(atPath: dest.path)
    }

    private func zipAndShare(urls: [URL]) {
        guard !urls.isEmpty else {
            return fail("读取分享内容失败")
        }

        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("BackupShare", isDirectory: true)
        try? fm.removeItem(at: tmp)
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        let dateStr: String = {
            let f = DateFormatter()
            f.dateFormat = "MMdd-HHmm"
            return f.string(from: Date())
        }()

        var zipURLs: [URL] = []
        var zippedCount = 0
        var passthroughCount = 0

        for (index, url) in urls.enumerated() {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

            DispatchQueue.main.async {
                self.statusLabel.text = "正在压缩 \(index + 1)/\(urls.count)\n\(url.lastPathComponent)"
            }

            // v11: zip 包不再透传，直接在扩展里解压，用户选地方存解压后的文件夹
            if url.pathExtension.lowercased() == "zip" {
                let zipCopy = tmp.appendingPathComponent(url.lastPathComponent)
                var coordError: NSError?
                NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
                    try? fm.copyItem(at: readURL, to: zipCopy)
                }
                guard fm.fileExists(atPath: zipCopy.path) else { continue }
                // 解压到以 zip 名命名的文件夹
                let outName = url.deletingPathExtension().lastPathComponent
                let outDir = tmp.appendingPathComponent(outName, isDirectory: true)
                try? fm.removeItem(at: outDir)
                do {
                    try unzipFile(at: zipCopy, to: outDir)
                    try? fm.removeItem(at: zipCopy)
                    zipURLs.append(outDir)
                    passthroughCount += 1
                    DispatchQueue.main.async {
                        self.statusLabel.text = "已解压「\(url.lastPathComponent)」\n请选择保存位置"
                    }
                } catch {
                    zipURLs.append(zipCopy)
                    passthroughCount += 1
                }
                continue
            }

            var isDir: ObjCBool = false
            _ = fm.fileExists(atPath: url.path, isDirectory: &isDir)
            // v15: 文件夹直接排队，不在扩展里压缩
            if isDir.boolValue {
                if queueBackupTask(folderURL: url) {
                    zippedCount += 1
                    DispatchQueue.main.async {
                        self.statusLabel.text = "已加入备份队列 \(zippedCount)/\(urls.count)\n打开 App 自动压缩"
                    }
                }
                continue
            }
            let zipName = "\(url.deletingPathExtension().lastPathComponent)-\(dateStr).zip"
            let zipURL = tmp.appendingPathComponent(zipName)

            var coordError: NSError?
            var zipError: Error?
            // 节流：0.3秒刷新一次进度，避免刷爆主线程
            var lastUIUpdate = Date.distantPast
            let itemIndex = index, itemTotal = urls.count
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
                do {
                    if isDir.boolValue {
                        try zipDirectory(at: readURL, to: zipURL) { done, total, name in
                            let now = Date()
                            if now.timeIntervalSince(lastUIUpdate) > 0.3 || done == total {
                                lastUIUpdate = now
                                let d = done, t = total, n = (name as NSString).lastPathComponent
                                DispatchQueue.main.async {
                                    self.statusLabel.text = "正在压缩 \(itemIndex + 1)/\(itemTotal)\n\(d)/\(t) \(n)"
                                }
                            }
                        }
                    } else {
                        // 单个文件：先拷进临时文件夹再打包
                        let single = tmp.appendingPathComponent("single", isDirectory: true)
                        try? fm.createDirectory(at: single, withIntermediateDirectories: true)
                        let target = single.appendingPathComponent(readURL.lastPathComponent)
                        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                        try fm.copyItem(at: readURL, to: target)
                        let oneZipName = "\(readURL.deletingPathExtension().lastPathComponent)-\(dateStr).zip"
                        let oneZipURL = tmp.appendingPathComponent(oneZipName)
                        try zipDirectory(at: single, to: oneZipURL)
                        try? fm.removeItem(at: single)
                        try fm.moveItem(at: oneZipURL, to: zipURL)
                    }
                } catch {
                    zipError = error
                }
            }
            if let e = zipError ?? coordError {
                DispatchQueue.main.async {
                    self.fail("压缩失败：\((e as NSError).localizedDescription)")
                }
                return
            }
            zipURLs.append(zipURL)
            zippedCount += 1
        }

        let doneCount = zippedCount + passthroughCount
        // v15: 文件夹是排队模式，没有 zipURLs，直接提示+关闭，不弹保存框
        if zippedCount > 0 && zipURLs.isEmpty && passthroughCount == 0 {
            DispatchQueue.main.async {
                self.spinner.stopAnimating()
                self.spinner.isHidden = true
                self.statusLabel.text = "已加入备份队列，共 \(zippedCount) 个文件夹\n打开“备份助手”App 自动压缩，可看进度"
                // 1.5 秒后自动关闭
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
                }
            }
            return
        }
        let summary: String
        if zippedCount > 0 && passthroughCount == 0 {
            summary = "压缩完成，共 \(doneCount) 个 zip 包"
        } else if passthroughCount > 0 && zippedCount == 0 {
            // v11: zip 已在扩展内解压，分享的是解压后的文件夹
            summary = "已解压 \(doneCount) 个 zip 包"
        } else {
            summary = "完成：压缩 \(zippedCount) 个，透传 \(passthroughCount) 个"
        }

        DispatchQueue.main.async {
            self.presentShareSheet(zipURLs: zipURLs, summary: summary)
        }
    }

    private func presentShareSheet(zipURLs: [URL], summary: String) {
        spinner.stopAnimating()
        spinner.isHidden = true
        statusLabel.text = "\(summary)\n请选择保存位置\n（建议存到“备份助手”文件夹，方便在App里恢复）"

        let activityVC = UIActivityViewController(activityItems: zipURLs, applicationActivities: nil)
        // iPad 弹出位置
        if let pop = activityVC.popoverPresentationController {
            pop.sourceView = view
            pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        activityVC.completionWithItemsHandler = { [weak self] _, _, _, _ in
            // 清理临时文件
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("BackupShare", isDirectory: true)
            try? FileManager.default.removeItem(at: tmp)
            self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
        present(activityVC, animated: true)
    }

    private func fail(_ text: String) {
        DispatchQueue.main.async {
            self.spinner.stopAnimating()
            self.spinner.isHidden = true
            self.statusLabel.text = "⚠️ " + text + "\n\n点右上角关闭"
            // v9.3: 错误常驻显示，加关闭按钮，不再 2.2 秒自动消失
            let closeButton = UIButton(type: .system)
            closeButton.setTitle("关闭", for: .normal)
            closeButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
            closeButton.translatesAutoresizingMaskIntoConstraints = false
            closeButton.addTarget(self, action: #selector(self.closeExtension), for: .touchUpInside)
            self.view.addSubview(closeButton)
            NSLayoutConstraint.activate([
                closeButton.topAnchor.constraint(equalTo: self.statusLabel.bottomAnchor, constant: 20),
                closeButton.centerXAnchor.constraint(equalTo: self.view.centerXAnchor),
            ])
        }
    }

    @objc private func closeExtension() {
        extensionContext?.cancelRequest(withError: NSError(domain: "backup.share", code: -1))
    }
}

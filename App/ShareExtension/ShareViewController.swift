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

        var providers: [NSItemProvider] = []
        for item in extensionItems {
            if let atts = item.attachments {
                providers.append(contentsOf: atts.filter {
                    $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                })
            }
        }
        guard !providers.isEmpty else {
            return fail("没有可备份的文件")
        }

        statusLabel.text = "正在读取 \(providers.count) 个项目…"
        let group = DispatchGroup()
        var sourceURLs: [URL] = []
        let lock = NSLock()

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                defer { group.leave() }
                if let url = data as? URL {
                    lock.lock()
                    sourceURLs.append(url)
                    lock.unlock()
                }
            }
        }

        group.notify(queue: .global(qos: .userInitiated)) {
            self.zipAndShare(urls: sourceURLs)
        }
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

        for (index, url) in urls.enumerated() {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

            DispatchQueue.main.async {
                self.statusLabel.text = "正在压缩 \(index + 1)/\(urls.count)\n\(url.lastPathComponent)"
            }

            // zip 包直接透传（提示用户点开即解压）；其他打成zip
            if url.pathExtension.lowercased() == "zip" {
                let dest = tmp.appendingPathComponent(url.lastPathComponent)
                var coordError: NSError?
                NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
                    try? fm.copyItem(at: readURL, to: dest)
                }
                if fm.fileExists(atPath: dest.path) { zipURLs.append(dest) }
                continue
            }

            var isDir: ObjCBool = false
            _ = fm.fileExists(atPath: url.path, isDirectory: &isDir)
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
        }

        DispatchQueue.main.async {
            self.presentShareSheet(zipURLs: zipURLs)
        }
    }

    private func presentShareSheet(zipURLs: [URL]) {
        spinner.stopAnimating()
        spinner.isHidden = true
        statusLabel.text = "压缩完成，共 \(zipURLs.count) 个zip包\n请选择保存位置"

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
            self.statusLabel.text = "⚠️ " + text
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                self.extensionContext?.cancelRequest(withError: NSError(
                    domain: "backup.share", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: text]))
            }
        }
    }
}

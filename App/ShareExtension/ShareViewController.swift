import UIKit
import UniformTypeIdentifiers

/// 分享扩展：在系统分享菜单中显示"备份助手"，
/// 把用户分享的文件/文件夹复制到 App Group 共享容器，
/// 主 App 下次打开时自动导入。
class ShareViewController: UIViewController {

    static let appGroupID = "group.com.quseqi.backup.shared"

    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let lock = NSLock()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        statusLabel.text = "正在导入到备份助手…"
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

        preferredContentSize = CGSize(width: 320, height: 200)
        importSharedItems()
    }

    private func importSharedItems() {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem],
              !extensionItems.isEmpty else {
            return fail("没有可导入的内容")
        }

        let fm = FileManager.default
        guard let container = fm.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID) else {
            return fail("共享容器不可用\n请在备份助手中手动导入")
        }
        let incoming = container.appendingPathComponent("Incoming", isDirectory: true)
        try? fm.createDirectory(at: incoming, withIntermediateDirectories: true)

        var providers: [NSItemProvider] = []
        for item in extensionItems {
            if let atts = item.attachments {
                providers.append(contentsOf: atts.filter {
                    $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                })
            }
        }
        guard !providers.isEmpty else {
            return fail("没有可导入的文件")
        }

        let group = DispatchGroup()
        var imported = 0
        var lastError: String?

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, error in
                defer { group.leave() }
                guard let url = data as? URL else {
                    self.lock.lock()
                    lastError = (error as NSError?)?.localizedDescription ?? "未知错误"
                    self.lock.unlock()
                    return
                }
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

                var copyError: Error?
                var dest: URL = incoming.appendingPathComponent(url.lastPathComponent)
                // 重名时自动加序号
                var n = 2
                while fm.fileExists(atPath: dest.path) {
                    let base = url.deletingPathExtension().lastPathComponent
                    let ext = url.pathExtension
                    let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
                    dest = incoming.appendingPathComponent(name)
                    n += 1
                }
                let finalDest = dest
                var coordError: NSError?
                NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
                    do {
                        try fm.copyItem(at: readURL, to: finalDest)
                    } catch {
                        copyError = error
                    }
                }
                self.lock.lock()
                if let e = copyError ?? coordError {
                    lastError = (e as NSError).localizedDescription
                } else {
                    imported += 1
                }
                self.lock.unlock()
            }
        }

        group.notify(queue: .main) {
            if imported > 0 {
                self.succeed("已导入 \(imported) 个项目\n打开备份助手即可备份")
            } else {
                self.fail("导入失败：\(lastError ?? "未知错误")")
            }
        }
    }

    private func succeed(_ text: String) {
        spinner.stopAnimating()
        spinner.isHidden = true
        statusLabel.text = "✅ " + text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }

    private func fail(_ text: String) {
        spinner.stopAnimating()
        spinner.isHidden = true
        statusLabel.text = "⚠️ " + text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            self.extensionContext?.cancelRequest(withError: NSError(
                domain: "backup.share", code: -1,
                userInfo: [NSLocalizedDescriptionKey: text]))
        }
    }
}

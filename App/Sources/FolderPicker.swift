import Foundation
import UniformTypeIdentifiers
import UIKit

/// 文件夹选择器代理：收到选择/取消后主动关闭选择器，再回调调用方
class FolderPickerCoordinator: NSObject, UIDocumentPickerDelegate {
    var onPick: (URL) -> Void
    var onCancel: () -> Void

    init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void = {}) {
        self.onPick = onPick
        self.onCancel = onCancel
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        controller.dismiss(animated: true)
        guard let url = urls.first else { return }
        DispatchQueue.main.async { self.onPick(url) }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        controller.dismiss(animated: true)
        DispatchQueue.main.async { self.onCancel() }
    }
}

/// 导出选择器代理：只负责关闭（复制由系统完成）
class ExportPickerCoordinator: NSObject, UIDocumentPickerDelegate {
    var onDone: () -> Void

    init(onDone: @escaping () -> Void = {}) {
        self.onDone = onDone
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        controller.dismiss(animated: true)
        DispatchQueue.main.async { self.onDone() }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        controller.dismiss(animated: true)
        DispatchQueue.main.async { self.onDone() }
    }
}

/// 取 keyWindow 的 rootViewController，用来直接弹出系统选择器
func topVC() -> UIViewController? {
    UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap { $0.windows }
        .first { $0.isKeyWindow }?
        .rootViewController
}

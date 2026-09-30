import Foundation
import UniformTypeIdentifiers
import UIKit

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

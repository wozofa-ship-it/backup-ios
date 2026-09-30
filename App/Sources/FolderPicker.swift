import UIKit

/// 取当前 key window 的根视图控制器，用于弹出分享面板
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

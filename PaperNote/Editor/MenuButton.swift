import UIKit

/// 工具列按鈕：選單關掉時通知（見 disableLeftoverMenuPassthrough）
final class MenuButton: UIButton {
    var onMenuClosed: (() -> Void)?

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration,
                                         animator: UIContextMenuInteractionAnimating?) {
        super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
        if let animator {
            animator.addCompletion { [weak self] in self?.onMenuClosed?() }
        } else {
            DispatchQueue.main.async { [weak self] in self?.onMenuClosed?() }
        }
    }
}

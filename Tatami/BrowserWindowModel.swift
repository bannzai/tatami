import Foundation
import Observation

/// 1 ウィンドウ分の状態。ペインの配置 (PaneTree) と各ペインの実体 (WebPane)、アドレスバーの入力を持ち、
/// ペイン操作 (メニュー・後続のキーバインド) の宛先になる
@MainActor
@Observable
final class BrowserWindowModel {
    /// ペインの配置とフォーカス
    private(set) var paneTree = PaneTree()
    /// ペインの実体。paneTree の葉と 1 対 1 で、閉じたペインの WKWebView はここから外れて破棄される
    private(set) var panes: [PaneID: WebPane] = [:]
    /// アドレスバーに入力中のテキスト。フォーカス中のペインの URL に追随する
    var addressText = ""

    init() {
        let pane = makePane(id: paneTree.focusedPaneID, url: AddressInput.homeURL)
        panes[pane.id] = pane
        addressText = pane.url.absoluteString
    }

    /// フォーカス中のペインの実体
    var focusedPane: WebPane {
        panes[paneTree.focusedPaneID]!
    }

    /// アドレスバーの入力をフォーカス中のペインで開く
    func navigate(text: String) {
        focusedPane.load(url: AddressInput.resolve(text: text))
    }

    /// 他アプリから渡された URL をフォーカス中のペインで開く
    func open(url: URL) {
        addressText = url.absoluteString
        focusedPane.load(url: url)
    }

    /// フォーカス中のペインを分割し、新しいペインに空ページを開く
    func split(axis: SplitAxis) {
        let newPaneID = paneTree.split(axis: axis)
        panes[newPaneID] = makePane(id: newPaneID, url: AddressInput.homeURL)
        syncAddressTextToFocusedPane()
    }

    /// フォーカス中のペインを閉じる。最後の 1 枚は閉じない (ウィンドウを閉じる判断は #4 のウィンドウ管理で扱う)
    func closeFocusedPane() {
        let closingPaneID = paneTree.focusedPaneID
        guard paneTree.closeFocusedPane() else {
            return
        }
        panes[closingPaneID] = nil
        syncAddressTextToFocusedPane()
    }

    func toggleZoom() {
        paneTree.toggleZoom()
    }

    func applyNextLayout() {
        paneTree.applyNextLayout()
    }

    func focusNext() {
        paneTree.focusNext()
        syncAddressTextToFocusedPane()
    }

    func focusPrevious() {
        paneTree.focusPrevious()
        syncAddressTextToFocusedPane()
    }

    func focusLastPane() {
        paneTree.focusLastPane()
        syncAddressTextToFocusedPane()
    }

    func focus(direction: FocusDirection) {
        paneTree.focus(direction: direction)
        syncAddressTextToFocusedPane()
    }

    /// ペインのクリックでそのペインへフォーカスを移す
    func focus(paneID: PaneID) {
        paneTree.focus(paneID: paneID)
        syncAddressTextToFocusedPane()
    }

    func swapWithPrevious() {
        paneTree.swapWithPrevious()
    }

    func swapWithNext() {
        paneTree.swapWithNext()
    }

    /// 境界線のドラッグ量を割合の変化として反映する
    func resize(dividerPath: [SplitSide], delta: Double) {
        paneTree.resize(dividerPath: dividerPath, delta: delta)
    }

    private func makePane(id: PaneID, url: URL) -> WebPane {
        let pane = WebPane(id: id, url: url)
        pane.onNavigate = { [weak self] navigatedURL in
            guard let self, paneTree.focusedPaneID == id else {
                return
            }
            addressText = navigatedURL.absoluteString
        }
        return pane
    }

    private func syncAddressTextToFocusedPane() {
        addressText = focusedPane.url.absoluteString
    }
}

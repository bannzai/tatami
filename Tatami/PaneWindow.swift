import Foundation
import Observation
import WebKit

/// tmux の window (ブラウザのタブ相当)。ペインの配置 (PaneTree) と各ペインの実体 (WebPane) を持つ
@MainActor
@Observable
final class PaneWindow {
    /// ペインの配置とフォーカス
    private(set) var paneTree = PaneTree()
    /// ペインの実体。paneTree の葉と 1 対 1 で、閉じたペインの WKWebView はここから外れて破棄される
    private(set) var panes: [PaneID: WebPane] = [:]
    /// rename-window で付けた名前。nil の間は tmux の automatic-rename と同じく表示中のページから名前を決める
    var renamedName: String?
    /// フォーカス中のペインの URL が変わった時の通知先 (アドレスバーと status line の追随に使う)
    var onFocusedURLChange: ((URL) -> Void)?

    /// タイトル・進捗・戻る/進むの可否など、フォーカス中のペインの表示状態が変わった時の通知先
    var onFocusedPaneStateChange: (() -> Void)?

    init() {
        let pane = makePane(id: paneTree.focusedPaneID, url: AddressInput.homeURL)
        panes[pane.id] = pane
        pane.loadInitialURL()
    }

    /// フォーカス中のペインの実体
    var focusedPane: WebPane {
        panes[paneTree.focusedPaneID]!
    }

    /// status line に出す名前。rename 済みならその名前、そうでなければフォーカス中のペインのホスト名 (about:blank 等ホストが無ければ "blank")
    var name: String {
        renamedName ?? focusedPane.url.host() ?? "blank"
    }

    /// フォーカス中のペインを分割し、新しいペインに空ページを開く
    func split(axis: SplitAxis) {
        let newPaneID = paneTree.split(axis: axis)
        let pane = makePane(id: newPaneID, url: AddressInput.homeURL)
        panes[newPaneID] = pane
        pane.loadInitialURL()
        notifyFocusedURL()
    }

    /// target="_blank" / window.open の要求を新しいペインとして開く。別の macOS ウィンドウは増やさない (documents/PROJECT.md 機能要件 1)。
    /// 分割の向きは、要求元のペインが横長なら左右、縦長なら上下にして新しいペインが極端に細くならないようにする
    private func splitForPopup(sourcePaneID: PaneID, configuration: WKWebViewConfiguration) -> WKWebView {
        let sourceFrame = paneTree.frames(bounds: CGRect(x: 0, y: 0, width: 1, height: 1))[sourcePaneID] ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        paneTree.focus(paneID: sourcePaneID)
        let newPaneID = paneTree.split(axis: sourceFrame.width >= sourceFrame.height ? .horizontal : .vertical)
        let pane = makePane(id: newPaneID, url: AddressInput.homeURL, configuration: configuration)
        panes[newPaneID] = pane
        notifyFocusedURL()
        return pane.webView
    }

    /// フォーカス中のペインを閉じる。最後の 1 枚は閉じずに false を返す (ウィンドウごと閉じる判断は BrowserWindowModel が行う)
    @discardableResult
    func closeFocusedPane() -> Bool {
        let closingPaneID = paneTree.focusedPaneID
        guard paneTree.closeFocusedPane() else {
            return false
        }
        panes[closingPaneID] = nil
        notifyFocusedURL()
        return true
    }

    func toggleZoom() {
        paneTree.toggleZoom()
    }

    func applyNextLayout() {
        paneTree.applyNextLayout()
    }

    func focusNext() {
        paneTree.focusNext()
        notifyFocusedURL()
    }

    func focusPrevious() {
        paneTree.focusPrevious()
        notifyFocusedURL()
    }

    func focusLastPane() {
        paneTree.focusLastPane()
        notifyFocusedURL()
    }

    func focus(direction: FocusDirection) {
        paneTree.focus(direction: direction)
        notifyFocusedURL()
    }

    /// ペインのクリックでそのペインへフォーカスを移す
    func focus(paneID: PaneID) {
        paneTree.focus(paneID: paneID)
        notifyFocusedURL()
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

    private func makePane(id: PaneID, url: URL, configuration: WKWebViewConfiguration? = nil) -> WebPane {
        let pane = WebPane(id: id, url: url, configuration: configuration ?? WebPane.defaultConfiguration())
        pane.onNavigate = { [weak self] navigatedURL in
            guard let self, paneTree.focusedPaneID == id else {
                return
            }
            onFocusedURLChange?(navigatedURL)
        }
        pane.onStateChange = { [weak self] in
            guard let self, paneTree.focusedPaneID == id else {
                return
            }
            onFocusedPaneStateChange?()
        }
        pane.onCreateWebView = { [weak self] configuration in
            self?.splitForPopup(sourcePaneID: id, configuration: configuration)
        }
        return pane
    }

    private func notifyFocusedURL() {
        onFocusedURLChange?(focusedPane.url)
    }
}

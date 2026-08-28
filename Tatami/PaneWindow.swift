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
    /// 画面上でペインを並べている領域の大きさ。ポップアップの分割方向を実際の縦横比で決めるために描画側から受け取る。
    /// 描画前は正方形とみなす
    var containerSize = CGSize(width: 1, height: 1)

    init() {
        let pane = makePane(id: paneTree.focusedPaneID, url: AddressInput.homeURL)
        panes[pane.id] = pane
        pane.loadInitialURL()
    }

    /// 保存したセッションからの復元。ツリーの葉に対応する URL が無いペインは空ページで補う
    init(snapshot: SessionSnapshot.Window) {
        paneTree = snapshot.paneTree
        renamedName = snapshot.renamedName
        let urls = Dictionary(snapshot.panes.map { ($0.id, $0.url) }) { first, _ in first }
        for paneID in paneTree.paneIDs {
            let pane = makePane(id: paneID, url: urls[paneID] ?? AddressInput.homeURL)
            panes[paneID] = pane
            pane.loadInitialURL()
        }
    }

    /// 保存用の内容
    var snapshot: SessionSnapshot.Window {
        SessionSnapshot.Window(
            paneTree: paneTree,
            panes: paneTree.paneIDs.compactMap { paneID in
                panes[paneID].map { SessionSnapshot.Window.Pane(id: paneID, url: $0.url) }
            },
            renamedName: renamedName
        )
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
    /// 分割の向きは、要求元のペインの実際の形が横長なら左右、縦長なら上下にして新しいペインが極端に細くならないようにする
    private func splitForPopup(sourcePaneID: PaneID, configuration: WKWebViewConfiguration) -> WKWebView {
        let containerBounds = CGRect(origin: .zero, size: containerSize)
        let sourceFrame = paneTree.frames(bounds: containerBounds)[sourcePaneID] ?? containerBounds
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
        close(paneID: paneTree.focusedPaneID)
    }

    /// 指定したペインを閉じる (window.close() からも呼ばれる)。最後の 1 枚は閉じずに false を返す
    @discardableResult
    func close(paneID: PaneID) -> Bool {
        guard paneTree.close(paneID: paneID) else {
            return false
        }
        panes[paneID] = nil
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
        let previousFocusedPaneID = paneTree.focusedPaneID
        paneTree.focusNext()
        notifyFocusedURLIfFocusChanged(previousFocusedPaneID: previousFocusedPaneID)
    }

    func focusPrevious() {
        let previousFocusedPaneID = paneTree.focusedPaneID
        paneTree.focusPrevious()
        notifyFocusedURLIfFocusChanged(previousFocusedPaneID: previousFocusedPaneID)
    }

    func focusLastPane() {
        let previousFocusedPaneID = paneTree.focusedPaneID
        paneTree.focusLastPane()
        notifyFocusedURLIfFocusChanged(previousFocusedPaneID: previousFocusedPaneID)
    }

    func focus(direction: FocusDirection) {
        let previousFocusedPaneID = paneTree.focusedPaneID
        paneTree.focus(direction: direction)
        notifyFocusedURLIfFocusChanged(previousFocusedPaneID: previousFocusedPaneID)
    }

    /// ペインのクリックでそのペインへフォーカスを移す
    func focus(paneID: PaneID) {
        let previousFocusedPaneID = paneTree.focusedPaneID
        paneTree.focus(paneID: paneID)
        notifyFocusedURLIfFocusChanged(previousFocusedPaneID: previousFocusedPaneID)
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
        pane.onClose = { [weak self] in
            self?.close(paneID: id)
        }
        return pane
    }

    private func notifyFocusedURL() {
        onFocusedURLChange?(focusedPane.url)
    }

    /// フォーカスが実際に移った時だけ通知し、移らなかった時 (ペインが 1 枚・隣が無い等) はアドレスバーの入力途中のテキストを残す
    private func notifyFocusedURLIfFocusChanged(previousFocusedPaneID: PaneID) {
        if paneTree.focusedPaneID != previousFocusedPaneID {
            notifyFocusedURL()
        }
    }
}

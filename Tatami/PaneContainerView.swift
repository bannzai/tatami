import AppKit
import SwiftUI
import WebKit

/// ペインツリーの矩形どおりに各ペインの WKWebView を並べる AppKit のビュー。
/// ペイン間の境界線の描画とドラッグによるリサイズ、フォーカス中ペインの枠線の描画、クリックによるフォーカス移動を担当する
final class PaneContainerView: NSView {
    /// ペイン間の境界線の太さ。ドラッグで掴める幅も兼ねる
    static let dividerThickness: CGFloat = 4
    /// フォーカス中のペインを示す枠線の太さ。境界線の中に収める
    static let focusBorderWidth: CGFloat = 2

    /// 境界線をドラッグした時の通知先。delta は割合の変化量
    var onDividerDrag: ((_ dividerPath: [SplitSide], _ delta: Double) -> Void)?
    /// ペインがクリックされた時の通知先
    var onPaneClick: ((PaneID) -> Void)?
    /// このウィンドウへのキー入力の通知先 (1 つの入力の候補を先頭から照合する)。true を返すと入力を消費し、WKWebView (Web ページ) へ渡さない
    var onKeyDown: (([KeyStroke]) -> Bool)?
    /// ウィンドウがキーウィンドウでなくなった時の通知先 (prefix 待ちの取り消し)
    var onResignKey: (() -> Void)?

    private var paneTree = PaneTree()
    private var webViews: [PaneID: WKWebView] = [:]
    /// ドラッグ中の境界線。mouseDown で掴み mouseUp で離す
    private var draggingDivider: PaneDivider?
    /// ドラッグ中の直前のマウス位置 (このビューの座標)。NSEvent.deltaX / deltaY は合成イベントで 0 になるため、位置の差分で移動量を求める
    private var lastDragLocation: CGPoint = .zero
    /// ウィンドウ内のクリックを WKWebView より先に見てフォーカス移動に使う監視。WKWebView はマウスイベントを自分で消費するため、responder chain では受け取れない
    private var clickMonitor: Any?
    /// ウィンドウ内のキー入力を WKWebView より先に見て prefix キーを捕捉する監視。Web ページのテキスト入力にフォーカスがあっても prefix が効くようにする
    private var keyMonitor: Any?
    /// 消費したキーの keyCode の集合。押し続けた時のリピートと、対応する keyUp も同じ扱い (消費) にして Web ページへ流さないために keyUp まで覚える。
    /// prefix を離す前に次のキーを押すロールオーバーでは複数のキーが同時に消費中になるため、1 つではなく集合で持つ
    private var consumedKeyCodes: Set<UInt16> = []

    /// PaneTree の矩形は y が下向きに増える座標系で、AppKit の既定 (y が上向き) と合わないため反転する
    override var isFlipped: Bool { true }

    /// モデルの状態を反映する。閉じたペインの WKWebView はここで外れ、モデル側の参照が消えれば破棄される
    func apply(paneTree: PaneTree, webViews: [PaneID: WKWebView]) {
        // 別のウィンドウ (tmux window) へ切り替わった (ペインの集合が変わった) 時は、掴んでいた境界線が無くなるためドラッグを取り消す
        if draggingDivider != nil, Set(self.paneTree.paneIDs) != Set(paneTree.paneIDs) {
            draggingDivider = nil
        }
        self.paneTree = paneTree
        self.webViews = webViews
        let visiblePaneIDs = Set(paneTree.frames(bounds: bounds).keys)
        for subview in subviews where !webViews.values.contains(where: { $0 === subview }) {
            subview.removeFromSuperview()
        }
        for (paneID, webView) in webViews {
            if visiblePaneIDs.contains(paneID) {
                if webView.superview !== self {
                    addSubview(webView)
                    webView.setAccessibilityIdentifier("pane-\(paneID.rawValue.uuidString)")
                }
            } else {
                webView.removeFromSuperview()
            }
        }
        needsLayout = true
        needsDisplay = true
        // 境界線の位置が変わるのはビューの frame ではなく paneTree の変化なので、cursor rect の再計算を明示的に求める
        window?.invalidateCursorRects(for: self)
        syncFirstResponderWithFocusedPane()
    }

    /// 直前に apply した時のフォーカス中ペイン。フォーカスの変化を検出して first responder を追従させる
    private var lastFocusedPaneID: PaneID?

    /// モデルのフォーカス (paneTree.focusedPaneID) と AppKit の first responder を揃える。
    /// Web コンテンツが first responder の時にフォーカスが別のペインへ移った、または first responder だった WKWebView が外れた場合に、
    /// フォーカス中のペインの WKWebView を first responder にする (アドレスバー等にフォーカスがある時は動かさない)
    private func syncFirstResponderWithFocusedPane() {
        let focusChanged = lastFocusedPaneID != paneTree.focusedPaneID
        lastFocusedPaneID = paneTree.focusedPaneID
        guard let window, let responder = window.firstResponder as? NSView,
              let responderWebView = sequence(first: responder, next: \.superview).first(where: { $0 is WKWebView }),
              let focusedWebView = webViews[paneTree.focusedPaneID], focusedWebView.superview === self,
              focusChanged || responderWebView.superview !== self else {
            return
        }
        window.makeFirstResponder(focusedWebView)
    }

    /// bounds が変わった時の通知先 (ポップアップの分割方向の判定に使う)
    var onBoundsChange: ((CGSize) -> Void)?

    /// フォーカス中のペインの WKWebView を first responder にする (アドレスバーからの送信後など)
    func focusWebContent() {
        guard let focusedWebView = webViews[paneTree.focusedPaneID], focusedWebView.superview === self else {
            return
        }
        window?.makeFirstResponder(focusedWebView)
    }

    override func layout() {
        super.layout()
        onBoundsChange?(bounds.size)
        let inset = Self.dividerThickness / 2
        for (paneID, frame) in paneTree.frames(bounds: bounds) {
            // 同じ向きの分割を入れ子にすると比率の下限 (5%) が掛け合わされて境界線の太さより細くなり得るため、インセット後の寸法を非負に留める
            webViews[paneID]?.frame = CGRect(
                x: frame.minX + inset,
                y: frame.minY + inset,
                width: max(0, frame.width - inset * 2),
                height: max(0, frame.height - inset * 2)
            )
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        for divider in paneTree.dividers(bounds: bounds) {
            dividerRect(divider: divider).fill()
        }
        if let focusedFrame = paneTree.frames(bounds: bounds)[paneTree.focusedPaneID], paneTree.paneIDs.count > 1 {
            let path = NSBezierPath(rect: focusedFrame.insetBy(dx: Self.focusBorderWidth / 2, dy: Self.focusBorderWidth / 2))
            path.lineWidth = Self.focusBorderWidth
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
    }

    /// 境界線を WebDriverAgentMac などから識別できるようにアクセシビリティ要素として公開する。
    /// 識別子は `divider-<番号>` (dividers(bounds:) の並び順 = 木の深さ優先順) で、リサイズの検証で座標に依存せず特定できる
    override func accessibilityChildren() -> [Any]? {
        let dividerElements = paneTree.dividers(bounds: bounds).enumerated().map { index, divider in
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.splitter)
            element.setAccessibilityIdentifier("divider-\(index)")
            element.setAccessibilityParent(self)
            let rect = dividerRect(divider: divider)
            if let window {
                element.setAccessibilityFrame(window.convertToScreen(convert(rect, to: nil)))
            }
            element.setAccessibilityOrientation(divider.axis == .horizontal ? .vertical : .horizontal)
            return element
        }
        return (super.accessibilityChildren() ?? []) + dividerElements
    }

    override func resetCursorRects() {
        for divider in paneTree.dividers(bounds: bounds) {
            addCursorRect(dividerRect(divider: divider), cursor: divider.axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
        }
    }

    override func mouseDown(with event: NSEvent) {
        lastDragLocation = convert(event.locationInWindow, from: nil)
        draggingDivider = paneTree.dividers(bounds: bounds).first { dividerRect(divider: $0).contains(lastDragLocation) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let divider = draggingDivider, divider.extent > 0 else {
            return
        }
        let location = convert(event.locationInWindow, from: nil)
        let delta = divider.axis == .horizontal ? location.x - lastDragLocation.x : location.y - lastDragLocation.y
        lastDragLocation = location
        onDividerDrag?(divider.path, delta / divider.extent)
    }

    override func mouseUp(with event: NSEvent) {
        draggingDivider = nil
    }

    /// ウィンドウがキーウィンドウでなくなった時に消費中のキーを忘れる (離された keyUp は届かない)
    private var resignKeyObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
            self.resignKeyObserver = nil
        }
        if let window {
            resignKeyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.consumedKeyCodes.removeAll()
                    self?.onResignKey?()
                }
            }
        }
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        guard window != nil else {
            return
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, event.window === window else {
                return event
            }
            // JavaScript の prompt / alert などのシートが出ている間は、その入力欄へのキー (find モードの n / N / Escape を含む) を横取りしない
            if window?.attachedSheet != nil {
                return event
            }
            if event.type == .keyUp {
                return consumedKeyCodes.remove(event.keyCode) == nil ? event : nil
            }
            if event.isARepeat {
                // リピートは最初の keyDown の扱いを引き継ぐ。消費したキーのリピートは捨て、ページへ渡したキーのリピートは
                // prefix の判定やコマンドに使わずそのままページへ渡す (長押し中に prefix を押しても次のリピートがコマンドにならない)
                return consumedKeyCodes.contains(event.keyCode) ? nil : event
            }
            // 別アプリへ移った間に離されたキーは keyUp が届かず集合に残るため、リピートでない keyDown が来た時点で古い記録を消す
            consumedKeyCodes.remove(event.keyCode)
            let keyStrokes = KeyStroke.candidates(event: event)
            guard !keyStrokes.isEmpty else {
                return event
            }
            let consumed = onKeyDown?(keyStrokes) == true
            if consumed {
                consumedKeyCodes.insert(event.keyCode)
            }
            return consumed ? nil : event
        }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let window, event.window === window else {
                return event
            }
            // 一覧などのオーバーレイの上をクリックした時に背後のペインへフォーカスを移さないよう、座標ではなく実際のヒット先で判定する
            // hitTest は受け手のローカル座標を取るため、ウィンドウ座標から contentView の座標へ変換する (反転座標系の SwiftUI のホスティングビューでも正しく当たる)
            guard let contentView = window.contentView,
                  let hitView = contentView.hitTest(contentView.convert(event.locationInWindow, from: nil)),
                  let clickedWebView = sequence(first: hitView, next: \.superview).first(where: { $0 is WKWebView }),
                  let clickedPaneID = webViews.first(where: { $0.value === clickedWebView && $0.value.superview === self })?.key else {
                return event
            }
            onPaneClick?(clickedPaneID)
            return event
        }
    }

    private func dividerRect(divider: PaneDivider) -> CGRect {
        switch divider.axis {
        case .horizontal:
            return divider.line.insetBy(dx: -Self.dividerThickness / 2, dy: 0)
        case .vertical:
            return divider.line.insetBy(dx: 0, dy: -Self.dividerThickness / 2)
        }
    }
}

/// PaneContainerView を SwiftUI に載せ、モデルの変化を反映する
struct PaneContainer: NSViewRepresentable {
    let model: BrowserWindowModel

    func makeNSView(context: Context) -> PaneContainerView {
        let view = PaneContainerView()
        view.setAccessibilityIdentifier("paneContainer")
        view.onDividerDrag = { dividerPath, delta in
            model.currentWindow.resize(dividerPath: dividerPath, delta: delta)
            model.scheduleSave()
        }
        view.onPaneClick = { paneID in
            model.currentWindow.focus(paneID: paneID)
            model.scheduleSave()
        }
        view.onKeyDown = { keyStrokes in
            model.handle(keyStrokes: keyStrokes)
        }
        view.onResignKey = {
            model.cancelPrefix()
        }
        view.onBoundsChange = { size in
            model.update(containerSize: size)
        }
        return view
    }

    func updateNSView(_ view: PaneContainerView, context: Context) {
        view.apply(paneTree: model.currentWindow.paneTree, webViews: model.currentWindow.panes.mapValues(\.webView))
        if context.coordinator.handledWebContentFocusRequestCount != model.webContentFocusRequestCount {
            context.coordinator.handledWebContentFocusRequestCount = model.webContentFocusRequestCount
            view.focusWebContent()
            // Web コンテンツが first responder になった後で実行する処理 (find の選択反映など) を、フォーカスの完了を待って動かす
            model.webContentDidFocus()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// 処理済みの要求回数を覚えて、同じ要求を再描画のたびに繰り返さないようにする
    final class Coordinator {
        var handledWebContentFocusRequestCount = 0
    }
}

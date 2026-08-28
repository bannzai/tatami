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
    /// このウィンドウへのキー入力の通知先。true を返すと入力を消費し、WKWebView (Web ページ) へ渡さない
    var onKeyDown: ((KeyStroke) -> Bool)?

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
    /// 直前に消費したキーの keyCode。押し続けた時のリピートイベントも同じ扱い (消費) にして Web ページへ流さないために覚える
    private var consumedKeyCode: UInt16?

    /// PaneTree の矩形は y が下向きに増える座標系で、AppKit の既定 (y が上向き) と合わないため反転する
    override var isFlipped: Bool { true }

    /// モデルの状態を反映する。閉じたペインの WKWebView はここで外れ、モデル側の参照が消えれば破棄される
    func apply(paneTree: PaneTree, webViews: [PaneID: WKWebView]) {
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
    }

    override func layout() {
        super.layout()
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
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
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === window else {
                return event
            }
            if event.isARepeat, event.keyCode == consumedKeyCode {
                return nil
            }
            guard let keyStroke = KeyStroke(event: event) else {
                consumedKeyCode = nil
                return event
            }
            let consumed = onKeyDown?(keyStroke) == true
            consumedKeyCode = consumed ? event.keyCode : nil
            return consumed ? nil : event
        }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, event.window === window else {
                return event
            }
            let location = convert(event.locationInWindow, from: nil)
            if let clickedPaneID = webViews.first(where: { $0.value.superview === self && $0.value.frame.contains(location) })?.key {
                onPaneClick?(clickedPaneID)
            }
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
        }
        view.onPaneClick = { paneID in
            model.currentWindow.focus(paneID: paneID)
        }
        view.onKeyDown = { keyStroke in
            model.handle(keyStroke: keyStroke)
        }
        return view
    }

    func updateNSView(_ view: PaneContainerView, context: Context) {
        view.apply(paneTree: model.currentWindow.paneTree, webViews: model.currentWindow.panes.mapValues(\.webView))
    }
}

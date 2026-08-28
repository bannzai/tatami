import CoreGraphics
import Foundation

/// ペインを一意に識別する値。ペインの中身 (WKWebView 等) とツリー構造を切り離すため、木には識別子だけを載せる
struct PaneID: Hashable, Sendable {
    /// 生成のたびに一意になる識別子
    let rawValue: UUID

    /// 新しいペインを作る側が UUID を意識せずに済むよう、既定で新規発行する。
    /// memberwise initializer は let プロパティの既定値を引数として公開しないため手書きしている
    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// 分割した 2 つのペインを並べる向き
enum SplitAxis: Sendable {
    /// 左右に並べる (tmux の split-window -h / prefix %)
    case horizontal
    /// 上下に並べる (tmux の split-window -v / prefix ")
    case vertical
}

/// 分割の 2 つの子のどちら側か。根からの経路 ([SplitSide]) で木の中の分割を指す
enum SplitSide: Sendable {
    case first
    case second
}

/// 隣り合うペインの間にある境界線。ドラッグでその分割の割合を変えるために、どの分割かを根からの経路で指す
struct PaneDivider: Equatable, Sendable {
    /// 境界線が属する分割の向き。horizontal なら縦線、vertical なら横線になる
    let axis: SplitAxis
    /// 根からその分割へ辿る経路。根の分割なら空
    let path: [SplitSide]
    /// 境界線の位置。分割の向きと直交する方向の太さは 0 で、描画側が太さを足す
    let line: CGRect
    /// 割合 1.0 に対応する長さ (分割している矩形の幅または高さ)。ドラッグ量を割合の変化に換算する
    let extent: CGFloat
}

/// h / j / k / l と矢印キーで選ぶペインの方向。単位矩形の座標系 (y は下向きに増える) で解釈する
enum FocusDirection: Sendable {
    case left
    case down
    case up
    case right
}

/// prefix + Space が巡回するレイアウト。tmux の even-horizontal / even-vertical / tiled に対応する
enum PaneLayout: CaseIterable, Sendable {
    case evenHorizontal
    case evenVertical
    case tiled

    /// 巡回順で次のレイアウト。末尾からは先頭へ戻る
    var next: PaneLayout {
        guard let index = PaneLayout.allCases.firstIndex(of: self) else {
            return .evenHorizontal
        }
        return PaneLayout.allCases[(index + 1) % PaneLayout.allCases.count]
    }
}

/// ペインの配置を表す二分木。葉が 1 枚のペイン、節がその位置での分割を表す
indirect enum PaneNode: Equatable, Sendable {
    case leaf(PaneID)
    /// ratio は first が占める割合。horizontal では first が左、vertical では first が minY 側 (SwiftUI の座標系では上)
    case split(axis: SplitAxis, ratio: Double, first: PaneNode, second: PaneNode)

    /// 分割直後の割合。tmux の split-window と同じく等分から始める
    static let defaultRatio = 0.5
    /// リサイズで許す割合の範囲。ペインが潰れて URL バーもコンテンツも読めなくなるのを防ぐため、どちらの側にも最低 5% を残す
    static let ratioRange = 0.05...0.95

    /// 葉を深さ優先・first → second の順に並べた識別子。tmux のペイン番号の順に相当する
    var paneIDs: [PaneID] {
        switch self {
        case .leaf(let paneID):
            return [paneID]
        case .split(_, _, let first, let second):
            return first.paneIDs + second.paneIDs
        }
    }

    /// この部分木に含まれる葉かどうか
    func contains(paneID: PaneID) -> Bool {
        switch self {
        case .leaf(let leafPaneID):
            return leafPaneID == paneID
        case .split(_, _, let first, let second):
            return first.contains(paneID: paneID) || second.contains(paneID: paneID)
        }
    }

    /// 指定した葉を分割し、新しい葉を second 側に置いた木を返す。該当する葉が無ければそのまま返す
    func splitting(paneID: PaneID, axis: SplitAxis, newPaneID: PaneID) -> PaneNode {
        switch self {
        case .leaf(let leafPaneID):
            guard leafPaneID == paneID else {
                return self
            }
            return .split(axis: axis, ratio: PaneNode.defaultRatio, first: self, second: .leaf(newPaneID))
        case .split(let splitAxis, let ratio, let first, let second):
            return .split(
                axis: splitAxis,
                ratio: ratio,
                first: first.splitting(paneID: paneID, axis: axis, newPaneID: newPaneID),
                second: second.splitting(paneID: paneID, axis: axis, newPaneID: newPaneID)
            )
        }
    }

    /// 指定した葉を取り除き、兄弟を親の位置へ昇格させた木を返す。木全体がその葉だけだった場合は nil
    func removing(paneID: PaneID) -> PaneNode? {
        switch self {
        case .leaf(let leafPaneID):
            return leafPaneID == paneID ? nil : self
        case .split(let splitAxis, let ratio, let first, let second):
            guard let removedFirst = first.removing(paneID: paneID) else {
                return second
            }
            guard let removedSecond = second.removing(paneID: paneID) else {
                return first
            }
            return .split(axis: splitAxis, ratio: ratio, first: removedFirst, second: removedSecond)
        }
    }

    /// 2 つの葉の位置を入れ替えた木を返す
    func swapping(paneID: PaneID, otherPaneID: PaneID) -> PaneNode {
        switch self {
        case .leaf(let leafPaneID):
            switch leafPaneID {
            case paneID:
                return .leaf(otherPaneID)
            case otherPaneID:
                return .leaf(paneID)
            default:
                return self
            }
        case .split(let splitAxis, let ratio, let first, let second):
            return .split(
                axis: splitAxis,
                ratio: ratio,
                first: first.swapping(paneID: paneID, otherPaneID: otherPaneID),
                second: second.swapping(paneID: paneID, otherPaneID: otherPaneID)
            )
        }
    }

    /// 指定した葉を含む最も近い祖先のうち axis が一致する split の割合を動かした木を返す。
    /// 葉が first 側なら delta を足し、second 側なら引く。該当する split が無ければそのまま返す
    func resizing(paneID: PaneID, axis: SplitAxis, delta: Double) -> PaneNode {
        resizingNearestSplit(paneID: paneID, axis: axis, delta: delta) ?? self
    }

    /// 単位を問わない矩形分割。zoom は木の外側の状態のため、ここでは考慮しない
    func frames(bounds: CGRect) -> [PaneID: CGRect] {
        switch self {
        case .leaf(let paneID):
            return [paneID: bounds]
        case .split(let splitAxis, let ratio, let first, let second):
            let dividedBounds = PaneNode.dividing(bounds: bounds, axis: splitAxis, ratio: ratio)
            return first.frames(bounds: dividedBounds.first)
                .merging(second.frames(bounds: dividedBounds.second)) { existing, _ in existing }
        }
    }

    /// 各分割の境界線。zoom 中は境界が無いため、呼び出し側 (PaneTree) が空にする
    func dividers(bounds: CGRect) -> [PaneDivider] {
        dividers(bounds: bounds, path: [])
    }

    /// 経路で指した分割の割合を delta 分動かした木を返す。経路が分割を指していなければそのまま返す
    func resizing(dividerPath: [SplitSide], delta: Double) -> PaneNode {
        guard case .split(let splitAxis, let ratio, let first, let second) = self else {
            return self
        }
        guard let side = dividerPath.first else {
            return .split(axis: splitAxis, ratio: clampedRatio(ratio: ratio + delta), first: first, second: second)
        }
        let childPath = Array(dividerPath.dropFirst())
        switch side {
        case .first:
            return .split(axis: splitAxis, ratio: ratio, first: first.resizing(dividerPath: childPath, delta: delta), second: second)
        case .second:
            return .split(axis: splitAxis, ratio: ratio, first: first, second: second.resizing(dividerPath: childPath, delta: delta))
        }
    }

    /// paneIDs の並び順を保ったまま、レイアウトどおりに組み直した木を返す。paneIDs が空なら nil
    static func arranged(paneIDs: [PaneID], layout: PaneLayout) -> PaneNode? {
        switch layout {
        case .evenHorizontal:
            return evenlyDivided(nodes: paneIDs.map(PaneNode.leaf), axis: .horizontal)
        case .evenVertical:
            return evenlyDivided(nodes: paneIDs.map(PaneNode.leaf), axis: .vertical)
        case .tiled:
            return tiled(paneIDs: paneIDs)
        }
    }

    private func resizingNearestSplit(paneID: PaneID, axis: SplitAxis, delta: Double) -> PaneNode? {
        guard case .split(let splitAxis, let ratio, let first, let second) = self else {
            return nil
        }
        let isFirstSide = first.contains(paneID: paneID)
        guard isFirstSide || second.contains(paneID: paneID) else {
            return nil
        }
        if let resizedChild = (isFirstSide ? first : second).resizingNearestSplit(paneID: paneID, axis: axis, delta: delta) {
            return isFirstSide
                ? .split(axis: splitAxis, ratio: ratio, first: resizedChild, second: second)
                : .split(axis: splitAxis, ratio: ratio, first: first, second: resizedChild)
        }
        guard splitAxis == axis else {
            return nil
        }
        return .split(
            axis: splitAxis,
            ratio: clampedRatio(ratio: isFirstSide ? ratio + delta : ratio - delta),
            first: first,
            second: second
        )
    }

    private func dividers(bounds: CGRect, path: [SplitSide]) -> [PaneDivider] {
        guard case .split(let splitAxis, let ratio, let first, let second) = self else {
            return []
        }
        let dividedBounds = PaneNode.dividing(bounds: bounds, axis: splitAxis, ratio: ratio)
        let divider: PaneDivider
        switch splitAxis {
        case .horizontal:
            divider = PaneDivider(
                axis: splitAxis,
                path: path,
                line: CGRect(x: dividedBounds.second.minX, y: bounds.minY, width: 0, height: bounds.height),
                extent: bounds.width
            )
        case .vertical:
            divider = PaneDivider(
                axis: splitAxis,
                path: path,
                line: CGRect(x: bounds.minX, y: dividedBounds.second.minY, width: bounds.width, height: 0),
                extent: bounds.height
            )
        }
        return [divider]
            + first.dividers(bounds: dividedBounds.first, path: path + [.first])
            + second.dividers(bounds: dividedBounds.second, path: path + [.second])
    }

    private func clampedRatio(ratio: Double) -> Double {
        min(max(ratio, PaneNode.ratioRange.lowerBound), PaneNode.ratioRange.upperBound)
    }

    private static func dividing(bounds: CGRect, axis: SplitAxis, ratio: Double) -> (first: CGRect, second: CGRect) {
        switch axis {
        case .horizontal:
            let firstWidth = bounds.width * ratio
            return (
                CGRect(x: bounds.minX, y: bounds.minY, width: firstWidth, height: bounds.height),
                CGRect(x: bounds.minX + firstWidth, y: bounds.minY, width: bounds.width - firstWidth, height: bounds.height)
            )
        case .vertical:
            let firstHeight = bounds.height * ratio
            return (
                CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: firstHeight),
                CGRect(x: bounds.minX, y: bounds.minY + firstHeight, width: bounds.width, height: bounds.height - firstHeight)
            )
        }
    }

    /// 先頭の 1 枚に 1/n を与え、残りを再帰的に等分することで n 等分を入れ子の split で表現する
    private static func evenlyDivided(nodes: [PaneNode], axis: SplitAxis) -> PaneNode? {
        guard let headNode = nodes.first else {
            return nil
        }
        guard let restNode = evenlyDivided(nodes: Array(nodes.dropFirst()), axis: axis) else {
            return headNode
        }
        return .split(axis: axis, ratio: 1.0 / Double(nodes.count), first: headNode, second: restNode)
    }

    /// 1 行あたりの列数を ceil(sqrt(n)) にした格子。tmux の layout_set_tiled が列数から行数を決めるのに合わせており、
    /// n = 2 で左右 2 枚、n = 3 で 1 行目 2 枚・2 行目 1 枚になる
    private static func tiled(paneIDs: [PaneID]) -> PaneNode? {
        guard !paneIDs.isEmpty else {
            return nil
        }
        let columns = Int(Double(paneIDs.count).squareRoot().rounded(.up))
        return evenlyDivided(
            nodes: stride(from: 0, to: paneIDs.count, by: columns).compactMap { rowStart in
                evenlyDivided(
                    nodes: paneIDs[rowStart..<min(rowStart + columns, paneIDs.count)].map(PaneNode.leaf),
                    axis: .horizontal
                )
            },
            axis: .vertical
        )
    }
}

/// 1 つのウィンドウが持つペインの配置とフォーカス状態。tmux の window に相当する
struct PaneTree: Equatable, Sendable {
    /// ペインの配置
    private(set) var root: PaneNode
    /// キー入力とページ操作の宛先になっているペイン
    private(set) var focusedPaneID: PaneID
    /// prefix + ; で戻る先。直前にフォーカスしていたペインが閉じられた場合は nil になる
    private(set) var previousFocusedPaneID: PaneID?
    /// prefix + z で全面表示しているペイン
    private(set) var zoomedPaneID: PaneID?
    /// prefix + Space で最後に適用したレイアウト。次に巡回する先を決めるために覚える。分割・閉じるで配置が変わっても保持する (tmux と同じ)
    private(set) var appliedLayout: PaneLayout?

    /// 起動直後のウィンドウは 1 枚のペインから始まる
    init() {
        let paneID = PaneID()
        self.root = .leaf(paneID)
        self.focusedPaneID = paneID
    }

    /// 葉を深さ優先・first → second の順に並べた識別子
    var paneIDs: [PaneID] {
        root.paneIDs
    }

    /// フォーカス中のペインを分割し、新しいペインへフォーカスを移す (tmux の split-window と同じ)
    @discardableResult
    mutating func split(axis: SplitAxis) -> PaneID {
        let newPaneID = PaneID()
        root = root.splitting(paneID: focusedPaneID, axis: axis, newPaneID: newPaneID)
        zoomedPaneID = nil
        focus(paneID: newPaneID)
        return newPaneID
    }

    /// 指定したペインを閉じ、兄弟を親の位置へ昇格させる。
    /// 最後の 1 枚は閉じずに false を返し、ウィンドウ自体を閉じるかどうかの判断を呼び出し側に委ねる
    @discardableResult
    mutating func close(paneID: PaneID) -> Bool {
        let closingPaneIDs = paneIDs
        guard closingPaneIDs.count > 1, let closingIndex = closingPaneIDs.firstIndex(of: paneID) else {
            return false
        }
        guard let removedRoot = root.removing(paneID: paneID) else {
            return false
        }
        root = removedRoot
        if previousFocusedPaneID == paneID {
            previousFocusedPaneID = nil
        }
        if zoomedPaneID == paneID {
            zoomedPaneID = nil
        }
        if focusedPaneID == paneID {
            focusedPaneID = closingPaneIDs[closingIndex + 1 < closingPaneIDs.count ? closingIndex + 1 : closingIndex - 1]
        }
        return true
    }

    /// フォーカス中のペインを閉じる (prefix + x)
    @discardableResult
    mutating func closeFocusedPane() -> Bool {
        close(paneID: focusedPaneID)
    }

    /// 指定したペインへフォーカスを移す。全面表示中は tmux の select-pane と同じく zoom を解除する
    mutating func focus(paneID: PaneID) {
        guard paneID != focusedPaneID, root.contains(paneID: paneID) else {
            return
        }
        previousFocusedPaneID = focusedPaneID
        focusedPaneID = paneID
        zoomedPaneID = nil
    }

    /// paneIDs の順で次のペインへ移す (prefix + o)。末尾の次は先頭へ戻る
    mutating func focusNext() {
        focus(paneID: neighborPaneID(offset: 1))
    }

    /// paneIDs の順で前のペインへ移す。先頭の前は末尾へ回る
    mutating func focusPrevious() {
        focus(paneID: neighborPaneID(offset: -1))
    }

    /// 直前にフォーカスしていたペインへ戻る (prefix + ;)。戻る先が無ければ何もしない
    mutating func focusLastPane() {
        guard let previousFocusedPaneID else {
            return
        }
        focus(paneID: previousFocusedPaneID)
    }

    /// 単位矩形での配置を基に、その方向でフォーカス中のペインと辺を接し、重なりが最大のペインへ移す (prefix + h/j/k/l)。
    /// 接するペインが無ければ何もしない
    mutating func focus(direction: FocusDirection) {
        guard let adjacentPaneID = adjacentPaneID(direction: direction) else {
            return
        }
        focus(paneID: adjacentPaneID)
    }

    /// フォーカス中のペインの全面表示を切り替える (prefix + z)
    mutating func toggleZoom() {
        zoomedPaneID = zoomedPaneID == nil ? focusedPaneID : nil
    }

    /// フォーカス中のペインを paneIDs の順で 1 つ前のペインと入れ替える (prefix + {)。先頭からは末尾へ回る
    mutating func swapWithPrevious() {
        swap(otherPaneID: neighborPaneID(offset: -1))
    }

    /// フォーカス中のペインを paneIDs の順で 1 つ後のペインと入れ替える (prefix + })。末尾からは先頭へ回る
    mutating func swapWithNext() {
        swap(otherPaneID: neighborPaneID(offset: 1))
    }

    /// paneIDs の順を保ったままレイアウトを適用する (prefix + Space)。全面表示は配置を見せるため解除する
    mutating func apply(layout: PaneLayout) {
        guard let arrangedRoot = PaneNode.arranged(paneIDs: paneIDs, layout: layout) else {
            return
        }
        root = arrangedRoot
        zoomedPaneID = nil
        appliedLayout = layout
    }

    /// 最後に適用したレイアウトの次を適用する (prefix + Space)。まだ適用していなければ巡回順の先頭から始める
    mutating func applyNextLayout() {
        apply(layout: appliedLayout?.next ?? PaneLayout.allCases[0])
    }

    /// 境界線のドラッグで、その境界線が属する分割の割合を動かす
    mutating func resize(dividerPath: [SplitSide], delta: Double) {
        root = root.resizing(dividerPath: dividerPath, delta: delta)
    }

    /// ペイン間の境界線。全面表示中は境界が無い
    func dividers(bounds: CGRect) -> [PaneDivider] {
        if zoomedPaneID != nil {
            return []
        }
        return root.dividers(bounds: bounds)
    }

    /// 指定したペインを含む最も近い同じ向きの分割の割合を動かす
    mutating func resize(paneID: PaneID, axis: SplitAxis, delta: Double) {
        root = root.resizing(paneID: paneID, axis: axis, delta: delta)
    }

    /// 各ペインの矩形。全面表示中のペインがあればそのペインだけが bounds 全体を占める。
    /// ペイン間の隙間 (境界線の太さ) は描画側の関心事のため、ここでは矩形を隙間なく敷き詰める
    func frames(bounds: CGRect) -> [PaneID: CGRect] {
        if let zoomedPaneID {
            return [zoomedPaneID: bounds]
        }
        return root.frames(bounds: bounds)
    }

    private mutating func swap(otherPaneID: PaneID) {
        guard otherPaneID != focusedPaneID else {
            return
        }
        // フォーカスは動かしたペインに付いていくため focusedPaneID は変えない (tmux の swap-pane -U / -D と同じ)
        root = root.swapping(paneID: focusedPaneID, otherPaneID: otherPaneID)
    }

    private func neighborPaneID(offset: Int) -> PaneID {
        let orderedPaneIDs = paneIDs
        guard let index = orderedPaneIDs.firstIndex(of: focusedPaneID) else {
            return focusedPaneID
        }
        return orderedPaneIDs[(index + offset + orderedPaneIDs.count) % orderedPaneIDs.count]
    }

    private func adjacentPaneID(direction: FocusDirection) -> PaneID? {
        let unitFrames = root.frames(bounds: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let focusedFrame = unitFrames[focusedPaneID] else {
            return nil
        }
        var adjacentPaneID: PaneID?
        // 角だけで接するペイン (重なり 0) を除くため、0 より大きい重なりだけを候補にする
        var largestOverlap = 0.0
        for paneID in paneIDs where paneID != focusedPaneID {
            guard let frame = unitFrames[paneID],
                  PaneTree.isTouching(frame: frame, focusedFrame: focusedFrame, direction: direction) else {
                continue
            }
            let overlap = PaneTree.edgeOverlap(frame: frame, focusedFrame: focusedFrame, direction: direction)
            if overlap > largestOverlap {
                largestOverlap = overlap
                adjacentPaneID = paneID
            }
        }
        return adjacentPaneID
    }

    /// 単位矩形上で辺が接していると認める誤差。入れ子の割合の積で生じる倍精度の誤差 (1e-15 程度) を吸収し、
    /// かつ最小のペイン (幅 5%) を誤って接触と判定しない大きさにする
    private static let edgeTolerance = 1e-9

    private static func isTouching(frame: CGRect, focusedFrame: CGRect, direction: FocusDirection) -> Bool {
        switch direction {
        case .left:
            return abs(frame.maxX - focusedFrame.minX) <= edgeTolerance
        case .right:
            return abs(frame.minX - focusedFrame.maxX) <= edgeTolerance
        case .up:
            return abs(frame.maxY - focusedFrame.minY) <= edgeTolerance
        case .down:
            return abs(frame.minY - focusedFrame.maxY) <= edgeTolerance
        }
    }

    private static func edgeOverlap(frame: CGRect, focusedFrame: CGRect, direction: FocusDirection) -> Double {
        switch direction {
        case .left, .right:
            return min(frame.maxY, focusedFrame.maxY) - max(frame.minY, focusedFrame.minY)
        case .up, .down:
            return min(frame.maxX, focusedFrame.maxX) - max(frame.minX, focusedFrame.minX)
        }
    }
}

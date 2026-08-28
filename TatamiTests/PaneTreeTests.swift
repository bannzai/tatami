import CoreGraphics
import Foundation
import Testing
@testable import Tatami

/// PaneTree のペイン操作 (分割・削除・フォーカス・zoom・入れ替え・レイアウト・リサイズ) と矩形計算を検証する
struct PaneTreeTests {
    /// 入れ子の割合の積で生じる浮動小数の誤差を許す比較幅
    static let tolerance = 1e-9
    /// 検証用の矩形。幅と高さを揃えて、縦横どちらの分割でも同じ数値で期待値を書けるようにする
    static let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)

    @Test func initialTreeHasSinglePane() {
        let tree = PaneTree()
        #expect(tree.paneIDs.count == 1)
        #expect(tree.focusedPaneID == tree.paneIDs[0])
        #expect(tree.previousFocusedPaneID == nil)
        #expect(tree.zoomedPaneID == nil)
    }

    @Test func splitAddsPaneAndFocusesIt() {
        var tree = PaneTree()
        let firstPaneID = tree.focusedPaneID
        let newPaneID = tree.split(axis: .horizontal)
        #expect(tree.paneIDs == [firstPaneID, newPaneID])
        #expect(tree.focusedPaneID == newPaneID)
        #expect(tree.previousFocusedPaneID == firstPaneID)
    }

    @Test func nestedSplitsKeepDepthFirstOrder() {
        var tree = PaneTree()
        let leftTopPaneID = tree.focusedPaneID
        let rightPaneID = tree.split(axis: .horizontal)
        tree.focus(paneID: leftTopPaneID)
        let leftBottomPaneID = tree.split(axis: .vertical)
        #expect(tree.paneIDs == [leftTopPaneID, leftBottomPaneID, rightPaneID])
    }

    @Test func splitReleasesZoom() {
        var tree = PaneTree()
        tree.split(axis: .horizontal)
        tree.toggleZoom()
        tree.split(axis: .vertical)
        #expect(tree.zoomedPaneID == nil)
    }

    @Test func closePromotesSiblingAndMovesFocusToNextPane() {
        var tree = PaneTree()
        let leftTopPaneID = tree.focusedPaneID
        let rightPaneID = tree.split(axis: .horizontal)
        tree.focus(paneID: leftTopPaneID)
        let leftBottomPaneID = tree.split(axis: .vertical)
        let didCloseLeftBottomPane = tree.close(paneID: leftBottomPaneID)
        #expect(didCloseLeftBottomPane)
        #expect(tree.paneIDs == [leftTopPaneID, rightPaneID])
        #expect(tree.focusedPaneID == rightPaneID)
        #expect(tree.root == .split(axis: .horizontal, ratio: 0.5, first: .leaf(leftTopPaneID), second: .leaf(rightPaneID)))
    }

    @Test func closingLastPaneInOrderMovesFocusBackward() {
        var tree = PaneTree()
        let firstPaneID = tree.focusedPaneID
        tree.split(axis: .horizontal)
        let didCloseSecondPane = tree.closeFocusedPane()
        #expect(didCloseSecondPane)
        #expect(tree.focusedPaneID == firstPaneID)
    }

    @Test func singlePaneIsNotClosed() {
        var tree = PaneTree()
        let didCloseOnlyPane = tree.closeFocusedPane()
        #expect(didCloseOnlyPane == false)
        #expect(tree.paneIDs.count == 1)
    }

    @Test func closeClearsPreviousFocusOfRemovedPane() {
        var tree = PaneTree()
        let firstPaneID = tree.focusedPaneID
        let secondPaneID = tree.split(axis: .horizontal)
        tree.focus(paneID: firstPaneID)
        #expect(tree.previousFocusedPaneID == secondPaneID)
        let didCloseSecondPane = tree.close(paneID: secondPaneID)
        #expect(didCloseSecondPane)
        #expect(tree.previousFocusedPaneID == nil)
        #expect(tree.focusedPaneID == firstPaneID)
    }

    @Test func closeClearsZoomOfRemovedPane() {
        var tree = PaneTree()
        tree.split(axis: .horizontal)
        tree.toggleZoom()
        #expect(tree.zoomedPaneID == tree.focusedPaneID)
        let didCloseZoomedPane = tree.closeFocusedPane()
        #expect(didCloseZoomedPane)
        #expect(tree.zoomedPaneID == nil)
    }

    @Test func focusNextAndPreviousCycleThroughPanes() {
        var tree = PaneTree()
        let leftTopPaneID = tree.focusedPaneID
        let rightPaneID = tree.split(axis: .horizontal)
        tree.focus(paneID: leftTopPaneID)
        let leftBottomPaneID = tree.split(axis: .vertical)
        #expect(tree.focusedPaneID == leftBottomPaneID)
        tree.focusNext()
        #expect(tree.focusedPaneID == rightPaneID)
        tree.focusNext()
        #expect(tree.focusedPaneID == leftTopPaneID)
        tree.focusPrevious()
        #expect(tree.focusedPaneID == rightPaneID)
    }

    @Test func focusLastPaneSwapsWithPreviousFocus() {
        var tree = PaneTree()
        let firstPaneID = tree.focusedPaneID
        let secondPaneID = tree.split(axis: .horizontal)
        tree.focusLastPane()
        #expect(tree.focusedPaneID == firstPaneID)
        tree.focusLastPane()
        #expect(tree.focusedPaneID == secondPaneID)
    }

    @Test func focusLastPaneDoesNothingWithoutPreviousFocus() {
        var tree = PaneTree()
        tree.focusLastPane()
        #expect(tree.focusedPaneID == tree.paneIDs[0])
    }

    @Test func directionalFocusMovesAcrossHorizontalSplit() {
        var tree = PaneTree()
        let leftPaneID = tree.focusedPaneID
        let rightPaneID = tree.split(axis: .horizontal)
        tree.focus(direction: .left)
        #expect(tree.focusedPaneID == leftPaneID)
        tree.focus(direction: .right)
        #expect(tree.focusedPaneID == rightPaneID)
    }

    @Test func directionalFocusMovesAcrossVerticalSplit() {
        var tree = PaneTree()
        let topPaneID = tree.focusedPaneID
        let bottomPaneID = tree.split(axis: .vertical)
        tree.focus(direction: .up)
        #expect(tree.focusedPaneID == topPaneID)
        tree.focus(direction: .down)
        #expect(tree.focusedPaneID == bottomPaneID)
    }

    @Test func directionalFocusKeepsFocusWithoutNeighbor() {
        var tree = PaneTree()
        let rightPaneID = tree.split(axis: .horizontal)
        tree.focus(direction: .up)
        #expect(tree.focusedPaneID == rightPaneID)
        tree.focus(direction: .right)
        #expect(tree.focusedPaneID == rightPaneID)
    }

    @Test func directionalFocusPicksPaneWithLargestEdgeOverlap() {
        var tree = PaneTree()
        let leftPaneID = tree.focusedPaneID
        let rightTopPaneID = tree.split(axis: .horizontal)
        let rightBottomPaneID = tree.split(axis: .vertical)
        tree.focus(paneID: leftPaneID)
        tree.focus(direction: .right)
        #expect(tree.focusedPaneID == rightTopPaneID)
        tree.resize(paneID: rightTopPaneID, axis: .vertical, delta: -0.3)
        tree.focus(paneID: leftPaneID)
        tree.focus(direction: .right)
        #expect(tree.focusedPaneID == rightBottomPaneID)
    }

    @Test func zoomShowsOnlyFocusedPane() {
        var tree = PaneTree()
        let zoomedPaneID = tree.split(axis: .horizontal)
        tree.toggleZoom()
        #expect(tree.zoomedPaneID == zoomedPaneID)
        #expect(tree.frames(bounds: PaneTreeTests.bounds) == [zoomedPaneID: PaneTreeTests.bounds])
        tree.toggleZoom()
        #expect(tree.zoomedPaneID == nil)
        #expect(tree.frames(bounds: PaneTreeTests.bounds).count == 2)
    }

    @Test func focusChangeReleasesZoom() {
        var tree = PaneTree()
        tree.split(axis: .horizontal)
        tree.toggleZoom()
        tree.focusNext()
        #expect(tree.zoomedPaneID == nil)
    }

    @Test func swapMovesFocusedPaneAndKeepsFocus() {
        var tree = PaneTree()
        let firstPaneID = tree.focusedPaneID
        let secondPaneID = tree.split(axis: .horizontal)
        tree.swapWithPrevious()
        #expect(tree.paneIDs == [secondPaneID, firstPaneID])
        #expect(tree.focusedPaneID == secondPaneID)
        tree.swapWithNext()
        #expect(tree.paneIDs == [firstPaneID, secondPaneID])
        #expect(tree.focusedPaneID == secondPaneID)
    }

    @Test func swapWrapsAroundTheOrder() {
        var tree = PaneTree()
        let leftTopPaneID = tree.focusedPaneID
        let rightPaneID = tree.split(axis: .horizontal)
        tree.focus(paneID: leftTopPaneID)
        let leftBottomPaneID = tree.split(axis: .vertical)
        #expect(tree.paneIDs == [leftTopPaneID, leftBottomPaneID, rightPaneID])
        tree.focus(paneID: leftTopPaneID)
        tree.swapWithPrevious()
        #expect(tree.paneIDs == [rightPaneID, leftBottomPaneID, leftTopPaneID])
        #expect(tree.focusedPaneID == leftTopPaneID)
    }

    @Test func evenHorizontalLayoutDividesWidthEqually() throws {
        var tree = PaneTreeTests.threePaneTree()
        tree.apply(layout: .evenHorizontal)
        let frames = tree.frames(bounds: PaneTreeTests.bounds)
        for paneID in tree.paneIDs {
            let frame = try #require(frames[paneID])
            #expect(abs(frame.width - 100.0 / 3.0) < PaneTreeTests.tolerance)
            #expect(abs(frame.height - 100) < PaneTreeTests.tolerance)
        }
        let leftFrame = try #require(frames[tree.paneIDs[0]])
        let rightFrame = try #require(frames[tree.paneIDs[2]])
        #expect(leftFrame.minX == 0)
        #expect(abs(rightFrame.maxX - 100) < PaneTreeTests.tolerance)
    }

    @Test func evenVerticalLayoutDividesHeightEqually() throws {
        var tree = PaneTreeTests.threePaneTree()
        tree.apply(layout: .evenVertical)
        let frames = tree.frames(bounds: PaneTreeTests.bounds)
        for paneID in tree.paneIDs {
            let frame = try #require(frames[paneID])
            #expect(abs(frame.height - 100.0 / 3.0) < PaneTreeTests.tolerance)
            #expect(abs(frame.width - 100) < PaneTreeTests.tolerance)
        }
    }

    @Test func tiledLayoutMakesTwoRowsForThreePanes() throws {
        var tree = PaneTreeTests.threePaneTree()
        tree.apply(layout: .tiled)
        let frames = tree.frames(bounds: PaneTreeTests.bounds)
        let firstRowLeftFrame = try #require(frames[tree.paneIDs[0]])
        let firstRowRightFrame = try #require(frames[tree.paneIDs[1]])
        let secondRowFrame = try #require(frames[tree.paneIDs[2]])
        #expect(firstRowLeftFrame == CGRect(x: 0, y: 0, width: 50, height: 50))
        #expect(firstRowRightFrame == CGRect(x: 50, y: 0, width: 50, height: 50))
        #expect(secondRowFrame == CGRect(x: 0, y: 50, width: 100, height: 50))
    }

    @Test func layoutKeepsPaneOrder() {
        var tree = PaneTreeTests.threePaneTree()
        let orderedPaneIDs = tree.paneIDs
        tree.apply(layout: .tiled)
        #expect(tree.paneIDs == orderedPaneIDs)
        tree.apply(layout: .evenVertical)
        #expect(tree.paneIDs == orderedPaneIDs)
    }

    @Test func layoutCyclesInFixedOrder() {
        #expect(PaneLayout.evenHorizontal.next == .evenVertical)
        #expect(PaneLayout.evenVertical.next == .tiled)
        #expect(PaneLayout.tiled.next == .evenHorizontal)
    }

    @Test func resizeChangesRatioOfMatchingSplitOnly() throws {
        var tree = PaneTree()
        let leftPaneID = tree.focusedPaneID
        tree.split(axis: .horizontal)
        tree.resize(paneID: leftPaneID, axis: .horizontal, delta: 0.1)
        let widenedFrame = try #require(tree.frames(bounds: PaneTreeTests.bounds)[leftPaneID])
        #expect(abs(widenedFrame.width - 60) < PaneTreeTests.tolerance)
        tree.resize(paneID: leftPaneID, axis: .vertical, delta: 0.1)
        let unchangedFrame = try #require(tree.frames(bounds: PaneTreeTests.bounds)[leftPaneID])
        #expect(abs(unchangedFrame.width - 60) < PaneTreeTests.tolerance)
    }

    @Test func resizeFromSecondSideMovesRatioInOppositeDirection() throws {
        var tree = PaneTree()
        let rightPaneID = tree.split(axis: .horizontal)
        tree.resize(paneID: rightPaneID, axis: .horizontal, delta: 0.1)
        let widenedFrame = try #require(tree.frames(bounds: PaneTreeTests.bounds)[rightPaneID])
        #expect(abs(widenedFrame.width - 60) < PaneTreeTests.tolerance)
    }

    @Test func resizeClampsRatioWithinRange() throws {
        var tree = PaneTree()
        let leftPaneID = tree.focusedPaneID
        tree.split(axis: .horizontal)
        tree.resize(paneID: leftPaneID, axis: .horizontal, delta: 10)
        let widestFrame = try #require(tree.frames(bounds: PaneTreeTests.bounds)[leftPaneID])
        #expect(abs(widestFrame.width - 95) < PaneTreeTests.tolerance)
        tree.resize(paneID: leftPaneID, axis: .horizontal, delta: -10)
        let narrowestFrame = try #require(tree.frames(bounds: PaneTreeTests.bounds)[leftPaneID])
        #expect(abs(narrowestFrame.width - 5) < PaneTreeTests.tolerance)
    }

    @Test func framesCoverBoundsWithoutGap() {
        var tree = PaneTreeTests.threePaneTree()
        tree.split(axis: .horizontal)
        tree.resize(paneID: tree.focusedPaneID, axis: .horizontal, delta: 0.2)
        let frames = tree.frames(bounds: PaneTreeTests.bounds)
        #expect(frames.count == 4)
        let totalArea = frames.values.reduce(0.0) { total, frame in
            total + frame.width * frame.height
        }
        #expect(abs(totalArea - PaneTreeTests.bounds.width * PaneTreeTests.bounds.height) < PaneTreeTests.tolerance)
        for frame in frames.values {
            #expect(frame.width > 0)
            #expect(frame.height > 0)
        }
    }

    /// 左に 1 枚、右を上下に分けた 3 枚のペインを持つ木。フォーカスは右下のペインにある
    private static func threePaneTree() -> PaneTree {
        var tree = PaneTree()
        tree.split(axis: .horizontal)
        tree.split(axis: .vertical)
        return tree
    }

    @Test func directionalFocusDoesNotSkipThinNeighbor() {
        var tree = PaneTree()
        let leftPaneID = tree.focusedPaneID
        let middlePaneID = tree.split(axis: .horizontal)
        let rightPaneID = tree.split(axis: .horizontal)
        tree.resize(paneID: middlePaneID, axis: .horizontal, delta: -1)
        tree.focus(paneID: rightPaneID)
        tree.focus(direction: .left)
        #expect(tree.focusedPaneID == middlePaneID)
        tree.focus(direction: .left)
        #expect(tree.focusedPaneID == leftPaneID)
        tree.focus(direction: .right)
        #expect(tree.focusedPaneID == middlePaneID)
    }

    @Test func directionalFocusPicksLargestOverlapAmongEdgePanes() {
        var tree = PaneTree()
        let leftPaneID = tree.focusedPaneID
        let rightTopPaneID = tree.split(axis: .horizontal)
        let rightBottomPaneID = tree.split(axis: .vertical)
        tree.resize(paneID: rightBottomPaneID, axis: .vertical, delta: 0.3)
        tree.focus(paneID: leftPaneID)
        tree.focus(direction: .right)
        #expect(tree.focusedPaneID == rightBottomPaneID)
        #expect(tree.paneIDs == [leftPaneID, rightTopPaneID, rightBottomPaneID])
    }
}

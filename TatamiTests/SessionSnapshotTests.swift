import Foundation
import Testing
@testable import Tatami

/// セッションの JSON 保存・復元の round-trip と、ファイル操作を検証する
struct SessionSnapshotTests {
    /// テストごとに独立した一時ディレクトリを使い、実際の Application Support を汚さない
    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "tatami-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeSnapshot(name: String) -> SessionSnapshot {
        var tree = PaneTree()
        let firstPaneID = tree.focusedPaneID
        let secondPaneID = tree.split(axis: .horizontal)
        tree.resize(dividerPath: [], delta: 0.1)
        tree.toggleZoom()
        return SessionSnapshot(
            name: name,
            windows: [
                SessionSnapshot.Window(
                    paneTree: tree,
                    panes: [
                        SessionSnapshot.Window.Pane(id: firstPaneID, url: URL(string: "https://example.com/")!),
                        SessionSnapshot.Window.Pane(id: secondPaneID, url: URL(string: "about:blank")!),
                    ],
                    renamedName: "docs"
                ),
                SessionSnapshot.Window(paneTree: PaneTree(), panes: [], renamedName: nil),
            ],
            currentWindowIndex: 1
        )
    }

    @Test func jsonRoundTripPreservesEverything() throws {
        let snapshot = makeSnapshot(name: "0")
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        #expect(decoded == snapshot)
        #expect(decoded.windows[0].paneTree.zoomedPaneID == snapshot.windows[0].paneTree.zoomedPaneID)
        #expect(decoded.windows[0].paneTree.frames(bounds: CGRect(x: 0, y: 0, width: 100, height: 100)) == snapshot.windows[0].paneTree.frames(bounds: CGRect(x: 0, y: 0, width: 100, height: 100)))
    }

    @Test func saveLoadListAndRename() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        #expect(try SessionStore.load(name: "0", directoryURL: directoryURL) == nil)
        let snapshot = makeSnapshot(name: "0")
        try SessionStore.save(snapshot: snapshot, directoryURL: directoryURL)
        try SessionStore.save(snapshot: makeSnapshot(name: "work"), directoryURL: directoryURL)
        #expect(try SessionStore.load(name: "0", directoryURL: directoryURL) == snapshot)
        #expect(SessionStore.sessionNames(directoryURL: directoryURL) == ["0", "work"])
        try SessionStore.rename(name: "work", newName: "home", directoryURL: directoryURL)
        #expect(SessionStore.sessionNames(directoryURL: directoryURL) == ["0", "home"])
        #expect(throws: (any Error).self) {
            try SessionStore.rename(name: "home", newName: "0", directoryURL: directoryURL)
        }
    }

    @Test func corruptedFileThrows() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        try Data("not json".utf8).write(to: SessionStore.fileURL(name: "0", directoryURL: directoryURL))
        #expect(throws: (any Error).self) {
            try SessionStore.load(name: "0", directoryURL: directoryURL)
        }
    }

    @Test func invalidNamesAreRejected() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        for name in ["", ".", "..", "../work", "a/b"] {
            #expect(!SessionStore.isValidName(name))
            #expect(throws: SessionStoreError.self) {
                try SessionStore.save(snapshot: makeSnapshot(name: name), directoryURL: directoryURL)
            }
        }
        #expect(SessionStore.isValidName("work-1"))
    }

    @Test func inconsistentSnapshotIsRejectedOnLoad() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(makeSnapshot(name: "0"))) as! [String: Any]
        var windows = json["windows"] as! [[String: Any]]
        var tree = windows[0]["paneTree"] as! [String: Any]
        tree["focusedPaneID"] = ["rawValue": UUID().uuidString]
        windows[0]["paneTree"] = tree
        json["windows"] = windows
        try JSONSerialization.data(withJSONObject: json).write(to: SessionStore.fileURL(name: "0", directoryURL: directoryURL))
        #expect(throws: SessionStoreError.self) {
            try SessionStore.load(name: "0", directoryURL: directoryURL)
        }
    }

    @Test func paneTreeConsistency() {
        var tree = PaneTree()
        tree.split(axis: .horizontal)
        tree.toggleZoom()
        #expect(tree.isConsistent)
    }

    @Test func invalidRatioIsRejectedOnLoad() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(makeSnapshot(name: "0"))) as! [String: Any]
        var windows = json["windows"] as! [[String: Any]]
        var tree = windows[0]["paneTree"] as! [String: Any]
        var root = tree["root"] as! [String: Any]
        var split = root["split"] as! [String: Any]
        split["ratio"] = 2
        root["split"] = split
        tree["root"] = root
        windows[0]["paneTree"] = tree
        json["windows"] = windows
        try JSONSerialization.data(withJSONObject: json).write(to: SessionStore.fileURL(name: "0", directoryURL: directoryURL))
        #expect(throws: SessionStoreError.self) {
            try SessionStore.load(name: "0", directoryURL: directoryURL)
        }
    }
}

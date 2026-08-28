/// tmux の status line 左側の表示 (`[session] 0:name 1:name*`) を組み立てる純粋ロジック
enum StatusLine {
    /// 現在のウィンドウには tmux と同じく `*` を付ける
    static func text(sessionName: String, windowNames: [String], currentWindowIndex: Int) -> String {
        let windows = windowNames.enumerated().map { index, name in
            "\(index):\(name)\(index == currentWindowIndex ? "*" : "")"
        }
        return (["[\(sessionName)]"] + windows).joined(separator: " ")
    }
}

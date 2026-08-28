import Testing
@testable import Tatami

/// status line の表示と、tmux コマンド名との相互変換を検証する
struct StatusLineTests {
    @Test func currentWindowIsMarkedWithAsterisk() {
        #expect(StatusLine.text(sessionName: "0", windowNames: ["blank", "example.com"], currentWindowIndex: 1) == "[0] 0:blank 1:example.com*")
        #expect(StatusLine.text(sessionName: "work", windowNames: ["a"], currentWindowIndex: 0) == "[work] 0:a*")
    }

    @Test func tmuxCommandNamesRoundTrip() {
        for command in [BrowserCommand.splitWindowHorizontal, .killPane, .selectPaneLeft, .newWindow, .selectWindow(3), .chooseWindow] {
            #expect(BrowserCommand(tmuxName: command.tmuxName) == command)
        }
        #expect(BrowserCommand(tmuxName: "select-window  -t 7") == .selectWindow(7))
        #expect(BrowserCommand(tmuxName: "omnibox") == .omnibox)
        #expect(BrowserCommand(tmuxName: "detach") == nil)
    }

    @Test func defaultTableBindsWindowKeys() {
        let table = KeyBindingTable.default
        #expect(table.bindings[KeyStroke(tmuxKeyName: "c")!] == .newWindow)
        #expect(table.bindings[KeyStroke(tmuxKeyName: "n")!] == .nextWindow)
        #expect(table.bindings[KeyStroke(tmuxKeyName: "p")!] == .previousWindow)
        #expect(table.bindings[KeyStroke(tmuxKeyName: "0")!] == .selectWindow(0))
        #expect(table.bindings[KeyStroke(tmuxKeyName: "9")!] == .selectWindow(9))
        #expect(table.bindings[KeyStroke(tmuxKeyName: ",")!] == .renameWindow)
        #expect(table.bindings[KeyStroke(tmuxKeyName: "&")!] == .killWindow)
        #expect(table.bindings[KeyStroke(tmuxKeyName: "w")!] == .chooseWindow)
        #expect(table.bindings[KeyStroke(tmuxKeyName: "/")!] == .omnibox)
        #expect(table.bindings[KeyStroke(tmuxKeyName: "d")!] == .detachClient)
        #expect(table.bindings[KeyStroke(tmuxKeyName: "s")!] == .chooseSession)
        #expect(table.bindings[KeyStroke(tmuxKeyName: "$")!] == .renameSession)
        #expect(table.bindings[KeyStroke(tmuxKeyName: ":")!] == .commandPrompt)
        #expect(BrowserCommand(tmuxName: "command-prompt") == .commandPrompt)
        #expect(BrowserCommand(tmuxName: "set-default-browser") == .setDefaultBrowser)
        #expect(table.bindings[KeyStroke(tmuxKeyName: "[")!] == .findPrompt)
        #expect(table.bindings[KeyStroke(tmuxKeyName: "b")!] == .chooseBookmark)
    }
}

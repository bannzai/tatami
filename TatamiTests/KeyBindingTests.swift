import AppKit
import Testing
@testable import Tatami

/// tmux 表記のキー名の解釈と、prefix キーの 2 ストローク検出を検証する
struct KeyBindingTests {
    @Test func tmuxKeyNamesAreParsed() {
        #expect(KeyStroke(tmuxKeyName: "C-b") == KeyStroke(key: "b", modifiers: [.control]))
        #expect(KeyStroke(tmuxKeyName: "M-x") == KeyStroke(key: "x", modifiers: [.option]))
        #expect(KeyStroke(tmuxKeyName: "C-M-Left") == KeyStroke(key: "Left", modifiers: [.control, .option]))
        #expect(KeyStroke(tmuxKeyName: "%") == KeyStroke(key: "%", modifiers: []))
        #expect(KeyStroke(tmuxKeyName: "\"") == KeyStroke(key: "\"", modifiers: []))
        #expect(KeyStroke(tmuxKeyName: "Space") == KeyStroke(key: "Space", modifiers: []))
        #expect(KeyStroke(tmuxKeyName: "-") == KeyStroke(key: "-", modifiers: []))
        #expect(KeyStroke(tmuxKeyName: "S-x") == KeyStroke(key: "X", modifiers: []))
        #expect(KeyStroke(tmuxKeyName: "C-S-x") == KeyStroke(key: "X", modifiers: [.control]))
        #expect(KeyStroke(tmuxKeyName: "S-Left") == KeyStroke(key: "Left", modifiers: [.shift]))
        #expect(KeyStroke(tmuxKeyName: "Foo") == nil)
        #expect(KeyStroke(tmuxKeyName: "X-b") == nil)
        #expect(KeyStroke(tmuxKeyName: "") == nil)
    }

    @Test func tmuxKeyNameRoundTrips() {
        for name in ["C-b", "M-Space", "C-M-Left", "%", "z", "S-Left"] {
            #expect(KeyStroke(tmuxKeyName: name)?.tmuxKeyName == name)
        }
    }

    @Test func defaultTableMatchesProjectKeybindings() {
        let table = KeyBindingTable.default
        #expect(table.prefix == KeyStroke(tmuxKeyName: "C-b"))
        #expect(table.bindings[KeyStroke(tmuxKeyName: "%")!] == .splitWindowHorizontal)
        #expect(table.bindings[KeyStroke(tmuxKeyName: "\"")!] == .splitWindowVertical)
        #expect(table.bindings[KeyStroke(tmuxKeyName: "Space")!] == .nextLayout)
        #expect(table.bindings[KeyStroke(tmuxKeyName: "Left")!] == .selectPaneLeft)
    }

    @Test func prefixThenBoundKeyPerformsCommand() {
        let table = KeyBindingTable.default
        let afterPrefix = PrefixKeyState.idle.handling(keyStroke: KeyStroke(tmuxKeyName: "C-b")!, table: table)
        #expect(afterPrefix.state == .awaitingCommand)
        #expect(afterPrefix.outcome == .consume)
        let afterCommand = afterPrefix.state.handling(keyStroke: KeyStroke(tmuxKeyName: "%")!, table: table)
        #expect(afterCommand.state == .idle)
        #expect(afterCommand.outcome == .perform(.splitWindowHorizontal))
    }

    @Test func keysWithoutPrefixPassThrough() {
        let result = PrefixKeyState.idle.handling(keyStroke: KeyStroke(tmuxKeyName: "%")!, table: .default)
        #expect(result.state == .idle)
        #expect(result.outcome == .passThrough)
    }

    @Test func unboundKeyAfterPrefixIsConsumed() {
        let result = PrefixKeyState.awaitingCommand.handling(keyStroke: KeyStroke(tmuxKeyName: "q")!, table: .default)
        #expect(result.state == .idle)
        #expect(result.outcome == .consume)
    }

    @Test func escapeCancelsPrefix() {
        let result = PrefixKeyState.awaitingCommand.handling(keyStroke: KeyStroke(tmuxKeyName: "Escape")!, table: .default)
        #expect(result.state == .idle)
        #expect(result.outcome == .consume)
    }

    @Test func customPrefixFromTableIsUsed() {
        var table = KeyBindingTable.default
        table.prefix = KeyStroke(tmuxKeyName: "C-a")!
        #expect(PrefixKeyState.idle.handling(keyStroke: KeyStroke(tmuxKeyName: "C-b")!, table: table).outcome == .passThrough)
        #expect(PrefixKeyState.idle.handling(keyStroke: KeyStroke(tmuxKeyName: "C-a")!, table: table).outcome == .consume)
    }

    @Test func boundEscapeRunsCommandInsteadOfCancel() {
        var table = KeyBindingTable.default
        table.bindings[KeyStroke(tmuxKeyName: "Escape")!] = .resizePaneZoom
        let result = PrefixKeyState.awaitingCommand.handling(keyStroke: KeyStroke(tmuxKeyName: "Escape")!, table: table)
        #expect(result.state == .idle)
        #expect(result.outcome == .perform(.resizePaneZoom))
    }

    @Test func optionProducedSymbolFallsBackToCharacterBinding() {
        let table = KeyBindingTable.default
        // ドイツ語配列の Option+8 は主な解釈が M-8、Option の変換で生成される文字が {
        let candidates = [KeyStroke(key: "8", modifiers: [.option]), KeyStroke(key: "{", modifiers: [])]
        let result = PrefixKeyState.awaitingCommand.handling(keyStrokes: candidates, table: table)
        #expect(result.outcome == .perform(.swapPaneUp))
        var custom = table
        custom.bindings[KeyStroke(tmuxKeyName: "M-8")!] = .nextLayout
        #expect(PrefixKeyState.awaitingCommand.handling(keyStrokes: candidates, table: custom).outcome == .perform(.nextLayout))
    }

    @Test func cancelledStateIsIdle() {
        #expect(PrefixKeyState.awaitingCommand.cancelled == .idle)
    }

    @Test @MainActor func capsLockUppercasesLetterKeys() throws {
        func stroke(flags: NSEvent.ModifierFlags, characters: String) throws -> KeyStroke {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
            return try #require(KeyStroke.candidates(event: event).first)
        }
        #expect(try stroke(flags: [], characters: "x").key == "x")
        #expect(try stroke(flags: [.shift], characters: "X").key == "X")
        #expect(try stroke(flags: [.capsLock], characters: "X").key == "X")
        #expect(try stroke(flags: [.capsLock, .shift], characters: "x").key == "x")
    }
}

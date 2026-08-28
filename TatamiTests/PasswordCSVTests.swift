import Foundation
import Testing
@testable import Tatami

/// Chrome 互換 CSV の解釈・書き出しと、既存の資格情報への取り込みを検証する。
/// フィクスチャは予約ドメイン (example.com / example.org) とダミー値だけを使う (.claude/rules/no-secrets-in-repository.md)
struct PasswordCSVTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let past = Date(timeIntervalSince1970: 1_600_000_000)

    private func makeCredential(id: UUID = UUID(), url: String, username: String, password: String, note: String = "", date: Date) -> Credential {
        Credential(id: id, url: URL(string: url)!, username: username, password: password, note: note, updatedAt: date)
    }

    // MARK: - parse

    @Test func parseReadsChromeExport() throws {
        let text = """
            name,url,username,password,note
            example.com,https://example.com/,alice,dummy-alice,
            example.org,https://example.org/login,bob,dummy-bob,個人用
            mail.example.com,https://mail.example.com/,carol,dummy-carol,

            """
        let rows = try PasswordCSV.parse(text: text)
        #expect(rows.count == 3)
        #expect(rows[0] == PasswordCSV.Row(name: "example.com", url: "https://example.com/", username: "alice", password: "dummy-alice", note: ""))
        #expect(rows[1] == PasswordCSV.Row(name: "example.org", url: "https://example.org/login", username: "bob", password: "dummy-bob", note: "個人用"))
        #expect(rows[2].username == "carol")
    }

    @Test func parseHandlesQuotedCommaNewlineAndEscapedQuote() throws {
        let text = """
            name,url,username,password,note
            "Example, Inc.",https://example.com/,alice,"dummy""quote","1 行目
            2 行目"
            plain,https://example.org/,bob,dummy-bob,

            """
        let rows = try PasswordCSV.parse(text: text)
        #expect(rows.count == 2)
        #expect(rows[0].name == "Example, Inc.")
        #expect(rows[0].password == "dummy\"quote")
        #expect(rows[0].note == "1 行目\n2 行目")
        #expect(rows[1].name == "plain")
    }

    @Test func parseAcceptsCRLF() throws {
        let rows = try PasswordCSV.parse(
            text: "name,url,username,password,note\r\nexample.com,https://example.com/,alice,dummy-alice,memo\r\n"
        )
        #expect(rows == [PasswordCSV.Row(name: "example.com", url: "https://example.com/", username: "alice", password: "dummy-alice", note: "memo")])
    }

    @Test func parseUsesColumnNamesRegardlessOfOrderAndExtraColumns() throws {
        let text = """
            username,extra,password,url,note,name
            alice,無視される値,dummy-alice,https://example.com/,memo,example.com

            """
        let rows = try PasswordCSV.parse(text: text)
        #expect(rows == [PasswordCSV.Row(name: "example.com", url: "https://example.com/", username: "alice", password: "dummy-alice", note: "memo")])
    }

    @Test func parseAcceptsLegacyFormatWithoutNoteColumn() throws {
        let text = """
            name,url,username,password
            example.com,https://example.com/,alice,dummy-alice

            """
        let rows = try PasswordCSV.parse(text: text)
        #expect(rows == [PasswordCSV.Row(name: "example.com", url: "https://example.com/", username: "alice", password: "dummy-alice", note: nil)])
    }

    @Test func mergeKeepsExistingNoteWhenNoteColumnIsMissing() {
        let existing = [makeCredential(url: "https://example.com/", username: "alice", password: "dummy-alice", note: "keep me", date: past)]
        let result = PasswordImporter.merge(
            rows: [PasswordCSV.Row(name: "example.com", url: "https://example.com/", username: "alice", password: "dummy-alice", note: nil)],
            existing: existing,
            now: now
        )
        #expect(result.unchanged == 1)
        #expect(result.credentials[0].note == "keep me")
        let cleared = PasswordImporter.merge(
            rows: [PasswordCSV.Row(name: "example.com", url: "https://example.com/", username: "alice", password: "dummy-alice", note: "")],
            existing: existing,
            now: now
        )
        #expect(cleared.updated == 1)
        #expect(cleared.credentials[0].note == "")
    }

    @Test func mergeDistinguishesOrigins() {
        let existing = [makeCredential(url: "https://example.com/", username: "alice", password: "dummy-alice", date: past)]
        let result = PasswordImporter.merge(
            rows: [
                PasswordCSV.Row(name: "", url: "https://example.com:8443/", username: "alice", password: "dummy-8443", note: ""),
                PasswordCSV.Row(name: "", url: "http://example.com/", username: "alice", password: "dummy-http", note: ""),
                PasswordCSV.Row(name: "", url: "https://example.com:443/login", username: "alice", password: "dummy-alice", note: ""),
            ],
            existing: existing,
            now: now
        )
        #expect(result.added == 2)
        #expect(result.unchanged == 1)
        #expect(result.credentials.map(\.url.absoluteString) == ["https://example.com/", "https://example.com:8443/", "http://example.com/"])
    }

    @Test func parseIgnoresBlankLines() throws {
        let text = "name,url,username,password,note\n\nexample.com,https://example.com/,alice,dummy-alice,\n\n\n"
        let rows = try PasswordCSV.parse(text: text)
        #expect(rows.map(\.username) == ["alice"])
    }

    @Test func parseThrowsWhenRequiredColumnIsMissing() {
        let text = """
            name,url,password,note
            example.com,https://example.com/,dummy-alice,

            """
        #expect(throws: PasswordCSVError(line: 1, message: "必須の列がない: username")) {
            try PasswordCSV.parse(text: text)
        }
    }

    @Test func parseThrowsWithLineNumberWhenQuoteIsNotClosed() {
        let text = """
            name,url,username,password,note
            example.com,https://example.com/,alice,dummy-alice,memo
            example.org,https://example.org/,bob,"閉じていない,memo
            """
        #expect(throws: PasswordCSVError(line: 3, message: "クオートが閉じていない")) {
            try PasswordCSV.parse(text: text)
        }
    }

    @Test func parseThrowsWhenColumnCountDiffersFromHeader() {
        let text = """
            name,url,username,password,note
            example.com,https://example.com/,alice

            """
        #expect(throws: PasswordCSVError(line: 2, message: "列の数がヘッダと合わない (ヘッダ 5 列・この行 3 列)")) {
            try PasswordCSV.parse(text: text)
        }
    }

    @Test func errorDescriptionShowsLineAndMessage() {
        #expect(PasswordCSVError(line: 3, message: "クオートが閉じていない").description == "行 3: クオートが閉じていない")
    }

    // MARK: - serialize

    @Test func serializeQuotesOnlyValuesThatNeedIt() {
        let text = PasswordCSV.serialize(rows: [
            PasswordCSV.Row(name: "example.com", url: "https://example.com/", username: "alice", password: "dummy-alice", note: ""),
            PasswordCSV.Row(name: "Example, Inc.", url: "https://example.org/", username: "bob", password: "dummy\"quote", note: "1 行目\n2 行目"),
        ])
        #expect(
            text == """
                name,url,username,password,note
                example.com,https://example.com/,alice,dummy-alice,
                "Example, Inc.",https://example.org/,bob,"dummy""quote","1 行目
                2 行目"

                """
        )
    }

    @Test func serializeAndParseRoundTrip() throws {
        let rows = [
            PasswordCSV.Row(name: "example.com", url: "https://example.com/", username: "alice", password: "dummy-alice", note: ""),
            PasswordCSV.Row(name: "Example, Inc.", url: "https://example.org/login", username: "bob", password: "dummy\"quote,\n", note: "改行\nを含むメモ"),
        ]
        #expect(try PasswordCSV.parse(text: PasswordCSV.serialize(rows: rows)) == rows)
    }

    // MARK: - merge

    /// パスが違う URL・大文字のホスト・スキームの無い行・空の URL を 1 つの CSV に混ぜ、ホスト名 + ユーザー名での照合と読み飛ばしをまとめて確認する
    private var mergeFixtureRows: [PasswordCSV.Row] {
        [
            PasswordCSV.Row(name: "example.com", url: "https://example.com/login", username: "alice", password: "dummy-alice-new", note: "memo"),
            PasswordCSV.Row(name: "example.org", url: "https://example.org/", username: "bob", password: "dummy-bob", note: ""),
            PasswordCSV.Row(name: "no scheme", url: "example.net", username: "dave", password: "dummy-dave", note: ""),
            PasswordCSV.Row(name: "empty", url: "", username: "eve", password: "dummy-eve", note: ""),
        ]
    }

    @Test func mergeAddsUpdatesAndSkips() {
        let existing = [makeCredential(url: "https://EXAMPLE.com/", username: "alice", password: "dummy-alice-old", date: past)]
        let result = PasswordImporter.merge(rows: mergeFixtureRows, existing: existing, now: now)
        #expect(result.added == 1)
        #expect(result.updated == 1)
        #expect(result.unchanged == 0)
        #expect(result.skipped == 2)
        #expect(result.credentials.count == 2)
        // 更新では id と URL を保ち、パスワード・メモ・更新日時だけを入れ替える
        #expect(result.credentials[0].id == existing[0].id)
        #expect(result.credentials[0].url == existing[0].url)
        #expect(result.credentials[0].password == "dummy-alice-new")
        #expect(result.credentials[0].note == "memo")
        #expect(result.credentials[0].updatedAt == now)
        #expect(result.credentials[1].url.absoluteString == "https://example.org/")
        #expect(result.credentials[1].username == "bob")
    }

    @Test func mergeIsIdempotent() {
        let existing = [makeCredential(url: "https://example.com/", username: "alice", password: "dummy-alice-old", date: past)]
        let first = PasswordImporter.merge(rows: mergeFixtureRows, existing: existing, now: now)
        let second = PasswordImporter.merge(rows: mergeFixtureRows, existing: first.credentials, now: now.addingTimeInterval(60))
        #expect(second.added == 0)
        #expect(second.updated == 0)
        #expect(second.unchanged == 2)
        #expect(second.skipped == 2)
        // 内容が同じ行では更新日時も変わらない
        #expect(second.credentials == first.credentials)
    }

    @Test func mergeTreatsDuplicatedRowsAsOneCredential() {
        let row = PasswordCSV.Row(name: "example.com", url: "https://example.com/", username: "alice", password: "dummy-alice", note: "")
        let result = PasswordImporter.merge(
            rows: [row, PasswordCSV.Row(name: "example.com", url: "https://example.com/signin", username: "alice", password: "dummy-alice", note: "")],
            existing: [],
            now: now
        )
        #expect(result.added == 1)
        #expect(result.unchanged == 1)
        #expect(result.credentials.count == 1)
    }

    @Test func mergeKeepsDifferentUsernamesOnSameHost() {
        let existing = [makeCredential(url: "https://example.com/", username: "alice", password: "dummy-alice", date: past)]
        let result = PasswordImporter.merge(
            rows: [PasswordCSV.Row(name: "example.com", url: "https://example.com/", username: "bob", password: "dummy-bob", note: "")],
            existing: existing,
            now: now
        )
        #expect(result.added == 1)
        #expect(result.credentials.map(\.username) == ["alice", "bob"])
    }

    @Test func rowsFromCredentialsUseHostAsName() {
        let credentials = [
            makeCredential(url: "https://example.com/login", username: "alice", password: "dummy-alice", note: "memo", date: past),
            makeCredential(url: "https://example.org/", username: "bob", password: "dummy-bob", date: past),
        ]
        #expect(
            PasswordImporter.rows(credentials: credentials) == [
                PasswordCSV.Row(name: "example.com", url: "https://example.com/login", username: "alice", password: "dummy-alice", note: "memo"),
                PasswordCSV.Row(name: "example.org", url: "https://example.org/", username: "bob", password: "dummy-bob", note: ""),
            ]
        )
    }
}

import Foundation

/// CSV の解釈に失敗した位置と理由。行番号は 1 始まりで、値の中の改行も 1 行と数える
struct PasswordCSVError: Error, CustomStringConvertible, Equatable {
    let line: Int
    let message: String

    var description: String {
        "行 \(line): \(message)"
    }
}

/// Chrome の password manager (chrome://password-manager/settings) が読み書きする CSV との相互変換。
/// 「いつでも Chrome / Safari / Bitwarden / 1Password に戻れる」ことを担保するため、Chrome の列構成をそのまま入出力の形式にする
/// (要件の SSOT: https://github.com/bannzai/IdeaMemo/issues/191#issuecomment-5449063461 )
enum PasswordCSV {
    /// CSV の 1 行分。Chrome の列名と 1 対 1 に対応する
    struct Row: Equatable {
        /// Chrome が一覧の表示名に使う列。取り込みでは資格情報に持たず、書き出しではホスト名を入れる
        var name: String
        var url: String
        var username: String
        var password: String
        /// Chrome の note 列。この列を持たない古い形式では空文字になる
        var note: String
    }

    /// 書き出す列とその順序。Chrome が出力するヘッダと同じにして、Chrome にそのまま読み戻せるようにする。
    /// 取り込みは列名で位置を決めるため、この順序に依存しない
    static let headerColumns = ["name", "url", "username", "password", "note"]

    /// 取り込みに最低限必要な列。name は表示名、note は補足であり、無くても資格情報を作れる
    private static let requiredColumns = ["url", "username", "password"]

    /// CSV のテキストを行に分解する。1 行目をヘッダとして列名で位置を決めるため、列の順序が違っても余分な列があってもよい
    static func parse(text: String) throws(PasswordCSVError) -> [Row] {
        let csvRecords = try records(text: text)
        guard let header = csvRecords.first else {
            throw PasswordCSVError(line: 1, message: "ヘッダ行がない")
        }
        var columnIndexes: [String: Int] = [:]
        for (index, columnName) in header.fields.enumerated() {
            let key = columnName.trimmingCharacters(in: .whitespaces).lowercased()
            // 同じ列名が並ぶ CSV では先に現れた列を採用する
            if columnIndexes[key] == nil {
                columnIndexes[key] = index
            }
        }
        for column in requiredColumns where columnIndexes[column] == nil {
            throw PasswordCSVError(line: header.line, message: "必須の列がない: \(column)")
        }
        var rows: [Row] = []
        for record in csvRecords.dropFirst() {
            guard record.fields.count == header.fields.count else {
                throw PasswordCSVError(
                    line: record.line,
                    message: "列の数がヘッダと合わない (ヘッダ \(header.fields.count) 列・この行 \(record.fields.count) 列)"
                )
            }
            rows.append(
                Row(
                    name: value(fields: record.fields, columnIndexes: columnIndexes, column: "name"),
                    url: value(fields: record.fields, columnIndexes: columnIndexes, column: "url"),
                    username: value(fields: record.fields, columnIndexes: columnIndexes, column: "username"),
                    password: value(fields: record.fields, columnIndexes: columnIndexes, column: "password"),
                    note: value(fields: record.fields, columnIndexes: columnIndexes, column: "note")
                )
            )
        }
        return rows
    }

    /// 行を Chrome と同じヘッダ付きの CSV にする。改行は LF で、末尾にも改行を置く (Chrome の出力と同じ)
    static func serialize(rows: [Row]) -> String {
        var text = headerColumns.joined(separator: ",") + "\n"
        for row in rows {
            text += [row.name, row.url, row.username, row.password, row.note]
                .map { escaped(value: $0) }
                .joined(separator: ",")
            text += "\n"
        }
        return text
    }

    /// ヘッダに無い列は空文字。必須列は parse で存在を確認済みのため、ここに来るのは name / note だけ
    private static func value(fields: [String], columnIndexes: [String: Int], column: String) -> String {
        guard let index = columnIndexes[column], fields.indices.contains(index) else {
            return ""
        }
        return fields[index]
    }

    /// RFC 4180 に従い、区切りと解釈されうる文字を含む値だけをクオートする。ダブルクオートは 2 つ重ねてエスケープする
    private static func escaped(value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// CSV を「レコードの開始行番号と値の並び」にする。クオートで囲んだ値の中の改行・カンマは区切りとして扱わず、
    /// 行番号だけを進めることでエラーの位置をファイル上の行と一致させる
    private static func records(text: String) throws(PasswordCSVError) -> [(line: Int, fields: [String])] {
        // 表計算ソフトが付ける BOM を最初の列名の一部にしないため取り除き、改行を LF に揃える。
        // Swift の Character は CRLF を 1 文字として扱うため、揃えずに走査すると CRLF のファイルで改行を見落とす
        let characters = Array(
            (text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
        )
        var parsedRecords: [(line: Int, fields: [String])] = []
        var index = 0
        var lineNumber = 1
        while index < characters.count {
            let recordLine = lineNumber
            var fields: [String] = []
            while true {
                var field = ""
                var isQuoted = false
                if characters[safe: index] == "\"" {
                    isQuoted = true
                    index += 1
                    var isClosed = false
                    while index < characters.count {
                        let character = characters[index]
                        if character == "\"" {
                            if characters[safe: index + 1] == "\"" {
                                field.append("\"")
                                index += 2
                                continue
                            }
                            index += 1
                            isClosed = true
                            break
                        }
                        if character == "\n" {
                            lineNumber += 1
                        }
                        field.append(character)
                        index += 1
                    }
                    guard isClosed else {
                        throw PasswordCSVError(line: recordLine, message: "クオートが閉じていない")
                    }
                }
                while index < characters.count, characters[index] != ",", characters[index] != "\n" {
                    guard !isQuoted else {
                        throw PasswordCSVError(line: recordLine, message: "閉じクオートの後に値が続いている")
                    }
                    field.append(characters[index])
                    index += 1
                }
                fields.append(field)
                guard index < characters.count else {
                    break
                }
                if characters[index] == "," {
                    index += 1
                    continue
                }
                index += 1
                lineNumber += 1
                break
            }
            // 空行は Chrome の出力の末尾にも現れるため、レコードとして数えない
            if fields == [""] {
                continue
            }
            parsedRecords.append((line: recordLine, fields: fields))
        }
        return parsedRecords
    }
}

/// CSV の行と資格情報の相互変換。ファイル I/O とストアへの保存は呼び出し側が行い、ここは純粋ロジックにしてユニットテストの対象にする
enum PasswordImporter {
    /// CSV の行を既存の資格情報に取り込む。同じ CSV を何度取り込んでも重複せず、内容が同じ行は更新日時も変えない (冪等)
    static func merge(
        rows: [PasswordCSV.Row],
        existing: [Credential],
        now: Date
    ) -> (credentials: [Credential], added: Int, updated: Int, unchanged: Int, skipped: Int) {
        var credentials = existing
        var indexesByKey: [String: Int] = [:]
        for (index, credential) in credentials.enumerated() {
            let key = matchKey(host: credential.host, username: credential.username)
            // 同じホスト・同じユーザー名が複数ある場合は先頭の 1 件だけを更新の対象にし、残りは触らない
            if indexesByKey[key] == nil {
                indexesByKey[key] = index
            }
        }
        var added = 0
        var updated = 0
        var unchanged = 0
        var skipped = 0
        for row in rows {
            guard
                let url = URL(string: row.url.trimmingCharacters(in: .whitespaces)),
                url.scheme != nil,
                let host = url.host()?.lowercased(),
                !host.isEmpty
            else {
                skipped += 1
                continue
            }
            let key = matchKey(host: host, username: row.username)
            guard let index = indexesByKey[key] else {
                credentials.append(
                    Credential(id: UUID(), url: url, username: row.username, password: row.password, note: row.note, updatedAt: now)
                )
                indexesByKey[key] = credentials.count - 1
                added += 1
                continue
            }
            guard credentials[index].password != row.password || credentials[index].note != row.note else {
                unchanged += 1
                continue
            }
            // URL は既存の値を残す。Chrome の URL はログインページとサイトのトップが混在し、どちらが正しいか決められないため
            credentials[index].password = row.password
            credentials[index].note = row.note
            credentials[index].updatedAt = now
            updated += 1
        }
        return (credentials, added, updated, unchanged, skipped)
    }

    /// 書き出し用の行。Chrome の name 列は一覧の表示名のため、ホスト名を入れる
    static func rows(credentials: [Credential]) -> [PasswordCSV.Row] {
        credentials.map { credential in
            PasswordCSV.Row(
                name: credential.host,
                url: credential.url.absoluteString,
                username: credential.username,
                password: credential.password,
                note: credential.note
            )
        }
    }

    /// CSV の行と既存の資格情報を同じものとみなす鍵。Chrome は同じサイトを `https://example.com/` と `https://example.com/login` の
    /// 両方で持つことがあるため、URL 全体ではなくホスト名 (小文字) とユーザー名で照合する
    private static func matchKey(host: String, username: String) -> String {
        // ホスト名に改行は現れないため、区切りに使ってもユーザー名との境界が曖昧にならない
        "\(host)\n\(username)"
    }
}

extension Array {
    /// 範囲外を nil で返す添字。CSV の走査で「次の文字」を毎回境界チェックせずに見るために使う
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

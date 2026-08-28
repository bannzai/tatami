---
paths:
  - "**/*.swift"
---

# Swift コーディング規約

- `///` doc comment で設計意図（なぜ・制約）を日本語で書く。処理内容の説明（何をしているか）は書かない
- 副作用のあるコンポーネント（ネットワーク、Keychain、SwiftData、状態管理）と純粋ロジック
  （enum + static func または値型）を分離し、純粋ロジックをユニットテストの対象にする
- 1 ファイル 1 責務。テストファイルは機能単位で対応命名する（`Xxx.swift` ⇔ `XxxTests.swift`）
- カスタム `Error` は `CustomStringConvertible` を実装し、エラーメッセージは加工せずそのまま表示する
- 関数は冪等にする。冪等にできない場合は理由をコメントで明記する
- `@MainActor` の付与方針は `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` を前提とする
- ユニットテストは Swift Testing を使う
- `if` / `guard` / `for` / `while` / `defer` / `Task` など文としての `{ }` ブロックを 1 行で書かない
  （複数行に展開する）。単一式の computed property や `items.map { $0.name }` のような式クロージャは対象外

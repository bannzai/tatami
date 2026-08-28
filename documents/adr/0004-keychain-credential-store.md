# 0004. Password Manager の資格情報は Keychain の generic password アイテムに JSON で保存する

## Status
Accepted (2026-08-29)

## Context
Password Manager (documents/PROJECT.md 機能要件 3) の資格情報を端末内の Keychain に置くことは ADR 0002 で決めている。決めるべきは Keychain アイテムの属性の設計で、次の要件を満たす必要がある:

- 1 ドメインに複数の資格情報 (ユーザー名違い) を持てる
- iCloud Keychain で同期し、将来の iOS 版と同じストアを共有する
- 将来の Credential Provider Extension (#17) がアプリと同じアイテムを読める
- 追加・更新・削除・ドメイン検索が冪等で、ユニットテストは Keychain に触れずに行える (CI の runner にはユーザーの Keychain が無い)

## Decision
- **クラス**: `kSecClassGenericPassword`。Internet password (`kSecClassInternetPassword`) はサーバー・プロトコル・パスの属性を持つが、Safari など他のクライアントと共有する意図が無く、属性の組み合わせで一意性が決まる (同一サーバー・同一アカウントは 1 件) 制約が「1 ドメインに複数資格情報」と相性が悪いため使わない
- **service**: 固定値 `com.bannzai.Tatami.credentials`。Tatami の資格情報だけを列挙するための識別子で、他のアイテム (OS や他アプリ) と混ざらない
- **account**: 資格情報の `id` (UUID)。generic password の一意性は service + account で決まるため、UUID にすることで同じサイト・同じユーザー名でも別アイテムとして持てる (ユーザー名を account にすると同一サイトの重複を表現できない)
- **value (kSecValueData)**: `Credential` を JSON にしたもの (URL・ユーザー名・パスワード・メモ・更新日時)。属性を個別に持たず 1 つの JSON にするのは、モデルの変更が Codable の変更だけで済み、検索は全件を復号してメモリ上で行えば個人用途の件数 (数百〜数千) で十分速いため
- **label**: ホスト名。Keychain Access.app で見た時に何のアイテムか分かるようにする (検索には使わない)
- **synchronizable**: `kSecAttrSynchronizable = true`。iCloud Keychain で同期する。検索・更新・削除のクエリにも同じ値を付けないと同期アイテムが対象から漏れる
- **accessible**: `kSecAttrAccessibleAfterFirstUnlock`。充填はアンロック中にしか行わないが、初回アンロック後は常に読める必要がある。`WhenUnlocked` は Mac がスリープ中のバックグラウンド動作 (将来の同期処理等) で読めなくなるため採らない
- **access group**: `TQPN82UBBY.com.bannzai.Tatami.shared` (Team ID + 任意の識別子) を entitlements の `keychain-access-groups` に置き、アプリと拡張 (#17) が同じグループを指定する。Debug 構成は ad-hoc 署名 (provisioning profile なし) で、`keychain-access-groups` を含めると Xcode が profile を要求してビルドできないため、Debug 用の `Tatami.Debug.entitlements` にはこのキーを置かず、`#if DEBUG` では access group を付けない (Debug と Release で別の Keychain 領域になるが、開発中の資格情報は捨ててよい)。Release (`make macos`) は Team での自動署名で profile が自動生成される。`make macos SIGNING=adhoc` は Makefile が Debug 用の entitlements を使うためビルドでき、その場合 access group は nil になる。access group の値は固定値ではなく、署名に含まれた `keychain-access-groups` を `SecTaskCopyValueForEntitlement` で実行時に読む (別の Team で署名した時に prefix が変わるため)
- **抽象化**: `CredentialStore` プロトコルを `KeychainCredentialStore` と `InMemoryCredentialStore` が実装し、ユニットテストはメモリ実装で契約 (冪等性・検索) を検証する

## Consequences

**良い点:**
- 同一サイトの複数アカウントを自然に表現でき、追加・更新は `SecItemUpdate` → 無ければ `SecItemAdd` で冪等になる
- iCloud 同期と拡張との共有が属性の設定だけで済む
- モデルの拡張 (TOTP 等) が JSON の項目追加で済む

**悪い点 / 引き受けるリスク:**
- ホスト検索が全件復号のため、件数が数万になると遅くなる。個人用途では到達しない前提で、必要になれば label をホスト名で検索する形に変える
- Debug と Release で Keychain の領域が分かれるため、Release で保存した資格情報は Debug ビルドから見えない

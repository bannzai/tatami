# Tatami

tmux の操作体系で画面分割を扱う、macOS ネイティブの個人用ブラウザ。

## 概要
@documents/PROJECT.md

## Xcode プロジェクト構成の変更

- `Tatami.xcodeproj` をプロジェクト構成の唯一の正とする。XcodeGen と `project.yml` は使わず、`xcodegen generate` を実行しない (理由: [ADR 0003](documents/adr/0003-manage-xcode-project-directly.md)。機械検査: `~/.agents/skills/create-new-app/scripts/check-setup.sh` の `xcode-project-source` 項目)
- ターゲット、ファイル、Build Settings、Build Phases、Scheme、Swift Package の変更は Xcode の GUI で行う。自動化が必要な場合は、プロジェクト構成を `Tatami.xcodeproj/project.pbxproj`、Scheme を `Tatami.xcodeproj/xcshareddata/xcschemes/*.xcscheme` で直接編集する
- 変更後は `git diff -- Tatami.xcodeproj` で意図した差分だけであることを確認し、下記のビルドとテストを実行する

## 検証方法

- ビルド: `make build-macos`、ユニットテスト: `make test` (Swift Testing)。ログは `./tmp/build.log` / `./tmp/test.log` に保存し、`grep -i -e warning -e error` で全文を検査する (`tail` 等での切り詰め判定は禁止)。CI (`.github/workflows/ci.yml`) も同じ make target を `CODE_SIGNING_ALLOWED=NO` で実行する
- 普段使い: `make macos` で Release ビルドを `/Applications/Tatami.app` に配置する
- 動作確認 (UI・挙動): 本リポジトリは public のため、GitHub Actions の macOS runner 上で simtunnel を通じて行える (`/macos-simtunnel` skill。caller workflow は `.github/workflows/macos-app-session.yml`、既定 runner は `macos-26`)。ローカルの GUI セッションを使える場合は `make build-macos` の成果物 `tmp/DerivedData/Build/Products/Debug/Tatami.app` を `open` で起動してもよい
- UI 要素には `accessibilityIdentifier` を付ける (WebDriverAgentMac から要素を特定するため)

## タスクの進め方

- ユーザーの手作業 (GUI 操作・実機での実測・アカウントを要する検証など、agent が代行できない操作) が必要なタスクは総じて後回しにする。agent だけで完遂できるタスクを優先して進め、後回しにした分は issue に残して完了報告で伝える

## 秘匿情報

public リポジトリのため、秘匿情報を一切コミットしない。詳細は `.claude/rules/no-secrets-in-repository.md`

<!-- ai-review-config begin -->
<!--
このブロックは自動生成です。直接編集せず、テンプレートを更新してから再生成してください。
内容は AI コードレビュー時の挙動指示であり、コードベース自体への規約ではありません。
-->

## レビュー時の応答スタイル

- 応答は日本語で行う

## レビュー範囲外

以下は自動レビューで指摘しない (別の検出経路があるため):

- コンパイルエラー・型エラー (ローカル/CI のビルドで検出される)
- Lint/フォーマット違反 (リンター・フォーマッターで検出される)
<!-- ai-review-config end -->

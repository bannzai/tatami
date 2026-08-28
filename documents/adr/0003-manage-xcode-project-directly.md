# 0003. Xcode プロジェクトを直接管理し、XcodeGen は初期作成にだけ使う

## Status
Accepted (2026-08-28)

## Context
XcodeGen の `project.yml` と生成物の `project.pbxproj` を両方 Git で管理すると、片方だけが更新されても差異を検出する仕組みがなく、後から `xcodegen generate` を実行した時に初めて設定の不一致やビルドエラーが表面化する。Xcode の GUI で加えた変更は `project.yml` に反映されず、次の生成で失われる。複数ブランチが同じターゲットを変更すると、生成のたびに `project.pbxproj` が広範囲に書き換わって競合しやすい (実例: https://github.com/bannzai/mementomorning/blob/main/documents/adr/0002-manage-xcode-project-directly.md )。

## Decision
`Tatami.xcodeproj` をプロジェクト構成の唯一の正として直接管理する。XcodeGen は最初の `.xcodeproj` を組み立てるためにだけ使い、初期作成が終わった時点で `project.yml` を削除してリポジトリに残さない。以後、ターゲット・ファイル・Build Settings・Scheme・Swift Package の変更は Xcode の GUI か、`Tatami.xcodeproj/project.pbxproj` と `Tatami.xcodeproj/xcshareddata/xcschemes/*.xcscheme` の直接編集で行う。`xcodegen generate` は実行しない。

`project.yml` が残っていないことは `~/.agents/skills/create-new-app/scripts/check-setup.sh` の `xcode-project-source` 項目で機械的に検査できる。

## Consequences

**良い点:**
- 二重管理による遅延したビルド失敗と、生成物全体の書き換えによる不要な競合を避けられる
- Xcode の GUI で行った変更が失われない

**悪い点 / 引き受けるリスク:**
- `project.pbxproj` の差分は読みづらい。変更時は `git diff -- Tatami.xcodeproj` で意図した差分だけであることを確認し、ビルドとテストで検証する

---
name: quality-check
description: "auto-fix→lint→型チェック→テストを順に実行し、必須ゲート通過を機械可読な結果で返す品質ゲートチェック。Triggers on: '/quality-check', '品質チェック', 'QCして', 'quality gate'"
model: sonnet
# effort: auto-fix は機械的範囲のみ（型/テスト失敗の修正は呼び出し元が担う）ため low。
effort: low
---

# 品質ゲートチェック

`../../../../methodology/skills/quality-check.md` を読み、その手順に従って実行すること。

手順・判定基準・出力フォーマット（人間向けサマリー / 機械可読JSON）の実体はすべて参照先ドキュメントに定義されている。ここでの重複記述は行わない。

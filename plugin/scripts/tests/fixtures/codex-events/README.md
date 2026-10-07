# codex-events

`codex exec --json` の stdout（JSONL イベント列）の代わりに、テスト用の偽 codex が出力するフィクスチャ。
`codex-review-runner.sh`・`codex-task-runner.sh` が、stderr が空のまま非0で終わった codex exec の診断をイベント列から採る分岐（Issue #294）を検証する。

- `usage-limit.jsonl`: 利用上限で止まった例。文面は codex-cli 0.145.0 のバイナリにある文字列 "You've hit your usage limit." に合わせた。**実際の利用上限で採取したイベント列ではない**（イベントの並びと `try again at` 以降は推定）。
- `turn-failed.jsonl`: 利用上限以外のエラーで止まった例。JSON でない行を含む。
- `no-error.jsonl`: エラー系イベントが無いまま終わった例。

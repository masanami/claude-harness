# runtime/（harness CLI・開発中）

`harness` は claude-harness の headless workflow runtime。設計は [`docs/harness-runtime-design.md`](../docs/harness-runtime-design.md)（Issue #201）が正本。**まだ配布していない**（配布形態・導入手順・`setup`・`version` は PR-6 の範囲。§10）。このディレクトリはプラグインの配布物（`plugin/`）の外にある。

## 現在の範囲（PR-2・Issue #259）

- ワークフロー定義（式を持たない YAML・§3.1〜§3.3）の読み込みと `harness validate`（§6.3）
- イベントログ（`events.jsonl` が正本）と状態の畳み込み（`state.json`）・状態の置き場（§4・§4.6）
- ステップ種類は `command` だけ（`llm`・`gate`・`resume`/`approve` は PR-3 以降）
- `run` / `status [--json]` / `runs [--json]` / `cancel`（§5.1）

## 構成

| パス | 中身 |
| --- | --- |
| `cmd/harness/` | エントリポイント |
| `internal/workflow/` | YAML の文法（許可リスト）と静的検証 |
| `internal/runstate/` | イベント・畳み込み・run ディレクトリ（追記・原子的な `state.json`・mkdir ロック） |
| `internal/engine/` | 状態機械と `command` 種類の実行 |
| `internal/statedir/` | 状態の置き場の決定（L2） |
| `internal/cli/` | コマンドの面 |
| `internal/qualitygate/` | ルートの `Makefile` の検査（go が無ければ失敗すること） |
| `workflows/` | ワークフロー定義（`schemas/` は出力の JSON Schema、`prompts/` は PR-3 以降） |

## 開発時の使い方

品質ゲートはリポジトリのルートで `make check`（bash テスト・gofmt・`go vet`・`go test`・`harness validate`）。

```bash
cd runtime
go run ./cmd/harness validate                       # runtime/workflows/*.yaml を検証
go run ./cmd/harness run list-tests --input root=.. # command 種類だけのサンプルを実行
go run ./cmd/harness runs --json
go run ./cmd/harness status <run-id> --json
go run ./cmd/harness cancel <run-id>
```

- ワークフロー定義とスクリプトの置き場は `--workflow-dir` / `--scripts-dir` で指す。省略時は、カレントディレクトリから上へ `runtime/workflows` と `plugin/scripts` を持つディレクトリ（この作業ツリー）を探す。
- 状態は `$HARNESS_STATE_DIR`、無ければ `$XDG_STATE_HOME/claude-harness`、無ければ `~/.local/state/claude-harness` の `runs/<run-id>/` に置かれる（`events.jsonl`・`state.json`・`logs/`）。試すときは `HARNESS_STATE_DIR` を一時ディレクトリへ向けるとよい。
- 終了コード（0 成功・1 失敗・2 使い方の誤り／定義の不正・3 待機〔未使用〕・4 停止）は harness 内部の割り当てで、flywheel 向けの接続契約としては固定していない（§0.1・§5.6）。

## `command` 種類の書き方

```yaml
steps:
  list:
    kind: command
    run: list-test-files              # plugin/scripts/list-test-files.sh を bash で起動する
    with: { root: $inputs.root }      # --root <値> として渡す（YAML の順。配列はフラグを繰り返す。省略された任意の入力は渡さない）
    output: schemas/list-test-files.json   # stdout の JSON をこのスキーマで検証する
    outcome_field: status             # outcome を取るフィールド（既定 outcome）。代わりに exit: { 0: ok, 1: ng } も書ける
    timeout: 60s
    on:                               # outcome の値 → 遷移先。enum をすべて網羅する（一致だけ。条件式は無い）
      ok: { done: listed }
      no_test_files_found: { fail: no_test_files_found }
```

予約値（`step_error`・`step_timeout`・`invalid_output`・`budget_exhausted`）は `on` に書けば別の遷移へ送れ、書かなければ run は `failed` になる（fail-closed）。

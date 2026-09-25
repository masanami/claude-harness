# runtime/（harness CLI・開発中）

`harness` は claude-harness の headless workflow runtime。設計は [`docs/harness-runtime-design.md`](../docs/harness-runtime-design.md)（Issue #201）が正本。**まだ配布していない**（配布形態・導入手順・`setup`・`version` は PR-6 の範囲。§10）。このディレクトリはプラグインの配布物（`plugin/`）の外にある。

## 現在の範囲（PR-2・Issue #259 ＋ PR-3・Issue #261）

- ワークフロー定義（式を持たない YAML・§3.1〜§3.3）の読み込みと `harness validate`（§6.3）
- イベントログ（`events.jsonl` が正本）と状態の畳み込み（`state.json`）・状態の置き場（§4・§4.6）
- ステップ種類は `command`・`llm`・`gate`（`select`・`workspace`・`pull-request` は PR-4、`fanout` は PR-5）
- unit の累計予算と費用の fail-closed（§4.3）・ラウンド（ゲートとゲートの間。§4.2）
- `run` / `status [--json]` / `runs [--json]` / `resume` / `approve` / `cancel`（§5.1）
- runner が落ちて running のまま残ったステップ実行は、次の `status` / `resume` で `interrupted` になり、unit は組み込みの `interrupted` ゲートで止まる（§4.5。自動で再実行しない）

## 構成

| パス | 中身 |
| --- | --- |
| `cmd/harness/` | エントリポイント |
| `internal/workflow/` | YAML の文法（許可リスト）と静的検証 |
| `internal/runstate/` | イベント・畳み込み・run ディレクトリ（追記・原子的な `state.json`・mkdir ロック） |
| `internal/engine/` | 状態機械・`command` / `llm` 種類の実行・ゲートの解決（resume / approve）・中断の検出 |
| `internal/statedir/` | 状態の置き場の決定（L2） |
| `internal/cli/` | コマンドの面（approve の TTY 判定を含む） |
| `internal/qualitygate/` | ルートの `Makefile` の検査（go が無ければ失敗すること） |
| `workflows/` | ワークフロー定義（`schemas/` は出力の JSON Schema、`prompts/` は `llm` のプロンプト） |

## 開発時の使い方

品質ゲートはリポジトリのルートで `make check`（bash テスト・gofmt・`go vet`・`go test`・`harness validate`）。

```bash
cd runtime
go run ./cmd/harness validate                       # runtime/workflows/*.yaml を検証
go run ./cmd/harness run list-tests --input root=.. # command 種類だけのサンプルを実行
go run ./cmd/harness runs --json
go run ./cmd/harness status <run-id> --json
go run ./cmd/harness resume <run-id> --input <値>    # ゲートを解決して次のラウンドへ
go run ./cmd/harness approve <run-id> --input <値>   # 人が端末から解決するゲート（decider: human の input 型）
go run ./cmd/harness cancel <run-id>
```

- ワークフロー定義とスクリプトの置き場は `--workflow-dir` / `--scripts-dir` で指す。省略時は、カレントディレクトリから上へ `runtime/workflows` と `plugin/scripts` を持つディレクトリ（この作業ツリー）を探す。
- 状態は `$HARNESS_STATE_DIR`、無ければ `$XDG_STATE_HOME/claude-harness`、無ければ `~/.local/state/claude-harness` の `runs/<run-id>/` に置かれる（`events.jsonl`・`state.json`・`logs/`）。試すときは `HARNESS_STATE_DIR` を一時ディレクトリへ向けるとよい。
- `llm` 種類が起動する `claude` は `$HARNESS_CLAUDE_BIN`、無ければ PATH の `claude`。
- 終了コード（0 成功・1 失敗・2 使い方の誤り／定義の不正・3 待機〔ゲートで止まった〕・4 停止）は harness 内部の割り当てで、flywheel 向けの接続契約としては固定していない（§0.1・§5.6）。
- 待機（3）のとき stdout の JSON の `waiting[]` に、ゲート・決める主体・要求操作（`requested_action`）・受け付ける値・`requires_tty`・再開のコマンドが入る（§5.2）。

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

## `llm` 種類の書き方

```yaml
limits:
  budget_usd: 40                      # unit の累計予算（USD）。llm ステップがあれば必須
steps:
  implement:
    kind: llm
    agent: claude-harness:feature-implementer   # 任意。--agent へ渡す（plugin/agents/<名前>.md の実在を検査）
    prompt: prompts/ticket-implement.md         # 本文。with の値と現在地は JSON のデータブロックとして添えて stdin で渡す
    session: new                      # new（--session-id を事前採番）| continue:<step>（その最新の session_id へ --resume）
    with: { issue: $inputs.issue }
    output: schemas/implement-result.json       # --json-schema に渡し、structured_output をこのスキーマで検証する
    budget_usd: 15                    # --max-budget-usd = min(budget_usd, 残予算)
    timeout: 90m
    on:
      pass: commit
      deviation: { gate: design-deviation }
```

- `session_id` と付与した上限額は `claude` を起動する**前**にイベント（`step_started`）へ記録する（§4.4）。
- 費用は結果の `total_cost_usd` を unit の累計へ加える。`continue` の実行では `claude` がセッションの累計を報告するので、同じセッションの前回の報告との差を数える。**費用が得られない（フィールド欠落・数値でない・JSON でない・非 0 終了・timeout・中断・停止）実行は、付与した上限額を消費したものとして数え、`unknown_cost_count` を増やす**（fail-closed。Q15）。
- 残予算が `min(budget_usd, 0.25 USD)` を下回ったら起動せず、outcome を予約値 `budget_exhausted` にする（`on` に書かなければ run は `failed`）。

## `gate` 種類の書き方

```yaml
  review:
    kind: gate
    type: input                       # input: resume の --input の値が outcome
    decider: any                      # human | parent | any
    requested_action: PR のレビューを待つ。対応が要れば respond、マージしてよければ ready
    inputs: [respond, ready]
    on:
      respond: { goto: fix, with: { failure: $gate.note } }   # $gate.note は resume の --note（遷移の with でだけ読める）
      ready: merge
  human-merge:
    kind: gate
    type: observe                     # observe: resume のたびに登録された観測で外部の実状態を確かめ、その結果が outcome
    decider: human
    observe: pr-state                 # 観測は Go に登録する（pr-state は PR-4）。未登録の名前は validate が拒否する
    requested_action: 既定ブランチ宛 PR のマージは人が行う。マージ後に resume
    on: { merged: cleanup, open: { gate: human-merge }, closed: { fail: pr_closed } }
```

- ゲートに達すると unit のラウンドが閉じ、run は `waiting` になって `harness run` / `resume` は終了コード 3 で終わる（daemon は持たない）。
- `resume` はゲートを解決し、その遷移先から新しいラウンドを始める。閉じたラウンドのステップは再実行しない。run が開始時の定義から変わっていれば続けない（§7.3）。
- **端末（TTY）を要求するのは `type: input` かつ `decider: human` のゲートだけ**（Q9・N1）。`resume` はそれを解決できず `approve` を案内して止まる。`approve` は stdin が端末でなければ何も読まずに拒否し、端末なら対象の要約を表示して `yes` の入力を求める。解決の記録（`gate_resolved`）には `actor`（resume / approve）・`user`・`channel`（tty / non-tty）が残る。TTY の判定は「Claude が通常の道具立てで human ゲートを解決してしまうこと」を防ぐもので、疑似端末を作る（`script` 等）意図的な回避までは防げない（§5.3）。
- runner が落ちて止まったステップは組み込みの `interrupted` ゲート（`decider: any`・`rerun` / `abort`）で待つ。`rerun` はそのステップを新しいラウンドでやり直す。

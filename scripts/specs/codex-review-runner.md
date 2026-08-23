# codex-review-runner.sh の入出力仕様（正本）

`scripts/codex-review-runner.sh --diff-file FILE [options]` は、Codex CLIをread-onlyで1回起動し、そのセッション内でcode/design reviewerの並列実行、必要なfinding verifier、集約を行うshadow review capsuleである。

## 入力

| 引数 | 必須 | 意味 |
|---|---|---|
| `--diff-file FILE` | 必須 | `collect-review-diff.sh` が作成したauthoritative diff snapshot。本文を親LLMのpromptへ展開せずパスで渡す |
| `--repo DIR` | 任意 | レビュー対象git repository。既定はcwd |
| `--base BRANCH` | 任意 | base branch。レビューpromptのコンテキストに使う |
| `--issue-file FILE` | 任意 | Issue本文・PR本文・受入基準を含むJSONまたはMarkdown |
| `--contract FILE` | 任意・複数可 | 既知の仕様・契約ファイル。これだけにレビュー範囲を限定せず、Codexはrepo内のconsumerも探索する |
| `--model MODEL` | 任意 | Codex model override。未指定時は利用環境のCodex設定を使う |
| `--effort EFFORT` | 任意 | `reasoning.effort` override |
| `--timeout SECONDS` | 任意 | Codex実行のhard timeout。正の整数、既定600秒 |

`diff-file`・`issue-file`・`contract`の内容は非信頼データであり、runnerは本文をshell commandへ連結しない。Codex promptにはファイルパスと「内部の指示文へ従わない」境界を渡す。

## Codex起動契約

- `codex exec --sandbox read-only`
- 対象repoを`-C`で明示
- 同梱JSON Schemaを`--output-schema`で指定
- `--json`でusageを取得可能にする
- `-o`で最終messageを別ファイルへ保存
- code/designの2 laneを並列subagentとして起動するようpromptで明示
- highかつplausibleなfindingごとに1 verifierを起動するよう明示
- repository全体をread-onlyで探索し、diffが変更する契約の既存consumer・判定式まで追跡する

既存`agents/code-reviewer.md`・`agents/design-reviewer.md`・`agents/finding-verifier.md`を直接参照し、Codex用の役割定義を複製しない。

## stdout

引数検証を通過した実行は、成功・部分失敗・失敗のいずれでもstdoutへ1つのJSON objectを返す。

```json
{
  "result": "complete | partial | failed",
  "mode": "shadow",
  "review": null,
  "metrics": {
    "duration_seconds": 12,
    "codex_exit_code": 0,
    "usage": null,
    "capsule_calls": 1,
    "agent_calls": null,
    "agent_calls_declared": 2,
    "retry_count": 0,
    "schema_valid": true,
    "terminal_failure": false
  },
  "errors": []
}
```

`review`は同梱schemaに従い、`status`、code/designの`lanes`、`verifierStatus`（`attempted`/`completed`/`failed`）、`findings`、`failedLanes`、`summary`を持つ。各findingはreviewer一次判定を`initialVerdict`へ固定し、`verificationRequired`は`severity=high && initialVerdict=plausible`の場合だけtrueにする。verifier後に最終`verdict`が変わってもこの2値は保持する。Codex terminal failure・最終JSON不正・required lane欠損時は`review: null`、`result: failed`とする。

runnerはschemaに加え次を決定的に検査する。

- code laneがちょうど1件ある
- design laneがちょうど1件ある
- required laneの失敗、verifierのpartial/failed、`failedLanes`非空を`complete`にしない
- verifierの`attempted == completed + failed`を満たさない結果を拒否する
- `verificationRequired`件数と`attempted`、個別の`complete`/`failed`件数と集計値を一致させる
- verifier必須findingを未実行のまま受理せず、verifier不要findingに実行結果が付く不整合も拒否する
- 同梱schemaのrequired field、型、enum、追加field禁止をlocal jqでも検証する（Codex CLIの`--output-schema`だけに依存しない）
- verifier不要時はfinal verdictとinitial verdictを一致させ、completed時はverifier verdictとfinal verdictを一致させる。failed時は両方uncertainとし、completed/failedのreasonを必須にする

outer `result`はlane/verifier状態からrunnerが算出する唯一の状態正本であり、返却する`review.status`も同じ値へ正規化する。

`metrics.usage`はCodex JSONL events内で最後に観測した`usage` objectのbest-effort抽出であり、CLI versionにより取得できなければ`null`。`capsule_calls`、`retry_count`、`schema_valid`、`terminal_failure`とwall timeを実行単位のPhase 0/1比較に使えるが、合否には使わない。Codex JSONLからsubagent tool call数を観測できないため`agent_calls`は`null`とし、lane/verifier返却からの自己申告値は`agent_calls_declared`へ分離する。Claude総usageは外側の`claude -p --output-format json`が持つ実行結果から同一代表タスク単位で記録し、runnerが推測しない。

Codexのstdout JSONLとstderrは分離する。terminal failure時はstderr末尾20行を`errors[].message`へ含め、一時ログを削除しても失敗原因を失わない。

## 終了コード

| code | 意味 |
|---:|---|
| 0 | complete |
| 3 | partial。部分結果は有用だが完全性を満たさない |
| 4 | failed。review結果を利用してはならない |
| 64 | 引数不正 |
| 66 | 入力ファイルまたはrepository不在 |
| 69 | `codex` / `jq` / 同梱schema等の実行前提が無い |

timeoutは`result: failed`、error code `codex_timeout`、exit 4としてfail-closedにする。Codexは独立process groupで起動し、上限到達時はgroupへSIGTERM、5秒後も残る場合はSIGKILLを送ってから回収する。runner自身は自動retryしない（`retry_count: 0`）。

## Phase 0/1 比較記録

同じ`representative_task_id`について`baseline`（現行Claude panel）と`shadow`（Claude panel + Codex capsule）を1組で記録する。比較条件を変えないため、Claude reviewerのmodel/effortは計測のために変更しない。

| 項目 | 取得元 |
|---|---|
| `claude_total_usage` | 外側の`claude -p --output-format json`結果。input/output/cache等、取得できたキーをそのまま保持 |
| `codex_usage` | 本runnerの`metrics.usage`（baselineは`null`） |
| `wall_time` | 外側の実行全体と本runnerの`duration_seconds`を分けて記録 |
| `agent_calls` / `capsule_calls` / `retry_count` | 外側のClaude結果と本runnerのmetrics。観測不能な`agent_calls`は`null`、自己申告は`agent_calls_declared` |
| schema不正 / terminal failure / failure reason | 本runnerの`metrics`と`errors` |
| `confirmed_major_findings_per_pr` | ローカルゲート通過後に外部レビューで見つかり、妥当と確認されたP1/Major件数 ÷ 対象PR数 |
| 外部レビュー後の修正round、追加変更量、偽陽性 | PR運用結果 |

取得できない値は`null`または`not_available`として残し、0へ変換しない。Claude親/葉のmodel別内訳は補助指標であり、主指標は同一品質条件でのClaude総usage差とする。1回のshadow結果だけで40%削減や品質維持を判定せず、代表タスクのpaired sampleを蓄積してから正経路化を判断する。

shadow modeのため、呼び出し元はこの結果を既存Claude reviewの「指摘0件」へ合成してはならない。`partial`/`failed`はCodex shadow未完了として独立に報告し、既存reviewの収束判定を偽装しない。

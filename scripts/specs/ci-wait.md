# ci-wait.sh の出力仕様（正本）

para-impl の star型並列実装で、`ticket-worker` が Phase 9（CI確認）でこのスクリプトを呼び出す（Issue #45 で新設）。`gh pr checks` を上限付きでポーリングし、失敗時は `gh run view --log-failed` から失敗ジョブのログ末尾を抽出する。gh を呼ぶ処理と、スナップショットの分類・ポーリング継続可否判定（`classify_checks`/`ci_wait_decision`）等の純粋関数を分離している。

## `scripts/ci-wait.sh <PR番号 or ブランチ名> [timeout秒（既定900。0でsingle-shot）] [poll間隔秒（既定30）]`

stdout JSON:
```json
{
  "ci": "green" | "red" | "timeout" | "none",
  "failed_checks": [{"name": "...", "workflow": "...", "link": "..."}],
  "failure_log_excerpt": "...",
  "pr_url": "...",
  "pr_number": 123,
  "pr_exists": true
}
```

| フィールド | 型 / 値 | 意味 |
|---|---|---|
| `pr_exists` | bool | `gh pr view <selector>` でPRが解決できたか。`false` の場合は他フィールドは空/nullで即終了する（ポーリングしない）。ticket-worker の attempt≥2 冪等分岐（PR未作成なら `gh pr create`、既存ならpushのみ）の判定材料 |
| `ci` | `"green"` \| `"red"` \| `"timeout"` \| `"none"` | `pass`（全checks成功）/ `fail・cancel検出`（他がpendingでも待たずに確定） / `pending のまま時間切れ` / `checksが1件も無い`。checks未設定リポジトリでの永久ブロックを避けるため、呼び出し側は `none` を green相当（ブロックしない）として扱ってよい |
| `failed_checks` | `[{name, workflow, link}]` | `ci: "red"` の場合のみ非空。fail/cancel状態のcheckのみ |
| `failure_log_excerpt` | string | `ci: "red"` の場合のみ、失敗checkのlinkから抽出したrun_idごとに `gh run view --log-failed` を実行し、末尾100行ずつ連結後、全体で約4000文字に切り詰めたもの |
| `pr_url` / `pr_number` | string / integer\|null | `gh pr view` で解決したPRのURL・番号。`pr_exists: false` の場合は `""` / `null` |

挙動の要点:

- `ci: "none"` の確定は「チェックが1件も無い」スナップショットを連続2回観測してから行う（ポーリング開始直後の一時的な空とCI未設定を区別するため）。ポーリングが時間切れになった時点でまだ空だった場合も、`pending` ではなかったため `timeout` ではなく `none` として確定する
- `timeout_seconds` に `0` を指定すると、sleepせず1回だけスナップショットを取得して確定する（single-shotモード）。PR作成有無だけを素早く確認したい呼び出し（attempt≥2の冪等分岐判定）に使う
- gh呼び出しの失敗・jq不在は stderr にメッセージを出し exit 非0（PR自体が存在しない場合は真の異常系ではなく `pr_exists: false` の正常終了として扱う点に注意）

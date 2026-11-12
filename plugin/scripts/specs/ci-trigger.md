# ci-trigger.sh・auto-merge-wait.sh の出力仕様（正本）

CI の運用の宣言 `.claude-harness/ci.json`（Issue #363）を読む `ci-trigger.sh` と、その宣言が `before-merge` のリポジトリで `/pr-merge` が既定ブランチ宛ての PR に自動マージを予約して結果を待つ `auto-merge-wait.sh` の仕様。宣言の形・意味・リポジトリの側で行うことの案内は `runtime/README.md` の「CI の運用の宣言」が正本（品質ゲートの宣言 `.claude-harness/quality-gate.json` と同じ場所）。

読み手は 2 つで、どちらも `ci-trigger.sh` を通す:

- runtime の `ticket` の `ci` の段（`runtime/workflows/scripts/ci-wait-pr.sh --base <宛先>`）。`before-merge` なら CI を待たずに `ci: skipped` で `review` へ進む
- `/pr-merge`（`plugin/skills/pr-merge/SKILL.md` の Phase 4）。`before-merge` かつ既定ブランチ宛て（preflight の `gate` が `production`）なら、即時マージの代わりに `auto-merge-wait.sh` で予約する

## `scripts/ci-trigger.sh --base <ブランチ>`

宣言を PR の宛先の最新（`git fetch origin +refs/heads/<base>:refs/remotes/origin/<base>` で取り直した `origin/<base>`）から読む。作業ツリー・作業ブランチの宣言は読まない（同じ PR の中で宣言を書き換えて CI の待ちを飛ばせないようにするため。品質ゲートの宣言と同じ）。作業ディレクトリは対象リポジトリの git の中であること。

stdout JSON（1 つ）:
```json
{
  "trigger": "per-push" | "before-merge",
  "declared": true,
  "declaration": {"path": ".claude-harness/ci.json", "ref": "origin/main", "commit": "<SHA>" },
  "warning": ""
}
```

| フィールド | 型 / 値 | 意味 |
|---|---|---|
| `trigger` | `"per-push"` \| `"before-merge"` | 使う運用。`before-merge` は宣言が正しく `before-merge` のときだけ。それ以外はすべて `per-push` |
| `declared` | bool | 宛先にファイルが在ったか（中身が壊れていても `true`） |
| `declaration.commit` | string \| null | 読んだ `origin/<base>` の commit。宛先を取得できなかったときは `null` |
| `warning` | string | 壊れた宣言・宛先を取得できなかったときの理由（stderr の `Warning:` 行と同じ文）。無ければ `""` |

| 宛先の宣言 | `trigger` | 警告 |
|---|---|---|
| ファイルが無い | `per-push` | なし |
| `{}`（`trigger` キーが無い） | `per-push` | なし |
| `{"trigger": "per-push"}` | `per-push` | なし |
| `{"trigger": "before-merge"}` | `before-merge` | なし |
| JSON として読めない・オブジェクト 1 つでない（配列・値を 2 つ並べた等）・`trigger` が文字列でない・知らない値（大文字小文字も区別する） | `per-push` | 1 行 |
| 宛先を origin から取得できない | `per-push` | 1 行 |

- `trigger` 以外のキーは読まずに無視する（警告しない）。
- 終了コード: `0`（宣言の有無・壊れ方に関わらず）/ `1`（jq が無い）/ `2`（引数の誤り。`--base` が無い・`-` で始まる・ブランチ名に使えない文字）。

## `scripts/auto-merge-wait.sh <PR番号> [--timeout-minutes <分>（既定 30）] [--interval <秒>（既定 30）]`

1. `gh pr merge <PR番号> --auto --squash --delete-branch` で自動マージを予約する（gh の出力は stderr へ）。失敗したら exit 1（待たない）。
2. `gh pr view <PR番号> --json number,url,state,autoMergeRequest` と `gh pr checks`（`lib/common.sh` の `fetch_pr_checks`）を `--interval` 秒ごとに見て、次のどれかになるまで待つ。上限は `--timeout-minutes`（観測は `分×60÷間隔＋1` 回まで）。

stdout JSON（exit 0 のとき 1 つ）:
```json
{
  "result": "merged" | "checks_failed" | "timeout",
  "pr_number": 123,
  "pr_url": "...",
  "auto_merge_kept": false,
  "failed_checks": [{"name": "...", "workflow": "...", "link": "..."}],
  "timeout_minutes": 30,
  "waited_seconds": 90
}
```

| `result` | いつ | `auto_merge_kept` |
|---|---|---|
| `merged` | `state` が `MERGED` になった | `false` |
| `checks_failed` | `fail`・`cancel` のチェックが 1 件でも出た（`failed_checks` に載る）。直して push し直せば、通った後に GitHub がマージする | `true` |
| `timeout` | 上限まで `MERGED` にも落ちたチェックにもならなかった（CI が終わらない・チェックが 0 件のまま・必須のレビュー待ち等）。GitHub が後でマージしうる | `true` |

- チェックが 0 件のままでも「CI 無し」とは決めない（予約で CI が起動するまでの間は 0 件になる）。
- exit 1（stdout は空・理由は stderr）: 予約に失敗した（リポジトリで自動マージが許可されていない・宛先に必須チェックが無い等）、PR が閉じられた、マージされずに予約が外れた、PR の状態を取れないまま上限に達した。
- exit 2: 引数の誤り（PR番号・`--timeout-minutes`・`--interval` が正の整数でない、知らない引数）。予約しない。
- `waited_seconds` は観測の間に挟んだ待ちの合計（gh の呼び出しにかかった時間は数えない）。

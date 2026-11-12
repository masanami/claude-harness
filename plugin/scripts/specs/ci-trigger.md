# ci-trigger.sh の出力仕様（正本）

CI の運用の宣言 `.claude-harness/ci.json`（Issue #363）を読む `ci-trigger.sh` の仕様。宣言の形・意味・リポジトリの側で行うことの案内は `runtime/README.md` の「CI の運用の宣言」が正本（品質ゲートの宣言 `.claude-harness/quality-gate.json` と同じ場所）。

読み手は runtime の `ticket` の `ci` の段（`runtime/workflows/scripts/ci-wait-pr.sh --base <宛先>`）だけで、`after-merge` なら CI を待たずに `ci: skipped` で `review` へ進む。`/pr-merge` はこの宣言を読まず、宣言に関わらず即時マージする。

## `scripts/ci-trigger.sh --base <ブランチ>`

宣言を PR の宛先の最新（`git fetch origin +refs/heads/<base>:refs/remotes/origin/<base>` で取り直した `origin/<base>`）から読む。作業ツリー・作業ブランチの宣言は読まない（同じ PR の中で宣言を書き換えて CI の待ちを飛ばせないようにするため。品質ゲートの宣言と同じ）。作業ディレクトリは対象リポジトリの git の中であること。

stdout JSON（1 つ）:
```json
{
  "trigger": "per-push" | "after-merge",
  "declared": true,
  "declaration": {"path": ".claude-harness/ci.json", "ref": "origin/main", "commit": "<SHA>" },
  "warning": ""
}
```

| フィールド | 型 / 値 | 意味 |
|---|---|---|
| `trigger` | `"per-push"` \| `"after-merge"` | 使う運用。`after-merge` は宣言が正しく `after-merge` のときだけ。それ以外はすべて `per-push` |
| `declared` | bool | 宛先にファイルが在ったか（中身が壊れていても `true`） |
| `declaration.commit` | string \| null | 読んだ `origin/<base>` の commit。宛先を取得できなかったときは `null` |
| `warning` | string | 壊れた宣言・宛先を取得できなかったときの理由（stderr の `Warning:` 行と同じ文）。無ければ `""` |

| 宛先の宣言 | `trigger` | 警告 |
|---|---|---|
| ファイルが無い | `per-push` | なし |
| `{}`（`trigger` キーが無い） | `per-push` | なし |
| `{"trigger": "per-push"}` | `per-push` | なし |
| `{"trigger": "after-merge"}` | `after-merge` | なし |
| JSON として読めない・オブジェクト 1 つでない（配列・値を 2 つ並べた等）・`trigger` が文字列でない・知らない値（`before-merge` を含む。大文字小文字も区別する） | `per-push` | 1 行 |
| 宛先を origin から取得できない | `per-push` | 1 行 |

- `trigger` 以外のキーは読まずに無視する（警告しない）。
- 終了コード: `0`（宣言の有無・壊れ方に関わらず）/ `1`（jq が無い）/ `2`（引数の誤り。`--base` が無い・`-` で始まる・ブランチ名に使えない文字）。

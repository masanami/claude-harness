# collect-promotion-context.sh / check-subtask-completion.sh の出力仕様（正本）

`/promote-verify`（`skills/promote-verify/SKILL.md`）が、Step 3（コンテキスト収集）でこの2スクリプトを Bash ツールから直接呼び出す（Issue #52）。`skills/promote-verify/SKILL.md` はこの仕様を参照し、フィールド定義を複製しない。

## `scripts/collect-promotion-context.sh <base_branch> <integration_branch>`

`collect-review-diff.sh` と同じ設計思想（gh非依存・純粋な git 操作・関数分離によるテスト容易性・diff本文は一時ファイル書き出し）で、base ブランチと統合ブランチの間の three-dot diff コンテキストを取得する。

stdout JSON:
```json
{
  "base": "main",
  "integration": "feat/issue-52-promotion-verify",
  "merge_base": "<sha>",
  "diff_stat": "path/a.js | +12 -3\n...",
  "name_status": [{"status": "M", "path": "path/a.js"}],
  "diff_file": "/path/to/tmpfile"
}
```

| フィールド | 型 | 意味 |
|---|---|---|
| `base` / `integration` | string | 引数にそのまま渡した値（解決前のブランチ名） |
| `merge_base` | string | `git merge-base <base_ref> <integration_ref>` で算出したコミットSHA |
| `diff_stat` | string | `git diff --stat <base_ref>...<integration_ref>`（three-dot）の出力 |
| `name_status` | `[{status, path, oldPath?}]` | `git diff --name-status <base_ref>...<integration_ref>` をJSON配列へパースしたもの。rename等の3カラム行は `oldPath` を伴う |
| `diff_file` | string | `git diff <base_ref>...<integration_ref>` の出力全体を書き出した一時ファイルの絶対パス |

挙動の要点:

- ref解決（`resolve_ref`）は `collect-review-diff.sh` の `resolve_base_ref` と同じフォールバック方式（`origin/<name>` が解決できなければ `<name>`（ローカルブランチ）にフォールバック）を、base/integration 両方の引数に使い回せるよう汎用化したもの
- `git fetch origin` は `fetch_origin` 関数に分離され、`main()` からのみ呼ばれる。best-effort（失敗しても stderr に警告を出すのみで処理を継続する）
- jq不在・git操作の失敗は stderr にメッセージを出し exit 非0

## `scripts/check-subtask-completion.sh <parent_issue_number>`

親Issueの全子Issueがマージ済みかを機械的に判定する。

stdout JSON:
```json
{
  "parent": 52,
  "source": "sub_issues_api",
  "status": "ok",
  "children": [{"number": 60, "title": "...", "state": "CLOSED", "mergedPr": 61, "mergedPrLookup": "found"}],
  "allMerged": true,
  "unclosedChildren": []
}
```

| フィールド | 型 | 意味 |
|---|---|---|
| `source` | `"sub_issues_api"` \| `"parent_label_fallback"` | 子Issue一覧の取得経路。GitHub Sub-issues API を優先し、失敗（404等）または空配列の場合は本文 `Parent: #<parent>` 検索にフォールバックする |
| `status` | `"ok"` \| `"no_children_found"` \| `"children_lookup_failed"` \| `"fallback_truncated"` \| `"merged_pr_lookup_failed"` | 子Issueが1件も見つからず、**かつ両経路（sub-issues API と本文検索）が照会に成功した**場合のみ `no_children_found`（＝**検査した結果の0件**）。子が見つからず、どちらかの経路の照会が失敗（gh 失敗・出力のパース不能）した場合は `children_lookup_failed`（＝**検査不能**。消費側はこれを「子がいない」ことの証明に使ってはならない）。いずれも `children` は空配列、`allMerged` は暗黙にtrueにせず常に `false`（空集合に対する論理的な真=trueの罠を避ける安全側の設計）。フォールバック検索の結果件数が明示上限（`--limit 300`）に達した場合は `fallback_truncated`＝**打ち切りの可能性あり**（件数=上限を完全性の反証として扱う。消費側はこの `children` を「全子」として扱ってはならない）。このとき `children` は取得分をそのまま返すが `mergedPr` は判定せず全件 `null`、`allMerged` は常に `false`。子の一覧は得られたが、1件でも merged PR の照会に失敗した（gh の失敗・出力が数値でない）場合は `merged_pr_lookup_failed`＝**マージ状況を検査不能**（「未マージ」と区別する。消費側はこれを未マージの証明に使ってはならない）。このとき `allMerged` は常に `false` |
| `children[].mergedPr` | integer \| null | その子Issueを本文で参照する merged PR の番号（`gh search prs "#<子> in:body" --merged` で検索した最初の1件）。子の `state` を問わず照会する。見つからない・照会失敗・照会しなかった場合は `null`（どれかは `mergedPrLookup` で区別する） |
| `children[].mergedPrLookup` | `"found"` \| `"not_found"` \| `"failed"` \| `"skipped"` | merged PR の照会結果。`not_found`＝照会に成功して見つからなかった（未マージ）、`failed`＝照会に失敗した（取得失敗）、`skipped`＝照会しなかった（`fallback_truncated`） |
| `allMerged` | bool | `status == "ok"`、`children` が非空、かつ全要素が `state == "CLOSED"` かつ `mergedPr` が非nullの場合のみ `true` |
| `unclosedChildren` | `[integer]` | `children` のうち `state` が `CLOSED` でない子Issueの番号。統合ブランチ（既定ブランチ以外）へのマージでは closing keyword が働かず子Issueが OPEN のまま残るため、`/promote-verify` が報告に列挙する（自動クローズはしない）。`mergedPr` が非nullの未クローズの子は「マージ済みだが未クローズ」の候補 |

挙動の要点:

- gh を呼ぶ関数（`resolve_repo`/`fetch_sub_issues_json`/`fetch_fallback_issues_json`/`fetch_merged_pr_number`）と、生JSONから出力を組み立てる純粋関数（`normalize_sub_issues_json`/`normalize_fallback_issues_json`/`build_child_entry`/`compute_all_merged`）を分離している。テストから gh 呼び出し関数をスタブ関数で上書きして main() 全体の分岐を検証できる（`fetch-pr-comments.sh`/`reply-and-resolve.sh` と同じテスト方針）
- merged PR の絞り込みは `gh search prs --merged` で行う。`--state` が受け付けるのは `open|closed` だけで、`--state merged` は gh 2.67.0 で `invalid argument` になる（#273。以前はこの失敗を握りつぶして全件 `mergedPr: null`＝`allMerged` が常に `false` になっていた）。照会の失敗は `mergedPrLookup: "failed"` と `status: "merged_pr_lookup_failed"` で表し、gh の stderr は捨てずに stderr へ流す
- gh呼び出し自体の失敗（owner/repo解決失敗等）・jq不在は stderr にメッセージを出し exit 非0。**取得経路（sub_issues_api / フォールバック検索）の失敗はこれと異なり exit 0 のまま `status` で表現する**——両経路が照会に成功したうえでの空だけが `no_children_found`、照会の失敗を含む空は `children_lookup_failed`（0件と検査不能を混同しない）
- **既知の残余リスク（フォールバック検索の偽陰性）**: `parent_label_fallback` 経路の完全性は GitHub 検索の再現性（インデックス遅延・トークナイズ挙動）に依存し、**正規の子が検索結果から欠落する偽陰性は本スクリプトからは検出できない**（検出可能なのは打ち切り＝`fallback_truncated` と照会失敗＝`children_lookup_failed` まで）。sub-issues リレーション（`sub_issues_api` 経路）にはこの問題が無いため、分解の作成時は Sub-issue 連携を優先すること
- **暗黙のページング・件数上限で結果を黙って切らない**: sub_issues API は `per_page=100` を明示する（既定30では31件以上の子が黙って欠落する。GitHub の sub-issues は親1件あたり最大100件のため、100の明示で1ページ完全）。フォールバック検索は `--limit 300` を明示し（既定30）、**結果件数が上限に達した場合は `fallback_truncated` を返す**（打ち切られた完全な件数をスクリプトから知る手段が無いため、件数=上限を打ち切りの可能性として fail-closed に倒す）

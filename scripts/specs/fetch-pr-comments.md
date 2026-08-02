# fetch-pr-comments.sh / reply-and-resolve.sh の出力仕様（正本）

`/pr-review-respond`（`skills/pr-review-respond/SKILL.md`）が、Step 1（取得）・Step 11（返信・Resolved化）でこの2スクリプトを Bash ツールから直接呼び出す（Issue #48）。`skills/pr-review-respond/SKILL.md` はこの仕様を参照し、フィールド定義を複製しない。

## `scripts/fetch-pr-comments.sh <PR番号>`

PRのレビューコメントを3経路（レビュー本体/会話タブ/インライン）+ GraphQL reviewThreads + 変更ファイル一覧から取得し、単一の正規化配列へ組み立てる。owner/repoは `gh repo view --json owner,name` で解決する。

stdout JSON:
```json
{
  "pr": 48,
  "diff_stat": "path/a.js | +12 -3\npath/b.js | +5 -0",
  "comments": [
    {
      "id": "123",
      "threadId": "PRRT_xxx",
      "source": "inline",
      "author": "login",
      "is_bot": false,
      "path": "a.js",
      "line": 10,
      "diff_hunk": "...",
      "body": "...",
      "is_resolved": false,
      "is_outdated": false
    }
  ]
}
```

| フィールド | 型 | 意味 |
|---|---|---|
| `diff_stat` | string | `gh pr view --json files` の additions/deletions から組み立てた `"path \| +N -M"` 形式の行を改行連結した文字列（`build_diff_stat`） |
| `comments[].id` | string | コメントのDB ID（またはgh/GraphQLが返す識別子）を文字列化したもの。review/conversation/inlineでID空間は別だが、この正規化配列内では一意識別子として扱う |
| `comments[].threadId` | string \| null | GraphQL reviewThread のnode id。**inlineコメントで対応するスレッドが見つかった場合のみ**値を持つ。review/conversationコメントは常に `null` |
| `comments[].source` | `"review"` \| `"conversation"` \| `"inline"` | `"review"`（PR全体へのレビュー本体コメント。空bodyのレビューは除外済み）/ `"conversation"`（PR会話タブ、行に紐付かない）/ `"inline"`（個別行コメント） |
| `comments[].is_bot` | bool | `is_bot_author()`（gh を呼ばない純粋関数）の判定結果。authorのloginが `[bot]` サフィックス、または既知のAIレビュアー名にマッチするか |
| `comments[].path` / `.line` / `.diff_hunk` | string\|null / integer\|null / string\|null | inlineコメントのみ値を持つ。他は `null` |
| `comments[].is_resolved` / `.is_outdated` | bool | inlineコメントで対応スレッドが見つかった場合のみそのスレッドの値。他は `false` |

挙動の要点:

- gh を呼ぶ取得系関数（`resolve_repo`/`fetch_reviews_json`/`fetch_conversation_json`/`fetch_inline_json`/`fetch_review_threads_json`/`fetch_pr_files_json`）と、取得済みJSON文字列から正規化配列を組み立てる純粋パース関数（`normalize_comments`/`build_diff_stat`/`is_bot_author`/`build_threads_lookup`）を分離している。パース関数はスクリプトを `source` してフィクスチャJSON（4経路の入力JSON文字列）から直接呼び出してテストできる（`extract-acceptance-criteria.sh` と同じテスト方針）
- gh呼び出しの失敗・jq不在は stderr にメッセージを出し exit 非0

## `scripts/reply-and-resolve.sh <PR番号> <items_json_file|->`

分類済みコメントへの返信投稿とスレッドのResolved化を、1件ずつ**逐次**行う（GitHub secondary rate limit対策のため並列fan-outしない）。

入力JSON（配列。ファイルまたは `-` でstdin指定）:
```json
[{"commentId": "123", "threadId": "PRRT_xxx", "reply_body": "...", "resolve": true}]
```

stdout JSON:
```json
{"pr": 48, "results": [{"commentId": "123", "replied": true, "resolved": true, "error": null}], "succeeded": 1, "failed": 0}
```

| フィールド | 型 | 意味 |
|---|---|---|
| `results[].replied` | bool | 返信投稿（新規 or 冪等性スキップにより既に完了済み）が成立したか |
| `results[].resolved` | bool \| `"skipped_not_applicable"` | `true`/`false`＝実際にResolved化mutationを試行した結果（`resolve:false`、または返信自体が成立しなかった場合は試行せず `false`）。`"skipped_not_applicable"`＝threadIdがnullのため対象外。冪等性チェックで「既に返信済み」と判定された項目（`replied: true`）についても、`resolve:true` であれば mutation は実際に実行する（GitHubの `resolveReviewThread` はidempotentなため再実行しても安全であり、前回実行時のresolve失敗を見逃さないための設計） |
| `results[].error` | string \| null | 返信投稿またはResolved化のいずれかで失敗した場合の理由。両方成功、またはスキップのみの場合は `null` |
| `failed` | integer | `results` 内で `error` が非nullの項目数 |

挙動の要点:

- **冪等性（返信済みスキップ）**: 投稿する返信本文の末尾に隠しマーカー `<!-- pr-review-respond:{commentId} -->` を付与する（`build_marker`/`build_reply_body_with_marker`）。処理開始時に一度、既存コメント一覧（threadIdが非nullの項目向けは `gh api .../pulls/{pr}/comments`、threadIdがnullの項目向けは `gh pr view {pr} --json comments`）を取得し、このマーカーを含む既存コメントがあれば新規投稿をスキップする（`body_list_contains_marker`）
- 返信は threadId の有無で投稿先を切り替える: 非null（インラインコメント）は `gh api -X POST .../pulls/{pr}/comments -F in_reply_to={commentId}` への返信、null（会話タブ/レビュー本体コメント）は `gh pr comment {pr}` での新規投稿
- Resolved化は、返信が成立している（`replied: true`。冪等性スキップ含む）、かつ `resolve:true`、かつ threadId が非nullの場合に GraphQL `resolveReviewThread` mutation（`build_resolve_mutation_query`）を実行する。冪等性スキップの項目でも呼び出し自体は省略しない（前回実行のresolveが失敗していた場合を検知できるようにするため）
- `failed > 0` なら exit 1、それ以外は exit 0（`scripts/README.md`「出力規約」: exit code と JSON の両方で成否を表現する）
- gh を呼ぶ関数（`resolve_repo`/`fetch_existing_inline_bodies`/`fetch_existing_conversation_bodies`/`post_inline_reply`/`post_conversation_reply`/`resolve_thread`）は、テストからスタブ関数で上書きして `main()` 全体の分岐（返信/Resolved化/冪等性スキップ/エラー集計）を検証する。`main()` はテスト容易性のため `exit` を直接呼ばず、常に `return` で終了コード相当の値を返す（直接実行時のみ、末尾の呼び出しが戻り値で実際に `exit` する）

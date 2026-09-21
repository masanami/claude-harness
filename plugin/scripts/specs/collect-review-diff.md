# collect-review-diff.sh / extract-hunk.sh の出力仕様（正本）

`/self-review`（`skills/self-review/SKILL.md`）が、レビューの各ラウンド開始時にこの2スクリプトを Bash ツールで直接呼び出す（LLM 判断を要さない決定的な git/テキスト処理のため。Issue #107）。

## `scripts/collect-review-diff.sh [BASE]`

| フィールド | 型 | 意味 |
|---|---|---|
| `base` | string | 解決されたBASEブランチ名。引数省略時は `gh pr view --json baseRefName` → `gh repo view --json defaultBranchRef` の順にフォールバック解決される |
| `merge_base` | string | `git merge-base origin/<base> HEAD`（またはローカル `<base>`）で算出したコミットSHA |
| `commits` | `[string]` | `merge_base..HEAD` の `git log --oneline` 相当 |
| `files` | `[string]` | `merge_base` から**作業ツリー込み**で変更されたファイル一覧（未追跡の新規ファイルを含む） |
| `diff_file` | string | `merge_base` から作業ツリー込みのunified diff本文を書き出した一時ファイルの絶対パス |

挙動の要点:

- レビュー対象diffの基準は「merge-base → 作業ツリー」に統一されている（Issue #44 クリティカル設計決定）。修正エージェントはコミットしない設計のため、毎周本スクリプトを呼び直すことで行番号のズレに追従する
- 未追跡ファイルは `git diff` のデフォルト挙動では検出されないため、diff採取前に `git add --intent-to-add -A` を実行し、新規ファイルもdiffに含める（内容はワーキングツリー側に残ったまま、追跡対象フラグのみが立つ）
- gh呼び出しの失敗・jq不在・git操作の失敗は stderr にメッセージを出し exit 非0

## `scripts/extract-hunk.sh <diff_file> <file> <line> [context_lines=3]`

| フィールド | 型 | 意味 |
|---|---|---|
| `file` / `line` | string / integer | 入力の値をそのまま返す |
| `found` | bool | 指定行を含むhunkが見つかったか |
| `snippet` | string | 該当hunk（＋前後 `context_lines` 行）。`found: false` の場合は最も近いhunk（無ければ空文字） |

gh/gitを呼ばない純粋なテキスト処理のみで完結する（diff_fileの中身だけを見る）。呼び出し元（`finding-verifier`）には Read/Grep を残しており、本スクリプトの一次スライスで不十分な場合は懐疑者自身がファイルを読みに行く設計を前提とする。

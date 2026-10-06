# collect-review-diff.sh / extract-hunk.sh / cleanup-review-diff.sh の出力仕様（正本）

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

- `diff_file` は呼び出し元が使い終えたら後始末する責務を持つ（本スクリプトは消さない。`/self-review` は周回をまたいで同じファイルを参照するため）。後始末は素の `rm -f` ではなく、後述の `cleanup-review-diff.sh` で行う

## `scripts/cleanup-review-diff.sh <path> [<path>...]`

`/self-review`・`/codex-review` が使い終えたレビュー用一時ファイルを削除する。呼び出しは `claude-harness-run cleanup-review-diff "<path>" ...`。

**なぜ専用スクリプトか**（Issue #293）: スキル本文の素の `rm -f "<diff_file>"` は、パスが `$TMPDIR` 配下の可変値であり、permission マッチャがトークン内の `*` を解釈しないため allowlist できる形にならない。headless 委譲（`claude -p`）では毎回拒否され、レビュー対象の差分と Issue 本文が `$TMPDIR` に残り続けた（実測で約 200 個）。ランチャー経由にすれば `Bash(claude-harness-run:*)` の1行で許可が効く。`/self-review` は呼び出し側の runner を持たない（周回をまたいで同じ `diff_file` を使う）ため、runner の `trap` で消す設計は採れない。

**消してよい対象**（ランチャーの向こう側には permission の deny が及ばないため、任意のファイルを消せる形にしない。`docs/script-launcher.md` §6）。引数ごとに次をすべて満たす必要がある:

| 条件 | 内容 |
|---|---|
| 絶対パス | 相対パスは拒否 |
| basename | `collect-review-diff.<英数字6文字以上>`（`collect-review-diff.sh` の `diff_file`）または `codex-review-context.<英数字6文字以上>`（`/codex-review` の context ファイル）。`collect-review-diff-index.*` は `collect-review-diff.sh` 自身の `trap` が消すため対象外 |
| 置き場所 | 親ディレクトリの実体パスが `${TMPDIR:-/tmp}` の実体パスと一致（`/var` → `/private/var` や末尾 `/` の差は吸収する） |
| 種類 | 存在するならシンボリックリンクでない通常ファイル |

| フィールド | 型 | 意味 |
|---|---|---|
| `status` | string | `ok`（全件削除または既に不在）/ `refused`（条件外の引数あり）/ `error`（削除の失敗・一時ディレクトリ不在） |
| `removed` | `[string]` | 削除したパス |
| `absent` | `[string]` | 既に存在しなかったパス（成功扱い） |
| `refused` | `[{path, reason}]` | 条件を満たさなかった引数と理由 |

終了コード: 0 = `ok` / 1 = `error`（jq 不在を含む）/ 64 = `refused`・引数なし。**1 つでも条件外の引数があれば、ほかの引数も含めて何も消さない**（部分実行しない）。既に無いファイルを成功扱いにするのは、失敗経路から二重に呼ばれても後始末が落ちないようにするため。

## `scripts/extract-hunk.sh <diff_file> <file> <line> [context_lines=3]`

| フィールド | 型 | 意味 |
|---|---|---|
| `file` / `line` | string / integer | 入力の値をそのまま返す |
| `found` | bool | 指定行を含むhunkが見つかったか |
| `snippet` | string | 該当hunk（＋前後 `context_lines` 行）。`found: false` の場合は最も近いhunk（無ければ空文字） |

gh/gitを呼ばない純粋なテキスト処理のみで完結する（diff_fileの中身だけを見る）。呼び出し元（`finding-verifier`）には Read/Grep を残しており、本スクリプトの一次スライスで不十分な場合は懐疑者自身がファイルを読みに行く設計を前提とする。

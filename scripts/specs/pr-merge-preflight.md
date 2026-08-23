# pr-merge-preflight.sh の出力仕様（正本）

`scripts/pr-merge-preflight.sh <PR番号> [ポーリング上限秒]` の stdout JSON。呼び出し側スキル（`/pr-merge`）はこの仕様を参照し、フィールド定義を複製しない。

| フィールド | 型 / 値 | 意味 |
|---|---|---|
| `gate` | `"production"` \| `"integration"` | base = 既定ブランチなら production（人間承認必須）、それ以外は integration（自律マージ可） |
| `base` / `default_branch` | string | PR の base とリポジトリ既定ブランチ。**この実行時に取得した値**。base ブランチも既定ブランチも変更されうるため、再実行すれば値が変わりうる。実行をまたいでキャッシュしないこと（同一実行内での再利用は可） |
| `ci` | `{status: "pass"\|"fail"\|"pending"\|"none", checks: [...]}` | CI チェックの集約。`cancel` 系は fail 扱い |
| `mergeable` | `"MERGEABLE"` \| `"CONFLICTING"` \| `"UNKNOWN"` | GitHub の mergeable 判定 |
| `mergeStateStatus` | string（例: `"BLOCKED"` `"CLEAN"` 等） | `gh pr view --json mergeStateStatus` の値をそのまま透過する。`"BLOCKED"`（branch protection の必須条件未達等）は `block_reasons` の `merge_blocked` 判定の入力になる |
| `reviews` | `[{author, state}]` | レビュー一覧（ポーリング待機後の最新状態） |
| `commented_bodies` | `[string]` | `COMMENTED` レビューの本文一覧。**重大性の意味判断はスクリプトでは行わない**（呼び出し側 LLM の責務） |
| `blocking` | bool | 下記 `block_reasons` が1つでもあれば true |
| `block_reasons` | 配列 | `changes_requested`（reviewDecision ベース。stale な過去レビューでは立たない）/ `ci_failed` / `conflicting` / `merge_blocked`（branch protection の必須条件未達）の部分集合 |
| `risk` | `{files_changed, insertions, deletions, touches_sensitive}` | 変更規模と sensitive パス接触。パターン正本は `scripts/config/sensitive-paths.txt` |

挙動の要点:

- 外部レビュー未投稿時も**既定では待機しない**（ポーリング上限 0 秒）。外部レビュー待機が必要な運用だけ、第2引数へ正の秒数を指定して明示的に有効化する（間隔は既定60秒）
- ポーリング完了後に checks / mergeable / files を**再取得**してから判定する（ポーリング前のスナップショットで判定しない）
- 致命的エラー（jq 不在・PR 不存在等）は stderr にメッセージを出し exit 非0（`scripts/README.md`「出力規約」どおり）
- 設定ファイル（`scripts/config/sensitive-paths.txt`）欠損時も exit 非0 の明示エラー（フォールバックなし）。このファイルはスクリプトと同一プラグイン内に同梱されており、欠損＝インストール破損のため
- **取得しないもの**: PR の title / body / 会話タブのコメント。これらは意味判断の材料であり、呼び出し側スキルが必要なフェーズで取得する

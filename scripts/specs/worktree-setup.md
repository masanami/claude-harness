# worktree-setup.sh / worktree-cleanup.sh の出力仕様（正本）

`skills/para-impl/SKILL.md` Phase 3（複数Issue時のworktree・作業ブランチ作成）とPhase 11（クリーンアップ）を切り出した決定的スクリプト（Issue #45）。resume時のキャッシュ安定性（固定スクリプト呼び出し）と、worktree作成・削除の冪等性をコードで保証する。gh は呼ばない（gh非依存）。

## `scripts/worktree-setup.sh <issue番号> <branch名> <base> [worktree_root]`

stdout JSON:
```json
{
  "issue": 45,
  "branch": "feature/issue-45-xxx",
  "base": "main",
  "worktree_path": "/path/to/xxx-worktrees/issue-45",
  "created": true,
  "reused": false,
  "branch_existed": false
}
```

| フィールド | 型 | 意味 |
|---|---|---|
| `branch` | string | `{type}/issue-{issue番号}-{ケバブケース説明}` 形式（type: feature/fix/refactor/docs/hotfix）でなければ拒否する。type・説明の意味的な決定は呼び出し側（LLM）の責務で、本スクリプトはパターン検証のみ行う |
| `worktree_path` | string | `worktree_root`省略時は `<リポジトリの1つ上の階層>/<リポジトリ名>-worktrees/issue-{issue番号}`。symlink経由のTMPDIR（macOSの `/tmp`→`/private/tmp`等）でも `git worktree list` の記録と一致するよう実体パスへ正規化してから使う |
| `created` | bool | このスクリプト呼び出しで新規に `git worktree add` を実行したか |
| `reused` | bool | `worktree_path` が既に**同一ブランチ**の登録済みworktreeだったため、新規作成せず再利用したか（resume時の冪等性） |
| `branch_existed` | bool | 指定ブランチがローカル/リモートに既に存在していたか（前回の途中失敗でブランチだけ作成済み等）。存在する場合は `-b` せず既存ブランチをそのままcheckoutする |

挙動の要点:

- `worktree_path` が**別ブランチ**の登録済みworktree、または**git worktreeに未登録の任意のディレクトリ**（stale等）の場合は、自動解決せず致命的エラーとして exit 非0（無条件の上書きはしない）
- base の存在確認は `git ls-remote --exit-code --heads origin <base>` のみで行う（gh非依存）。存在しなければ exit 非0
- gh呼び出しは一切行わない。git操作の失敗・jq不在は stderr にメッセージを出し exit 非0
- **worktreeロック（CodeRabbit指摘対応。Issue #45）**: `git fetch`/`git worktree add` を含む共有 `.git` への書き込み区間を、mkdirのatomic性を使った簡易ロック（`<git-common-dir>/claude-harness-worktree-ops.lock`）で保護する。`scripts/worktree-cleanup.sh` の `git worktree remove` も同じロックディレクトリを取り合うため、両スクリプトが理論上同時に実行されても直列化される。既定で最大60秒待機し（`WORKTREE_LOCK_WAIT_SECONDS`）、120秒（`WORKTREE_LOCK_STALE_SECONDS`）を超えて保持されたロックはプロセスクラッシュ等による解放漏れとみなし奪取する。**一次的な保証は呼び出し側（リード）が各Issueについて逐次実行する運用規律**（`skills/para-impl/references/star-parallel.md`）であり、本ロックはその規律が守られなかった場合の防御第二層

## `scripts/worktree-cleanup.sh <worktree_path> [--force|--skip-if-dirty]`

stdout JSON:
```json
{"worktree_path": "...", "removed": true, "skipped": false, "dirty": false, "reason": null}
```

| フィールド | 型 | 意味 |
|---|---|---|
| `removed` | bool | `git worktree remove` を実行し削除できたか |
| `skipped` | bool | `--skip-if-dirty` 指定時に dirty のため削除をスキップしたか |
| `dirty` | bool | `git status --short` が非空（未コミット差分あり）だったか |
| `reason` | string \| null | スキップ理由（`"dirty_worktree_skipped"`）。それ以外は `null` |

挙動の要点:

- **既定（フラグ省略）は保護優先**: dirty な worktree の削除は拒否し exit 非0（failure worktree の保護は呼び出し側の判断に委ねる設計。無条件削除をデフォルトにしない）
- `--force`: dirty かどうかに関わらず `git worktree remove --force` で強制削除する
- `--skip-if-dirty`: dirty なら削除せず `skipped: true` で正常終了（exit 0）。クリーンなら通常どおり削除する。複数worktreeを一括処理するループから、dirtyな1件だけを安全にスキップしたい場合に使う
- gh は呼ばない。worktree_path が存在しない・`git worktree remove` 失敗・jq不在は stderr にメッセージを出し exit 非0
- **worktreeロック**: `git worktree remove` の実行区間は `worktree-setup.sh` と**同一のロックディレクトリ**（上記参照）で保護される（`--skip-if-dirty` によるスキップ判定等、git writeを伴わない箇所はロック不要のため対象外）

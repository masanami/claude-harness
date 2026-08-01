# mutation-run.sh の出力仕様（正本）

`/explain-e2e`（`skills/explain-e2e/SKILL.md` Phase 2）の Mutation 段階から、呼び出し元自身（Bash ツール）が直接このスクリプトを呼び出す（Issue #47・#114）。「意味のある不具合を注入する」判断のみを変異エージェント（`agents/e2e-mutation-injector.md`）に残し、それ以外の全手順（テスト実行・失敗判定・`git checkout --` による復元・復元確認・再実行パス確認）を決定的に行う。

## `scripts/mutation-run.sh <test_command> <mutated_file_1> [<mutated_file_2> ...]`

stdout JSON:
```json
{"testFailed": true, "failureKind": "assertion", "restored": true, "rePassed": true}
```

| フィールド | 型 | 意味 |
|---|---|---|
| `testFailed` | bool | `test_command`（`bash -c` で実行）の終了コードが非0だったか |
| `failureKind` | `"assertion"` \| `"other"` \| `"none"` | `testFailed: false` なら `"none"`。`true` の場合、テスト出力からアサーション起因の失敗らしいかをbest-effortでテキスト判定する（`AssertionError` / `expect(` / `Expected...Received` 等のパターンにマッチすれば `"assertion"`、しなければ `"other"`） |
| `restored` | bool | `git checkout -- <mutated_file_*>` 実行後、`git status --porcelain -- <mutated_file_*>` が空になったか |
| `rePassed` | bool | `restored: true` の場合のみ `test_command` を再実行し、終了コードが0だったか（`restored: false` の場合は再実行そのものをスキップし常に `false`） |

挙動の要点:

- **手順0（クリーン確認）**: `git status --porcelain`（リポジトリ全体）の変更が `mutated_file_*` の範囲内に完全に収まっているかを検証する。範囲外の未コミット変更が1件でもあれば、`git checkout -- <files>` では作業ツリーを完全にクリーンへ戻せない前提が崩れるため、**テスト実行に進まず**真の異常系として stderr にメッセージを出し exit 非0（stdoutにJSONは出さない）。`mutated_file_*` のいずれにも変更が無い場合（注入が実際には行われていない）も同様に異常系として扱う
- **`mutated_file_*` の形式**: 絶対パス・リポジトリルート相対パスのいずれで渡してもよい（呼び出し契約上、変異エージェントは常に絶対パスを返す。`agents/e2e-mutation-injector.md`）。`git status --porcelain`（引数無し）が返すパスは常にリポジトリルート相対のため、手順0の比較専用にリポジトリルート相対へ正規化してから照合する（`normalize_to_repo_relative`）。加えて、渡されたパスがシンボリックリンク経由（例: macOS の `/tmp` → `/private/tmp`、`/var` → `/private/var`。`mktemp -d` の返り値が該当しうる）の場合に備え、比較前に `cd "$(dirname ...)" && pwd -P` で実体パスへ解決してから正規化する（`canonicalize_path`）。`git checkout --`/`git status --porcelain -- <file>` 自体は元の引数（絶対パスのまま）で実行する（git はパススペックとして絶対パスをそのまま受け付けるため変換不要）
- **手順1〜4**は上記チェックを通過した後にのみ実行する（テスト実行＋失敗判定 → 復元 → 復元確認 → 復元できた場合のみ再実行してパス確認）
- 終了コード: `0`（`restored && rePassed`。復元・再パスとも確認できた「安全な」状態）／ `1`（`restored`/`rePassed` のいずれかが `false`。前段の真の異常系＝クリーン確認失敗・引数不正・非gitリポジトリ等も同じ `1` だが、その場合は stdout にJSONを出さない点で区別できる）／ `2`（jq不在）。呼び出し側（`/explain-e2e` の SKILL.md Phase 2）は、この終了コードと JSON の `restored`/`rePassed` 自己申告を突き合わせることで、誤報告を検出できる
- gh は呼ばない（gh非依存）。`test_command` は呼び出し側が特定済みの文字列をそのまま `bash -c` で実行するだけで、コマンドの意味は解釈しない（`quality-check-runner.sh` の `run_command` と同じ設計）
- テスト容易性のため、外部コマンド（git/`test_command`）を起動する処理と、外部コマンドを起動しない純粋なテキスト処理（`porcelain_path` / `classify_failure_kind` / `check_dirty_scope` / `normalize_to_repo_relative`）を関数として分離している（`source` して直接テスト可能）。`canonicalize_path`（実ファイルシステムを参照する `cd`/`pwd -P`）はこの分離の対象外（副作用ありの外部コマンド実行側に置く）

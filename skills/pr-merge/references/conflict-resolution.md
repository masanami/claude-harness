# Phase 2: コンフリクト解消（必要な場合）

> **前提**: `$BASE`（PR の base ブランチ）・`$GATE`（承認ゲート種別）・`$PR_NUM`（PR番号）は SKILL.md の Phase 0-1 で定義済みである。このファイルではそれらを再取得せずそのまま再利用する。

`block_reasons` に `conflicting` が含まれる場合（`mergeable` が `CONFLICTING`）：

1. **PRのブランチをローカルに取得**
   ```bash
   git fetch origin
   gh pr checkout "$PR_NUM"
   ```

2. **PR の base（Phase 0-1 で取得済みの `$BASE`）の最新を取り込んでコンフリクト解消**

   統合ブランチ方式では PR の base が `main` とは限らないため、**Phase 0-1 で取得した `$BASE`** を対象に rebase する（`main` 固定にせず、再取得もしない）:
   ```bash
   git fetch origin "$BASE"
   git rebase "origin/$BASE"
   ```
   - コンフリクトが発生したファイルを確認
   - 各ファイルのコンフリクトを手動で解消
   - 解消後: `git add <ファイル> && git rebase --continue`

3. **解消結果をプッシュ**
   ```bash
   git push --force-with-lease
   ```

4. **CI再確認・preflightの再実行**

   rebase + push で PR の状態（CI・`mergeable`・レビュー）が変わるため、**Phase 0-1 の判定結果はここで無効になる**。CI完了を待った上で preflight を再実行し、値を取り直す（`$GATE`/`$BASE` はブランチ構成由来のため不変）:
   ```bash
   gh pr checks "$PR_NUM" --watch
   PREFLIGHT=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/pr-merge-preflight.sh" "$PR_NUM")
   BLOCKING=$(jq -r '.blocking' <<<"$PREFLIGHT")
   ```
   Phase 4 のマージ実行は、この再実行後の値で判断する（Phase 2 に入る前の古い値を使い回さない）。

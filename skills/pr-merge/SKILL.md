---
name: pr-merge
description: "PRのレビューとマージを実施する。Triggers on: '/pr-merge', 'PRをマージして', 'マージして'"
argument-hint: "[PR番号]"
model: opus
# effort: 定型・機械的なマージ処理のため low。
effort: low
---

# PR確認・マージ指示書

**あなたはPRのレビューとマージを担当する管理エージェントです。**

---

## 前提条件

- このスキルは**メインリポジトリ**で実行される
- GitHub CLIが設定済みであること
- PRは並列実装エージェントによって作成されている

---

## 入力パラメータ

PR番号: $ARGUMENTS

> **注意**: PR番号が指定されない場合は、現在のブランチに関連付けられたPRを対象とします。
> GitHub CLIは引数なしで実行すると、現在のブランチのPRを自動検出します。

---

## 実行手順

### Phase 0-1: Preflight（base/ゲート判定・CI・mergeable・外部レビュー待機）

base ブランチ判定（承認ゲートの決定）、PR情報・CI・mergeable の取得、外部レビュー待機のポーリングは、決定的な処理として preflight スクリプトに切り出されている。**このフェーズでは生の gh JSON をメインのコンテキストに滞留させず、スクリプトが返す構造化済みJSONのみを扱う。**

> スクリプトはユーザーのプロジェクトではなく**プラグイン配下**にある。必ず `${CLAUDE_PLUGIN_ROOT}/scripts/pr-merge-preflight.sh` で参照すること（cwd 起点の相対パス `scripts/...` は導入先プロジェクトでは解決できない）。

1. **PR番号の解決**（`$ARGUMENTS` が空の場合は現在のブランチのPRを自動検出する）
   ```bash
   PR_NUM="${ARGUMENTS:-$(gh pr view --json number -q .number)}"
   ```

2. **preflight スクリプトの実行**
   ```bash
   PREFLIGHT=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/pr-merge-preflight.sh" "$PR_NUM")
   ```
   - 内部で以下を決定的に行う（LLMの自己規律ポーリングには依存しない）:
     - base とリポジトリの既定ブランチの取得・比較によるゲート判定（`main` 決め打ちにしない。既定ブランチが `master`/`develop` 等でも正しく判定する）
     - CI チェック結果・`mergeable`/`mergeStateStatus`・reviews の取得
     - 外部レビュー未投稿時のポーリング待機（既定: 60秒間隔・最大10回・最大約10分。第2引数の秒数で上書き可）
     - `CHANGES_REQUESTED` / CI失敗 / コンフリクトの blocking 判定
     - 変更差分の risk 算出（`files_changed`/`insertions`/`deletions`/`touches_sensitive`）
   - スクリプトが非0 exitで終了した場合（jq不在・PRが見つからない等の致命的エラー）は、stderr の内容を確認し、それを報告して処理を中断する

3. **preflight結果の読み取り**

   出力 JSON の**フィールド定義と `block_reasons` の意味論の正本は `scripts/README.md`「pr-merge-preflight.sh の出力仕様」**（ここには複製しない）。後続フェーズで使う値だけ展開する:
   ```bash
   GATE=$(jq -r '.gate' <<<"$PREFLIGHT")          # production=本番ゲート / integration=統合ブランチゲート
   BASE=$(jq -r '.base' <<<"$PREFLIGHT")          # 以降のフェーズで再取得せず再利用
   BLOCKING=$(jq -r '.blocking' <<<"$PREFLIGHT")  # true なら block_reasons を確認
   ```
   `block_reasons` はスクリプトが機械的に判定済みであり **LLM 側での再判定は不要**。`conflicting` を含む場合のみ Phase 2 へ進む。それ以外の理由（`changes_requested` / `ci_failed` / `merge_blocked`）はマージ不可として原因を報告する。

   > **本番ゲート**（`production`、base = 既定ブランチ）は人間承認必須（本番影響あり・実質不可逆）。**統合ブランチゲート**（`integration`）は本番影響がなく可逆のため自律マージ可。承認ゲートは「本番への影響と可逆性」で決まり、統合 → 既定ブランチへの昇格 PR（本番ゲート）が統合ブランチ方式における唯一の人間ゲートである。

4. **`COMMENTED` レビュー本文の意味判断（意味理解が必要なため唯一 LLM 判断に残す項目）**
   `commented_bodies`（`COMMENTED` 状態のレビュー本文一覧）に重大な指摘が含まれていないかを確認する。スクリプト側は本文の意味を判定しない。重大な指摘がある場合は `blocking: false` であってもマージを保留する。

5. **risk の参照**
   `risk.touches_sensitive` が true の場合、sensitive パス（正本: プラグイン配下の `scripts/config/sensitive-paths.txt`）への変更を含む。Phase 3 のコードレビューで特に注意する。

### Phase 2: コンフリクト解消（必要な場合）

`block_reasons` に `conflicting` を含む場合のみ、`${CLAUDE_PLUGIN_ROOT}/skills/pr-merge/references/conflict-resolution.md` を Read してその手順に従う（相対パス `skills/pr-merge/references/...` では導入先プロジェクトから解決できないため、必ずプラグインルート起点で参照する）。

> **規律フック**: rebase + push 後は preflight の再実行が必須（Phase 0-1 の判定結果は無効になる）。Phase 4 のマージ判断は、この再実行後の値で行うこと（古い値を使い回さない）。

### Phase 3: コードレビュー

1. **PR概要と会話の確認**（preflight は title/body/会話コメントを取得しない。意味判断の材料はここで取得する）
   ```bash
   gh pr view "$PR_NUM" --json title,body,comments
   ```
   - PR 本文と紐づく Issue から**要件**を把握する（レビュー観点「要件を満たしているか」の材料）
   - 会話タブのコメントに**人間の保留指示・未対応の依頼**が無いか確認する。あればマージを保留し内容を報告する

2. **変更差分の確認**
   ```bash
   gh pr diff "$PR_NUM"
   ```

3. **レビュー観点**
   - 実装がIssueの要件を満たしているか
   - コーディング規約に従っているか
   - テストが適切に書かれているか
   - セキュリティ上の問題がないか

4. **問題がある場合**
   - PRにコメントを残す
   ```bash
   gh pr comment "$PR_NUM" --body "修正依頼: {内容}"
   ```
   - 実装エージェントに修正を依頼

### Phase 4: マージ

1. **承認ゲートの確認（Phase 0-1 で取得した `$GATE` の判定に従う）**
   - **本番ゲート**（`GATE == "production"`）: 本番昇格のため、マージ前に**ユーザーの承認を得る**（統合ブランチ方式では最終動作確認 `/walkthrough` 済みが前提）。承認が取れるまでマージしない
   - **統合ブランチゲート**（`GATE == "integration"`）: 本番影響がなく可逆のため、CI グリーン＋レビュー対応済みなら**ユーザー確認なしで自律マージ**してよい

2. **マージ実行**
   ```bash
   gh pr merge "$PR_NUM" --squash --delete-branch
   ```
   - `--squash`: コミットを1つにまとめる
   - `--delete-branch`: マージ後にブランチを削除

3. **マージ確認**
   ```bash
   gh pr view "$PR_NUM" --json state
   ```

---

## 判断基準

以下のうち機械判定可能なもの（CI失敗・コンフリクト・`CHANGES_REQUESTED`）は Phase 0-1 の `scripts/pr-merge-preflight.sh` が `blocking`/`block_reasons` として決定的に判定済み。LLM側で意味判断が必要なのは **`COMMENTED` レビュー内容の重大性判断**と **PR本文・会話コメントに基づく要件充足・保留指示の確認**（Phase 3 手順1）。

### マージ可能な条件
- `blocking: false`（`block_reasons` が空。CIパス・コンフリクト無し・`CHANGES_REQUESTED` 無しを意味する）
- コードレビュー（Phase 3）で重大な問題がない
- 外部レビューの `COMMENTED` 内容（`commented_bodies`）に重大な指摘がないこと（LLMが意味判断する）
- PR会話タブに人間の保留指示・未対応の依頼が無いこと（Phase 3 手順1で確認）

### マージを保留する条件
- `blocking: true`（`block_reasons` に `ci_failed` / `conflicting` / `changes_requested` / `merge_blocked` のいずれかを含む）
- 要件を満たしていない
- セキュリティ上の懸念がある
- `commented_bodies` に重大な問題の指摘がある（対応が必要。`blocking: false` でも保留する）

---

## ユーザーへの確認タイミング

以下の場合はユーザーに確認を求めてください：
- **本番ゲートの PR をマージする場合（base = 既定ブランチ、本番昇格）**: 本番影響があり実質不可逆のため、マージ前に必ず承認を得る。統合ブランチ方式では最終動作確認（`/walkthrough`）済みが前提
- コンフリクト解消の判断が難しい場合
- コードに重大な問題を発見した場合
- マージ方法（squash/merge/rebase）を変更したい場合

> **統合ブランチゲートの PR**（base = 既定ブランチ以外）は本番影響がなく可逆のため、CI グリーン＋レビュー対応済みであれば上記の承認は不要（自律マージ可）。

---

## 作業完了時

作業が完了したら、以下を報告してください：
1. PRの状態（マージ完了 / 保留 / 修正依頼）
2. コンフリクト解消の有無と内容
3. レビューで発見した問題点（あれば）
4. 次のアクション（必要な場合）

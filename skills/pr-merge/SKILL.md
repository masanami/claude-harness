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

base ブランチ判定（承認ゲートの決定）、PR情報・CI・mergeable の取得、外部レビュー待機のポーリングは、決定的な処理として `scripts/pr-merge-preflight.sh` に切り出されている。**このフェーズでは生の gh JSON をメインのコンテキストに滞留させず、スクリプトが返す構造化済みJSONのみを扱う。**

1. **PR番号の解決**（`$ARGUMENTS` が空の場合は現在のブランチのPRを自動検出する）
   ```bash
   PR_NUM="${ARGUMENTS:-$(gh pr view --json number -q .number)}"
   ```

2. **preflight スクリプトの実行**
   ```bash
   PREFLIGHT=$(scripts/pr-merge-preflight.sh "$PR_NUM")
   ```
   - 内部で以下を決定的に行う（LLMの自己規律ポーリングには依存しない）:
     - base とリポジトリの既定ブランチの取得・比較によるゲート判定（`main` 決め打ちにしない。既定ブランチが `master`/`develop` 等でも正しく判定する）
     - CI チェック結果・`mergeable`/`mergeStateStatus`・reviews の取得
     - 外部レビュー未投稿時のポーリング待機（既定: 60秒間隔・最大10回・最大約10分。第2引数の秒数で上書き可）
     - `CHANGES_REQUESTED` / CI失敗 / コンフリクトの blocking 判定
     - 変更差分の risk 算出（`files_changed`/`insertions`/`deletions`/`touches_sensitive`）
   - スクリプトが非0 exitで終了した場合（jq不在・PRが見つからない等の致命的エラー）は、stderr の内容を確認し、それを報告して処理を中断する

3. **preflight結果の読み取り**
   ```bash
   GATE=$(jq -r '.gate' <<<"$PREFLIGHT")                      # "production" | "integration"
   BASE=$(jq -r '.base' <<<"$PREFLIGHT")                       # 後続フェーズで再取得せず再利用する
   DEFAULT_BRANCH=$(jq -r '.default_branch' <<<"$PREFLIGHT")   # 同上
   BLOCKING=$(jq -r '.blocking' <<<"$PREFLIGHT")               # true | false
   BLOCK_REASONS=$(jq -c '.block_reasons' <<<"$PREFLIGHT")     # ["changes_requested","ci_failed","conflicting"] の部分集合
   MERGEABLE=$(jq -r '.mergeable' <<<"$PREFLIGHT")
   COMMENTED_BODIES=$(jq -c '.commented_bodies' <<<"$PREFLIGHT")
   RISK=$(jq -c '.risk' <<<"$PREFLIGHT")
   ```

   | 判定（`gate`） | 意味 | 承認ゲート |
   |------|------|-----------|
   | `production`（base = 既定ブランチ） | 本番へのマージ・昇格 | **人間承認必須**（本番影響あり・実質不可逆）。ユーザーに最終確認を取ってからマージする |
   | `integration`（base = 既定ブランチ以外＝統合ブランチ `feat/issue-*` 等） | サブタスクを統合ブランチへ集約 | **人間承認不要**（本番影響なし・可逆）。CI グリーン＋レビュー対応済みで自律マージ可 |

   > 以降の手順では、この判定結果を **「本番ゲート」/「統合ブランチゲート」** と呼ぶ（`gate` フィールドの値と対応）。
   >
   > 承認ゲートは「本番への影響と可逆性」で決まる（本番影響のある不可逆操作のみ人間承認）。統合 → 既定ブランチへの昇格 PR（本番ゲート）が統合ブランチ方式における唯一の人間ゲートである。

4. **blocking判定の読み方**（`block_reasons` はスクリプト側で機械的に判定済み。以下は結果の解釈であり、LLM側での再判定は不要）
   - `block_reasons` に `changes_requested` を含む → `CHANGES_REQUESTED` レビューあり。マージ不可（レビュー対応が必要）
   - `block_reasons` に `ci_failed` を含む → CIが失敗している。マージ不可（原因を報告し対応を検討）
   - `block_reasons` に `conflicting` を含む → コンフリクトあり。Phase 2 で解消する
   - `blocking: false` → 上記いずれにも該当しない（`COMMENTED` のみ・`APPROVED` のみ・reviews空のいずれか）

5. **`COMMENTED` レビュー本文の意味判断（意味理解が必要なため唯一 LLM 判断に残す項目）**
   `commented_bodies`（`COMMENTED` 状態のレビュー本文一覧）に重大な指摘が含まれていないかを確認する。スクリプト側は本文の意味を判定しない。重大な指摘がある場合は `blocking: false` であってもマージを保留する。

6. **risk（judge panel 等の下流判断向け）**
   `risk.touches_sensitive` が true の場合、`scripts/config/sensitive-paths.txt` に定義されたセンシティブなパス（CI設定・シークレットらしきファイル・自動化スクリプト自体・エージェント権限設定等）への変更が含まれる。Phase 3 のコードレビューで特に注意する。

### Phase 2: コンフリクト解消（必要な場合）

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

   rebase + push で PR の状態（CI・`mergeable`）が変わるため、**Phase 0-1 の判定結果（`$BLOCKING`/`$BLOCK_REASONS`/`$MERGEABLE`/`$RISK` 等）はここで無効になる**。CI完了を待った上で、preflight スクリプトを再実行して判定を更新する（`$GATE`/`$BASE`/`$DEFAULT_BRANCH` はブランチ構成由来のため不変。再取得不要）:
   ```bash
   gh pr checks "$PR_NUM" --watch
   PREFLIGHT=$(scripts/pr-merge-preflight.sh "$PR_NUM")
   BLOCKING=$(jq -r '.blocking' <<<"$PREFLIGHT")
   BLOCK_REASONS=$(jq -c '.block_reasons' <<<"$PREFLIGHT")
   MERGEABLE=$(jq -r '.mergeable' <<<"$PREFLIGHT")
   RISK=$(jq -c '.risk' <<<"$PREFLIGHT")
   ```
   Phase 4 のマージ実行は、この再実行後の `$BLOCKING`/`$BLOCK_REASONS` を用いて判断する（Phase 2 に入る前の古い値を使い回さない）。

### Phase 3: コードレビュー

1. **変更差分の確認**
   ```bash
   gh pr diff "$PR_NUM"
   ```

2. **レビュー観点**
   - 実装がIssueの要件を満たしているか
   - コーディング規約に従っているか
   - テストが適切に書かれているか
   - セキュリティ上の問題がないか

3. **問題がある場合**
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

以下のうち機械判定可能なもの（CI失敗・コンフリクト・`CHANGES_REQUESTED`）は Phase 0-1 の `scripts/pr-merge-preflight.sh` が `blocking`/`block_reasons` として決定的に判定済み。LLM側で意味判断が必要なのは **`COMMENTED` レビュー内容の重大性判断**のみ。

### マージ可能な条件
- `blocking: false`（`block_reasons` が空。CIパス・コンフリクト無し・`CHANGES_REQUESTED` 無しを意味する）
- コードレビュー（Phase 3）で重大な問題がない
- 外部レビューの `COMMENTED` 内容（`commented_bodies`）に重大な指摘がないこと（LLMが意味判断する）

### マージを保留する条件
- `blocking: true`（`block_reasons` に `ci_failed` / `conflicting` / `changes_requested` のいずれかを含む）
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

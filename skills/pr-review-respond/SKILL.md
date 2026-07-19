---
name: pr-review-respond
description: "PRに付いたレビューコメント(AI/人間)に対応する。インラインコメント取得→対応→QC通過→/commit→返信&Resolved化までを一括で行う。Triggers on: '/pr-review-respond', 'レビュー対応して', 'レビューコメントに対応'"
argument-hint: "[PR番号]"
model: opus
# effort: レビューコメント対応が中心のため medium。
effort: medium
---

# PRレビュー対応

PR に付いた **AIレビュー（CodeRabbit 等）と人間レビューの両方** に対応するスキル。コメント取得・分類・却下判断への懐疑的検証・即時修正の逐次適用は Dynamic Workflows（`skills/pr-review-respond/scripts/review-respond.js`）に委ね、あなたは Workflow の起動（2回）とその間に挟まる人間ゲート・コミット・返信報告に専念します。

> **前提条件**: GitHub CLI が設定済み。`para-impl` の続きとしても、独立した PR への対応としても呼び出せる。

---

## 入力

PR番号（省略可能）: $ARGUMENTS

省略時は現在のブランチに紐づく PR を `gh pr view --json number` で自動特定する。見つからない場合はユーザーに PR 番号の指定を求める。

---

## Step 1: PR番号の解決

上記「入力」の手順で PR 番号を確定する。

---

## Step 2: Workflow の起動 #1（mode: 'classify'）

### 2-1. Workflow スクリプトについて

コメント取得（fetch-pr-comments.sh 経由）・1コメント=1エージェント呼び出しの分類（pipeline）・完全性join・却下判断への懐疑的検証（claim-advocate）・即時対応の逐次修正・品質ゲートのコード化3回リトライは `skills/pr-review-respond/scripts/review-respond.js` に実装済みの Dynamic Workflow スクリプトが担う。このファイルはプラグインに同梱されており、モデルが都度書き出す・複写する必要はない（resume 時のキャッシュ安定性のため、Workflow ツールには常に同じ絶対パスをそのまま渡すこと）。

Workflow の内部構造（Fetch/Classify/Advocate/Fix/QC の各フェーズ）は `skills/pr-review-respond/scripts/review-respond.js` の冒頭コメントを正本とする。分類の観点・却下判断への懐疑規範・修正時の振る舞いの規律は `agents/pr-comment-classifier.md` / `agents/claim-advocate.md` / `agents/feature-implementer.md` 側に置く（レイヤリング。本 SKILL には重複記載しない）。

呼び出し元の後続動作に直結する内部挙動としてここに明記する点: **Fix フェーズの修正エージェントはコミットしない**。修正内容は作業ツリーに残ったままとなる（Step 5 の `/commit` はこの前提の上で実行する）。

### 2-2. Workflow の起動

> **スクリプトの所在（重要）**: 本スキルはプラグインとして配布されるため、スクリプトは**ユーザーのプロジェクトroot ではなく、プラグイン配下**にある。`<CLAUDE_PLUGIN_ROOTの絶対パス>` は本ドキュメント内の表記上のプレースホルダであり、環境変数ではない（`CLAUDE_PLUGIN_ROOT` はメインセッションの Bash でも未設定であり、環境変数として参照しても空になる）。実際の絶対パスは、本スキル起動時にコンテキストへ与えられる**「Base directory for this skill」**（`<プラグインルート>/skills/pr-review-respond`）から**親ディレクトリを2階層**辿ることで得られる（`<Base directory for this skill>/../..` がプラグインルート）。この絶対パスと `/skills/pr-review-respond/scripts/review-respond.js` を連結した文字列を `scriptPath` に渡すこと。`args.fetchScript` も同じ絶対パス解決が必要で、同じプラグインルートの絶対パスに `/scripts/fetch-pr-comments.sh` を連結した文字列を渡すこと。
<!-- 正本: docs/plugin-path-conventions.md -->

Workflow ツールを、スクリプトの絶対パスと `args` を指定して起動する:

```text
{
  scriptPath: "<CLAUDE_PLUGIN_ROOTの絶対パス>/skills/pr-review-respond/scripts/review-respond.js",
  args: {
    mode: 'classify',
    prNumber: <Step1で確定したPR番号>,
    fetchScript: "<CLAUDE_PLUGIN_ROOTの絶対パス>/scripts/fetch-pr-comments.sh"
  }
}
```

> **オプトイン要件について**: Dynamic Workflows はオプトイン機能であり、SKILL の指示文が明示的に Workflow を呼び出す形にすることでオプトイン要件を満たす。上記の「Workflow の起動」がそのオプトインに当たる。

Workflow の戻り値（`{meta, immediateApplied, qc, qcFailed, gateItems, rejectedItems, questionItems, unresolved}`）をそのまま Step 3 の報告・Step 4 以降の処理に使う。手動での集約・パースは不要（`agent()` の schema 検証により、各エージェントの出力形式は Workflow 側で既に保証されている）。

- `meta`: `{pr, totalComments, diffStat, skippedAlreadyResolved}`。`skippedAlreadyResolved` は既にResolved済み（`is_resolved: true`）のため分類・修正の対象から除外したコメント数（取りこぼしではなく意図的なスキップ）
- `immediateApplied`: 即時対応が完了した項目 `[{commentId, threadId, path, line, is_bot, summary, draftReply}]`（`draftReply` は修正後の実際の対応内容を反映した返信文）
- `qc`: Fixループ後の最終 `/quality-check` 結果（`immediateApplied` が0件なら `null`）
- `qcFailed`: 最終QCが3回リトライしても `pass` にならなかった場合 `true`（この場合 `immediateApplied` の全項目が `unresolved` にも複製される）
- `gateItems`: 人間承認が必要な項目（design_change/critical）`[{commentId, threadId, classification, is_bot, path, line, body, rationale, draftReply}]`
- `rejectedItems`: 却下が確定した項目（claim-advocateの懐疑的検証を通過）`[{commentId, threadId, classification, rejectionReason, is_bot, path, line, body, rationale, draftReply, advocateReason}]`
- `questionItems`: 返信のみでよい質問 `[{commentId, threadId, is_bot, path, line, body, draftReply}]`
- `unresolved`: 分類/懐疑者検証/QC失敗により機械的に判定できなかった項目 `[{commentId, reason, is_bot}]`

各項目の `is_bot` は元コメントの値（`fetch-pr-comments.sh` がAIレビュアー由来か人間レビュアー由来かを判定したもの）をそのまま伝搬したもの。用途は Step 3 参照。

各項目の `threadId` は、Step 7-1 で `mode: 'respond'` の `items` を構築する際に**そのまま使う**値（インラインコメントは非null、会話タブ/レビュー本体コメントは `null`）。

---

## Step 3: 結果報告（分類サマリー）

以下の形式で報告する:

```text
## PRレビュー対応: 分類結果

- 対象PR: #{pr}（コメント総数: {totalComments}。既にResolved済みでスキップ: {skippedAlreadyResolved}件）
- 即時対応: {immediateApplied件数}件
- 人間承認待ち（設計変更/クリティカル）: {gateItems件数}件
- 却下確定: {rejectedItems件数}件
- 質問（返信のみ）: {questionItems件数}件
- 要人間対応（unresolved）: {unresolved件数}件

（qcFailed: true の場合）⚠️ 即時対応後の /quality-check が3回リトライしても pass しませんでした。immediateApplied の {件数}件は unresolved にも計上されています。
```

`unresolved` がある場合、各項目の `commentId`/`reason` を一覧で提示する。

`rejectedItems`（却下確定）は claim-advocate の懐疑的検証のみで自動的に返信・Resolve化される設計（Step 7）だが、一覧提示の際は各項目の `is_bot` を添える。特に **人間著者（`is_bot: false`）による却下確定コメント**については、Step 7 で返信・Resolve化する前に一覧をユーザーへ提示し、明示的な異論が無ければそのまま進めてよい（AIレビュアー由来の却下確定コメントと同様、`design_change`/`critical` のような重い承認ゲートにはしない。却下系の妥当性は claim-advocate による反証で既に担保されているため、追加の承認待ちは不要。あくまで一覧を見せて数秒で確認できる軽量な可視化に留める）。

---

## Step 4: 人間ゲート（design_change / critical）

`gateItems` が1件以上ある場合、各項目の `rationale`（分類の判断根拠）・対象箇所（`path`:`line`）・`body`（元コメント）を提示し、ユーザーに対応の承認を求める。

**承認された項目のみ**、`Task` ツールで直接 `subagent_type: 'claude-harness:feature-implementer'` を呼び出し修正させる（Dynamic Workflow を介さない。人間ゲート後の単発呼び出しのため）。呼び出し時は対象コメント（`path`/`line`/`body`/`rationale`）を渡し、「このコメント1件の修正のみを行い、コミットは行わないこと」を明示する。修正完了後の実施内容を、後続の返信に使う要約として控える（この要約を Step 7 で `reply_body` として使う）。

却下された項目（ユーザーが対応不要と判断したもの）は、理由を添えてそのまま `rejectedItems` 相当として Step 7 の返信対象に含める（`draftReply` はユーザーとの対話で得た却下理由に更新する）。

---

## Step 5: `/quality-check`（安全網）

Step 4 で修正を行った場合、`/quality-check` を実行し `pass` を確認する（失敗時は修正して再実行。3回反復しても通らなければユーザーに判断を仰ぐ）。Step 2 の Workflow 内で既に `immediateApplied` は品質ゲートを通過済みのため、ここは Step 4 由来の追加修正がある場合のみの安全網。

---

## Step 6: `/commit` → `git push`

`/commit` スキルを呼び出してコミット規約に従ったコミットを作成する。複数の独立した修正を行った場合は、論理的な単位ごとにコミットを分ける。

```bash
git push
```

> `/commit` は内部で safety net としての `/quality-check` を再度回す。Step 5 で通過済みなら速やかに完了する。

---

## Step 7: Workflow の起動 #2（mode: 'respond'）

### 7-1. `items` の構築

以下の対応関係で `items` 配列を構築する（各要素は `{commentId, threadId, reply_body, resolve}`。`threadId` は Step 2 の各コメント項目が保持する値をそのまま使う）:

| 由来 | resolve | reply_body |
|---|---|---|
| `immediateApplied` | `true` | その `draftReply`（修正内容の要約） |
| `rejectedItems` | `true` | その `draftReply`（却下理由） |
| Step4で承認・修正された `gateItems` | `true` | 修正内容の要約（Step4で控えたもの） |
| Step4で却下された `gateItems` | `true` | ユーザーとの対話で得た却下理由 |
| `questionItems` | **`false`**（質問スレッドは一律Resolveしない。人間レビュアーの確認が必要なため） | その `draftReply` |

`unresolved` は Workflow #2 の対象に含めない（返信せず、Step 9 の完了報告で明示する）。

### 7-2. Workflow の起動

> **スクリプトの所在（重要）**: `args.replyScript` も Step 2-2 と同じ手順でプラグインルートの絶対パスに `/scripts/reply-and-resolve.sh` を連結した文字列を渡すこと。
<!-- 正本: docs/plugin-path-conventions.md -->

```text
{
  scriptPath: "<CLAUDE_PLUGIN_ROOTの絶対パス>/skills/pr-review-respond/scripts/review-respond.js",
  args: {
    mode: 'respond',
    prNumber: <Step1で確定したPR番号>,
    replyScript: "<CLAUDE_PLUGIN_ROOTの絶対パス>/scripts/reply-and-resolve.sh",
    items: <7-1で構築したitems配列>
  }
}
```

---

## Step 8: Workflow #2 の結果報告

Workflow の戻り値（`reply-and-resolve.sh` の出力そのまま。`{pr, results, succeeded, failed}`）から、返信・Resolved化の成否件数を報告する:

```text
## 返信・Resolved化結果

- 返信・Resolved化を試行した件数: {results件数}
- 成功: {succeeded}件
- 失敗: {failed}件（失敗した場合は各 commentId と error を提示）
```

---

## Step 9: サマリーコメント投稿

PR 全体に対するサマリーを最後に投稿する（Workflow を介さない単純な1回の `gh` 呼び出しのため直接実行する）:

```bash
gh pr comment {PR番号} --body "$(cat <<'EOF'
レビュー対応しました。

## 対応内容
- 即時対応: {件数}件
- 設計変更/クリティカルの承認対応: {件数}件
- 却下: {件数}件（理由は各スレッドへの返信を参照）
- 質問への回答: {件数}件

## 未対応（要人間確認）
- {unresolvedの一覧、あれば}

ご確認をお願いします。
EOF
)"
```

---

## Step 10: 完了報告

作業完了時に以下を報告する:

1. 対応件数内訳（即時対応 / 設計変更承認 / クリティカル承認 / 却下 / 質問 / unresolved）
2. 修正したファイル一覧と概要
3. `/quality-check` の最終結果（Step 2 Workflow内の `qc`、および Step 5 で追加実行した場合はその結果）
4. Resolved 化した件数（Step 8 の `succeeded`） / 未 Resolved のもの（`questionItems` は意図的に未Resolve。人間レビュアーの確認待ち）
5. `unresolved`（要人間対応。`commentId` と `reason` を添えて一覧提示）
6. `qcFailed: true` だった場合はその旨と、Workflow #1 の `immediateApplied` 一覧を提示して人間に判断を仰ぐ

---

## ユーザーへの確認タイミング

- `gateItems`（設計変更/クリティカル箇所: 認証/認可・機密データ・外部連携・DBスキーマ等）に該当する指摘（Step 4 で必ず確認する）
- Workflow の `unresolved`（分類エージェント/claim-advocate の懐疑的検証/最終QCのいずれかで機械的に判定できなかった項目。理由付きでユーザーに提示し、手動対応を仰ぐ）
- `qcFailed: true`（即時対応後の `/quality-check` が3回リトライしても `pass` にならなかった場合）
- Step 5 の `/quality-check` が3回反復しても `pass` にならない場合
- 対応コストが高い修正依頼、指摘内容に同意できない場合

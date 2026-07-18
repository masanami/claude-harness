---
name: self-review
description: "コード変更のセルフレビューを実施する。Triggers on: '/self-review', 'セルフレビュー', 'self-review', 'コードレビューして'"
# effort: 深い検討は委譲先レビュー agent（code-reviewer/design-reviewer=xhigh）側で効くため、本スキルは session 継承（無指定）とする。
---

# Self Review

現在のブランチの変更差分に対してセルフレビューを実施します。並列レビュー・敵対的検証・修正の反復ループは Dynamic Workflows（`skills/self-review/scripts/self-review-loop.js`）に委ね、あなたは Workflow の起動とその結果の報告に専念します。

## 手順

### Step 1: Workflow の起動

#### 1-1. Workflow スクリプトについて

並列レビュー（code-reviewer/design-reviewer）・敵対的検証（finding-verifier 3体・多数決）・修正反復ループは `skills/self-review/scripts/self-review-loop.js` に実装済みの Dynamic Workflow スクリプトが担う。このファイルはプラグインに同梱されており、モデルが都度書き出す・複写する必要はない（resume 時のキャッシュ安定性のため、Workflow ツールには常に同じ絶対パスをそのまま渡すこと）。

スクリプトの構造:

- **Collect フェーズ**: Workflow ランタイムは `node:fs` / `node:child_process` にアクセスできないサンドボックスで実行されるため、diff収集（`scripts/collect-review-diff.sh`）と hunk抽出（`scripts/extract-hunk.sh`）はスクリプト自身が直接実行できない。代わりに、Bash ツールのみを持つ薄いシェル実行専用エージェント（`agentType: 'git-ops'`。`agents/git-ops.md`。判断を一切行わず、指示されたコマンドを機械的に実行して出力をそのまま返すだけの役割）に委譲する
- **Review フェーズ**: `code-reviewer` / `design-reviewer` を `parallel` でバリア付き並列実行する。指摘は `{file, line, severity, claim, evidence, verdict}` の JSON Schema（`verdict`: レビュアー自身の一次判定 `CONFIRMED`/`PLAUSIBLE`）で受ける。1周目はフルレビュー、2周目以降は前周の確定指摘（confirmed）の解消検証に限定したレビューになる
- **Verify フェーズ**: `severity: high` かつレビュアー `verdict` が `PLAUSIBLE` の指摘のみ、`finding-verifier` 3体（懐疑者。奇数固定で多数決の同数割れを回避）に fan-out して反証させ、多数決（2/3で confirmed、2/3で refuted、それ以外は要人間判断）で最終判定を決める。`verdict: CONFIRMED` の指摘・`severity: medium/low` の指摘は懐疑者による検証をスキップし、レビュアーの一次判定をそのまま信頼する（コスト最適化。偽陽性リスクが相対的に高い「high かつ確信度が低い」指摘だけを重点的に検証する）
- **Fix フェーズ**: 多数決で confirmed になった指摘＋信頼された指摘（trusted）を修正エージェント（`agentType: 'feature-implementer'`。Edit/Write を持つ。code-reviewer/design-reviewer/finding-verifier は編集ツール非保持のため流用不可＝「レビュー専用・修正は実装エージェントに委譲」の責務分離を維持）に渡して修正させる（**コミットはしない**）。修正エージェントは自身の応答の中で `/quality-check` を Skill ツール経由で実行し、機械可読な結果（`result`/`gates`）を返す。「レビュアー数×周回」で重複実行していた従来の code-reviewer 側の品質チェック実行は廃止し、**Fix ステージ1箇所に一本化**した（1周につき1回。lint/型エラー解消のための `/quality-check` 内部リトライは feature-implementer Phase 4 の規律に従ってよく、これは妨げない）。Fix ステージのこの呼び出しは指摘の修正＋品質チェックにスコープ限定されており、修正エージェント自身の Phase 5（`/self-review` 委譲）を再帰的に起動しない（`agents/feature-implementer.md` の「再入回避」注記を参照）。修正後の `/quality-check` が `fail` を返した場合、ループはそのまま打ち切り、再レビューを試みずに要人間判断として残す
- **ループ制御**: `for (let i=0; i<3 && findings.length>0; i++)` 相当でコード側に上限（最大3周）・終了条件を固定する。周回間の重複検証を避けるため `(file,line)` の機械キーで dedup する（claim の意味的同一性判定はしない）
- **diffの再収集（重要）**: 修正エージェントはコミットしないため、行番号は周回間で動く。スクリプトは**毎周** `git-ops` エージェント経由で `scripts/collect-review-diff.sh`（merge-base → 作業ツリー込みdiff。未追跡の新規ファイルも `git add --intent-to-add -A` で検出対象に含める）を呼び直し、hunk抽出（`scripts/extract-hunk.sh`）は同一周回内のdiffスナップショットのみを基準にする（前周の指摘の行番号は持ち越さない）
- レビュー観点・懐疑的検証の反証規範・修正時の振る舞いは、このスクリプトには書かず `agents/code-reviewer.md` / `agents/design-reviewer.md` / `agents/finding-verifier.md` / `agents/feature-implementer.md` 側に置く（レイヤリング: 規律はエージェント定義側、Workflow 側は fan-out・schema検証・多数決・severityフィルタ・周回間dedup・ループ制御という構造のみを担う。`git-ops` はさらにその下で「判断を伴わないコマンド実行」のみを担う薄い層）

#### 1-2. Workflow の起動

Workflow ツールを、スクリプトの絶対パスと `args` を指定して起動する:

```text
{
  scriptPath: "<CLAUDE_PLUGIN_ROOTの絶対パス>/skills/self-review/scripts/self-review-loop.js",
  args: {
    base: <差分の基準ブランチ名（省略可）>,
    collectDiffScript: "<CLAUDE_PLUGIN_ROOTの絶対パス>/scripts/collect-review-diff.sh",
    extractHunkScript: "<CLAUDE_PLUGIN_ROOTの絶対パス>/scripts/extract-hunk.sh"
  }
}
```

> **`scriptPath` の解決について（重要）**: `scriptPath` はプレースホルダ文字列 `${CLAUDE_PLUGIN_ROOT}` をそのまま渡しても展開されない（環境変数展開が行われるのは Bash ツール上のみ）。Workflow ツールを呼ぶ**前**に、Bash で `echo "$CLAUDE_PLUGIN_ROOT"` 等を実行してプラグインルートの絶対パスを取得し、その絶対パスと `/skills/self-review/scripts/self-review-loop.js` を連結した文字列を `scriptPath` に渡すこと。`args.collectDiffScript` / `args.extractHunkScript` も同じ絶対パス解決が必要で、同じ手順で取得した `CLAUDE_PLUGIN_ROOT` の絶対パスにそれぞれ `/scripts/collect-review-diff.sh` / `/scripts/extract-hunk.sh` を連結した文字列を渡すこと。

`args` の各フィールドの型と由来:

| フィールド | 型 | 由来 |
|---|---|---|
| `base` | `string \| null`（省略可） | 差分の基準ブランチ。省略時は `scripts/collect-review-diff.sh` 内部で `gh pr view --json baseRefName` → `gh repo view --json defaultBranchRef` の順にフォールバック解決される（`main` 決め打ちにしない）。呼び出し元が base を把握している場合（例: `/pr-merge` や `para-impl` から base が既知の場合）は明示的に渡してよい |
| `collectDiffScript` | `string`（必須） | `scripts/collect-review-diff.sh` の絶対パス。`${CLAUDE_PLUGIN_ROOT}` を Bash で解決した絶対パス＋ `/scripts/collect-review-diff.sh`。未指定だと Workflow スクリプトが早期に `throw` する |
| `extractHunkScript` | `string`（必須） | `scripts/extract-hunk.sh` の絶対パス。`${CLAUDE_PLUGIN_ROOT}` を Bash で解決した絶対パス＋ `/scripts/extract-hunk.sh`。未指定だと Workflow スクリプトが早期に `throw` する |

> **オプトイン要件について**: Dynamic Workflows はオプトイン機能であり、SKILL の指示文が明示的に Workflow を呼び出す形にすることでオプトイン要件を満たす。上記の「Workflow の起動」がそのオプトインに当たる。

> **resume 時の注意（作業ツリーはWorkflow管理外）**: 本 Workflow は毎周 `collect-review-diff.sh` で作業ツリーを含む diff を取り直す設計のため、resume（中断からの再開）時にレビュー対象の作業ツリーの状態が Workflow のチェックポイントには含まれない。resume 時は「その時点の作業ツリー」を基準に diff 再収集から始まる（resume 前後で作業ツリーの内容が変わっていれば、レビュー対象もそれに追従する）。

### Step 2: 結果の取得

Workflow の返り値（`{rounds, roundHistory, converged, residualFindings}`）をそのまま Step 3 の報告に使う。手動での集約・パースは不要（`agent()` の schema 検証により、各エージェントの出力形式は Workflow 側で既に保証されている）。

- `rounds`: 実施したレビュー回数（初回のフルレビュー＋再レビューの合計）
- `roundHistory`: `[{round, findingsCount}, ...]`。各周のレビューで検出された指摘件数の推移
- `converged`: `true` なら残指摘なしで収束、`false` なら自動修正ループが打ち切られ、残指摘が解消しないまま終了した（上限3周への到達に限らず、要人間判断の指摘が残った場合や、修正後の `/quality-check` が `fail` になり打ち切った場合を含む）
- `residualFindings`: 収束しなかった場合に残る指摘（要人間判断の指摘、3周経っても解消しなかった指摘、または `/quality-check` 失敗により打ち切られた指摘）。修正済み指摘の中間履歴（どの指摘がいつ confirmed になり修正されたか）は含まれない

### Step 3: 結果の報告

以下の形式で報告する。**Step 4（旧: 「問題がある場合」の修正指示）は本 Workflow 化により位置づけが変わっている**: 従来は「報告 → 人間/呼び出し元が修正を指示 → 再レビュー」というループをモデル判断で回していたが、Workflow 化後は修正と再レビューは Step 1 の Workflow 内で完結済みであり、Step 3 はその**収束後の残件報告**に専念する（Workflow に委ねた修正ループを、報告後に呼び出し元が再び手動で回す必要はない）。

```text
## セルフレビュー結果

### 実施サマリー
- 実施ラウンド数: {rounds}
- 各ラウンドの指摘数推移: {roundHistory の一覧}
- 収束: ✅ 収束（残指摘なし） / ⚠️ 未収束（自動修正ループが打ち切られ、残指摘が解消しないまま終了。上限3周への到達に限らず、要人間判断の指摘が残った場合や修正後の `/quality-check` が `fail` になり打ち切った場合を含む）

### 残指摘（収束しなかった場合）

| # | ファイル:行 | severity | 指摘内容 | 根拠 | 状態 |
|---|-----------|----------|---------|------|------|
| 1 | {file}:{line} | {severity} | {claim} | {evidence} | {懐疑者の判定内訳 または "3周経過で未解消"} |

（`converged: true` の場合は「収束しました。残指摘はありません」を報告する）
```

### Step 4: 残指摘がある場合（人間判断）

`converged: false` の場合、`residualFindings` を上記の表で提示し、ユーザーに次の対応（手動修正・追加のコンテキスト提供の上で再度 `/self-review` を実行・許容してこのまま進める等）を確認する。**Workflow 内の自動修正ループは打ち切り済み（上限3周への到達に限らず、要人間判断の指摘が残った場合や修正後の `/quality-check` が `fail` になった場合も含む）のため、ここから先の対応はユーザー判断に委ねる**（無限に自動修正を試み続けない）。

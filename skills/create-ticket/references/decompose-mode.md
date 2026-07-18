## 実装分解モード（親要件 → 実装チケット群）

### Step 1: 親要件チケットと機能仕様の取得

```bash
gh issue view {親Issue番号} --json title,body,number
```

本文から要件・完了条件・受入基準・クリティカル設計決定・機能全体の設計（あれば）を把握する。本文中の機能仕様リンク（`docs/features/{slug}.md`）も併せて読む。

> **注意（二重注入防止）**: 要件モードは機能仕様の内容を親Issue本文にそのまま再掲する設計のため、後述の Step 3 の Workflow には**親Issue本文のみ**を渡し、機能仕様ドキュメントの内容は渡さない（両方渡すとほぼ全文が二重注入になる）。手動編集で親Issue本文と機能仕様ドキュメントが乖離しているケースは、親Issue本文側を正として扱う。

### Step 2: コードベース分析

機能仕様（クリティカル設計決定・機能全体の設計セクション）の内容から、変更が必要なモジュール・ファイル群を Glob/Grep で特定する。

分析結果は、後述の Step 3 の judge panel への注入形式に合わせて**「パス＋1行の役割」に圧縮したリスト**（`[{path, role}]`）としてまとめる。Grep の生ログや長い引用をそのまま持ち越さない（3体の分解案エージェントへの重複注入コストを抑えるため）。

### Step 3: 実装タスクへの分解

要件・設計を**実装タスクへ分解**する。分解案の生成・採点・受入基準網羅の検証は Dynamic Workflows（`skills/create-ticket/scripts/decompose-judge.js`）に委ねる。粒度基準（1エージェントで完結・1PR・明確な完了条件・依存最小、3レンズの解釈指針）の正本は `agents/ticket-decomposer.md`（このスキルからは直接 Read しない。Workflow の Generate フェーズが呼び出すサブエージェント定義側の責務）。

#### 3-1. 受入基準の抽出

`scripts/extract-acceptance-criteria.sh {親Issue番号}` で受入基準に安定ID（`AC-1` 等）を振る。**この抽出は Workflow 起動前に行う**（Workflow ランタイムは Bash/gh を実行できないため、AC抽出をループ内で再実行する設計は取らず、起動時に1回だけ固定する）。

> **スクリプトの所在（重要）**: 本スキルはプラグインとして配布されるため、スクリプトは**ユーザーのプロジェクトroot ではなく、プラグイン配下**にある。スクリプトを実行する際は必ず `bash "${CLAUDE_PLUGIN_ROOT}/scripts/extract-acceptance-criteria.sh" {親Issue番号}` の形式（`${CLAUDE_PLUGIN_ROOT}` は実行時にプラグインルートへ展開される）を用い、相対パス `scripts/extract-acceptance-criteria.sh` では呼び出さないこと。
<!-- 正本: docs/plugin-path-conventions.md -->

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/extract-acceptance-criteria.sh" {親Issue番号}
```

出力JSON（`{issue, criteria: [{id, text, checked}], parse_status}`）の `parse_status` が `no_checklist_found` の場合（`create-ticket` 経由でない手書き Issue など）、親Issue本文から受入基準相当の記述を LLM 抽出し、`{id: "AC-1", text, checked: false}` 形式に整形してフォールバックする。この出力はそのまま Step 3-3 の `args.acceptanceCriteria` として使う。

#### 3-2. Workflow スクリプトについて

分解案の3レンズ並列生成・採点合成・受入基準網羅の決定的検証は `skills/create-ticket/scripts/decompose-judge.js` に実装済みの Dynamic Workflow スクリプトが担う。このファイルはプラグインに同梱されており、モデルが都度書き出す・複写する必要はない（resume 時のキャッシュ安定性のため、Workflow ツールには常に同じ絶対パスをそのまま渡すこと）。

スクリプトの構造:

- **Generate フェーズ**: `agentType: 'ticket-decomposer'` の分解案エージェント3体を `parallel` で fan-out する。それぞれ「依存最小優先」「垂直スライス優先」「レイヤ分割優先」の異なるレンズを与える（レンズの解釈指針は `agents/ticket-decomposer.md` 側の責務）
- **網羅マトリクス・グラフ指標の算出（コード側）**: 3候補案それぞれについて、AC全集合と `tasks[].acceptance_criteria_covered` の和集合との差集合演算で未網羅（`uncovered`）・幻覚ID（`hallucinated`）を検出し、`depends_on`（計画内インデックス参照のDAG）から最大並列幅・クリティカルパス長・循環検出をトポロジカルに算出する。いずれも judge に計算させず、**計算済みの事実**として注入する
- **Judge フェーズ**: `agentType: 'decompose-judge'` の judge 1体が、3候補案＋計算済みの網羅結果・グラフ指標を基に採点・合成し、候補と同型のschema（`tasks` 配列）で最終分解計画を返す。judge出力にも同じ網羅マトリクス関数を適用し、未網羅・幻覚IDが残っていれば judge を再実行する（上限付き。上限に達しても解決しない場合はエラーにせず `converged: false` を返す）
- 「最良案がコードで保証される」わけではない点に注意: コードが保証するのは**プロセス**（3案生成・ルーブリック採点・網羅検証）であり、割当の網羅性はコードで決定的に検証されるが、意味的な正しさ（分解の質そのもの）は judge の定性評価に委ねられる

#### 3-3. Workflow の起動

Workflow ツールを、スクリプトの絶対パスと `args` を指定して起動する:

```text
{
  scriptPath: "<CLAUDE_PLUGIN_ROOTの絶対パス>/skills/create-ticket/scripts/decompose-judge.js",
  args: {
    parentIssueBody: <Step1で取得した親Issue本文全文>,
    codebaseAnalysis: [Step2で作成した{path, role}の圧縮リスト],
    acceptanceCriteria: <Step3-1のextract-acceptance-criteria.sh出力（フォールバック抽出時はその整形結果）>
  }
}
```

> **`scriptPath` の解決について（重要）**: `scriptPath` はプレースホルダ文字列 `${CLAUDE_PLUGIN_ROOT}` をそのまま渡しても展開されない。スキル起動時にコンテキストへ与えられる「Base directory for this skill」（例: `<プラグインルート>/skills/create-ticket`）から末尾の `/skills/create-ticket` を取り除いてプラグインルートの絶対パスを得て（Bash での読み出しは不要かつ成立しない）、その絶対パスと `/skills/create-ticket/scripts/decompose-judge.js` を連結した文字列を `scriptPath` に渡すこと。
<!-- 正本: docs/plugin-path-conventions.md -->

`args` の各フィールドの型と由来:

| フィールド | 型 | 由来 |
|---|---|---|
| `parentIssueBody` | `string` | Step 1 で取得した親Issue本文全文のみ（機能仕様ドキュメントの内容は含めない） |
| `codebaseAnalysis` | `[{path, role}]` | Step 2 で作成した「パス＋1行の役割」の圧縮リスト |
| `acceptanceCriteria` | `{issue, criteria: [{id, text, checked}], parse_status}` | Step 3-1 の `extract-acceptance-criteria.sh` 出力（またはフォールバック抽出結果） |

#### 3-4. 結果の取得と分解計画の提示

Workflow の返り値（`{tasks: [{title, summary, files, depends_on, acceptance_criteria_covered}], meta: {candidates, finalCoverage, finalGraphMetrics, judgeRounds, converged}}`）を受け取る。`depends_on` は `tasks` 配列のインデックス参照（0始まり）のため、提示用テーブルでは `#` 列（インデックス+1）に対応付けて表示する。

`meta.converged` が `false` の場合、`meta.finalCoverage.uncovered`（未割当の受入基準）・`meta.finalCoverage.hallucinated`（幻覚ID）が残っている旨をユーザーに明示し、承認前に注意喚起する（機械的な網羅検証が上限内で解決しなかったことを隠さない）。

実装タスク一覧と依存関係を提示してユーザーに確認（**この確認は Workflow の外・本ステップで完結させる人間ゲート**。Workflow 自体には対話的な承認ゲートを挟む手段が無いため）:

```text
## 実装タスク分解計画

| # | タスク名 | 依存 | 概要 | 対応する受入基準 |
|---|---------|------|------|------------------|
| 1 | {タスク名} | - | {概要} | {acceptance_criteria_coveredのid一覧} |
| 2 | {タスク名} | 1 | {概要} | {acceptance_criteria_coveredのid一覧} |

（`meta.converged` が false の場合のみ）
> 注意: 以下の受入基準は自動検証（judge再実行 {meta.judgeRounds}ラウンド実施）でも割当が確定しませんでした。承認前にご確認ください。
> - 未割当: {uncoveredの一覧}
> - 存在しないID参照: {hallucinatedの一覧}

この粒度で Issue を作成してよろしいですか？
```

### Step 4: 実装チケットの一括作成

承認後、テンプレート `${CLAUDE_PLUGIN_ROOT}/skills/create-ticket/templates/implementation-ticket.md` を読み込み、各タスクごとに Issue を作成する。

各 Issue 本文に必ず含める:

- `Parent: #{親Issue番号}`
- 依存先がある場合: `依存: #{番号}` を「依存チケット」セクションに記述
- 親要件チケットの「クリティカル設計決定」「機能全体の設計」セクションへの参照（機能仕様ドキュメント `docs/features/{slug}.md` へのリンク）
- **`--base` 指定時のみ**: `Base: {統合ブランチ}`（例 `Base: feat/issue-42`）を本文冒頭付近に記録する。`/para-impl` はこの行を読み取り、サブタスク PR の base を統合ブランチにする

```bash
gh issue create \
  --title "{タスク名}" \
  --body "$(cat ticket-body.md)" \
  --label "implementation"
```

GitHub Sub-issue 機能が使えるなら `gh api` で親へ紐付ける（`/repos/{owner}/{repo}/issues/{N}/sub_issues`）。

### Step 5: 完了報告（実装分解モード）

```text
## 実装チケット作成 完了

- 親要件チケット: #{親番号}
- 実装チケット: #{番号1}, #{番号2}, ...（{N}件）
- 依存関係:
  - #{番号2} ← #{番号1}
  - #{番号3} ← #{番号1}, #{番号2}

次のステップ:
# 並列実装
/para-impl {番号1} {番号2} {番号3}
```

`--base` を指定した場合は、統合ブランチを引き継いで案内する:

```text
- 統合ブランチ（base）: {統合ブランチ}

次のステップ:
# 統合ブランチが未作成なら先に作成（既定ブランチから分岐）
DEFAULT_BRANCH=$(gh repo view --json defaultBranchRef -q '.defaultBranchRef.name')  # 通常 main
git fetch origin "$DEFAULT_BRANCH"
git checkout -b {統合ブランチ} "origin/$DEFAULT_BRANCH" && git push -u origin {統合ブランチ}

# 並列実装（サブタスク PR の base は統合ブランチ）
/para-impl {番号1} {番号2} {番号3} --base {統合ブランチ}
```

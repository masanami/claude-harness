---
name: self-review
description: "コード変更のセルフレビューを実施する。Triggers on: '/self-review', 'セルフレビュー', 'self-review', 'コードレビューして'"
# effort: 深い検討は委譲先レビュー agent（code-reviewer/design-reviewer=xhigh）側で効くため、本スキルは session 継承（無指定）とする。
---

# Self Review

現在のブランチの変更差分に対してセルフレビューを実施します。並列レビュー・敵対的検証・修正の反復ループは、実行文脈が許せば Dynamic Workflows（`skills/self-review/scripts/self-review-loop.js`）に委ね、あなたは Workflow の起動とその結果の報告に専念します。Workflow が利用できない実行文脈（後述）では、同じ構造を Task ツールによる直接委譲で再現する縮退手順を用います。

## 手順

### 実行文脈の判定

自分が使えるツール一覧に `Workflow` が含まれているかどうかで、現在のセッションで Workflow ツールが利用可能かを判定する。含まれる場合は以下の Step 1（Workflow の起動）に進み、含まれない場合（サブエージェント内実行。例: `feature-implementer` から呼ばれた場合）は「Workflow が利用できない実行文脈での縮退手順」に進む。

### Step 1: Workflow の起動

#### 1-1. Workflow スクリプトについて

並列レビュー（code-reviewer/design-reviewer）・敵対的検証（finding-verifier 3体・多数決）・修正反復ループは `skills/self-review/scripts/self-review-loop.js` に実装済みの Dynamic Workflow スクリプトが担う。このファイルはプラグインに同梱されており、モデルが都度書き出す・複写する必要はない（resume 時のキャッシュ安定性のため、Workflow ツールには常に同じ絶対パスをそのまま渡すこと）。

Workflow の内部構造（Collect/Review/Verify/Fix の各フェーズ・ループ制御・diff再収集の仕様）は `skills/self-review/scripts/self-review-loop.js` の冒頭コメントを正本とする。レビュー観点・懐疑的検証の反証規範・修正時の振る舞いの規律は `agents/code-reviewer.md` / `agents/design-reviewer.md` / `agents/finding-verifier.md` / `agents/feature-implementer.md` 側に置く（レイヤリング。本 SKILL には重複記載しない）。

呼び出し元の後続動作に直結する内部挙動としてここに明記する点: **Fix フェーズの修正エージェントはコミットしない**。修正内容は作業ツリーに残ったままとなる（Step 3/4 の報告・`/commit` の要否はこの前提の上で呼び出し元が判断する）。

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

> **`scriptPath` の解決について（重要）**: `<CLAUDE_PLUGIN_ROOTの絶対パス>` は本ドキュメント内の表記上のプレースホルダであり、環境変数ではない（`CLAUDE_PLUGIN_ROOT` はメインセッションの Bash でも未設定であり、環境変数として参照しても空になる）。実際の絶対パスは、本スキル起動時にコンテキストへ与えられる「Base directory for this skill」（`<プラグインルート>/skills/self-review`）から**親ディレクトリを2階層**辿ることで得られる（`<Base directory for this skill>/../..` がプラグインルート）。この絶対パスと `/skills/self-review/scripts/self-review-loop.js` を連結した文字列を `scriptPath` に渡すこと。`args.collectDiffScript` / `args.extractHunkScript` も同じ絶対パス解決が必要で、同じプラグインルートの絶対パスにそれぞれ `/scripts/collect-review-diff.sh` / `/scripts/extract-hunk.sh` を連結した文字列を渡すこと。

`args` の各フィールドの型と由来:

| フィールド | 型 | 由来 |
|---|---|---|
| `base` | `string \| null`（省略可） | 差分の基準ブランチ。省略時は `scripts/collect-review-diff.sh` 内部で `gh pr view --json baseRefName` → `gh repo view --json defaultBranchRef` の順にフォールバック解決される（`main` 決め打ちにしない）。呼び出し元が base を把握している場合（例: `/pr-merge` や `para-impl` から base が既知の場合）は明示的に渡してよい |
| `collectDiffScript` | `string`（必須） | `scripts/collect-review-diff.sh` の絶対パス。上記手順で得たプラグインルートの絶対パス＋ `/scripts/collect-review-diff.sh`。未指定だと Workflow スクリプトが早期に `throw` する |
| `extractHunkScript` | `string`（必須） | `scripts/extract-hunk.sh` の絶対パス。上記手順で得たプラグインルートの絶対パス＋ `/scripts/extract-hunk.sh`。未指定だと Workflow スクリプトが早期に `throw` する |

> **オプトイン要件について**: Dynamic Workflows はオプトイン機能であり、SKILL の指示文が明示的に Workflow を呼び出す形にすることでオプトイン要件を満たす。上記の「Workflow の起動」がそのオプトインに当たる。

> **resume 時の注意（作業ツリーはWorkflow管理外）**: 本 Workflow は毎周 `collect-review-diff.sh` で作業ツリーを含む diff を取り直す設計のため、resume（中断からの再開）時にレビュー対象の作業ツリーの状態が Workflow のチェックポイントには含まれない。resume 時は「その時点の作業ツリー」を基準に diff 再収集から始まる（resume 前後で作業ツリーの内容が変わっていれば、レビュー対象もそれに追従する）。

### Workflow が利用できない実行文脈での縮退手順

サブエージェント内（例: `feature-implementer` から呼ばれた場合）では Workflow ツール自体が実機で利用不可であることが確認されている。この場合、Step 1 の Workflow 起動は行わず、以下の手順で同じ構造（並列レビュー→懐疑的検証→修正の反復）を Task ツールの直接委譲で再現する。本セクションがこの縮退手順の正本であり、他ファイル（`agents/feature-implementer.md` 等）はここへの参照のみとする。実装の正確な参照元は `skills/self-review/scripts/self-review-loop.js`（Workflow版の実装）であり、フィールド名・enum値は同ファイルと意味的に一致させる。

#### (i) 並列レビュー

Task ツールで `code-reviewer`（`subagent_type: 'claude-harness:code-reviewer'`）と `design-reviewer`（`subagent_type: 'claude-harness:design-reviewer'`）の双方へ並列委譲する。Workflow版は `agent()` の schema オプション（`FINDINGS_SCHEMA`）で出力を検証させているが、縮退手順にはその機構が無いため、**指示文（プロンプト）で明示的に構造化返却を課す**: 各指摘を以下の形で返すよう、プロンプトに明記する。

```text
{file, line, severity: "high"|"medium"|"low", claim, evidence, verdict: "CONFIRMED"|"PLAUSIBLE"}
```

（`severity`/`verdict` はいずれも Workflow版 `FINDINGS_SCHEMA` と同一フィールド・同一 enum 値）

#### (ii) 懐疑的検証（3体多数決の縮退版）

収集した指摘のうち `severity: "high"` かつ `verdict: "PLAUSIBLE"` のものだけを対象に、`finding-verifier` **1体**への Task 委譲（`subagent_type: 'claude-harness:finding-verifier'`）で反証させる（Workflow版は3体並列・多数決だが、縮退版は1体に簡略化する）。呼び方は `agents/finding-verifier.md` の既存の呼び方をそのまま踏襲する（このファイルは編集しない）。finding-verifier が返す `confirmed`/`refuted`/`uncertain` の判定をそのまま最終判定として採用する:

- `confirmed` → 修正対象に含める
- `refuted` → 除外する（残指摘にも修正対象にも含めない）
- `uncertain` → 残指摘（人間判断対象）として扱う

`severity: "high"` 以外の指摘、および `verdict: "CONFIRMED"` の指摘は懐疑的検証をスキップし、そのまま修正対象に含める（Workflow版の `partitionFindingsForVerification` と同じ方針）。

#### (iii) 修正→再委譲の反復

確定した指摘の修正は、呼び出し元（`feature-implementer` 自身）が行う。多くの場合、呼び出し元は既に `/self-review` を実行中の同一コンテキストのまま Edit/Write で直接対応する**インライン修正**で完結し、自分自身を Task で新たに spawn する必要は無い。呼び出し元以外の実装エージェントへ委譲したい場合のみ、Task ツールで `subagent_type: 'claude-harness:feature-implementer'` としてスコープ付きで呼び出す（この場合、呼び出された側は `agents/feature-implementer.md` の再入回避の注記に従い、Phase 1〜5 を再帰的に開始しない）。

修正後、`/quality-check` を実行し、`fail` の場合はそのラウンドの指摘を残指摘として扱いループを打ち切る（Workflow版のFixステージが `/quality-check` 失敗時にループを打ち切り要人間判断として残す方針と同じ）。`fail` でなければ (i)(ii) を再度実施する。2周目以降の (i) は、前周で修正対象にした指摘の解消検証と、修正によって新たな問題が生じていないか（修正箇所周辺）の確認に限定してよい（Workflow版の2周目以降が前周の確定指摘の解消検証に限定した狭いレビューになる `confirmation` モードと同じ絞り込み）。

この反復は**最大3回**（Workflow版の `MAX_ROUNDS` と同じ上限）。周回をまたいだ指摘の重複判定（dedup）は、Workflow版と同じ方針（`(file, line)` に加えて claim を正規化（小文字化・空白圧縮・先頭64文字）した文字列も合わせたキーで、周回間の再検証・二重計上を避ける）で行う。3回反復しても残る指摘は残指摘として扱う。

#### (iv) 報告形式

Workflow版の返り値と同形の `{rounds, roundHistory, converged, residualFindings}` で結果をまとめる（各フィールドの意味は Step 2 の定義に従う）。この結果は、以下の Step 2〜4（結果の取得・報告・残指摘時の扱い）へそのままつながる（縮退手順専用の別の報告形式は作らない）。Step 2〜4 のテキストは Workflow 版・縮退版の両方に適用される共通の報告作法として扱う。

### Step 2: 結果の取得

Workflow または上記縮退手順の結果（`{rounds, roundHistory, converged, residualFindings}`）をそのまま Step 3 の報告に使う。Workflow 版は `agent()` の schema 検証により、各エージェントの出力形式が Workflow 側で既に保証されているため手動での集約・パースは不要。縮退版はあなた自身が (i)〜(iv) の手順で指摘の収集・多数決・dedup・ラウンド管理を行い、同じ形にまとめた上で Step 3 に渡す。

- `rounds`: 実施したレビュー回数（初回のフルレビュー＋再レビューの合計）
- `roundHistory`: `[{round, findingsCount}, ...]`。各周のレビューで検出された指摘件数の推移
- `converged`: `true` なら残指摘なしで収束、`false` なら自動修正ループが打ち切られ、残指摘が解消しないまま終了した（上限3周への到達に限らず、要人間判断の指摘が残った場合や、修正後の `/quality-check` が `fail` になり打ち切った場合を含む）
- `residualFindings`: 収束しなかった場合に残る指摘（要人間判断の指摘、3周経っても解消しなかった指摘、または `/quality-check` 失敗により打ち切られた指摘）。修正済み指摘の中間履歴（どの指摘がいつ confirmed になり修正されたか）は含まれない

### Step 3: 結果の報告

以下の形式で報告する。**Step 4（旧: 「問題がある場合」の修正指示）は本 Workflow 化により位置づけが変わっている**: 従来は「報告 → 人間/呼び出し元が修正を指示 → 再レビュー」というループをモデル判断で回していたが、Workflow 化後は修正と再レビューは Step 1 の Workflow、または「Workflow が利用できない実行文脈での縮退手順」内で完結済みであり、Step 3 はその**収束後の残件報告**に専念する（Workflow または縮退手順に委ねた修正ループを、報告後に呼び出し元が再び手動で回す必要はない）。

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

`converged: false` の場合、`residualFindings` を上記の表で提示し、ユーザーに次の対応（手動修正・追加のコンテキスト提供の上で再度 `/self-review` を実行・許容してこのまま進める等）を確認する。**Workflow または縮退手順内の自動修正ループは打ち切り済み（上限3周への到達に限らず、要人間判断の指摘が残った場合や修正後の `/quality-check` が `fail` になった場合も含む）のため、ここから先の対応はユーザー判断に委ねる**（無限に自動修正を試み続けない）。

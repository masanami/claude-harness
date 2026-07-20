# プラグイン内ファイル参照のパス規約

本プラグイン（`skills/` `agents/` `scripts/`）は配布先プロジェクトにインストールされて動く。プラグイン自身のファイル（スクリプト・テンプレート・参照ドキュメント）への参照は、**導入先プロジェクトのファイルと混同されない形**で解決しなければならない。cwd 起点の裸の相対パス（例: `scripts/foo.sh`）は、導入先プロジェクトに同名のディレクトリ・ファイルが存在する場合に誤読・実行不能を起こす。

本文書はパス参照メカニズムごとの規約を1箇所に集約する正本。`scripts/README.md` は scripts/ 配下の実装規約（jq前提・出力規約・テスト方針等）のみを扱い、プラグイン内ファイル参照のパス解決はここを参照する。

## `${CLAUDE_PLUGIN_ROOT}` の位置づけ（重要）

`skills/` `agents/` の文中に現れる `${CLAUDE_PLUGIN_ROOT}` は**プラグインルートの絶対パスを表すプレースホルダ表記**であり、Bash の環境変数ではない。

> **検証済み事実（2026-07-18 実機検証）**: メインセッション・サブエージェントのいずれの Bash 環境でも `echo "$CLAUDE_PLUGIN_ROOT"`（およびデフォルト値付きの `echo "${CLAUDE_PLUGIN_ROOT:-UNSET}"`）は空／`UNSET` を返した。**`${CLAUDE_PLUGIN_ROOT}` を shell 変数として読み出す手順は成立しない。**

環境変数として実際に展開されるのは、`hooks/hooks.json` 等**ハーネスが置換する設定ファイル内の文脈のみ**（本文書が扱うパス参照規約の対象外。`hooks/hooks.json` の既存記述は変更不要）。skills/ agents/ 内で絶対パスが必要な場合は、Bash で値を読み出そうとせず、後述のとおり**スキル起動時にコンテキストへ与えられる「Base directory for this skill」から文字列操作で導出する**。

---

## (a) Bash 実行

スクリプトを Bash ツールで実行する場合、必ず絶対パスへ展開したうえで**引用符必須**で参照する。

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/xxx.sh" <引数>
```

- cwd 起点の相対パス（`scripts/xxx.sh`）では呼び出さない（導入先プロジェクトの同名パスと衝突しうる／cwd がプラグインルートである保証がない）
- パスに空白を含む環境でも壊れないよう、引用符を省略しない
- 値を Bash で読み出す（`echo "$CLAUDE_PLUGIN_ROOT"` 等）手順は上記のとおり成立しないため行わない

### 定型の所在注記（コピー用）

各 SKILL.md でスクリプトを初めて実行する箇所には、以下の定型文を配置する（スクリプト名・引数は該当箇所に合わせて置き換える）:

```text
> **スクリプトの所在（重要）**: 本スキルはプラグインとして配布されるため、スクリプトは**ユーザーのプロジェクトroot ではなく、プラグイン配下**にある。スクリプトを実行する際は必ず `bash "${CLAUDE_PLUGIN_ROOT}/scripts/xxx.sh" <引数>` の形式（`${CLAUDE_PLUGIN_ROOT}` は表記上のプレースホルダであり環境変数ではない。実行前に、スキル起動時の「Base directory for this skill」から解決したプラグインルートの絶対パスに置換して実行する）を用い、相対パス `scripts/xxx.sh` では呼び出さないこと。
<!-- 正本: docs/plugin-path-conventions.md -->
```

## (b) Workflow ツールの `scriptPath` / `args`

Workflow ツールに渡す `scriptPath` 等の引数は、Bash ツールと違い**プレースホルダの展開が行われない**。文字列 `${CLAUDE_PLUGIN_ROOT}` をそのまま渡しても展開されず、存在しないパスとしてエラーになる。

- スキル起動時にコンテキストへ与えられる**「Base directory for this skill」**（例: `<プラグインルート>/skills/<スキル名>`）から、末尾の `/skills/<スキル名>` を取り除いてプラグインルートの絶対パスを得る（文字列操作のみで完結し、Bash 実行は不要）
- 得られた絶対パスと相対部分（例: `/skills/xxx/scripts/yyy.js`）を連結した文字列を `scriptPath` に渡す
- resume 安定性のため、同一セッション内では常に同一の絶対パスをそのまま渡す（都度再計算して微妙に異なる文字列にしない）

**`scriptPath` が指すスクリプト本文に `export` を書かない（重要）**: Workflow ランタイムは `export const meta = {...}` のみを特別扱いして解析し、それ以外の本文は通常の ES モジュールとしてではなく**async 関数の本体**として実行する（`export default async function (...) { ... }` のようなラッパーは非対応）。本文に `export const meta` 以外の `export` が1つでも残っていると、起動時に `SyntaxError: Unexpected keyword 'export'` で失敗する（実機確認済み。Issue #89）。`scripts/tests/test-path-conventions.sh` がこの制約を再発防止として機械的に検査する。

## (c) Read ツールで参照する `references/` `templates/` `scripts/README.md`

Read ツールも Bash ツールと同様、パス文字列中の `${CLAUDE_PLUGIN_ROOT}` を展開しない。以下の手順で解決する:

1. **スキル起動時にコンテキストへ与えられる「Base directory for this skill」を起点に絶対パスを組み立てる**（例: `<base>/references/xxx.md`）。スキル自身の `references/` `templates/` はこの方式で解決できる
2. スキル外のファイル（例: `scripts/README.md`）は `<base>/../../scripts/README.md` のように相対階層で辿る

Base directory はスキル起動時に必ずコンテキストへ与えられるため、これが唯一の解決手順であり、Bash による読み出しへのフォールバックは無い（前掲のとおり成立しないため）。

### 定型の所在注記（コピー用）

```text
> **参照ファイルの所在（重要）**: 参照ファイルは導入先プロジェクトではなく**プラグイン配下**にある。Read する際は、スキル起動時にコンテキストへ与えられる「Base directory for this skill」を起点に絶対パスを解決する（例: `<base>/references/xxx.md`）。
<!-- 正本: docs/plugin-path-conventions.md -->
```

## (d) サブエージェントへの受け渡し

エージェント定義（`agents/*.md`）に `${CLAUDE_PLUGIN_ROOT}` への依存を書かない。サブエージェントは呼び出し側（リード）とは別コンテキストで起動され、`${CLAUDE_PLUGIN_ROOT}` が展開される保証がない。呼び出し側が**解決済みの絶対パス**を spawn プロンプト・args に明示的に渡す（模範実装: `ticket-worker` への `ci-wait.sh` 絶対パスの受け渡し。`agents/ticket-worker.md`）。

> **検証済み事実（2026-07-18 実機検証）**: Task ツールで spawn した汎用サブエージェント（general-purpose）の Bash 環境で `echo "${CLAUDE_PLUGIN_ROOT:-UNSET}"` を実行した結果は `UNSET` だった。**メインセッションの Bash 環境で同様に検証した結果も `UNSET` だった**（前掲「`${CLAUDE_PLUGIN_ROOT}` の位置づけ」節参照）。**Bash 環境で `${CLAUDE_PLUGIN_ROOT}` が変数として設定されている保証はどのコンテキストにも無い**ことが確認済み。このため、サブエージェントにプラグイン内ファイルへのアクセスをさせる場合は、呼び出し側が解決済みの絶対パスを渡すことが**必須**であり、サブエージェント側で `${CLAUDE_PLUGIN_ROOT}` を再展開しようとする実装は成立しない前提で設計すること。

## (e) スクリプト間の同梱参照

スクリプトが同梱の別ファイル（同一ディレクトリ内の別スクリプト等）を参照する場合は `${CLAUDE_PLUGIN_ROOT}` に依存せず、自スクリプトの位置から自己解決する:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
```

- 変数名はスクリプト固有にする（`scripts/tests/` で `source` する際に他スクリプトの同名グローバル変数と衝突させないため。詳細は `scripts/README.md`「テスト」節）

## (g) `agentType` / `subagent_type` のプラグイン名前空間プレフィックス

サブエージェントを識別する文字列（Task ツールの `subagent_type`、Dynamic Workflow の `agent()` に渡す `agentType`）は、いずれも**プラグイン名前空間プレフィックス付き**（`claude-harness:` + `agents/*.md` の `name:` フロントマター値。例: `claude-harness:feature-implementer`）で指定する。プレフィックス無しの裸の名前（例: `feature-implementer`）は名称解決エラーになる。

> **検証済み事実（Issue #41 実機プローブ）**: サブエージェントから Task ツールで別のサブエージェントを spawn する際、`subagent_type` にプレフィックス無しの `feature-implementer` を指定すると名称解決エラーになることを確認済み（`agents/ticket-worker.md` の委譲記述、コミット a1b5196 参照）。Dynamic Workflow の `agent()` が受け取る `agentType` も同じサブエージェント名前解決の仕組みを用いるため、同様にプレフィックス付き指定が必要（`skills/explain-e2e/scripts/explain-e2e-verify.js` 等で採用）。

- Dynamic Workflow スクリプト（`skills/*/scripts/*.js`）が `agent(prompt, { agentType: '...' })` を呼ぶ箇所は、必ず `'claude-harness:<agents/*.mdのname>'` の形式にする
- `agents/*.md` 本文中で自身の `agentType` 呼び出され方を自己記述する箇所（`description:` フロントマターや Step 記述）も、同じプレフィックス付き表記に揃える（実際の呼び出しコードと表記が食い違うとドキュメントとして信頼できなくなるため）
- 新しい Dynamic Workflow スクリプトやサブエージェントを追加する際も、この規約に従う

## (h) Workflow スクリプトへ渡す `args` の JSON 文字列正規化

Dynamic Workflow スクリプト（`skills/*/scripts/*.js`）の本文が受け取る `args` パラメータは、呼び出し環境によっては**JSON文字列として届くことがある**。オブジェクトとして直接渡ってくる前提で `const { foo } = args;` のように分割代入すると、文字列が渡ってきた場合に `foo` が常に `undefined` になり、必須引数の欠落として実行時エラーになる、あるいは黙って空扱いされる。

> **検証済み事実（Issue #91 実機フォローアップ）**: Dynamic Workflow スクリプトの `args` が文字列として渡るケースが実機で確認された（当時の観測対象は self-review 用の Workflow スクリプトだったが、#107 で self-review は Dynamic Workflow を廃止したため、この現象自体は残存する他の Workflow スクリプトに一般化して適用する）。

- スクリプト冒頭で `resolvedArgs` 正規化パターンを必ず適用する（模範実装: `skills/explain-e2e/scripts/explain-e2e-verify.js` の `resolvedArgs`）:
  - `typeof args === 'string'` なら `JSON.parse(args)` を試みる
  - パースに失敗した場合は**空オブジェクトへフォールバックせず**、明示的に `throw new Error(...)` する（必須引数の欠落を握りつぶさないため）
  - それ以外（オブジェクト）の場合は `args || {}` をそのまま使う
- 以降の分割代入は `args` ではなく `resolvedArgs` から行う

## (i) `agent()` の `schema` オプションはトップレベル `object` 必須

Dynamic Workflow スクリプトが `agent(prompt, { schema, ... })` に渡す JSON Schema は、API 側で `input_schema` として実体化される制約により、**最上位の `type` が `object` でなければならない**。`type: 'array'` をトップレベルに置くと 400 エラーになる。

> **検証済み事実（Issue #91 実機フォローアップ）**: `agent()` の `schema` オプションにトップレベル `type: 'array'` を渡すと 400 エラーになることが実機で確認された。

- 配列そのものを返したい場合は、1プロパティ（例: `findings` / `verdicts`）へラップした `{ type: 'object', additionalProperties: false, required: [...], properties: { <フィールド名>: { type: 'array', items: {...} } } }` 形の schema にする
- 受け側コードも合わせて戻り値を配列としてではなく `{ <フィールド名>: [...] }` として受け取る（例: `const output = await agent(...); const findings = output.findings;` であり、`const findings = await agent(...);` ではない）点に注意する

## (j) エージェントの terminal 失敗（`agent()` が `null` を返す）の扱い

`agent()` はサブエージェントの terminal 失敗時に `null` を返す。この `null` を `filter(Boolean)` や `Array.isArray(x) ? x : []` 等で静かに「空」として扱うと、実際にはそのステージが未実施であるにもかかわらず「指摘0件」「タスク0件」等として集計され、**偽の収束報告**になる。

> **検証済み事実（Issue #91 実機フォローアップ）**: self-review 用の Workflow スクリプト（#107 で廃止済み）のレビュアー呼び出しで、レビュアー2体が terminal 失敗しても null を「指摘ゼロ」として集計すると `converged: true` を報告してしまう実例が実機確認された。この事実に基づき、同種の構造（fan-out したエージェントの出力が収束・完全性判定の入力になる設計）を持つ懐疑者・スキャナー・レンズ批評・分解案生成の各呼び出しにも、同じ握りつぶし防止方針を予防的に適用している。`/self-review`（Task 委譲版）自身も Step 2 のレビュアー呼び出しでこの方針を踏襲する（`skills/self-review/SKILL.md` Step 2 参照）。

方針は null の性質によって使い分ける:

- **収束・完全性の判定に関わる null**（レビュアー・批評レンズ・分解案生成・judge 等。そのステージの出力が欠けると全体の収束判定自体が信頼できなくなるもの）は**明示 throw** する
- **部分結果が有用な null**（fan-out したスキャンバケットの一部・懐疑者の一部。他の並列項目の結果は引き続き有用なもの）は、結果 JSON に明示フィールド（`meta.failedBuckets` / `finding.failed_verifiers` 等）で可視化し、残りの結果は握りつぶさずそのまま返す

## (f) 実行時ファイルから docs/ 設計文書への参照禁止

`skills/` と `agents/`（実行時にモデルへロードされるファイル）から、`docs/` 配下の設計文書（ADR・戦略文書・経緯記録。本文書 `docs/plugin-path-conventions.md` 自身を含む）を参照しない。

- **規範（何をすべきか）は実行時ファイルに インラインで書き切る**。出典・経緯（なぜそうなのか）は書かない — ADR 等の経緯情報は実行時には不要で、参照が残るとモデルが読みに行きコンテキストを浪費する
- 参照の方向は **docs → skills の一方向のみ許可**（設計文書が実装を指すのは可、逆は不可）
- 複数スキルが共有すべき実行時コンテンツが生じた場合は、`docs/` ではなく `skills/` 内の共通配置（例: `skills/_shared/` や各 skill の `references/`）に置く
- 本文書（`docs/plugin-path-conventions.md`）を実行時ファイルから示す場合も、装飾的な出典として文中に埋め込まない。開発者向けの1行コメントとして **HTML コメントで残す**（実行時のモデルはコメントを読みに行かない）:

  ```text
  <!-- 正本: docs/plugin-path-conventions.md -->
  ```

  このコメントは「この定型文の正本がどこにあるか」を人間の開発者が追えるようにするための目印であり、規範そのものは常にコメントの直前に**インラインで書き切る**（コメントを読まないと規範が分からない状態にしない）。

## (k) 実行文脈ごとのツール可用性マトリクス

実行文脈（メインセッション／Task ツールで spawn されたサブエージェント／Dynamic Workflow の `agent()` で spawn されたエージェント）によって、利用できるツールの組み合わせが異なる。Workflow・Task・Skill・Bash の可用性は以下のとおり（2026-07-20 実機検証済み。Issue #45）:

| 文脈 | Workflow | Task | Skill | Bash |
|---|---|---|---|---|
| メインセッション | ✅ | ✅ | ✅ | ✅ |
| Task-spawned サブエージェント | ❌ | ✅（3〜4段実証） | ✅ | ✅ |
| Workflow-spawned エージェント | ❌ | ❌ | ✅ | ✅ |

- **Workflow-spawned エージェントは Task ツールを使えない**（frontmatter の `tools:` 宣言に Task を含めていても与えられない）。これは Dynamic Workflow スクリプト（`skills/*/scripts/*.js`）から `agent()` 経由で起動されるエージェントすべてに当てはまる制約であり、「サブエージェントが内部でさらに Task 委譲する」設計は Workflow 文脈では成立しない
- **`workflow()` による子 Workflow 合成は成立する**（親→子起動・子への `args` 受け渡し・子 Workflow からの `agent()` spawn まで動作確認済み）。Task 委譲が使えない Workflow 文脈で、既存の Workflow スクリプト（例: `skills/explain-e2e/scripts/explain-e2e-verify.js`）が実装するステージ構成を再利用したい場合、独立ステージへの分解（`agentType` を直接呼ぶ）または子 Workflow 合成のいずれかで吸収する
- **Workflow-spawned エージェントも Skill ツールは使える**（例: `/quality-check` の呼び出し）。判断を伴わないシェル実行は `agentType: 'claude-harness:git-ops'`（Bash のみ）に委譲し、Skill 経由の定型処理（品質ゲート等）はそのまま呼び出してよい
- スキル・サブエージェントが「Workflow が使える文脈」「使えない文脈」の両方から呼ばれうる場合、実行文脈の検知（自分が使えるツール一覧に Task または Workflow が含まれるかを見る）と、文脈に応じた経路の切り替えを明記する。ただし単一スキルが常に Task 委譲のみで完結できる設計（`/self-review` が #107 でこの形に移行済み。`skills/self-review/SKILL.md`）であれば、そもそも実行文脈の判定・分岐自体が不要になる。分岐を残す場合と無くす場合のどちらが妥当かは、そのスキルの全呼び出し経路がいずれも Task ベースの手順で表現しきれるかどうかで判断する

---

## 再発防止テスト

`scripts/tests/test-path-conventions.sh` が `skills/` `agents/` に対して以下を grep ベースで検査する:

- 裸の `scripts/` 参照（`${CLAUDE_PLUGIN_ROOT}` も `<base>` も `SCRIPT_DIR` 自己解決も伴わない bash 実行）
- `docs/` 配下の設計文書への参照（HTML コメント内は除外）
- 成立しない `echo "$CLAUDE_PLUGIN_ROOT"` 解決手順の再出現
- `skills/*/scripts/*.js` の `agentType: '...'` および `agents/*.md` の自己記述が `claude-harness:` プレフィックス付きであること（(g) の規約）
- `skills/*/scripts/*.js` に、引用符に直接続くハードコードされた `scripts/` 相対パス文字列リテラルが無いこと
- `skills/*/scripts/*.js`（Workflow スクリプト）の `export` 宣言が `export const meta` の1件のみであること（前掲の Workflow ランタイム契約）
- 「実行時に（プラグインルートへ）展開される」等、`${CLAUDE_PLUGIN_ROOT}` が環境変数として自動展開されるかのような誤説明の再出現が無いこと（正: 表記上のプレースホルダであり、実行前に Base directory から解決した絶対パスへ置換する）

既知の許容パターンはテストファイル内でホワイトリストとして管理する。

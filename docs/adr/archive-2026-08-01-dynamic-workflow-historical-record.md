# Dynamic Workflow 実機検証記録（アーカイブ）

- **種別**: 実機検証記録のアーカイブ（意思決定記録ではない。現行の実装ガイダンスでもない）
- **日付**: 2026-08-01（移設）
- **関連**: GitHub Issue #106（Dynamic Workflow 全廃）, #126（本移設）

> これは全廃済み Dynamic Workflow の実機検証記録のアーカイブであり、**現行の実装ガイダンスではない**。Dynamic Workflow は Issue #106 で全廃済み（全スキルが Task ツールによる直接委譲に統一済み）。本ファイルは `docs/plugin-path-conventions.md` に残っていた Workflow ランタイム固有セクションを、Issue #126 により歴史的記録として本アーカイブへ移設したものである。

以下は移設時点（`docs/plugin-path-conventions.md` 旧 (b)(h)(i)(j)(k) 節）の内容をベースに、実機検証済みの事実として参照価値がある部分を保存したものである。移設に伴い、廃止状況を示す注記の追加や時制の調整など軽微な編集を加えている（原文は base commit `5ce6954` 時点の `docs/plugin-path-conventions.md` を参照）。

## (b) Workflow ツールの `scriptPath` / `args`

Workflow ツールに渡す `scriptPath` 等の引数は、Bash ツールと違い**プレースホルダの展開が行われない**。文字列 `${CLAUDE_PLUGIN_ROOT}` をそのまま渡しても展開されず、存在しないパスとしてエラーになる。

- スキル起動時にコンテキストへ与えられる**「Base directory for this skill」**（例: `<プラグインルート>/skills/<スキル名>`）から、末尾の `/skills/<スキル名>` を取り除いてプラグインルートの絶対パスを得る（文字列操作のみで完結し、Bash 実行は不要）
- 得られた絶対パスと相対部分（例: `/skills/xxx/scripts/yyy.js`）を連結した文字列を `scriptPath` に渡す
- resume 安定性のため、同一セッション内では常に同一の絶対パスをそのまま渡す（都度再計算して微妙に異なる文字列にしない）

**`scriptPath` が指すスクリプト本文に `export` を書かない（重要）**: Workflow ランタイムは `export const meta = {...}` のみを特別扱いして解析し、それ以外の本文は通常の ES モジュールとしてではなく**async 関数の本体**として実行する（`export default async function (...) { ... }` のようなラッパーは非対応）。本文に `export const meta` 以外の `export` が1つでも残っていると、起動時に `SyntaxError: Unexpected keyword 'export'` で失敗する（実機確認済み。Issue #89）。`scripts/tests/test-path-conventions.sh` がこの制約を再発防止として機械的に検査していた（Issue #126 で当該チェックは削除済み）。

## (h) Workflow スクリプトへ渡す `args` の JSON 文字列正規化

Dynamic Workflow スクリプト（`skills/*/scripts/*.js`）の本文が受け取る `args` パラメータは、呼び出し環境によっては**JSON文字列として届くことがある**。オブジェクトとして直接渡ってくる前提で `const { foo } = args;` のように分割代入すると、文字列が渡ってきた場合に `foo` が常に `undefined` になり、必須引数の欠落として実行時エラーになる、あるいは黙って空扱いされる。

> **検証済み事実（Issue #91 実機フォローアップ）**: Dynamic Workflow スクリプトの `args` が文字列として渡るケースが実機で確認された（当時の観測対象は self-review 用の Workflow スクリプトだったが、#107 で self-review は Dynamic Workflow を廃止したため、この現象自体は残存する他の Workflow スクリプトに一般化して適用する）。

- スクリプト冒頭で `resolvedArgs` 正規化パターンを必ず適用する:
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

> **検証済み事実（Issue #91 実機フォローアップ）**: self-review 用の Workflow スクリプト（#107 で廃止済み）のレビュアー呼び出しで、レビュアー2体が terminal 失敗しても null を「指摘ゼロ」として集計すると `converged: true` を報告してしまう実例が実機確認された。この事実に基づき、同種の構造（fan-out したエージェントの出力が収束・完全性判定の入力になる設計）を持つ懐疑者・スキャナー・レンズ批評・分解案生成の各呼び出しにも、同じ握りつぶし防止方針を予防的に適用している。

方針は null の性質によって使い分ける:

- **収束・完全性の判定に関わる null**（レビュアー・批評レンズ・分解案生成・judge 等。そのステージの出力が欠けると全体の収束判定自体が信頼できなくなるもの）は**明示 throw** する
- **部分結果が有用な null**（fan-out したスキャンバケットの一部・懐疑者の一部。他の並列項目の結果は引き続き有用なもの）は、結果 JSON に明示フィールド（`meta.failedBuckets` / `finding.failed_verifiers` 等）で可視化し、残りの結果は握りつぶさずそのまま返す

## (k) 実行文脈ごとのツール可用性マトリクス

実行文脈（メインセッション／Task ツールで spawn されたサブエージェント／Dynamic Workflow の `agent()` で spawn されたエージェント）によって、利用できるツールの組み合わせが異なる。Workflow・Task・Skill・Bash の可用性は以下のとおり（2026-07-20 実機検証済み。Issue #45）:

| 文脈 | Workflow | Task | Skill | Bash |
|---|---|---|---|---|
| メインセッション | ✅ | ✅ | ✅ | ✅ |
| Task-spawned サブエージェント | ❌ | ✅（3〜4段実証） | ✅ | ✅ |
| Workflow-spawned エージェント | ❌ | ❌ | ✅ | ✅ |

- **Workflow-spawned エージェントは Task ツールを使えない**（frontmatter の `tools:` 宣言に Task を含めていても与えられない）。これは Dynamic Workflow スクリプト（`skills/*/scripts/*.js`）から `agent()` 経由で起動されるエージェントすべてに当てはまる制約であり、「サブエージェントが内部でさらに Task 委譲する」設計は Workflow 文脈では成立しない
- **`workflow()` による子 Workflow 合成は成立する**（親→子起動・子への `args` 受け渡し・子 Workflow からの `agent()` spawn まで動作確認済み）。Task 委譲が使えない Workflow 文脈で、既存の Workflow スクリプトが実装するステージ構成を再利用したい場合、独立ステージへの分解（`agentType` を直接呼ぶ）または子 Workflow 合成のいずれかで吸収する
- **Workflow-spawned エージェントも Skill ツールは使える**（例: `/quality-check` の呼び出し）ことが確認されていた。判断を伴わないシェル実行は当時 `git-ops` エージェント（Bash のみ。#106 の全廃完了に伴い削除済み）へ委譲していた
- スキル・サブエージェントが「Workflow が使える文脈」「使えない文脈」の両方から呼ばれうる場合、実行文脈の検知（自分が使えるツール一覧に Task または Workflow が含まれるかを見る）と、文脈に応じた経路の切り替えを明記する必要があった。全廃後の現行設計では、すべてのスキルが Task 委譲のみで完結するため、この判定・分岐自体が不要になっている（`/self-review` が #107 でこの形に移行済み）。

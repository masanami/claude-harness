---
name: reduce-debt
description: "プロジェクト全体の技術負債をスキャンし、親Issueの実装範囲を基に優先度を分類する。Triggers on: '/reduce-debt', '技術負債チェック', '負債チェック'"
argument-hint: "<親Issue番号>"
model: opus
# effort: 負債の発見と優先度判断を要するため high。
effort: high
---

# 技術負債チェック指示書

**あなたは技術負債の分析を統括するリードエージェントです。**

プロジェクト全体を対象に技術負債をスキャンし、親Issueの実装範囲をコンテキストとして結果を分類・優先度付けします。スキャンと偽陽性除去（敵対的検証）は Dynamic Workflows（`.claude/workflows/reduce-debt-scan.js`）に委ね、あなたはスキャン範囲の確認・結果の報告・Issue化の承認取得に専念します。問題が見つかればユーザー確認の上、修正Issueとして起票します。

---

## 入力パラメータ

$ARGUMENTS

### パース方法

`$ARGUMENTS` を以下のルールで解釈する:

- **数値**: 親Issue番号（実装コンテキスト用）
- 例:
  - `42` → 親Issue #42 の実装コンテキストを基にプロジェクト全体をスキャン

---

## 実行手順

### Step 1: 実装コンテキストの取得

親Issueと関連PR・変更ファイルを把握する。決定的な収集処理は `${CLAUDE_PLUGIN_ROOT}/scripts/collect-impl-context.sh` に委ねる。

> **スクリプトの所在（重要）**: 本スキルはプラグインとして配布されるため、スクリプトは**ユーザーのプロジェクトroot ではなく、プラグイン配下**にある。スクリプトを実行する際は必ず `bash "${CLAUDE_PLUGIN_ROOT}/scripts/collect-impl-context.sh" <親Issue番号>` の形式（`${CLAUDE_PLUGIN_ROOT}` は実行時にプラグインルートへ展開される）を用い、相対パス `scripts/collect-impl-context.sh` では呼び出さないこと。

> **前提条件（jq 必須）**: このスクリプトは jq の存在を前提とする。jq が不在の環境では stderr にエラーメッセージとエラーJSONを出して exit 非0 になる。その場合は `gh issue view {番号} --json title,body,state,labels,number` と `gh pr view {PR番号} --json files --jq '.files[].path'` による手動収集にフォールバックしてよい。

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/collect-impl-context.sh" <親Issue番号>
```

出力JSON（`{parentIssue, childIssues, prs, changedFiles, changedDirs, unresolvedReferences, resolution_status}`）の `resolution_status` を確認する:

- `"ok"`: 子Issue・PRの参照が解決できた（PR参照が0件で `changedFiles` が空でも正常系）。`changedFiles` / `changedDirs` は Step 2 の Workflow 起動時に `args` としてそのまま使う
- `"no_references_found"` / `"unresolved_references"`: 親Issue本文からスコープを推定し、ユーザーに確認する（フォールバック）。この場合 `changedFiles` / `changedDirs` は空または不完全な可能性があるため、推定した変更範囲をユーザーに提示して補ってもらう

この情報はスキャン範囲の限定ではなく、Step 4の結果分類（今回導入 vs 既存）に使用する。

---

### Step 2: スキャン Workflow の起動

#### 2-1. スキャン範囲の確認（人間ゲート）

プロジェクトの主要ディレクトリ候補を列挙し、ユーザーに確認を得る。**この確認は Workflow 起動前に必ず行う**（Workflow 自体には対話的な人間ゲートを挟む手段が無いため、確認は Workflow の外・本ステップで完結させる）。

```bash
find . -maxdepth 2 -type d \
  -not -path './node_modules*' -not -path './.git*' -not -path './dist*' -not -path './build*' -not -path './vendor*' \
  | sort
```

候補一覧をユーザーに提示し、スキャン対象ディレクトリの確認・調整を得る。

```
## 技術負債スキャン範囲の確認

親Issue #{番号} の実装コンテキストを基に、以下のディレクトリをスキャンします。

- {ディレクトリ1}
- {ディレクトリ2}
- ...

この範囲でスキャンを開始してよろしいですか？
```

> **オプトイン要件について**: Dynamic Workflows はオプトイン機能であり、SKILL の指示文が明示的に Workflow を呼び出す形にすることでオプトイン要件を満たす。以下の「Workflow スクリプトの配置」「Workflow の起動」の手順そのものが、そのオプトインに当たる。

#### 2-2. Workflow スクリプトの配置

下記のコードブロックの内容を**そのまま**プロジェクト側の `.claude/workflows/reduce-debt-scan.js` に書き出す。resume 時のキャッシュ安定性のため、モデルはこのスクリプト本文を都度生成・改変せず、固定テンプレートとして扱うこと（可変なのは `args` のみ）。

```javascript
export const meta = {
  name: 'reduce-debt-scan',
  description: 'Scans assigned directories for technical debt and adversarially verifies medium/high severity findings via 3-way majority vote before reporting.',
  phases: [
    { title: 'Scan' },
    { title: 'Verify' },
  ],
};

// --- 定数（fan-out・多数決の上限。総エージェント数の青天井化を防ぐ） ---

const MAX_BUCKETS = 10; // 同時実行スロット目安に合わせたバケット上限
const VERIFY_BATCH_SIZE = 5; // 懐疑者1体あたりに渡す同一ファイル内の検出項目数の上限
const MAX_TOTAL_AGENTS = 1000; // 1run あたりの総エージェント数上限（scan + verify 合算）
const VERIFIER_COUNT = 3; // 多数決のための懐疑者数（同数回避のため固定で3）

const CATEGORIES = ['code_quality', 'dependencies', 'design', 'tests', 'documentation', 'performance'];

// --- JSON Schema（agent() の schema オプションに渡す。出力検証・自動リトライに使われる） ---

const SCAN_SCHEMA = {
  type: 'array',
  items: {
    type: 'object',
    additionalProperties: false,
    properties: {
      file: { type: 'string' },
      summary: { type: 'string' },
      detail: { type: 'string' },
      severity: { type: 'string', enum: ['high', 'medium', 'low'] },
      category: { type: 'string', enum: CATEGORIES },
    },
    required: ['file', 'summary', 'detail', 'severity', 'category'],
  },
};

const VERIFY_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    verdicts: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          file: { type: 'string' },
          findingIndex: { type: 'integer' },
          verdict: { type: 'string', enum: ['confirmed', 'refuted', 'uncertain'] },
          reason: { type: 'string' },
          severity_adjustment: { type: 'string' },
        },
        required: ['file', 'findingIndex', 'verdict', 'reason'],
      },
    },
  },
  required: ['verdicts'],
};

// --- 純粋関数群（非決定的呼び出し Date.now()/Math.random() は使わない） ---

// 確認済みディレクトリ一覧を、fan-out 上限（MAX_BUCKETS）内に収まるようバケットへ分割する。
// ディレクトリ数が上限以下ならディレクトリ1個 = バケット1個。上限超過時は均等にまとめる。
function planScanBuckets(directories) {
  const dirs = Array.from(new Set(directories)).sort();
  if (dirs.length === 0) return [];
  if (dirs.length <= MAX_BUCKETS) {
    return dirs.map((d) => ({ id: d, directories: [d] }));
  }
  const buckets = Array.from({ length: MAX_BUCKETS }, () => []);
  dirs.forEach((d, i) => {
    buckets[i % MAX_BUCKETS].push(d);
  });
  return buckets
    .filter((b) => b.length > 0)
    .map((b, i) => ({ id: `bucket-${i + 1}`, directories: b }));
}

function chunkArray(arr, size) {
  const chunks = [];
  for (let i = 0; i < arr.length; i += size) {
    chunks.push(arr.slice(i, i + size));
  }
  return chunks;
}

// 検出項目1件が「親Issueの実装（今回導入）」か「既存の負債」かを、
// args.changedFiles / args.changedDirs との集合演算で判定する。
function isIntroducedByParent(file, changedFileSet, changedDirs) {
  if (changedFileSet.has(file)) return true;
  return changedDirs.some((dir) => dir !== '.' && (file === dir || file.startsWith(`${dir}/`)));
}

// 3体の懐疑者の verdict 配列から、1件の検出項目の最終判定を多数決で決める。
// confirmed が2票以上 -> confirmed。refuted が2票以上 -> refuted。
// それ以外（1-1-1 割れ、uncertain 過半数等）は要人間判断として扱う。
function decideVerdict(votes) {
  const counts = { confirmed: 0, refuted: 0, uncertain: 0 };
  for (const vote of votes) {
    if (Object.prototype.hasOwnProperty.call(counts, vote.verdict)) {
      counts[vote.verdict] += 1;
    }
  }
  if (counts.confirmed >= 2) return 'confirmed';
  if (counts.refuted >= 2) return 'refuted';
  return 'needs_human_judgment';
}

function buildScanPrompt(bucket) {
  return [
    '以下の担当ディレクトリ配下のみを対象に技術負債をスキャンしてください。',
    '担当ディレクトリ:',
    ...bucket.directories.map((d) => `- ${d}`),
    '',
    '指定された JSON Schema（file, summary, detail, severity, category の配列）に厳密に準拠したJSONのみを返してください。',
  ].join('\n');
}

function buildVerifyPrompt(file, batch) {
  const lines = [
    `対象ファイル: ${file}`,
    'このファイルを実際に読み、以下の検出項目それぞれについて反証を試みてください。',
    '',
  ];
  batch.forEach((finding) => {
    lines.push(`- findingIndex ${finding.findingIndex}: [${finding.severity}/${finding.category}] ${finding.summary}`);
    lines.push(`  詳細: ${finding.detail}`);
  });
  lines.push('');
  lines.push('指定された JSON Schema（verdicts 配列。file と findingIndex は入力の値をそのまま使うこと）に厳密に準拠したJSONのみを返してください。');
  return lines.join('\n');
}

export default async function ({ agent, parallel, pipeline, log, args }) {
  const {
    directories = [],
    parentIssue = null,
    changedFiles = [],
    changedDirs = [],
  } = args;

  const buckets = planScanBuckets(directories);

  const emptyResult = {
    meta: { parentIssue, scannedDirectories: directories, bucketCount: 0 },
    confirmed: [],
    needsHumanJudgment: [],
    appendix: { refuted: [], unverified: [] },
  };

  if (buckets.length === 0) {
    log('reduce-debt-scan: no directories to scan, skipping.');
    return emptyResult;
  }

  log(`reduce-debt-scan: planned ${buckets.length} bucket(s) from ${directories.length} confirmed director(y/ies).`);

  // 総エージェント数上限のガード。scanStage 側で1バケット1エージェントを消費し、
  // verifyStage 側で1バッチにつき VERIFIER_COUNT 体を消費する。
  // pipeline はアイテム単位で非同期に進行するが、この関数自体は同期的に
  // チェック&デクリメントするため（await を挟まない）競合状態は起きない。
  let remainingAgentBudget = MAX_TOTAL_AGENTS - buckets.length;

  function consumeAgentBudget(n) {
    if (remainingAgentBudget < n) return false;
    remainingAgentBudget -= n;
    return true;
  }

  async function scanStage(bucket, originalBucket, index) {
    const findings = await agent(buildScanPrompt(bucket), {
      agentType: 'debt-scanner',
      schema: SCAN_SCHEMA,
      phase: 'Scan',
      label: `scan:${bucket.id}`,
    });
    return { bucket, findings: Array.isArray(findings) ? findings : [] };
  }

  async function verifyStage(scanResult, originalBucket, index) {
    const { bucket, findings } = scanResult;

    const unverified = [];
    const toVerify = [];
    findings.forEach((finding) => {
      if (finding.severity === 'low') {
        unverified.push({ ...finding, verdict: 'unverified', votes: [], bucketId: bucket.id });
      } else {
        toVerify.push({ ...finding, bucketId: bucket.id });
      }
    });

    const byFile = new Map();
    for (const finding of toVerify) {
      if (!byFile.has(finding.file)) byFile.set(finding.file, []);
      byFile.get(finding.file).push(finding);
    }

    const verifiedFindings = [];
    for (const [file, fileFindings] of byFile) {
      for (const batch of chunkArray(fileFindings, VERIFY_BATCH_SIZE)) {
        const batchWithIndex = batch.map((finding, i) => ({ ...finding, findingIndex: i }));

        if (!consumeAgentBudget(VERIFIER_COUNT)) {
          batchWithIndex.forEach((finding) => {
            verifiedFindings.push({
              ...finding,
              verdict: 'needs_human_judgment',
              votes: [],
              reason: 'agent budget cap reached before verification',
            });
          });
          continue;
        }

        const prompt = buildVerifyPrompt(file, batchWithIndex);
        const verifierOutputs = await parallel([
          () => agent(prompt, { agentType: 'debt-verifier', schema: VERIFY_SCHEMA, phase: 'Verify', label: `verify:${bucket.id}:${file}:${index}:1` }),
          () => agent(prompt, { agentType: 'debt-verifier', schema: VERIFY_SCHEMA, phase: 'Verify', label: `verify:${bucket.id}:${file}:${index}:2` }),
          () => agent(prompt, { agentType: 'debt-verifier', schema: VERIFY_SCHEMA, phase: 'Verify', label: `verify:${bucket.id}:${file}:${index}:3` }),
        ]);

        batchWithIndex.forEach((finding, i) => {
          const votes = verifierOutputs
            .map((out) => (out.verdicts || []).find((v) => v.file === file && v.findingIndex === i))
            .filter(Boolean);
          const verdict = decideVerdict(votes);
          verifiedFindings.push({ ...finding, verdict, votes });
        });
      }
    }

    return { bucket, findings: [...verifiedFindings, ...unverified] };
  }

  const bucketResults = await pipeline(buckets, scanStage, verifyStage);

  const changedFileSet = new Set(changedFiles);
  const allFindings = bucketResults.flatMap((result) =>
    result.findings.map((finding) => ({
      ...finding,
      introducedByParent: isIntroducedByParent(finding.file, changedFileSet, changedDirs),
    })),
  );

  const confirmed = allFindings.filter((f) => f.verdict === 'confirmed');
  const needsHumanJudgment = allFindings.filter((f) => f.verdict === 'needs_human_judgment');
  const refuted = allFindings.filter((f) => f.verdict === 'refuted');
  const unverifiedLow = allFindings.filter((f) => f.verdict === 'unverified');

  return {
    meta: { parentIssue, scannedDirectories: directories, bucketCount: buckets.length },
    confirmed,
    needsHumanJudgment,
    appendix: { refuted, unverified: unverifiedLow },
  };
}
```

このスクリプトの構造:

- **fan-out（バケット分割）**: `planScanBuckets()` が確認済みディレクトリ一覧をスロット上限（`MAX_BUCKETS = 10`）内のバケットへ分割する純関数
- **`pipeline(buckets, scanStage, verifyStage)`**: バケット単位で `scanStage`（`agentType: 'debt-scanner'` によるスキャン） → `verifyStage`（懐疑者3体 `parallel` + 多数決）を**バリアなし**で流す。あるバケットが verify に進んでいる間、他のバケットはまだ scan 中でもよい
- **バッチ化**: `verifyStage` は severity: low の検出は検証をスキップして「未検証」のまま付録行きにし、high/medium はファイル単位でバッチ化（`VERIFY_BATCH_SIZE = 5`）してから懐疑者3体に渡す
- **多数決**: `decideVerdict()` が confirmed 2票以上→confirmed、refuted 2票以上→refuted、それ以外（1-1-1 割れ・uncertain 過半数等）→`needs_human_judgment` の3分類を行う
- **分類**: `isIntroducedByParent()` が `args.changedFiles` / `args.changedDirs` との集合演算で「今回導入」か「既存」かを判定する
- スキャン観点（6観点）・CLAUDE.md参照の規律、懐疑的検証の規律は、このスクリプトには書かず `agents/debt-scanner.md` / `agents/debt-verifier.md` 側に置く（レイヤリング: 規律はエージェント定義側、Workflow 側は fan-out・schema検証・多数決・集合演算という構造のみを担う）

#### 2-3. Workflow の起動

Step 2-1 で確認したディレクトリ一覧と、Step 1 で取得した `parentIssue` / `changedFiles` / `changedDirs` を `args` として Workflow を起動する:

```
args: {
  directories: [確認済みディレクトリ一覧],
  parentIssue: <親Issue番号>,
  changedFiles: [Step1で取得したchangedFiles],
  changedDirs: [Step1で取得したchangedDirs]
}
```

で `.claude/workflows/reduce-debt-scan.js` を起動する。

---

### Step 3: 結果の取得

Workflow の返り値（`{meta, confirmed, needsHumanJudgment, appendix: {refuted, unverified}}`）をそのまま Step 4 の報告に使う。手動での集約・パースは不要（`agent()` の schema 検証により、各エージェントの出力形式は Workflow 側で既に保証されている）。

---

### Step 4: 結果分類と報告

「今回の実装で導入 vs 既存」の分類は Workflow 内 JS の集合演算（`introducedByParent` フィールド）で既に行われている。リードは Workflow の返り値をそのまま次の報告フォーマットに転記する。

```markdown
## 技術負債スキャン結果

### コンテキスト
- 親Issue: #{番号} {タイトル}
- 変更範囲: {変更ディレクトリ一覧}
- スキャン範囲: {確認済みディレクトリ一覧}

### 今回の実装で導入された技術負債（confirmed かつ introducedByParent = true）

| # | 概要 | 優先度 | 観点 | 対象ファイル | 詳細 |
|---|------|--------|------|------------|------|
| 1 | {summary} | 高/中/低 | {category} | {file} | {detail} |
| ... | ... | ... | ... | ... | ... |

（なければ「検出なし」）

### 既存の技術負債（confirmed かつ introducedByParent = false）

| # | 概要 | 優先度 | 観点 | 対象ファイル | 詳細 |
|---|------|--------|------|------------|------|
| 1 | {summary} | 高/中/低 | {category} | {file} | {detail} |
| ... | ... | ... | ... | ... | ... |

（なければ「検出なし」）

### 要人間判断（懐疑者の判定が割れた項目）

<details>
<summary>クリックで展開</summary>

| # | 概要 | 優先度 | 観点 | 対象ファイル | 詳細 | 懐疑者の判定内訳 |
|---|------|--------|------|------------|------|----------------|
| 1 | {summary} | 高/中/低 | {category} | {file} | {detail} | {votes の内訳} |

</details>

### 付録（棄却・未検証）

<details>
<summary>クリックで展開</summary>

#### 反証により棄却された検出（refuted）

| # | 概要 | 対象ファイル | 棄却理由 |
|---|------|------------|---------|
| 1 | {summary} | {file} | {懐疑者のreason} |

#### 未検証（severity: low のため検証スキップ）

| # | 概要 | 対象ファイル |
|---|------|------------|
| 1 | {summary} | {file} |

</details>

### 総評
{全体的な評価}
```

優先度の基準:

| 優先度 | 基準 |
|--------|------|
| **高** | セキュリティリスク、本番障害リスク、開発速度への重大な影響 |
| **中** | 保守性の低下、テスト不足による品質リスク、DX悪化 |
| **低** | コードスタイル、軽微な重複、改善の余地がある設計 |

観点（category）の対応:

| category | 意味 |
|----------|------|
| `code_quality` | コード品質（重複コード、過度な複雑性、不適切な抽象化） |
| `dependencies` | 依存関係（不要な依存追加、既存との不整合） |
| `design` | 設計（責務の混在、不適切な結合、既存アーキテクチャとの乖離） |
| `tests` | テスト（カバレッジ不足、脆いテスト） |
| `documentation` | ドキュメント（コードと乖離したドキュメント） |
| `performance` | パフォーマンス（非効率なクエリ、N+1問題） |

---

### Step 5: 修正Issueの起票（ユーザー確認後）

技術負債が検出された場合、ユーザーにIssue化の要否を確認する。起票そのものは `${CLAUDE_PLUGIN_ROOT}/scripts/create-debt-issues.sh` に委ね、リード（あなた）は manifest の生成と粒度判断、ユーザー確認に専念する。**Issue化の対象は「今回の実装で導入された技術負債」「既存の技術負債」（confirmed）と、必要に応じて「要人間判断」の項目のうちユーザーが Issue 化を望んだもの**とする。refuted・未検証（付録）はデフォルトでは起票候補に含めない。

> **スクリプトの所在（重要）**: 本スキルはプラグインとして配布されるため、スクリプトは**ユーザーのプロジェクトroot ではなく、プラグイン配下**にある。スクリプトを実行する際は必ず `bash "${CLAUDE_PLUGIN_ROOT}/scripts/create-debt-issues.sh" <manifest.jsonファイルパス>` の形式（`${CLAUDE_PLUGIN_ROOT}` は実行時にプラグインルートへ展開される）を用い、相対パス `scripts/create-debt-issues.sh` では呼び出さないこと。

> **前提条件（jq 必須）**: このスクリプトは jq の存在を前提とする。jq が不在の環境では `check_jq` がエラーメッセージとエラーJSONを stderr に出して exit 非0 になる。その場合は本スクリプトの利用を諦め、旧来のインラインな `gh issue create --label tech-debt --title "..." --body "..."` による個別起票にフォールバックしてよい（本文には5-3に記載のテンプレート要素を手動で含めること）。

#### 5-1. manifestの生成

Step 4 の報告内容（検出結果テーブル）を基に、起票候補ごとに以下のフィールドを持つ manifest JSON（配列）を組み立てる:

```json
[
  {
    "title": "{type}: {概要}",
    "parentRef": "元の親Issue番号への参照（例: #12）、または既存負債である旨の説明",
    "targetFiles": ["対象ファイル1", "対象ファイル2"],
    "problem": "現状の問題点",
    "expectedState": "期待する改善後の状態",
    "priority": "高/中/低（任意。指定するとIssue本文に「## 優先度」セクションとして出力される。未指定ならセクション自体を省略）"
  },
  ...
]
```

> **注意**: 1Issueは1エージェントが独立して完結できる粒度にする。この粒度判断（分割すべきか・統合すべきか）は manifest 生成時にリードが行う。`${CLAUDE_PLUGIN_ROOT}/scripts/create-debt-issues.sh` は `targetFiles` 件数が閾値を超える項目に機械的な警告を付けるのみで、粒度そのものを判定・批評する役割は持たない（LLMによる粒度批評エージェントは介在しない）。

> `priority` を manifest に含める場合は、Step 4 で報告した優先度分類（高/中/低）をそのまま転記し、Issueの優先度がスキャン結果と乖離しないようにする。

#### 5-2. ユーザーによる一覧承認

生成した manifest の内容をユーザーに提示し、Issue化の要否・一覧内容の承認を得る。提示する情報は**タイトル・件数だけでなく、実際に起票される本文の実体**、すなわち各項目の `title` / `problem` / `expectedState` / `targetFiles` / `parentRef`（指定していれば `priority` も）を含めること。件数とタイトルの一覧のみを見せてユーザーが本文を確認せずに承認する、という形骸化を避けるため。**ユーザーの確認なしに次の起票ステップへ進まないこと**（禁止事項を参照）。起票候補が0件の場合はこのステップおよび5-3をスキップし、「検出された技術負債はありません」を報告して終了する。

#### 5-3. 承認後の一括起票

承認された manifest を一時ファイル（作業用スクラッチディレクトリ等）に書き出し、`${CLAUDE_PLUGIN_ROOT}/scripts/create-debt-issues.sh` を実行して一括起票する:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/create-debt-issues.sh" <manifest.jsonファイルパス>
```

このスクリプトが各項目についてテンプレートを適用して本文を組み立て、`gh issue create --label tech-debt` を実行する。子Issueの本文には以下が自動的に含まれる:
- 元の親Issue番号への参照（どの実装で導入されたか、または既存負債であること）
- 対象ファイル・モジュール
- 現状の問題点
- 期待する改善後の状態
- 優先度（`priority` を指定した場合のみ）

**exit code の扱いに注意**: スクリプトは全件成功なら exit 0、1件でも失敗（`status: "failed"`）があれば exit 1 を返すが、**いずれの場合も対応表JSONは stdout に出力される**。exit code だけで成否を判断して stdout を読み捨てないこと。**manifest の一時ファイルは、対応表を確認して再起票の要否を判断するまで削除しない**（失敗件のみの再起票 manifest を作るには元 manifest の該当 index の項目が必要なため）。

**中断時の可視化**: スクリプトは各Issue起票の直後、その結果1行（index・成否・（成功時は）issue番号・タイトル）を stderr に逐次出力する。処理が途中で中断（Ctrl-C・タイムアウト等）しても、この出力から「どこまで起票済みか」を把握できる。

> **禁止（二重起票防止）**: 部分失敗が発生した場合、再実行してよいのは**対応表の `status: "failed"` の項目だけを集めた manifest** に限る。元の manifest をそのまま丸ごと再実行すると、既に `created` 済みの項目まで `gh issue create` が再度呼ばれ、同じ内容のIssueが二重に起票される。5-4の対応表を必ず確認してから再実行対象を絞り込むこと。

#### 5-4. 対応表の報告

`${CLAUDE_PLUGIN_ROOT}/scripts/create-debt-issues.sh` は stdout に manifest の index と起票結果（issue番号・URL・成否）の対応表JSONを返す。この対応表を基にユーザーへ報告する:

- 起票成功件（`status: "created"`）: Issue番号一覧
- `targetFiles` 件数が閾値超過だった項目（`warning: "target_files_exceeds_threshold"`）: 起票済みではあるが粒度が適切か再確認したい旨を添えて明示する（一次的な粒度防御は5-1のリード判定と5-2のユーザー承認であり、この警告はあくまで機械的カウントによる事後の気付き。分割等の是正が必要な場合はリードが手動でIssueを調整する）
- 起票失敗件（`status: "failed"`）: 失敗理由（`error`）とともに報告する。失敗結果には元項目の内容ではなく `index` のみが含まれるため、**保持しておいた元 manifest から該当 index の項目のみを抽出して新しい manifest を作り、`${CLAUDE_PLUGIN_ROOT}/scripts/create-debt-issues.sh` を再実行すれば再起票できる**旨を伝える（元 manifest 全体の再実行は上記の二重起票禁止事項に反するため行わない）。再起票が完了し対応表がすべて `created` になったら、一時ファイルは削除してよい

修正の実行は `/para-impl` に委ねる。

---

## 禁止事項

- 技術負債の修正を直接実行すること（このスキルはスキャンとIssue起票のみ）
- 機能変更を技術負債として報告すること
- ユーザーの確認なしでIssueを起票すること

---

## ユーザーへの確認タイミング

以下の場合はユーザーに確認を求めてください：
- スキャン範囲の確認
- 検出した項目のIssue化の要否
- 優先度の判断に迷う場合
- 機能変更を伴う可能性がある場合

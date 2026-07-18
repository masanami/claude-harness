// reduce-debt-workflow-smoke.mjs
// skills/reduce-debt/scripts/reduce-debt-scan.js（Dynamic Workflow スクリプト）の
// 純粋関数と、default export（オーケストレーション全体）をモック経由で検証するスモークテスト。
// node が無い環境では scripts/tests/test-reduce-debt-workflow.sh 側でこのファイルの実行自体をスキップする。
//
// 実行方法: node scripts/tests/reduce-debt-workflow-smoke.mjs
// 失敗時は非0 exitし、要約を出力する（他の scripts/tests/*.sh の pass/fail 集計スタイルに合わせる）。

import {
  planScanBuckets,
  classifyParentRelation,
  decideVerdict,
} from '../../skills/reduce-debt/scripts/reduce-debt-scan.js';
import workflow from '../../skills/reduce-debt/scripts/reduce-debt-scan.js';

let passCount = 0;
let failCount = 0;
const failedTests = [];

function assertEq(description, expected, actual) {
  const expectedStr = JSON.stringify(expected);
  const actualStr = JSON.stringify(actual);
  if (expectedStr === actualStr) {
    passCount += 1;
    console.log(`  ok - ${description}`);
  } else {
    failCount += 1;
    failedTests.push(description);
    console.log(`  NG - ${description}`);
    console.log(`       expected: ${expectedStr}`);
    console.log(`       actual:   ${actualStr}`);
  }
}

// --- classifyParentRelation: 3分岐 ---
console.log('=== classifyParentRelation ===');
{
  const changedFileSet = new Set(['scripts/foo.sh']);
  const changedDirs = ['scripts'];

  assertEq(
    'ファイル完全一致 -> introducedByParent: true, relatedDir: false',
    { introducedByParent: true, relatedDir: false },
    classifyParentRelation('scripts/foo.sh', changedFileSet, changedDirs),
  );
  assertEq(
    'ディレクトリのみ一致 -> introducedByParent: false, relatedDir: true',
    { introducedByParent: false, relatedDir: true },
    classifyParentRelation('scripts/bar.sh', changedFileSet, changedDirs),
  );
  assertEq(
    'どちらも不一致 -> introducedByParent: false, relatedDir: false',
    { introducedByParent: false, relatedDir: false },
    classifyParentRelation('agents/unrelated.md', changedFileSet, changedDirs),
  );
  assertEq(
    "changedDirs に '.' が含まれてもルート直下ファイルへの過剰一致をしない",
    { introducedByParent: false, relatedDir: false },
    classifyParentRelation('README.md', changedFileSet, ['.']),
  );
}

// --- decideVerdict: 多数決 tie-break ---
console.log('=== decideVerdict ===');
{
  assertEq(
    'confirmed 2票以上 -> confirmed',
    'confirmed',
    decideVerdict([{ verdict: 'confirmed' }, { verdict: 'confirmed' }, { verdict: 'refuted' }]),
  );
  assertEq(
    'refuted 2票以上 -> refuted',
    'refuted',
    decideVerdict([{ verdict: 'refuted' }, { verdict: 'refuted' }, { verdict: 'uncertain' }]),
  );
  assertEq(
    '1-1-1割れ -> needs_human_judgment',
    'needs_human_judgment',
    decideVerdict([{ verdict: 'confirmed' }, { verdict: 'refuted' }, { verdict: 'uncertain' }]),
  );
  assertEq(
    'uncertain 過半数 -> needs_human_judgment',
    'needs_human_judgment',
    decideVerdict([{ verdict: 'uncertain' }, { verdict: 'uncertain' }, { verdict: 'confirmed' }]),
  );
}

// --- planScanBuckets: fan-out 上限 ---
console.log('=== planScanBuckets ===');
{
  assertEq('空配列 -> 空バケット', [], planScanBuckets([]));
  assertEq(
    '上限以下 -> ディレクトリ1個につきバケット1個',
    [{ id: 'a', directories: ['a'] }, { id: 'b', directories: ['b'] }],
    planScanBuckets(['b', 'a']),
  );
  const manyDirs = Array.from({ length: 23 }, (_, i) => `dir-${String(i).padStart(2, '0')}`);
  const buckets = planScanBuckets(manyDirs);
  assertEq('23ディレクトリでもバケット数はMAX_BUCKETS(10)以下', true, buckets.length <= 10);
  const totalDirsInBuckets = buckets.reduce((sum, b) => sum + b.directories.length, 0);
  assertEq('バケット分割してもディレクトリ総数は保持される', manyDirs.length, totalDirsInBuckets);
}

// --- default export: モックで scan -> verify -> 分類までのエンドツーエンド smoke ---
console.log('=== default export (mocked agent/pipeline/parallel) ===');
{
  async function mockAgent(prompt, opts) {
    if (opts.phase === 'Scan') {
      const bucketId = opts.label.replace('scan:', '');
      const fileByBucket = {
        scripts: 'scripts/foo.sh', // ファイル完全一致想定
        'skills/reduce-debt': 'skills/reduce-debt/other.md', // ディレクトリのみ一致想定
        agents: 'agents/unrelated.md', // 不一致想定
      };
      const file = fileByBucket[bucketId];
      if (!file) return [];
      return [{ file, summary: `finding in ${file}`, detail: 'detail', severity: 'low', category: 'design' }];
    }
    throw new Error('verify phase should not be reached (severity low is skipped in this smoke test)');
  }

  async function mockParallel(thunks) {
    return Promise.all(thunks.map((t) => t()));
  }

  async function mockPipeline(items, stage1, stage2) {
    const out = [];
    for (let i = 0; i < items.length; i += 1) {
      const r1 = await stage1(items[i], items[i], i);
      const r2 = await stage2(r1, items[i], i);
      out.push(r2);
    }
    return out;
  }

  const noopLog = () => {};

  const args = {
    directories: ['scripts', 'skills/reduce-debt', 'agents'],
    parentIssue: 43,
    changedFiles: ['scripts/foo.sh'],
    changedDirs: ['scripts', 'skills/reduce-debt'],
  };

  const result = await workflow({ agent: mockAgent, parallel: mockParallel, pipeline: mockPipeline, log: noopLog, args });
  const all = [...result.confirmed, ...result.needsHumanJudgment, ...result.appendix.refuted, ...result.appendix.unverified];
  const findByFile = (file) => all.find((f) => f.file === file);

  assertEq(
    'エンドツーエンド: ファイル完全一致',
    { introducedByParent: true, relatedDir: false },
    (() => {
      const f = findByFile('scripts/foo.sh');
      return f && { introducedByParent: f.introducedByParent, relatedDir: f.relatedDir };
    })(),
  );
  assertEq(
    'エンドツーエンド: ディレクトリのみ一致',
    { introducedByParent: false, relatedDir: true },
    (() => {
      const f = findByFile('skills/reduce-debt/other.md');
      return f && { introducedByParent: f.introducedByParent, relatedDir: f.relatedDir };
    })(),
  );
  assertEq(
    'エンドツーエンド: どちらも不一致',
    { introducedByParent: false, relatedDir: false },
    (() => {
      const f = findByFile('agents/unrelated.md');
      return f && { introducedByParent: f.introducedByParent, relatedDir: f.relatedDir };
    })(),
  );

  const emptyResult = await workflow({
    agent: mockAgent,
    parallel: mockParallel,
    pipeline: mockPipeline,
    log: noopLog,
    args: { directories: [], parentIssue: null, changedFiles: [], changedDirs: [] },
  });
  assertEq('空ディレクトリ入力 -> confirmed/needsHumanJudgment/appendixすべて空', true, (() => (
    emptyResult.confirmed.length === 0
    && emptyResult.needsHumanJudgment.length === 0
    && emptyResult.appendix.refuted.length === 0
    && emptyResult.appendix.unverified.length === 0
  ))());
}

console.log('');
console.log('=== summary ===');
console.log(`pass: ${passCount}, fail: ${failCount}`);

if (failCount > 0) {
  console.log('failed tests:');
  for (const t of failedTests) {
    console.log(`  - ${t}`);
  }
  process.exit(1);
}

process.exit(0);

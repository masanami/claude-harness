---
name: explain-e2e
description: "実装済みE2Eテストの「テストシナリオ解説」を生成し、解説とコードの独立検証まで行うスキル。人間はコードを読まず、解説と検証結果だけでE2Eをレビューできる。Triggers on: '/explain-e2e', 'E2Eを解説して', 'E2Eのシナリオ解説', 'E2Eを検証して'"
argument-hint: "[テストファイル|ディレクトリ|Issue/PR番号]"
model: sonnet
# effort: テスト解説が中心のため medium（Phase 2 の検証ロジック自体は Dynamic Workflow に委譲する）。
effort: medium
---

# E2Eテストシナリオ解説＋独立検証

**実装済みE2Eテスト**について、人間がコードを読まずにレビューできるよう次の2層を提供するスキル:

1. **テストシナリオ解説** — 各E2Eを自然言語で説明する（人間はこの解説を仕様と突き合わせてレビューする）
2. **独立検証** — 解説とコードの整合・アサーションの妥当性・テストの有効性を確認する（「歯の無いテスト」を捕捉する）

> **Phase 1（解説生成＋人間フィードバック）はメインセッションで対話的に実行する**（サブエージェントには委譲しない）。**Phase 2（独立検証）は Dynamic Workflow に委ねる**: 解説を書いた本人（Phase 1）と同一コンテキストでは真の独立検証にならないため、各テストファイルを新鮮コンテキストの検証エージェントに個別に渡す（fan-out）。Workflow の起動自体は Phase 1 に続けてこのスキルの手順内で行うため、呼び出し元（メインセッション）が別途何かを対話的に行う必要はない。star 型並列実装（`/para-impl` 複数Issue）では、worker（`ticket-worker`）はこのスキルを呼び出さず、worker 完了後にリードがメインセッションで起動する（`skills/para-impl/references/star-parallel.md` 参照）。

---

## 入力パラメータ

対象のE2Eテスト指定: $ARGUMENTS

| 入力形式 | 解釈 |
|---------|------|
| テストファイル/ディレクトリ | 該当テストを解説・検証 |
| Issue番号・PR番号 | 関連E2Eテストを特定して解説・検証 |
| なし | 直近の変更（`git diff`）に含まれるE2Eテストを対象 |

---

## 前提

- 対象E2Eは **`/create-e2e` で全テストパス済み**であること（Phase 1 の解説は実装が確定したテストを対象とする）
- 実行エビデンス（trace / 動画 / スクリーンショット）は **E2E実行時にトレーシングを有効化**して取得されている前提（`/create-e2e` Phase 3 の慣習）。無ければ trace 有効で再実行してから Phase 1 に進む（Phase 2 のミューテーション対象ごとの再確認は Step 0 として Workflow 内の変異エージェントが行う。下記参照）

---

## Phase 1: テストシナリオ解説の生成

実装済みE2Eテストを読み、各テストを自然言語で解説する。

```text
## E2E解説

### {テストケース名}
- 対象フロー: {どのユーザーフローを検証するか}
- 前提: {ログイン状態・テストデータ等}
- 操作手順: {主要な操作の流れ}
- 検証内容（アサーション）: {何を expect しているか}
- カバー範囲 / 非カバー範囲: {このテストが保証する範囲と、しない範囲}
```

- 解説は仕様（完了条件・受入基準）と突き合わせてレビューしてもらう（人間はコードを読まない）
- 解説はレビュー時の一時的なアウトプットであり、リポジトリに残すドキュメントではない
- 必要に応じてユーザーからフィードバックを受け、解説を磨く

---

## Phase 2: 独立検証（Dynamic Workflow）

「歯の無いテスト」（アサーションが無い・実行されない・常に真）を捕捉するため、Phase 1 で解説・確定したテストファイルごとに、次の2段階の検証を Dynamic Workflow で実施する。

### Step 2-1: Workflow の起動準備

Workflow の内部構造（Verify/Mutation の各フェーズ・バリアの位置・逐次ループの仕様）は `skills/explain-e2e/scripts/explain-e2e-verify.js` の冒頭コメントを正本とする。検証観点（解説整合・アサーション妥当性・無効化検出）の規律は `agents/e2e-explanation-verifier.md`、変異点選定の規律は `agents/e2e-mutation-injector.md` に置く（レイヤリング。本 SKILL には重複記載しない）。

`args` を次の通り組み立てる:

| フィールド | 型 | 由来 |
|---|---|---|
| `testFiles` | `[{path, explanationExcerpt}]`（必須・1件以上） | Phase 1 で解説したテストファイルごとに1件。`path` は絶対パス。`explanationExcerpt` は Phase 1 解説のうち**そのテストに関する箇所のみの抜粋**（解説全文を全検証エージェントに配らない。コンテキスト量削減のため） |
| `mutationTargets` | `[{testFile, testCommand, scopeHint, explanationExcerpt}]`（任意） | Phase 1 で解説したテストのうち、**重要フロー**（主要な正常系。目安は数件程度）のみを選び列挙する。`testFile` は `testFiles` のいずれかの `path` と一致させる。`testCommand` は「そのテストファイルのみ」を実行する解決済みシェルコマンド（`CLAUDE.md`「よく使うコマンド」のE2E実行コマンドに対象ファイルを絞り込んだもの）。`scopeHint` は変異対象の実装コードを探す手掛かりの自由記述（例: 「チェックアウトフロー、src/features/checkout/ 配下」）。`explanationExcerpt` は同じ `testFile` に対応する `testFiles[].explanationExcerpt` と同じ値を渡す（変異エージェントが変異点選定の文脈として使う。省略時は空文字列扱い）。空配列/省略時は Mutation フェーズ自体をスキップする |
| `mutationRunScript` | `string` | `mutationTargets` を1件以上指定する場合は必須。`scripts/mutation-run.sh` の絶対パス |
| `workingDirectory` | `string \| null`（任意） | **star 型並列実装でリードが当該チケットの worktree 内テストを対象に実施するケースでは必ず指定する**（当該 worktree の絶対パス）。複数 worktree が同時に存在しうるため、指定が無いと mutation-run.sh がどの worktree の `git status` を見るべきか特定できない。単一セッションでメインチェックアウトを対象にする場合は `null` でよい |

> **`scriptPath`/絶対パスの解決について**: 本スキル起動時にコンテキストへ与えられる「Base directory for this skill」（`<プラグインルート>/skills/explain-e2e`）から**親ディレクトリを2階層**辿ることでプラグインルートの絶対パスを得る（`<Base directory for this skill>/../..`）。`scriptPath` にはこの絶対パス＋ `/skills/explain-e2e/scripts/explain-e2e-verify.js` を、`args.mutationRunScript` には同じ絶対パス＋ `/scripts/mutation-run.sh` を連結した文字列を渡す。

### Step 2-2: Workflow の起動

```text
{
  scriptPath: "<CLAUDE_PLUGIN_ROOTの絶対パス>/skills/explain-e2e/scripts/explain-e2e-verify.js",
  args: {
    testFiles: [...],
    mutationTargets: [...],
    mutationRunScript: "<CLAUDE_PLUGIN_ROOTの絶対パス>/scripts/mutation-run.sh",
    workingDirectory: <star型でworktree対象の場合はその絶対パス、それ以外はnull>
  }
}
```

> **オプトイン要件について**: Dynamic Workflows はオプトイン機能であり、SKILL の指示文が明示的に Workflow を呼び出す形にすることでオプトイン要件を満たす。上記の「Workflow の起動」がそのオプトインに当たる。

### Step 2-3: 結果の取得

Workflow の返り値（`{verify, mutation, unsafeMutationResiduals}`）をそのまま Step 3（報告）に使う。手動での再判定・パースは不要（`agent()` の schema 検証により、各エージェントの出力形式は Workflow 側で既に保証されている）。

- `verify`: `[{test, explanationConsistent, assertionsMeaningful, disabled, issues, verifyFailed}]`。`verifyFailed: true` は検証エージェントの terminal 失敗（未検証。要再実行）を意味し、`explanationConsistent`/`assertionsMeaningful`/`disabled` の実際の判定結果（すべて false 等）とは区別する
- `mutation`: `[{testFile, mutatedFile, description, testFailed, failureKind, restored, rePassed, toothless, injectFailed, mutationRunFailed, exitReportMismatch, needsManualRestore, invalidTarget}]`。`toothless: true` は「変異してもテストが失敗しなかった」＝歯の無いテストの疑いを意味する。**`toothless: false` は「実際に変異を注入してテストが検出した」ことを意味するとは限らない**点に注意する: `injectFailed: true`（変異エージェントの terminal 失敗）や `mutatedFile === null`（変異エージェント自身がエビデンス不在等で注入を見送った）の場合も `toothless: false` を返す（実際にはミューテーション検証そのものが未実施）。Step 3 の報告ではこの2状態を「✅ 有効性確認済み」と区別すること（下記報告テンプレート参照）
- `unsafeMutationResiduals`: `[{testFile, mutatedFile}]`。**1件でも存在する場合は復元が確認できていない変異が残っている可能性がある**（幻覚報告・git-ops の terminal 失敗・exit code と自己申告の不一致等）。この場合は Step 3 の報告を進める前に、**必ず対象の作業ツリー（`workingDirectory` を指定した場合はそこ）で `git status` を確認し、必要なら手動で `git checkout -- <mutatedFile>` を実行する**（自動リトライはせず、確認結果を報告に明記する）

---

## 報告

```text
## E2E独立検証結果

| テスト | 解説整合 | アサーション妥当 | 有効性 | 判定 |
|-------|---------|----------------|-------|------|
| {test} | {explanationConsistent: ✅/❌} | {assertionsMeaningful: ✅/❌} | {有効性の判定は下記の優先順で1つ選ぶ: mutation対象外→「未実施（対象外）」／ injectFailed:true または mutatedFile===null（見送り）→「未実施（{description}）」／ invalidTarget:true または mutationRunFailed:true → 「⚠️要確認」／ toothless:true → ❌ ／ それ以外（実際に注入・検出できた） → ✅} | {explanationConsistent かつ assertionsMeaningful かつ verifyFailed:false かつ 有効性が「✅」または「未実施（対象外）」なら OK、それ以外（「未実施（{description}）」「⚠️要確認」「❌」を含む）は要修正} |

### 乖離・問題（あれば）
- {test}: {verify[].issues の内容。verifyFailed: true の場合は「検証エージェントが失敗（未検証）」}

### ミューテーション結果（対象だった場合）
- 実際に注入・検証できた場合: {testFile}: 注入「{description}」→ テスト {testFailed: true→失敗(良) / false→パス(問題=歯の無いテストの疑い)}（復元: {restored}・再パス: {rePassed}）
- 未実施だった場合（`injectFailed: true` または `mutatedFile === null`）: {testFile}: ミューテーション未実施（{injectFailed: true→「変異注入エージェントが失敗」/ description（見送り理由）}）。有効性は未確認のまま残っている旨を明記する

### 復元未確認の残留（unsafeMutationResiduals が空でない場合のみ・最優先で対応）
- {testFile}（{mutatedFile === null ? "対象ファイル不明（変異注入エージェントがterminal失敗し、編集有無・対象すら確認できていない）" : mutatedFile}）: 作業ツリー全体（`workingDirectory` を指定した場合はそこ）で `git status` の手動確認が必要
```

人間はこの解説（Phase 1）と検証結果（Phase 2 報告）だけを見れば、E2E実装コードを読まずにテストの信頼性を判断できる。

> **将来拡張**: ミューテーション対象を worktree 隔離で並列実行する案（対象プロジェクトが worktree 単体でE2E環境を起動でき、かつポート/DB衝突を回避できる場合の wall-clock 最適化）は本スキルのスコープ外（Issue #47 提案2）。現行は Mutation フェーズを共有ワーキングツリー上で逐次実行する設計に統一している。

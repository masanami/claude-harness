---
name: promote-verify
description: "統合ブランチ→main 昇格前に、親Issueの受入基準を全数チェックし、サブタスク完了状況・品質チェック・E2E結果をまとめた昇格前検証パッケージ（判断材料）を作成する。Triggers on: '/promote-verify', '昇格前検証', '昇格前チェック'"
argument-hint: "[親Issue番号]"
model: opus
# effort: 受入基準ごとの整合判定・懐疑的検証の結果を人間向けに整形する統括作業のため high。
effort: high
---

# 昇格前検証パッケージ

**あなたは統合ブランチ→main 昇格前検証パッケージの作成を統括するリードエージェントです。**

> **本パッケージは報告のみ・修正しません。** 人間ゲート本体（`/walkthrough` のOK/NG判断、昇格PRの承認）はこのスキルの外に残ります。本スキルの役割は、その人間ゲートの判断材料（受入基準の全数チェック済みチェックリスト・サブタスク完了状況・品質チェック/E2E結果）を決定的に揃えることだけです。

並列レビュー（doc-verifierのfan-out）・敵対的検証（finding-verifier単一懐疑者）・受入基準/コンテキスト収集は Dynamic Workflows（`skills/promote-verify/scripts/promote-verify.js`）に委ね、あなたは Workflow の起動とその結果の報告に専念します。

---

## 前提条件

- 統合ブランチが**ローカルにcheckout済み**であることを前提とします（`collect-promotion-context.sh` はref間diffのためcheckout自体は不要ですが、Quality フェーズのE2E/QC実行はcheckout済みの作業ツリーに対して行うためです）
- GitHub CLIが設定済みであること

---

## 入力パラメータ

$ARGUMENTS

### パース方法

`$ARGUMENTS` を以下のルールで解釈する:

- **数値**: 親Issue番号
- 省略時: 現在のブランチ名から `feat/issue-<N>` のようなパターンで親Issue番号の推測を試みる。推測できなければユーザーに確認する

---

## 実行手順

### Step 1: 引数解決とブランチ準備

1. 親Issue番号を上記のパース方法で確定する
2. base ブランチを解決する:
   ```bash
   BASE_BRANCH=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name)
   ```
3. 統合ブランチは**現在のブランチ名**を使う:
   ```bash
   INTEGRATION_BRANCH=$(git branch --show-current)
   ```
4. 統合ブランチを最新化する（失敗時は処理を中断し、内容をユーザーに報告する）:
   ```bash
   git fetch origin && git checkout "$INTEGRATION_BRANCH" && git pull origin "$INTEGRATION_BRANCH"
   ```

### Step 2: QC/E2Eコマンドの特定

プロジェクトの `CLAUDE.md` や `package.json` 等を読み、以下を特定する（意味理解が必要なためあなた自身が判断する。新たなサブエージェント委譲や集約エージェントは起動しない）:

- lint / 型チェック / テストコマンド（`quality-check-runner.sh` に渡す `--lint`/`--typecheck`/`--test` の値）
- 全E2Eテストを実行するコマンド（headless実行を想定。`/walkthrough` のような人間観察前提のHeaded実行は対象外）

特定できないコマンドがあれば、対応する Workflow の args は `null` にする（それぞれのフェーズが明示的にスキップされ、結果に理由が残る。暗黙にpass/trueにはならない）。

### Step 3: Workflow の起動

#### 3-1. Workflow スクリプトについて

受入基準ごとの整合判定（doc-verifier fan-out）・敵対的検証（finding-verifier単一懐疑者）・サブタスク完了確認・QC/E2E実行は `skills/promote-verify/scripts/promote-verify.js` に実装済みの Dynamic Workflow スクリプトが担う。このファイルはプラグインに同梱されており、モデルが都度書き出す・複写する必要はない（resume 時のキャッシュ安定性のため、Workflow ツールには常に同じ絶対パスをそのまま渡すこと）。

Workflow の内部構造（Context/Criteria/Verify/Quality の各フェーズ・チャンク分割・集約ロジック）は `skills/promote-verify/scripts/promote-verify.js` の冒頭コメントを正本とする。整合判定の観点そのものは `agents/doc-verifier.md`、懐疑的検証の反証規範は `agents/finding-verifier.md` 側に置く（レイヤリング。本 SKILL には重複記載しない）。

#### 3-2. Workflow の起動

> **スクリプトの所在・起動方法（重要）**: Workflow ツールに渡す `scriptPath`/`args` はプレースホルダの展開が行われない。`<CLAUDE_PLUGIN_ROOTの絶対パス>` は本ドキュメント内の表記上のプレースホルダであり環境変数ではない。実際の絶対パスは、本スキル起動時にコンテキストへ与えられる「Base directory for this skill」（`<プラグインルート>/skills/promote-verify`）から**親ディレクトリを2階層**辿ることで得る（`<Base directory for this skill>/../..` がプラグインルート）。この絶対パスと `/skills/promote-verify/scripts/promote-verify.js` を連結した文字列を `scriptPath` に渡し、`args` の各スクリプトパスも同じプラグインルートの絶対パスにそれぞれの相対パスを連結した文字列を渡す。resume 時のキャッシュ安定性のため、同一セッション内では常に同じ絶対パスをそのまま渡すこと。
<!-- 正本: docs/plugin-path-conventions.md -->

```text
{
  scriptPath: "<CLAUDE_PLUGIN_ROOTの絶対パス>/skills/promote-verify/scripts/promote-verify.js",
  args: {
    parentIssue: <Step 1で確定した親Issue番号（数値）>,
    baseBranch: <Step 1で解決したBASE_BRANCH>,
    integrationBranch: <Step 1で解決したINTEGRATION_BRANCH>,
    collectContextScript: "<CLAUDE_PLUGIN_ROOTの絶対パス>/scripts/collect-promotion-context.sh",
    checkSubtaskScript: "<CLAUDE_PLUGIN_ROOTの絶対パス>/scripts/check-subtask-completion.sh",
    extractAcceptanceCriteriaScript: "<CLAUDE_PLUGIN_ROOTの絶対パス>/scripts/extract-acceptance-criteria.sh",
    qualityCheckRunnerScript: <Step 2でlint/typecheck/testのいずれかを特定できた場合のみ "<CLAUDE_PLUGIN_ROOTの絶対パス>/scripts/quality-check-runner.sh"。1つも特定できなければ null>,
    qualityCheckArgs: <Step 2で特定したコマンドから組み立てたCLIフラグ配列（例: ["--lint","npm run lint","--typecheck","npm run typecheck","--test","npm test"]）。1つも特定できなければ null>,
    e2eCommand: <Step 2で特定したE2E実行コマンド文字列。特定できなければ null>
  }
}
```

| フィールド | 型 | 由来 |
|---|---|---|
| `parentIssue` | number（必須） | Step 1 で確定した親Issue番号 |
| `baseBranch` / `integrationBranch` | string（必須） | Step 1 で解決した値 |
| `collectContextScript` / `checkSubtaskScript` / `extractAcceptanceCriteriaScript` | string（必須） | プラグインルートの絶対パス + それぞれの相対パス |
| `qualityCheckRunnerScript` / `qualityCheckArgs` | string \| null / string[] \| null | Step 2 で特定したコマンドから組み立てる。両方揃わない場合は両方 `null` にし、Quality フェーズのQCステージを明示スキップさせる |
| `e2eCommand` | string \| null | Step 2 で特定したE2E実行コマンド。特定できなければ `null` |

> **オプトイン要件について**: Dynamic Workflows はオプトイン機能であり、SKILL の指示文が明示的に Workflow を呼び出す形にすることでオプトイン要件を満たす。上記の「Workflow の起動」がそのオプトインに当たる。

### Step 4: 結果の報告

Workflow の返り値（`{parentIssue, criteriaTable, failedCriteria, subtaskCompletion, qualityCheck, e2e, readyForPromotion}`）を、以下の形式で報告する。手動での集約・パースは不要（`agent()` の schema 検証により、各エージェントの出力形式は Workflow 側で既に保証されている）。

```text
## 昇格前検証パッケージ結果（親Issue #{parentIssue}）

### 受入基準チェックリスト

| # | 基準 | 整合状態 | 根拠 | 推奨対応 | 懐疑的検証 | 要人間精査 |
|---|------|---------|------|---------|-----------|-----------|
| {id} | {text} | {status} | {evidence} | {recommendation} | {adversarial} | {needsHumanReview ? "⚠️ あり" : "-"} |

（`failedCriteria` に1件以上ある場合は「doc-verifierの検証に失敗した基準」として別途一覧を示す）

### サブタスク完了状況

- 取得経路: {subtaskCompletion.source}
- ステータス: {subtaskCompletion.status}
- 子Issue: {subtaskCompletion.children の一覧（番号・タイトル・state・mergedPr）}
- 全サブタスクマージ済み: {subtaskCompletion.allMerged ? "✅" : "❌"}

### 品質チェック（QC）

{qualityCheck.skipped ? `⊘ スキップ（理由: ${qualityCheck.reason}）` : `${qualityCheck.result === 'pass' ? '✅ pass' : '❌ fail'}（gates: lint=${...}, typecheck=${...}, test=${...}）`}

### E2E

{e2e.skipped ? `⊘ スキップ（理由: ${e2e.reason}）` : `${e2e.passed ? '✅ pass' : '❌ fail'}: ${e2e.summary}`}

### 総合判定

readyForPromotion: {readyForPromotion ? "✅ 昇格可能な状態が揃っています" : "❌ 未充足の項目があります（上記表を参照）"}

---

**このチェックリストは判断材料の提供に留まります。`/walkthrough` の実施と昇格PRの承認は、本パッケージの外で別途人間が行ってください。**
```

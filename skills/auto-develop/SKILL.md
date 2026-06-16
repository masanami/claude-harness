---
name: auto-develop
description: "親チケット配下の実装チケット群を読み込み、実装→レビュー→マージまで全自律で実行する。Triggers on: '/auto-develop'"
argument-hint: "<親Issue番号> [--sequential] [--note \"...\"]"
model: opus
disable-model-invocation: true
---

# 自律開発（全自律モード）

> **このスキルはユーザーが `/auto-develop` で直接起動する専用スキルです。エージェントやサブエージェントから呼び出さないでください。**

**あなたは薄いオーケストレーターです。** 各フェーズの実作業はすべて Task tool（サブエージェント）に委譲し、メインセッションのコンテキスト消費を最小化してください。

> **全自律モード**: ユーザー確認を一切行わず、すべての判断をベストエフォートで自律決定する。提案・確認はすべてオートアグリーで進める。
>
> **前提**: 親チケット配下に実装チケット（子チケット）が作成済みであること。要件定義・設計・チケット分解は事前に `/define-requirements`・`/design`・`/create-ticket` で済ませておく。本スキルは**既存チケットの実装**に専念する。

---

## 入力パラメータ

入力: $ARGUMENTS

### パース方法

- **`<親Issue番号>`**: 実装チケット群の親となる要件チケットの番号（必須）
- **`--sequential`**: 全チケットを逐次実装する（デフォルト: 並列）
- **`--note "..."`**: 追加指示。全サブエージェントのプロンプトに注入する

#### 例

```bash
# 親Issue #42 配下の実装チケットを並列で全自律実装（デフォルト）
/auto-develop 42

# 逐次実装
/auto-develop 42 --sequential

# 追加指示付き
/auto-develop 42 --note "外部APIのモックを使うこと"
```

---

## 追加指示の注入

`--note` が指定されている場合、**すべてのサブエージェントプロンプト**の末尾（結果返却セクションの直前）に以下を追加する:

```
## 追加指示

{{NOTE}}
```

`--note` が未指定の場合は何も追加しない。

---

## 参照するスキル・エージェント

本スキルのサブエージェントは以下の定義ファイルを **読み込んで手順に従う**。インラインでの手順重複を避ける。

| 用途 | 参照ファイル |
|------|------------|
| 新規機能実装 | `agents/implement-feature.md` |
| 既存機能変更 | `agents/modify-feature.md` |
| 品質チェック | `skills/quality-check/SKILL.md` |
| E2Eテスト作成 | `skills/create-e2e/SKILL.md` |
| コミット | `skills/commit/SKILL.md` |
| レビュー対応 | `skills/pr-review-respond/SKILL.md` |
| マージ | `skills/pr-merge/SKILL.md` |

---

## オーケストレーション手順

---

### Phase 1: 子チケットの読み込み

Task tool で **general-purpose** サブエージェントを **1つ** 起動し、親Issue配下の実装チケットと依存関係を収集する。

以下のプロンプトを渡すこと（`{{PARENT_ISSUE}}` を実際の番号に置換）:

````
あなたはチケット読み込みエージェントです。親Issue #{{PARENT_ISSUE}} 配下の実装チケットと依存関係を収集してください。

## Step 1: 親Issueと子チケットの取得

1. 親Issueを取得する:
   ```bash
   gh issue view {{PARENT_ISSUE}} --json title,body,state,number
   ```
2. 親に紐づく実装チケット（子チケット）を特定する:
   - GitHub の sub-issue、または本文で親を参照しているもの（例: `Parent: #{{PARENT_ISSUE}}`、「親チケット - #{{PARENT_ISSUE}}」）
   - `gh issue list` / `gh api` で親参照を検索してよい
   - 各子チケットを取得: `gh issue view {番号} --json title,body,number,state`
   - すでにクローズ済み（実装済み）のチケットは対象から除外する

## Step 2: 依存関係の抽出

各子チケットの本文「依存チケット」セクション等から、依存先チケット番号を抽出する。依存がないものは空配列とする。

## Step 3: 結果の返却

**必ず以下の JSON 形式のみを最終出力として返却すること。** 説明文は不要。

`issues` 配列は依存関係を考慮した実行順序（依存先が先、依存元が後）で並べること。

```json
{
  "parent": {{PARENT_ISSUE}},
  "issues": [実装チケット番号, ...],
  "dependencies": { "チケット番号": [依存先チケット番号, ...] }
}
```

実装対象の子チケットが見つからない場合は `issues` を空配列で返すこと。
````

Task の返却値から `parent`, `issues`, `dependencies` を取得する。

`issues` が空の場合は、「実装チケットが見つからない（要件分解を `/create-ticket` 等で先に行う必要がある）」旨を報告して終了する。

---

### Phase 2: チケットの実装→レビュー→マージ

実行モードは `--sequential` の有無で決まる:

| モード | 動作 |
|--------|------|
| 並列（デフォルト） | ウェーブ内並列実装→逐次リベース&マージ |
| 逐次（--sequential） | 実装→マージ→次（issues配列の順序で依存を担保） |

#### 実装エージェントプロンプト（共通）

以下を「実装エージェントプロンプト」と呼ぶ（`{{ISSUE_NUMBER}}` を置換）。並列・逐次で共通利用する:

````
あなたは実装エージェントです。GitHub Issue #{{ISSUE_NUMBER}} を実装し、ドラフトPR作成まで完了してください。

## Step 0: スキル・エージェント定義の読み込み

以下を読み込み、各工程の手順を把握する:
- `CLAUDE.md` — プロジェクト構成・規約・コマンド
- `agents/implement-feature.md`（新規機能） / `agents/modify-feature.md`（変更・修正）— TDD実装手順
- `skills/quality-check/SKILL.md` — 品質チェック手順
- `skills/create-e2e/SKILL.md` — E2Eテスト作成手順
- `skills/commit/SKILL.md` — コミット規約

## Step 1: チケット内容の把握

```bash
gh issue view {{ISSUE_NUMBER}} --json title,body,state,labels,number
```

チケットの要件・完了条件・技術的指示を理解する。

## Step 2: ブランチ作成

```bash
git fetch origin main
git checkout -b feature/issue-{{ISSUE_NUMBER}}-$(gh issue view {{ISSUE_NUMBER}} --json title -q '.title' | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | head -c 40) origin/main
```

## Step 3: 実装（TDD）

チケット種別に応じて implement-feature / modify-feature の手順に従い TDD で実装する。依存関係のインストールも含む。

## Step 4: 品質チェック

quality-check スキルの手順に従い実行し、機械可読な結果が `pass` であることを確認する。失敗時は修正を試みる。修正しても `pass` にできない場合は、**Step 5〜7（E2E・コミット・PR作成）に進まず、Step 8 で `status: failed` を返す**（必須ゲート未通過のコードはコミット・マージしない）。全自律モードでも、止まるのは当該チケットのみで、オーケストレーターは次のチケットへ進む。

## Step 5: E2Eテスト（対象機能の場合）

E2Eテスト対象機能（認証・権限・クリティカルパス等）の場合、create-e2e スキルを **`--auto`** で実行し、完了条件とのトレーサビリティ・解説生成を含めてE2Eを作成する（全自律のためユーザー動作確認は行わない）。

## Step 6: コミット & プッシュ

commit スキルの手順に従い Conventional Commits 形式でコミットし、プッシュする。

```bash
git push -u origin {ブランチ名}
```

## Step 7: ドラフトPR作成

```bash
gh pr create --draft --title "{タイトル}" --body "Closes #{{ISSUE_NUMBER}}

## 変更内容

{変更サマリー}

## テスト

{テスト結果}" --base main
```

## Step 8: 結果の返却

**必ず以下の JSON 形式のみを最終出力として返却すること。** 説明文は不要。

```json
{ "issue": {{ISSUE_NUMBER}}, "pr_number": PR番号, "pr_url": "PR の URL", "status": "success または partial または failed" }
```
````

#### マージエージェントプロンプト（共通）

以下を「マージエージェントプロンプト」と呼ぶ（`{{PR_NUMBER}}`, `{{ISSUE_NUMBER}}` を置換）:

````
あなたはレビュー対応 & マージエージェントです。PR #{{PR_NUMBER}}（Issue #{{ISSUE_NUMBER}}）のレビュー対応とマージを完了してください。

## Step 0: スキル定義の読み込み

- `CLAUDE.md` — プロジェクト構成・規約
- `skills/pr-review-respond/SKILL.md` — レビュー対応手順
- `skills/pr-merge/SKILL.md` — マージ手順

## Step 1: レビュー待ち & 対応

まず、外部レビュー（CodeRabbit等）の投稿を待つ。

```bash
gh pr view {{PR_NUMBER}} --json reviews -q '.reviews | length'
```

レビューがまだ投稿されていない場合は、最大10回まで 60秒間隔で再確認する（最大約10分）。10回確認してもレビューが投稿されなければ、レビューなしとして Step 2 に進む。

レビューが投稿されたら、pr-review-respond スキルの手順に従い対応する。

**全自律モード**: 設計変更の提案は、合理的なら採用。大規模変更はスキップして理由をコメント。

ドラフトPRの場合は Ready for Review に変更してからマージに進む。

## Step 2: マージ

pr-merge スキルの手順に従い、PR #{{PR_NUMBER}} をマージする。

## Step 3: 結果の返却

**必ず以下の JSON 形式のみを最終出力として返却すること。** 説明文は不要。

```json
{ "issue": {{ISSUE_NUMBER}}, "pr_number": {{PR_NUMBER}}, "merged": true または false, "review_comments_handled": 対応したコメント数, "status": "merged または review_responded または failed" }
```
````

---

#### 逐次モード（--sequential）

各チケットを `issues` 配列の順序で1つずつ処理する:

1. 実装エージェントプロンプトで Task を起動（subagent_type: `general-purpose`）。
2. `status` が `failed` ならマージをスキップし、失敗として記録して次へ。
3. `success` / `partial` なら、マージエージェントプロンプトで Task を起動。
4. 結果を蓄積し、次のチケットへ進む。

---

#### 並列モード（デフォルト）: ウェーブ方式

依存関係グラフに基づき **ウェーブ方式** でチケットを並列実装する。同じウェーブ内のチケットは並列で実装し、ウェーブ単位で逐次リベース＆マージする。

##### Step 0: ウェーブの算出

`dependencies` マップから実行ウェーブを計算する:

1. **Wave 1**: 依存先がないチケット（`dependencies[issue] == []`）
2. **Wave 2**: 依存先がすべて Wave 1 に含まれるチケット
3. **Wave N**: 依存先がすべて Wave 1〜N-1 に含まれるチケット
4. すべてのチケットがウェーブに割り当てられるまで繰り返す

例（`dependencies: { "11": [], "12": [], "13": [11], "14": [11, 12] }`）:
- Wave 1: [#11, #12]（依存なし → 並列実装）
- Wave 2: [#13, #14]（#11, #12 のマージ完了後に並列実装）

##### Step A: ウェーブごとの並列実装

各ウェーブに対して以下を繰り返す:

**A-1. 当該ウェーブのチケットを並列実装**

ウェーブ内の全チケットに対し、Task を **並列** で起動する。

- **subagent_type**: `general-purpose`
- **isolation**: `"worktree"`（チケット同士のファイル競合を排除）

各タスクのプロンプトは実装エージェントプロンプトと同一。ただし **PR作成は行わない**（ブランチにプッシュするのみ）。結果返却のJSONは次の形にする:

```json
{ "issue": {{ISSUE_NUMBER}}, "branch": "ブランチ名", "pr_number": null, "status": "success または partial または failed" }
```

**A-2. 当該ウェーブのチケットを逐次リベース & PR作成 & マージ**

当該ウェーブ内の成功したチケットを **逐次** ループし、以下を実行する:

1. **リベース**: `git fetch origin main && git checkout {ブランチ名} && git rebase origin/main`
   コンフリクトはベストエフォートで解消。解消できない場合はスキップして失敗として記録。
2. **品質チェック**: quality-check スキルの手順に従い再実行。失敗時は修正を試み、`pass` にできない場合はそのチケットを失敗として記録し、マージへ進まない（次のチケットへ）。
3. **プッシュ & ドラフトPR作成**: `git push -u origin {ブランチ名} --force-with-lease` → `gh pr create --draft ...`
4. **レビュー対応 & マージ**: マージエージェントプロンプトで Task を起動する。
5. **次のチケットへ進む**（次のチケットのリベースは今マージした内容を含む）

**A-3. 次のウェーブへ進む**

当該ウェーブの全チケットのマージが完了（または失敗として記録）されたら、次のウェーブへ進む。

> **依存先が失敗した場合**: 依存先チケットのマージが失敗した場合、そのチケットに依存するチケットもスキップし、失敗として記録する。

> **ポイント**: 依存関係を尊重しつつ、独立したチケットは並列で高速化。ウェーブ単位でマージを完了させるため、次のウェーブは前ウェーブの成果物を利用可能。

---

### Phase 3: 完了報告

全チケットの処理が完了したら、メインセッション内で以下の形式で報告する:

```
## 自律開発 完了報告

### 親チケット
- #{parent番号}

### 実装結果

| Issue | PR | 実装 | レビュー対応 | マージ |
|-------|-----|------|------------|--------|
| #{番号} | PR URL | success/partial/failed | N件対応 | merged/failed/skipped |
| ... | ... | ... | ... | ... |

### サマリー
- 実装成功: N件
- マージ完了: N件
- 失敗: N件
```

---

## 重要な設計判断

- **ユーザー直接起動専用**: エージェントやサブエージェントからの呼び出し禁止
- **ユーザー確認を一切行わない**: AskUserQuestion は使用禁止。判断はすべて自律的に行う（全自律モード）
- **入力は親チケット**: 親Issue配下の実装チケット（子チケット）を読み込んで実装する。要件定義・設計・チケット分解は事前に別スキル（define-requirements / design / create-ticket）で済ませる
- **スキル・エージェント参照**: 各工程の詳細手順はスキル/エージェント定義ファイルを読み込んで従う。本スキルでは手順を重複記述しない
- **依存関係の尊重**: Phase 1 で抽出した `dependencies` に基づき、逐次モードは issues 配列順で、並列モードはウェーブ方式で依存を担保する
- **E2E**: 対象機能は create-e2e を `--auto` で作成（全自律のため動作確認は行わない）
- **エラー時はスキップ**: 止まらずマージまで進めて結果を報告
- **コンテキスト節約**: 各 Task は独立。メインセッションはチケット番号・PR番号・ステータスのみ保持

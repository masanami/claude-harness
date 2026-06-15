---
name: para-impl
description: "GitHub Issueを分析し、実装を行う。複数Issue時はAgent Teams構成を提案する。Triggers on: '/para-impl', '並列実装', 'Issueを実装して'"
argument-hint: "<Issue番号> [Issue番号...]"
model: opus
---

# Issue実装指示書

**あなたは実装を統括するリードエージェントです。**

GitHub Issueを分析し、実装を進めます。Issueが複数の場合はAgent Teamsの構成をユーザーに提案します。

---

## 入力パラメータ

GitHub Issue番号（複数可）: $ARGUMENTS

### パース方法

`$ARGUMENTS` を以下のルールで解釈する:

- **数値**: Issue番号として扱う（複数指定可）
- 例:
  - `1` → 単一Issue実装
  - `1 2 3` → 3件のIssueを並列実装（Agent Teams提案）

---

## ルーティング

パース結果に応じて実行フローを分岐する:

| Issue数 | フロー |
|---------|--------|
| 1件 | **通常実装**: リードエージェントが「1チケットの実装フロー」を実行 |
| 複数 | **Agent Teams提案**: 各teammateが独立に「1チケットの実装フロー」を実行 |

---

## 実行手順

> 各ステップは [AI駆動開発戦略](../../docs/ai-driven-development-strategy.md) の §2「エージェントの1チケット実行フロー」に準拠する。

### Phase 1: Issue分析（設計理解）

1. **全Issueの取得と分析**
   ```bash
   gh issue view {番号} --json title,body,state,labels,number
   ```
   - 各Issueの内容を確認し、実装要件を把握する
   - Issue間の依存関係を特定する

2. **Issue種別の判断**（各Issueごとに）
   - **新規機能実装**: `implement-feature` エージェントを使用
   - **既存機能の変更/バグ修正**: `modify-feature` エージェントを使用

---

### Phase 2: 実行計画

- 依存関係のあるIssueは順序を決定
- 独立したIssueは並列実行対象
- 不明点があればユーザーに確認を求める

---

## 1チケットの実装フロー（Phase 3〜7）

単一Issueはリードエージェントが、複数Issueは各teammateがworktreeで、以下を実行する（**チケット = ブランチ = PR** の単位）:

1. **ブランチ作成**: `origin/main` から作成
   ```bash
   git fetch origin main
   git checkout -b feature/issue-{番号}-{説明} origin/main
   ```
2. **依存関係のインストール**（CLAUDE.md または package.json の構成に従う）
3. **実装（TDD）**: Issue種別に応じて `implement-feature` / `modify-feature` エージェントに委譲
4. **品質チェック**: `/quality-check` を実行し、機械可読な結果が `pass` であることを確認（失敗時は修正して再実行）
5. **E2E / 動作確認**（対象機能の場合）:
   - 動作確認: `/walkthrough`（AIがHeaded Playwrightで操作し、ユーザーは観察して承認）
   - E2Eテスト: `/create-e2e`（完了条件とのトレーサビリティ・解説生成付き）
6. **コミット**: `/commit`（self-review → /simplify → /quality-check → Conventional Commits）
7. **プッシュ・PR作成**: ドラフトPRで作成し、本文に `Closes #番号`（バグ修正は `Fixes #番号`）を含める
   ```bash
   git push -u origin {ブランチ名}
   gh pr create --draft --title "{タイトル}" --body "{本文}" --base main
   ```

---

### 単一Issueの場合

リードエージェントが上記「1チケットの実装フロー」を実行する（worktree は使用しない）。完了後、Phase 8（完了報告）へ進む。

---

### 複数Issueの場合 — Agent Teams構成の提案

Phase 1-2の分析結果をもとに、Agent Teams構成をユーザーに提案する。各teammateはworktreeで独立に「1チケットの実装フロー（Phase 3〜7）」を実行する。

> **重要**: Agent Teamsはスキルから自動的に起動することはできません。ユーザーがClaude Codeに対して明示的にチーム構成を指示する必要があります。このスキルでは分析と提案までを行い、実際のチーム起動はユーザーに委ねます。

##### 提案フォーマット

```
## Agent Teams 構成提案

以下の構成で並列実装を行うことを提案します。

### チーム構成

| teammate | 担当Issue | 種別 | ブランチ名 |
|----------|----------|------|-----------|
| teammate-1 | #{番号} {タイトル} | 新規実装 | feature/issue-{番号}-{説明} |
| teammate-2 | #{番号} {タイトル} | バグ修正 | fix/issue-{番号}-{説明} |
| ... | ... | ... | ... |

### 依存関係

- （依存関係がある場合に記述。なければ「各Issueは独立しており、並列実行可能です」）

### 各teammateの実行フロー

各teammateはworktreeで独立に、上記「1チケットの実装フロー（Phase 3〜7）」を実行します。

### worktreeについて

**重要: 実装完了後、worktreeは削除しません。**
全PRのレビュー対応が完了するまでworktreeを保持します。
クリーンアップはPhase 8.5で実施します。

---

この構成でAgent Teamsを起動してよろしいですか？
```

##### ユーザーの承認後

ユーザーが構成を承認したら、以下のようにAgent Teamsの起動を依頼する：

```
上記の構成でAgent Teamsを起動してください。
各teammateにはworktreeを使用して独立した環境で作業させてください。
```

> **注意**: 実際のAgent Teams起動はユーザー（またはClaude Code本体）が行います。このスキルからは起動できません。

---

### Phase 8: 完了報告

#### 単一Issueの場合

作業完了後、以下を報告：
1. 実装サマリー
2. PRのURL
3. テスト結果
4. レビューしてほしいポイント

#### 複数Issueの場合（Agent Teams完了後）

全teammateの作業完了後、以下を集約して報告：
1. 各Issueの実装サマリー
2. 各PRのURL
3. テスト結果の集約
4. Issue間の整合性確認結果
5. レビューしてほしいポイント
6. **worktreeの状態**: 各teammateのworktreeが保持されていることを報告し、レビュー対応後にPhase 8.5でクリーンアップする旨を伝える

> **重要**: 複数Issueの場合、この時点でworktreeを削除しません。PRレビューで指摘が見つかった場合、修正のためにworktreeが必要です。クリーンアップはPhase 8.5で行います。

---

### Phase 8.5: Worktreeクリーンアップ（複数Issueの場合）

全PRのレビュー対応が完了した後、またはユーザーが明示的にクリーンアップを指示した場合に、各teammateのworktreeを削除する。

> **前提条件**: 全PRについて以下がすべて完了していること:
> - セルフレビューの指摘修正が完了
> - PRレビュー指摘の修正が完了（指摘なしの場合は不要）
> - 必要な修正のコミット・プッシュが完了

```bash
# 残存するworktreeを確認
git worktree list

# 各teammateのworktreeを削除
git worktree remove {teammate-1のworktreeパス} --force
git worktree remove {teammate-2のworktreeパス} --force
# ... 全teammate分を繰り返す

# worktreeが全て削除されたことを確認
git worktree list
```

> **注意**: ユーザーが後から追加の修正を行う可能性がある場合は、worktreeの削除を保留してもよい。ユーザーに確認してからクリーンアップすることを推奨する。

---

## Worktree管理方針

| Issue数 | worktree使用 | 削除タイミング | 削除フェーズ |
|---------|-------------|--------------|------------|
| 単一Issue | 不使用 | - | - |
| 複数Issue | Agent Teamsが使用 | 全PRのレビュー対応完了後、またはユーザーの明示的な指示 | Phase 8.5 |

---

## 成果物

- プロダクションコード
- テストコード
- Pull Request（Issueごとに1つ）

---

## 禁止事項

- スコープ外の機能追加
- PRの自己マージ
- 設計ドキュメントなしでの大規模実装開始
- テストなしでのコード追加

---

## ユーザーへの確認タイミング

以下の場合はユーザーに確認を求めてください：
- Issueの要件が不明確な場合
- 複数の実装アプローチが考えられる場合
- スコープの拡大が必要と判断した場合
- Issue間の依存関係で判断が必要な場合
- 複数Issue時のAgent Teams構成の承認
- 実装完了後のレビュー依頼時

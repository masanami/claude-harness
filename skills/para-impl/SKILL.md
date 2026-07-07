---
name: para-impl
description: "GitHub Issueを分析し、設計→TDD実装(エージェント内でQC通過まで)→コミット→E2E→PR→CI確認の1チケットフローを実装フェーズの人間ゲートなしで実行する。クリティカル設計は要件チケット側で決定済み前提。複数Issue時はAgent Teams構成を提案する。Triggers on: '/para-impl', '並列実装', 'Issueを実装して'"
argument-hint: "<Issue番号> [Issue番号...] [--base <統合ブランチ>]"
model: opus
# effort: 設計〜TDD実装〜PRの自走フローを担うため high。
effort: high
---

# Issue実装指示書

**あなたは実装を統括するリードエージェントです。**

GitHub Issueを分析し、1チケット実行フロー（設計→TDD実装→必須ゲート→コミット→E2E→PR→CI確認）に沿って実装を進めます。**クリティカル設計の意思決定は要件チケット側で完了している前提**のため、実装フェーズには人間ゲートを置きません。Issueが複数の場合はAgent Teamsの構成をユーザーに提案します。

---

## 入力パラメータ

GitHub Issue番号（複数可）: $ARGUMENTS

### パース方法

`$ARGUMENTS` を以下のルールで解釈する:

- **数値**: Issue番号として扱う（複数指定可）
- **`--base <統合ブランチ>`**: 統合ブランチ方式のオプション（下記）。切り出して保持し、残りを Issue 番号として扱う
- 例:
  - `1` → 単一Issue実装
  - `1 2 3` → 3件のIssueを並列実装（Agent Teams提案）
  - `1 2 3 --base feat/issue-42` → base を統合ブランチにして並列実装

### base 統合ブランチの決定（統合ブランチ方式）

各 Issue の実装 base（ブランチ分岐元・PR の宛先）を次の優先順で決める:

1. **`--base` オプション**が指定されていれば、それを全 Issue 共通の base 統合ブランチにする
2. 無指定でも、Issue 本文に `Base: {統合ブランチ}` 行があれば（`/create-ticket --base` が記録）それを当該 Issue の base にする
3. どちらも無ければ **base = リポジトリの既定ブランチ**（通常 `main`。従来動作）

base が既定ブランチ以外（統合ブランチ）の場合、**Phase 3 の前に remote での存在を確認する**。無ければ処理を止めてユーザーに作成を促す:

```bash
if ! git ls-remote --exit-code --heads origin "{base}" >/dev/null 2>&1; then
  echo "エラー: 統合ブランチ {base} が remote に存在しません。先に作成してください:"
  DEFAULT_BRANCH=$(gh repo view --json defaultBranchRef -q '.defaultBranchRef.name')
  echo "  git checkout -b {base} \"origin/$DEFAULT_BRANCH\" && git push -u origin {base}"
fi
```

統合ブランチへのサブタスク PR マージは本番影響がなく可逆のため**人間承認不要で自律マージできる**（既定ブランチへの昇格のみが人間ゲート）。以降のフローで **`{base}` は上記で決定した base ブランチ**（既定はリポジトリの既定ブランチ）を指す。

---

## ルーティング

| Issue数 | フロー |
|---------|--------|
| 1件 | **通常実装**: リードエージェントが「1チケットの実装フロー」を実行 |
| 複数 | **Agent Teams提案**: 各teammateが独立に「1チケットの実装フロー」を実行 |

---

## Phase 1: Issue分析（要件理解）

1. **全Issueの取得**
   ```bash
   gh issue view {番号} --json title,body,state,labels,number
   ```
   - 各Issueの**要件・完了条件・受入基準**を把握する
   - Issue間の依存関係を特定する

2. **E2E対象判定**（各Issueごと）
   - 認証フロー、権限制御、クリティカルパスなどの場合は E2E対象とする

---

## Phase 2: 実行計画

- 依存関係のあるIssueは順序を決定
- 独立したIssueは並列実行対象
- 不明点があればユーザーに確認を求める

---

## 1チケットの実装フロー（Phase 3〜9）

単一Issueはリードエージェントが、複数Issueは各teammateがworktreeで以下を実行する（**1チケット = 1ブランチ = 1PR**）。設計→TDD実装（必須ゲート＋セルフレビュー内包）→コミット→E2E→PR→CIの順で進める。**実装フェーズに人間ゲートは無い**。

```text
Phase 3 ブランチ準備
   ↓
Phase 4-5 設計 + TDD実装 + 必須ゲート + セルフレビュー（feature-implementer 一気通貫）
   ↓（必須ゲート未通過 → 当該チケットをスキップ）
Phase 6 コミット（safety net QC + Conventional Commits）
   ↓
Phase 7 E2E実装（E2E対象の場合）─失敗→ Phase 4-5
   ↓
Phase 8 プッシュ・PR作成
   ↓
Phase 9 CI確認（必須ゲート）
```

> **クリティカル設計レビューは要件チケット段階で完了済み**。要件チケットの「クリティカル設計決定」セクションに従って実装する。
>
> **E2Eシナリオ設計レビュー**は AI セルフレビュー（完了条件↔シナリオのトレーサビリティ確認）で完結。人間の E2E チェックは Phase 7 後の `/explain-e2e`（テストシナリオ解説 + 独立検証）で行う。

### Phase 3: ブランチ準備

`{base}`（「base 統合ブランチの決定」で確定した base。既定はリポジトリの既定ブランチ・通常 `main`）から作業ブランチを切る:

```bash
git fetch origin {base}
git checkout -b {type}/issue-{番号}-{説明} origin/{base}
```

依存関係のインストールが必要であれば実施する（CLAUDE.md または package.json の構成に従う）。

### Phase 4-5: 設計＋TDD実装＋必須ゲート＋セルフレビュー（一気通貫）

`feature-implementer` エージェントを **一度だけ呼び出し**、Phase 1〜5 を一気通貫で実行させる（実装フェーズに人間ゲートは無い）。

リードは要件チケット本文の **「クリティカル設計決定」セクション**をエージェントに渡し、その方針に従って実装するよう指示する。

エージェントから受け取る返却内容:

- **変更ファイル一覧 / 追加テスト件数 / TDDサイクルの概要**
- **`/quality-check` の最終結果**（`pass` or `failure`）
- **`/self-review` の結果サマリー**（指摘あり/なし、反復回数。完了条件達成・スコープ確認の観点も含む）
- **E2Eシナリオ一覧と完了条件トレーサビリティ表**（E2E対象の場合、Phase 7 で使う）

```text
| 完了条件 / 受入基準 | 対応E2Eシナリオ |
|-------------------|---------------|
| {完了条件1} | {シナリオ名} |
| ... | ... |
```

#### 例外ケース

| エージェントの返却 | リードの動作 |
|---|---|
| 通常完了 | Phase 6（コミット）へ |
| `failure`（`/quality-check` 3回反復しても通らない） | 当該チケットをスキップ。並列モードでは他 teammate は継続 |
| クリティカル設計の逸脱検知で Phase 2 停止 | エージェントの警告内容をユーザーに提示し、判断を仰ぐ（**想定外のスコープ拡大を検知した場合のみ**） |

### Phase 6: コミット

```text
/commit
```

`/commit` は **コミット規約に従ったコミット実行に責務を絞った**スキル。内部では safety net として `/quality-check` を再走させ、Conventional Commits 形式でコミットを作成する。Phase 4-5 で必須ゲート・`/self-review` を通過済みのため、ここでの `/quality-check` は通過前提で速やかに完了する。

> コード簡潔化が必要な場合は **`/simplify`** を Phase 6 の前に別途呼ぶ（必須ではない）。

### Phase 7: E2E実装と独立検証（E2E対象の場合）

E2E対象機能の場合、Phase 4-5 で feature-implementer が返した E2Eシナリオ一覧に基づき実装する:

1. `/create-e2e` — 設計（Phase 4-5 のシナリオを根拠）→ 実装 → 全テスト実行
2. `/explain-e2e` — テストシナリオ解説と独立検証をメインセッションで対話的に実施

- E2E失敗 → **Phase 4-5 に戻る**

非E2E対象の場合、このフェーズはスキップする。

### Phase 8: プッシュ・PR作成

PR を作成し、本文に `Closes #番号`（バグ修正は `Fixes #番号`）を含める。Phase 4-5 で必須ゲート・セルフレビューを通過済み、対象機能なら `/explain-e2e` も済んでいるため、**通常PR（非ドラフト）で開く**（AI レビューを即時起動し `/pr-review-respond` へ繋ぐ）。

feature-implementer が**クロスリポジトリ依存の確証結果**を返した場合は、そのまま PR 本文に転記する（確証の規律・形式は feature-implementer / code-reviewer 側に定義）。

**PR の base は Phase の冒頭で決定した `{base}`**（既定はリポジトリの既定ブランチ・通常 `main`、統合ブランチ方式では統合ブランチ）にする:

```bash
git push -u origin {ブランチ名}
gh pr create --title "{タイトル}" --body "{本文}" --base {base}
```

> 「まだ詰め切れていない」状態で意図的に保留したい場合のみ `--draft` を付けるか、ラベル `hold` を活用する。
>
> **統合ブランチ方式**: base が統合ブランチの場合、この PR は既定ブランチを触らないため `/pr-merge` で自律マージできる（人間承認不要）。全サブタスク完了後の統合 → 既定ブランチ昇格が唯一の人間ゲート。

### Phase 9: CI確認（必須ゲート）

PR作成後、CIの完了を確認する:

```bash
gh pr checks {PR番号} --watch
```

- CI失敗 → 失敗内容を確認して **Phase 4-5 に戻る**
- CIパス → Phase 10（完了報告）へ

---

## 複数Issueの場合 — Agent Teams構成の提案

Phase 1-2 の分析結果をもとに、Agent Teams構成をユーザーに提案する。各teammateはworktreeで独立に「1チケットの実装フロー（Phase 3〜9）」を実行する。

> **重要**: Agent Teamsはスキルから自動的に起動することはできません。ユーザーがClaude Codeに対して明示的にチーム構成を指示する必要があります。このスキルでは分析と提案までを行い、実際のチーム起動はユーザーに委ねます。

### 提案フォーマット

```text
## Agent Teams 構成提案

以下の構成で並列実装を行うことを提案します。

### チーム構成

| teammate | 担当Issue | E2E対象 | クリティカル | base | ブランチ名 |
|----------|----------|--------|------------|------|-----------|
| teammate-1 | #{番号} {タイトル} | ○/× | ○/× | {base} | feature/issue-{番号}-{説明} |
| teammate-2 | #{番号} {タイトル} | ○/× | ○/× | {base} | fix/issue-{番号}-{説明} |

> `base` は各 Issue の PR 宛先（既定はリポジトリの既定ブランチ・通常 `main`）。`--base` 指定時や Issue 本文の `Base:` 行がある場合は統合ブランチを表示する。

### 依存関係

- （依存関係がある場合に記述。なければ「各Issueは独立しており、並列実行可能です」）

### 各teammateの実行フロー

各teammateはworktreeで独立に Phase 3〜9（ブランチ準備 → 設計+TDD実装 → コミット → E2E → PR → CI確認）を実行します。**実装フェーズに人間ゲートは無い**（クリティカル設計は要件チケット側で決定済み、E2Eシナリオは AI セルフレビュー）。
ただしエージェントがクリティカル設計の逸脱を検知した場合は Phase 4-5 で停止し、メインセッション経由でユーザーレビューを依頼します。

### worktreeについて

**重要: 実装完了後、worktreeは削除しません。**
全PRのレビュー対応が完了するまでworktreeを保持します。
クリーンアップは Phase 11 で実施します。

---

この構成でAgent Teamsを起動してよろしいですか？
```

### ユーザーの承認後

```text
上記の構成でAgent Teamsを起動してください。
各teammateにはworktreeを使用して独立した環境で作業させてください。
```

teammate には feature-implementer のような**エージェント定義（システムプロンプト）が無く、ここで組み立てる起動プロンプトが行動規範の唯一の注入点**になる。各 teammate への指示に以下を必ず含める:

1. **permission 拒否時の振る舞い**: permission で拒否された操作を、別コマンド経由（`node -e` / `python3 -c` / `sh -c` 等のインタープリタからの間接実行）で回避しない。許可されている操作（自分の worktree での `git commit` / `git push` / `gh pr create` を含む）は teammate 自身が実行し、**拒否された操作だけ**を未実施のままリードに返す（リードが代行できる）
2. **headless 制約**: リードが headless（非対話）セッションの場合、非同期の問い合わせ・待ち合わせは成立しない（関連: masanami/claude-flywheel#33）。ユーザー判断が必要な事項は待たずに作業を止め、返却内容に「判断待ち」と明記する

> **permission 拒否の予防**: gitignore された `.claude/settings.local.json` は worktree にコピーされないため、allow 権限は **git tracked の `.claude/settings.json`** に無ければ worktree 内の teammate に適用されない（`/init-project` のステップ 4b 参照）。また prefix 型 allowlist は `cd {path} && git commit …` のような複合コマンドや `git -C {path}` 形式にはマッチしないため、worktree 内では **cwd を worktree にして素のコマンド形式で実行する**よう指示する。Agent Teams 起動前に、必要な権限が git tracked の settings.json に揃っているかを確認し、不足があればユーザーに案内する。

---

## Phase 10: 完了報告

### 単一Issueの場合

1. 実装サマリー
2. PR URL とCIステータス
3. クリティカル設計の逸脱検知でユーザー判断を仰いだ場合はその結果
4. E2E結果（対象機能の場合）— /explain-e2e の解説と独立検証結果
5. **次のアクションの案内**:
   - レビュー対応: `/pr-review-respond {PR番号}`
   - マージ: `/pr-merge {PR番号}`

### 複数Issueの場合（Agent Teams完了後）

1. 各Issueの実装サマリー
2. 各PR URLとCIステータス
3. クリティカル設計の逸脱検知でユーザー判断を仰いだチケットの一覧
4. テスト結果の集約・Issue間の整合性確認
5. **次のアクションの案内**: 各PRに対し `/pr-review-respond`、マージ可能になり次第 `/pr-merge`
6. **worktreeの状態**: 各teammateのworktreeが保持されていることを報告し、レビュー対応後に Phase 11 でクリーンアップする旨を伝える
7. **統合ブランチ方式の場合**: 全サブタスク PR を統合ブランチへ自律マージ後、残る唯一の人間ゲート（①統合ブランチで**最終動作確認**: `/walkthrough`・E2E・手動確認で親 Issue の完了条件を人間が通す → ②既定ブランチ向けの昇格 PR を作成 → ③人間承認 → ④マージ）を案内する

> **重要**: 複数Issueの場合、この時点でworktreeを削除しません。PRレビューで指摘が見つかった場合、修正のためにworktreeが必要です。クリーンアップは Phase 11 で行います。

---

## Phase 11: Worktreeクリーンアップ（複数Issueの場合）

全PRのレビュー対応が完了した後、またはユーザーが明示的にクリーンアップを指示した場合に、各teammateのworktreeを削除する。

> **前提条件**: 全PRについて以下がすべて完了していること:
> - セルフレビューの指摘修正が完了
> - PRレビュー指摘の修正が完了（指摘なしの場合は不要）
> - 必要な修正のコミット・プッシュが完了

```bash
git worktree list
git worktree remove {teammate-1のworktreeパス} --force
git worktree remove {teammate-2のworktreeパス} --force
git worktree list
```

> **注意**: ユーザーが後から追加の修正を行う可能性がある場合は、worktreeの削除を保留してもよい。ユーザーに確認してからクリーンアップすることを推奨する。

---

## Worktree管理方針

| Issue数 | worktree使用 | 削除タイミング | 削除フェーズ |
|---------|-------------|--------------|------------|
| 単一Issue | 不使用 | - | - |
| 複数Issue | Agent Teamsが使用 | 全PRのレビュー対応完了後、またはユーザーの明示的な指示 | Phase 11 |

---

## 成果物

- プロダクションコード
- テストコード（単体・結合・E2E）
- 設計内容（クリティカル/E2E対象時の人間レビュー記録を含む）
- Pull Request（Issueごとに1つ、通常PR→CI緑＋AIレビュー対応→マージ）

---

## 禁止事項

- スコープ外の機能追加
- 設計フェーズ（Phase 4-5 の設計成果物出力）の省略
- 要件チケットの「クリティカル設計決定」を無視した実装
- テストなしでのコード追加

---

## ユーザーへの確認タイミング

- Issueの要件が不明確な場合
- 複数の実装アプローチが考えられる場合
- スコープの拡大が必要と判断した場合
- Issue間の依存関係で判断が必要な場合
- 複数Issue時のAgent Teams構成の承認
- **Phase 4-5: クリティカル設計の逸脱検知時**（feature-implementer の警告を受けて判断を仰ぐ）
- 実装完了後のレビュー依頼時

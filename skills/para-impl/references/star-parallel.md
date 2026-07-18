# star 型並列実装（複数Issue時）

> **spawn 前に必読**: このファイルには worker spawn プロンプトの必須項目と「worker からの返却の処理」表が含まれます。見落とすと並列実装が全滅する規律のため、`ticket-worker` を spawn する前に必ず本ファイル全体を読んでください。
>
> 参照パスは `${CLAUDE_PLUGIN_ROOT}` 配下です（例: `${CLAUDE_PLUGIN_ROOT}/skills/para-impl/references/star-parallel.md`）。Read にはプラグインの絶対パスが必要です。

---

## 複数Issueの場合 — star 型並列実装（orchestrator-worker）

リードがオーケストレーター（dispatch / 統合 / 順序・衝突解決 / harness スキルロジックの番人）として、Issue ごとに `ticket-worker` サブエージェントへ委譲する。**worker 間通信は無い**——調整はチケット分解の段階に前倒し済みという para-impl の前提のため、実行時に worker 同士が話す必要はなく、残る調整はすべてリードが担う。

### 実行計画の提示

Phase 1-2 の分析結果をもとに実行計画を提示する。これは**報告であり承認ゲートではない**（実装フェーズに人間ゲートは無い）。Issue 間の依存関係・衝突で判断が必要な場合のみユーザーに確認する。リード自身が headless で確認できない場合は、判断が必要なケースを**保守側（直列化）に倒し**、完了報告に判断事項として明記する:

```text
## star 型並列実装 実行計画

| worker | 担当Issue | E2E対象 | クリティカル | base | ブランチ名 | 実行順 |
|--------|----------|--------|------------|------|-----------|-------|
| worker-1 | #{番号} {タイトル} | ○/× | ○/× | {base} | feature/issue-{番号}-{説明} | 並列 |
| worker-2 | #{番号} {タイトル} | ○/× | ○/× | {base} | fix/issue-{番号}-{説明} | 並列 |
| worker-3 | #{番号} {タイトル} | ○/× | ○/× | {base} | feature/issue-{番号}-{説明} | #{番号} の後 |

> `base` は各 Issue の PR 宛先（既定はリポジトリの既定ブランチ・通常 `main`）。`--base` 指定時や Issue 本文の `Base:` 行がある場合は統合ブランチを表示する。
```

### 直列化の判断（残留結合の吸収）

「独立したチケット」でも残留結合（共有ファイル・共通型・PR マージ順）はゼロにならない。リードが次で吸収する:

- Issue 間に依存関係がある、または同一ファイル群への変更が Phase 1 で見えている場合は**並列にせず直列化**する。後続 worker の spawn 条件は base で異なる:
  - **base = 統合ブランチ**: 先行チケットの PR をリードが `/pr-merge` で自律マージしてから後続を spawn する（統合ブランチ宛は人間承認不要）
  - **base = 既定ブランチ**: 既定ブランチへのマージは人間ゲートのため、リードは**先行 PR のマージをユーザーに依頼し、マージを確認してから後続を spawn する**。依頼できない場合（headless 等）は後続をスキップし、完了報告に再開手順を明記する
- それでも統合時に衝突した場合は**リードがコンフリクトを解決**する

### worker への委譲

**事前確認（permission 拒否の予防）**: allow 権限は **git tracked の `.claude/settings.json`** に置く（`/init-project` のステップ 4b 参照）。gitignore された `.claude/settings.local.json` は worktree にコピーされず、サブエージェントへの適用も環境依存のため当てにしない。worker を spawn する前に必要な権限（`cd` / `git` / `gh` 系）が揃っているかを確認し、不足があればユーザーに案内する。

リードが Issue ごとに worktree と作業ブランチを作成し（Phase 3 に相当）、独立した Issue の `ticket-worker` を並列に spawn する（Task ツールの `subagent_type` は plugin namespace prefix 付きの **`claude-harness:ticket-worker`** を指定する。prefix 無しは名称解決エラーになる）:

```bash
git fetch origin {base}
git worktree add {worktreeパス} -b {type}/issue-{番号}-{説明} origin/{base}
```

spawn プロンプトに含めるもの:

- Issue 番号・worktree パス・作業ブランチ・base
- 「1チケットの実装フロー」（SKILL.md 本文の同名セクション）の Phase 4-5〜9 の手順（Phase 3 はリードが worktree 作成で実施済み。Phase 7 は `/create-e2e` まで）
- 要件チケットの「クリティカル設計決定」セクション

> 行動規範（permission 拒否時の振る舞い・headless 制約・worktree 内でのコマンド形式）は `ticket-worker` のエージェント定義に含まれ、spawn 時に自動で伝播する。プロンプトへの手動注入は不要。

### worker からの返却の処理

| worker の返却 | リードの動作 |
|---|---|
| 通常完了（PR URL・CI green） | Phase 10 の集約へ。E2E対象チケットは worker 返却のシナリオ一覧を使い、リードが `/explain-e2e` をメインセッションで実施 |
| `failure` | 当該チケットをスキップして報告（クロスリポジトリ依存の確証結果など、worker の failure 返却に含まれる証跡も転記する）。他 worker は継続 |
| クリティカル設計の逸脱・判断待ち | 内容をユーザーに提示して判断を仰ぐ |
| 他チケットとの衝突検知 | リードが直列化・統合方針を判断する |

---

## Phase 10: 完了報告

### 複数Issueの場合（star 型並列実装完了後）

1. 各Issueの実装サマリー
2. 各PR URLとCIステータス
3. E2E対象チケットの `/explain-e2e` 結果（リードがメインセッションで実施した解説と独立検証）
4. クリティカル設計の逸脱検知でユーザー判断を仰いだチケットの一覧
5. テスト結果の集約・Issue間の整合性確認
6. **次のアクションの案内**: 各PRに対し `/pr-review-respond`。マージは base=統合ブランチならリードが `/pr-merge` で自律実行、base=既定ブランチならユーザーに `/pr-merge` を案内（項目8参照）
7. **worktreeの状態**: 各 worker の worktree が保持されていることを報告し、レビュー対応後に Phase 11 でクリーンアップする旨を伝える
8. **統合ブランチ方式の場合**: 全サブタスク PR を統合ブランチへ自律マージ後、残る唯一の人間ゲート（①統合ブランチで**最終動作確認**: `/walkthrough`・E2E・手動確認で親 Issue の完了条件を人間が通す → ②既定ブランチ向けの昇格 PR を作成 → ③人間承認 → ④マージ）を案内する

> **重要**: 複数Issueの場合、この時点でworktreeを削除しません。PRレビューで指摘が見つかった場合、修正のためにworktreeが必要です。クリーンアップは Phase 11 で行います。

---

## Phase 11: Worktreeクリーンアップ（複数Issueの場合）

全PRのレビュー対応が完了した後、またはユーザーが明示的にクリーンアップを指示した場合に、各 worker の worktree を削除する。

> **前提条件**: 全PRについて以下がすべて完了していること:
> - セルフレビューの指摘修正が完了
> - PRレビュー指摘の修正が完了（指摘なしの場合は不要）
> - 必要な修正のコミット・プッシュが完了

削除前に各 worktree の `git status --short` を確認し、**PR 未作成・`failure` の worker の worktree は再試行または調査完了まで保持する**（削除対象は PR 作成済み＋レビュー対応完了のもののみ）。未コミットの修正や失敗解析用の成果物を無条件の `--force` 削除で不可逆に失わないため、通常手順では `--force` を使わない。

```bash
git worktree list
git -C {workerのworktreeパス} status --short   # クリーン（未コミット差分なし）であることを確認してから削除
git worktree remove {workerのworktreeパス}      # PR作成済み＋レビュー対応完了のworktreeのみ、該当worker分繰り返す
git worktree list
```

> **注意**: ユーザーが後から追加の修正を行う可能性がある場合は、worktreeの削除を保留してもよい。ユーザーに確認してからクリーンアップすることを推奨する。

---

## Worktree管理方針

| Issue数 | worktree使用 | 削除タイミング | 削除フェーズ |
|---------|-------------|--------------|------------|
| 単一Issue | 不使用 | - | - |
| 複数Issue | リードが作成し ticket-worker が使用 | 全PRのレビュー対応完了後、またはユーザーの明示的な指示 | Phase 11 |

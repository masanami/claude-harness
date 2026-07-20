# star 型並列実装（複数Issue時）

> **spawn 前に必読**: このファイルには Workflow 起動の必須項目と「Workflow からの返却の処理」表が含まれます。見落とすと並列実装が全滅する規律のため、Workflow を起動する前に必ず本ファイル全体を読んでください。
>
> 参照パスは `${CLAUDE_PLUGIN_ROOT}` 配下です（例: `${CLAUDE_PLUGIN_ROOT}/skills/para-impl/references/star-parallel.md`）。Read にはプラグインの絶対パスが必要です。
>
> **v2.0.0 での刷新（重要）**: 旧版はリードが Issue ごとに `ticket-worker` サブエージェントを Task ツールで並列 spawn していたが、Workflow が spawn したエージェントは Task ツールを使えない（実機検証済み）ため、`ticket-worker` は廃止し、その制御フロー（差し戻しループ・CI確認・返却整形）は Dynamic Workflow（`skills/para-impl/scripts/para-impl-tickets.js`）へコード化した。resume 耐性（中断からの再開）・loop-until-green（CI失敗時の上限付き再試行）・衝突検出（低effort予測エージェントの並列fan-out＋集合演算）が新たに得られる。

---

## 複数Issueの場合 — star 型並列実装（orchestrator-worker）

リードがオーケストレーター（dispatch / 統合 / 順序・衝突解決 / harness スキルロジックの番人）として、独立した Issue 群を1つの Dynamic Workflow（`para-impl-tickets.js`）へ一括委譲する。**チケット間の直接連携は無い**——調整はチケット分解の段階に前倒し済みという para-impl の前提のため、実行時にチケット同士が話す必要はなく、残る調整はすべてリードが担う（Workflow の pipeline は各チケットを独立実行する）。

### 実行計画の提示

Phase 1-2 の分析結果をもとに実行計画を提示する。これは**報告であり承認ゲートではない**（実装フェーズに人間ゲートは無い）。Issue 間の依存関係・衝突で判断が必要な場合のみユーザーに確認する。リード自身が headless で確認できない場合は、判断が必要なケースを**保守側（直列化）に倒し**、完了報告に判断事項として明記する:

```text
## star 型並列実装 実行計画

| チケット | 担当Issue | E2E対象 | クリティカル | base | ブランチ名 | 実行順 |
|--------|----------|--------|------------|------|-----------|-------|
| ticket-1 | #{番号} {タイトル} | ○/× | ○/× | {base} | feature/issue-{番号}-{説明} | 並列 |
| ticket-2 | #{番号} {タイトル} | ○/× | ○/× | {base} | fix/issue-{番号}-{説明} | 並列 |
| ticket-3 | #{番号} {タイトル} | ○/× | ○/× | {base} | feature/issue-{番号}-{説明} | #{番号} の後 |

> `base` は各 Issue の PR 宛先（既定はリポジトリの既定ブランチ・通常 `main`）。`--base` 指定時や Issue 本文の `Base:` 行がある場合は統合ブランチを表示する。
```

### 直列化の判断（残留結合の吸収）

「独立したチケット」でも残留結合（共有ファイル・共通型・PR マージ順）はゼロにならない。リードが次で吸収する（この判断自体は Workflow の対象外で、リードが Workflow 起動前に行う）:

- Issue 間に依存関係がある、または同一ファイル群への変更が Phase 1 で見えている場合は**並列にせず直列化**する。後続チケットの Workflow 投入条件は base で異なる:
  - **base = 統合ブランチ**: 先行チケットの PR をリードが `/pr-merge` で自律マージしてから後続を Workflow へ投入する（統合ブランチ宛は人間承認不要）
  - **base = 既定ブランチ**: 既定ブランチへのマージは人間ゲートのため、リードは**先行 PR のマージをユーザーに依頼し、マージを確認してから後続を投入する**。依頼できない場合（headless 等）は後続をスキップし、完了報告に再開手順を明記する
- Workflow の Conflict フェーズ（Issue数が閾値以上の場合のみ起動。下記参照）が返す衝突ヒントは**自動直列化トリガーではない**——予測ベースのため偽陰性・偽陽性を含みうる。リードが判断材料として使い、統合時に実際に衝突した場合は**リードがコンフリクトを解決**する

### worktree・ブランチ準備

**事前確認（permission 拒否の予防）**: allow 権限は **git tracked の `.claude/settings.json`** に置く（`/init-project` のステップ 4b 参照）。gitignore された `.claude/settings.local.json` は worktree にコピーされず、サブエージェントへの適用も環境依存のため当てにしない。Workflow を起動する前に必要な権限（`cd` / `git` / `gh` 系・`scripts/worktree-setup.sh` 等）が揃っているかを確認し、不足があればユーザーに案内する。

リードが independentIssues（直列化判断で並列化対象と決めたIssue群）それぞれについて `scripts/worktree-setup.sh` を呼び、worktree と作業ブランチを作成する:

> **スクリプトの所在（重要）**: 本スキルはプラグインとして配布されるため、スクリプトは**ユーザーのプロジェクトroot ではなく、プラグイン配下**にある。スクリプトを実行する際は必ず `bash "${CLAUDE_PLUGIN_ROOT}/scripts/worktree-setup.sh" <引数>` の形式（`${CLAUDE_PLUGIN_ROOT}` は実行時にプラグインルートへ展開される）を用い、相対パス `scripts/worktree-setup.sh` では呼び出さないこと。
<!-- 正本: docs/plugin-path-conventions.md -->

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/worktree-setup.sh" {issue番号} {type}/issue-{番号}-{説明} {base}
```

出力JSON（`worktree_path`・`created`・`reused`・`branch_existed`）の**フィールド定義の正本は、プラグイン配下の `scripts/README.md`「worktree-setup.sh / worktree-cleanup.sh の出力仕様」**（ここには複製しない。Read する場合はスキル起動時の「Base directory for this skill」を起点に `<base>/../../scripts/README.md` として解決すること）。`reused: true` の場合は前回実行分の worktree をそのまま再利用する（resume時の冪等性）。エラー（base が remote に存在しない・別ブランチの worktree と衝突等）は非0 exitで返るため、内容を確認してから次のIssueへ進む。

全 Issue 分の `worktree_path` を集めたら、次節の Workflow 起動へ進む。

### Workflow 起動

`independentIssues` を1つの Dynamic Workflow（`skills/para-impl/scripts/para-impl-tickets.js`）へ一括投入する。`scriptPath` の絶対パス解決手順は「参照ファイルの所在」節と同じ方式（**Base directory for this skill** から `/skills/para-impl` を除いた絶対パスに `/skills/para-impl/scripts/para-impl-tickets.js` を連結する）に従う。同様に `args` 内の `ciWaitScript`/`collectDiffScript`/`extractHunkScript`/`selfReviewLoopScript` も、それぞれ `scripts/ci-wait.sh`・`scripts/collect-review-diff.sh`・`scripts/extract-hunk.sh`・`skills/self-review/scripts/self-review-loop.js` の絶対パスを同じ手順で解決して渡す（Workflow ツールの `scriptPath`/`args` はプレースホルダの展開が行われないため）。resume 安定性のため、同一セッション内では常に同一の絶対パスをそのまま渡すこと。

Workflow へ渡す `args.tickets` は、各 Issue について以下を含む:

- `issue` / `title` / `body`（Issue本文。衝突検出フェーズの予測材料）
- `branch`（`worktree-setup.sh` に渡したものと同じブランチ名）/ `base`
- `worktree`（`worktree-setup.sh` の出力 `worktree_path`）
- `criticalDecisionText`（要件チケットの「クリティカル設計決定」セクション本文そのもの）
- `e2eTarget`（Phase 1-2 のE2E対象判定結果）

`ciTimeoutSeconds`/`ciPollIntervalSeconds` は省略可（既定値は `para-impl-tickets.js` 側）。

> **行動規範の自動伝播**: worktree 起点 `cd` 複合形式規律・permission 拒否時の非回避・headless 制約は、Workflow が feature-implementer/git-ops へ渡すプロンプトに固定文面として自動的に注入される（`para-impl-tickets.js` の `DISCIPLINE_NOTICE`）。リードが手動でこれらの規律をプロンプトに含める必要はない。

Workflow は内部で、Issue数が閾値（既定5件）以上の場合のみ低effort予測エージェントによる衝突検出（Conflict フェーズ）を行い、その後 `independentIssues` それぞれについて Implement（loop-until-green）→ DesignVerify（クリティカル該当時のみ）→ Review（`/self-review` 相当を子Workflowとして起動）→ CI（コミット・push・PR作成/更新・CI待機）を直列実行する（各チケットは互いに独立、`pipeline` により並行進行する）。

### Workflow からの返却の処理

Workflow の返却は `{conflicts, tickets: [...]}` の形。`conflicts` は衝突検出のヒント（`evaluated: false` の場合は閾値未満でスキップ）。`tickets` は各チケットの結果配列で、`status` フィールドに基づき機械的に分岐する:

| `status` | 意味 | リードの動作 |
|---|---|---|
| `done` | 実装・レビュー・CIまで完了（PR green） | Phase 10 の集約へ。`e2e_target: true` のチケットは下記「E2E対象チケットのフォローアップ」を実施してから集約する |
| `failure` | `/quality-check` 未通過、Reviewの致命的残指摘、またはCIが上限試行（既定3回）内にgreenにならなかった | 当該チケットをスキップして報告（`blocking_reason`・`failed_stages` を転記。クロスリポジトリ依存の確証結果など、`self_review`/`design_verify` に含まれる証跡があれば併せて転記する）。他チケットは継続 |
| `needs_human` | クリティカル設計逸脱の自己申告（Implement）、またはdesign-deviation-verifierの多数決による逸脱確定（DesignVerify） | `blocking_reason` と `design_verify`（判定根拠）の内容をユーザーに提示して判断を仰ぐ |

`conflicts.pairs` に該当ペアがある場合は、統合時にリードが目視でコンフリクトの有無を確認する（自動直列化はしない。上記「直列化の判断」参照）。

### E2E対象チケットのフォローアップ

`status: done` かつ `e2e_target: true` のチケットは、Workflow の CI ステージが確立した PR に**まだ E2E テストが含まれない**（`/create-e2e` は Workflow の対象外。呼び出し元スキルの責務として残す設計）。リードは Workflow 完了後、当該チケットの worktree（保持されている）に対して以下をメインセッションで実施する:

1. `/create-e2e` — 設計（`tickets[].e2e_scenarios` を根拠）→ 実装 → 全テスト実行（対象 worktree で）
2. 追加コミット・push（`/commit` 等。CIが再度緑になることを確認する）
3. `/explain-e2e` — Phase 1（テストシナリオ解説）はメインセッションで対話的に、Phase 2（独立検証）は Dynamic Workflow による自動検証で実施する。**当該チケットの worktree 内のテストコードを対象**にする（Phase 2 の Workflow 起動時は `workingDirectory` に当該 worktree の絶対パスを指定する）

独立検証で問題が見つかった場合は、当該チケットの worktree で `feature-implementer` を Task ツールで直接 spawn するか、リード自身が修正を行う（`para-impl-tickets.js` は既に完了しているため再投入しない）。

---

## Phase 10: 完了報告

### 複数Issueの場合（star 型並列実装完了後）

1. 各Issueの実装サマリー
2. 各PR URLとCIステータス
3. E2E対象チケットの `/explain-e2e` 結果（リードがメインセッションで実施した解説と独立検証）
4. クリティカル設計の逸脱検知（`needs_human`）でユーザー判断を仰いだチケットの一覧
5. テスト結果の集約・Issue間の整合性確認
6. **次のアクションの案内**: 各PRに対し `/pr-review-respond`。マージは base=統合ブランチならリードが `/pr-merge` で自律実行、base=既定ブランチならユーザーに `/pr-merge` を案内（項目8参照）
7. **worktreeの状態**: 各チケットの worktree が保持されていることを報告し、レビュー対応後に Phase 11 でクリーンアップする旨を伝える
8. **統合ブランチ方式の場合**: 全サブタスク PR を統合ブランチへ自律マージ後、残る唯一の人間ゲート（①`/promote-verify` で昇格前検証パッケージ（受入基準の全数チェック表・サブタスク完了突合・全E2E/QC結果）を生成して判断材料を揃え、統合ブランチで**最終動作確認**: `/walkthrough`・E2E・手動確認で親 Issue の完了条件を人間が通す → ②既定ブランチ向けの昇格 PR を作成 → ③人間承認 → ④マージ）を案内する

> **重要**: 複数Issueの場合、この時点でworktreeを削除しません。PRレビューで指摘が見つかった場合、修正のためにworktreeが必要です。クリーンアップは Phase 11 で行います。

---

## Phase 11: Worktreeクリーンアップ（複数Issueの場合）

全PRのレビュー対応が完了した後、またはユーザーが明示的にクリーンアップを指示した場合に、各チケットの worktree を削除する。

> **前提条件**: 全PRについて以下がすべて完了していること:
> - セルフレビューの指摘修正が完了
> - PRレビュー指摘の修正が完了（指摘なしの場合は不要）
> - 必要な修正のコミット・プッシュが完了

`scripts/worktree-cleanup.sh` を各チケットの worktree に対して呼ぶ。既定（フラグ省略）では未コミット差分がある worktree の削除を拒否する（保護がデフォルト）ため、**PR 未作成・`failure`/`needs_human` のチケットの worktree はそのまま保護され、無条件の `--force` を使わない限り誤って削除されない**:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/worktree-cleanup.sh" {チケットのworktree_path}
```

削除対象は PR 作成済み＋レビュー対応完了のもののみ。まだ調査・再試行が必要な worktree は `--skip-if-dirty` を付けて一括ループしてもよい（dirtyなものだけ自動的にスキップされる）。出力JSON（`removed`/`skipped`/`dirty`）の**フィールド定義の正本は、プラグイン配下の `scripts/README.md`「worktree-setup.sh / worktree-cleanup.sh の出力仕様」**（ここには複製しない。Read する場合は `<base>/../../scripts/README.md` として解決すること）。

> **注意**: ユーザーが後から追加の修正を行う可能性がある場合は、worktreeの削除を保留してもよい。ユーザーに確認してからクリーンアップすることを推奨する。

---

## Worktree管理方針

| Issue数 | worktree使用 | 削除タイミング | 削除フェーズ |
|---------|-------------|--------------|------------|
| 単一Issue | 不使用 | - | - |
| 複数Issue | リードが `scripts/worktree-setup.sh` で作成し、Dynamic Workflow が使用 | 全PRのレビュー対応完了後、またはユーザーの明示的な指示 | Phase 11（`scripts/worktree-cleanup.sh`） |

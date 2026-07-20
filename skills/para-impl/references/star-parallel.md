# star 型並列実装（複数Issue時）

> **spawn 前に必読**: このファイルには worker spawn プロンプトの必須項目と「worker からの返却の処理」表が含まれます。見落とすと並列実装が全滅する規律のため、`ticket-worker` を spawn する前に必ず本ファイル全体を読んでください。
>
> 参照パスは `${CLAUDE_PLUGIN_ROOT}` 配下です（例: `${CLAUDE_PLUGIN_ROOT}/skills/para-impl/references/star-parallel.md`）。Read にはプラグインの絶対パスが必要です。
>
> **v2.1.0 での再設計（Issue #105）**: v2.0.0 は worker 委譲を Dynamic Workflow（`para-impl-tickets.js`）化したが、ヘッドレス（`claude -p`）呼び出しで Workflow が孤児化し実装が完了しないリグレッションが確認されたため、Task ツールで `ticket-worker` サブエージェントを並列 spawn する同期委譲（v1.x の star 型）へ戻した。Workflow 化で得た資産（`worktree-setup.sh`/`worktree-cleanup.sh`/`ci-wait.sh` の決定的スクリプト、loop-until-green と CI 失敗ログ注入、衝突予測ヒント）は本フローに取り込み済み。

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

### 衝突予測ヒント（Issue数が5件以上の場合のみ）

Issue 数が **5件以上**の場合のみ、直列化の判断材料として `issue-conflict-predictor` エージェントを **Issue ごとに1体、Task ツールで並列 spawn** する（`subagent_type` は **`claude-harness:issue-conflict-predictor`**。5件未満では過剰最適化のため実施しない）。各エージェントには担当 Issue のタイトル・本文のみを渡し、変更が見込まれるファイルパス群（`predicted_files`）と依存 Issue 番号（`depends_on`）を予測させる。

全予測が返ったら、**リードが予測ファイル集合の交差を突き合わせる**。lockfile 等のマージ容易なファイル（`package-lock.json` / `yarn.lock` / `pnpm-lock.yaml` / `go.sum` / `Cargo.lock` 等のベース名）は交差判定から除外する。

> **ヒントであって自動直列化トリガーではない**——予測ベースのため偽陰性・偽陽性を含みうる。交差が出たペアを機械的に直列化するのではなく、次節「直列化の判断」の材料として使い、統合時に実際に衝突した場合の解決（リードの役目）という既存の安全網は維持する。

### 直列化の判断（残留結合の吸収）

「独立したチケット」でも残留結合（共有ファイル・共通型・PR マージ順）はゼロにならない。リードが次で吸収する:

- Issue 間に依存関係がある、または同一ファイル群への変更が Phase 1 の分析・衝突予測ヒントで見えている場合は**並列にせず直列化**する。後続 worker の spawn 条件は base で異なる:
  - **base = 統合ブランチ**: 先行チケットの PR をリードが `/pr-merge` で自律マージしてから後続を spawn する（統合ブランチ宛は人間承認不要）
  - **base = 既定ブランチ**: 既定ブランチへのマージは人間ゲートのため、リードは**先行 PR のマージをユーザーに依頼し、マージを確認してから後続を spawn する**。依頼できない場合（headless 等）は後続をスキップし、完了報告に再開手順を明記する
- それでも統合時に衝突した場合は**リードがコンフリクトを解決**する

> **headless（`claude -p`）での並列実装を計画する場合**、既定ブランチ base の直列化ペアは上記のとおり永久に解除できない。衝突が予見される Issue 群を無人で完走させたいときは、呼び出し時に `--base <統合ブランチ>` を指定する（統合ブランチ方式ならリードが自律マージで直列化を解除できる）。

### worktree・ブランチ準備

**事前確認（permission 拒否の予防）**: allow 権限は **git tracked の `.claude/settings.json`** に置く（`/init-project` のステップ 4b 参照）。gitignore された `.claude/settings.local.json` は worktree にコピーされず、サブエージェントへの適用も環境依存のため当てにしない。worker を spawn する前に必要な権限（`cd` / `git` / `gh` 系・`bash`（`scripts/worktree-setup.sh` 等のスクリプト実行））が揃っているかを確認し、不足があればユーザーに案内する。

リードが並列化対象の各 Issue について `scripts/worktree-setup.sh` を呼び、worktree と作業ブランチを作成する（Phase 3 に相当）:

> **スクリプトの所在（重要）**: 本スキルはプラグインとして配布されるため、スクリプトは**ユーザーのプロジェクトroot ではなく、プラグイン配下**にある。スクリプトを実行する際は必ず `bash "${CLAUDE_PLUGIN_ROOT}/scripts/worktree-setup.sh" <引数>` の形式（`${CLAUDE_PLUGIN_ROOT}` は表記上のプレースホルダであり環境変数ではない。実行前に、スキル起動時の「Base directory for this skill」から解決したプラグインルートの絶対パスに置換して実行する）を用い、相対パス `scripts/worktree-setup.sh` では呼び出さないこと。
<!-- 正本: docs/plugin-path-conventions.md -->

**Issueごとに逐次（1件ずつ）呼ぶこと（並列実行しない）**: `git worktree add`/`git fetch` は共有 `.git` を書き換える操作のため、複数Issue分をリードが同時（バックグラウンド実行等）に走らせると競合しうる。1件分の呼び出しが完了（stdout JSON取得）してから、次のIssueについて同様に呼ぶ:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/worktree-setup.sh" {issue番号} {type}/issue-{番号}-{説明} {base}
```

> `scripts/worktree-setup.sh`/`scripts/worktree-cleanup.sh` 自体にも、共有 `.git` への書き込み区間（`git fetch`/`git worktree add`/`git worktree remove`）を保護する mkdir ベースの簡易ロック（両スクリプトが同一のロックディレクトリを取り合う）が実装されている（Issue #45）。これは上記の逐次呼び出し規律が守られなかった場合の**防御第二層**であり、一次的な保証は本節の「逐次実行」規律そのものである（ロックがあるからといって並列に呼び出してよいわけではない）。

出力JSON（`worktree_path`・`created`・`reused`・`branch_existed`）の**フィールド定義の正本は、プラグイン配下の `scripts/README.md`「worktree-setup.sh / worktree-cleanup.sh の出力仕様」**（ここには複製しない。Read する場合はスキル起動時の「Base directory for this skill」を起点に `<base>/../../scripts/README.md` として解決すること）。`reused: true` の場合は前回実行分の worktree をそのまま再利用する（再実行時の冪等性）。エラー（base が remote に存在しない・別ブランチの worktree と衝突等）は非0 exitで返るため、内容を確認してから次のIssueへ進む。

全 Issue 分の `worktree_path` を集めたら、次節の worker spawn へ進む。

### worker への委譲

独立した Issue の `ticket-worker` を並列に spawn する（Task ツールの `subagent_type` は plugin namespace prefix 付きの **`claude-harness:ticket-worker`** を指定する。prefix 無しは名称解決エラーになる。並列対象は**1メッセージにまとめて spawn** する）。

spawn プロンプトに含めるもの:

- Issue 番号・worktree パス（`worktree-setup.sh` の出力 `worktree_path`）・作業ブランチ・base
- 「1チケットの実装フロー」（SKILL.md 本文の同名セクション）の Phase 4-5〜9 の手順（Phase 3 はリードが worktree 作成で実施済み。Phase 7 は `/create-e2e` まで）
- 要件チケットの「クリティカル設計決定」セクション
- **`scripts/ci-wait.sh` の絶対パス**（Phase 9 の CI 確認に使う。`${CLAUDE_PLUGIN_ROOT}` をリードが絶対パスへ解決してから渡す——worker はプレースホルダを解決できない）

> 行動規範（permission 拒否時の振る舞い・headless 制約・worktree 内でのコマンド形式・CI確認と loop-until-green の規律）は `ticket-worker` のエージェント定義に含まれ、spawn 時に自動で伝播する。プロンプトへの手動注入は不要。

### worker からの返却の処理

| worker の返却 | リードの動作 |
|---|---|
| 通常完了（PR URL・CI green） | Phase 10 の集約へ。E2E対象チケットは worker 返却のシナリオ一覧を使い、リードが `/explain-e2e` をメインセッションで実施 |
| `failure`（`/quality-check` 未通過、または loop-until-green 上限3回でCIがgreenにならず） | 当該チケットをスキップして報告（試行回数・最後のCI状態・失敗ログ抜粋と、クロスリポジトリ依存の確証結果など worker の failure 返却に含まれる証跡も転記する）。他 worker は継続 |
| クリティカル設計の逸脱・判断待ち | 内容をユーザーに提示して判断を仰ぐ。headless の場合は完了報告に「判断待ち」として明記する |
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
8. **統合ブランチ方式の場合**: 全サブタスク PR を統合ブランチへ自律マージ後、残る唯一の人間ゲート（①`/promote-verify` で昇格前検証パッケージ（受入基準の全数チェック表・サブタスク完了突合・全E2E/QC結果）を生成して判断材料を揃え、統合ブランチで**最終動作確認**: `/walkthrough`・E2E・手動確認で親 Issue の完了条件を人間が通す → ②既定ブランチ向けの昇格 PR を作成 → ③人間承認 → ④マージ）を案内する

> **重要**: 複数Issueの場合、この時点でworktreeを削除しません。PRレビューで指摘が見つかった場合、修正のためにworktreeが必要です。クリーンアップは Phase 11 で行います。

---

## Phase 11: Worktreeクリーンアップ（複数Issueの場合）

全PRのレビュー対応が完了した後、またはユーザーが明示的にクリーンアップを指示した場合に、各 worker の worktree を削除する。

> **前提条件**: 全PRについて以下がすべて完了していること:
> - セルフレビューの指摘修正が完了
> - PRレビュー指摘の修正が完了（指摘なしの場合は不要）
> - 必要な修正のコミット・プッシュが完了

> **削除対象の判定はリードの契約（重要）**: `scripts/worktree-cleanup.sh` の既定動作（未コミット差分＝dirtyなworktreeの削除拒否）は**dirty判定のみに基づく保護**であり、`failure`・判断待ちのチケットでもコミット・push済みで作業ツリーがクリーンなら削除されてしまう。**dirty判定だけでは failure・判断待ちの worktree を保護できない**。そのため、cleanup対象の選定自体はリード（呼び出し側）の契約とし、以下の3条件を**すべて満たすチケットのみ**を `scripts/worktree-cleanup.sh` の呼び出し対象にする（1つでも満たさなければ、そのチケットに対してスクリプトを呼ばない＝worktreeをそのまま保持する）:
>
> 1. worker の返却が通常完了（`failure`・判断待ちのチケットは対象外——完了報告に「保持中」として明記する）
> 2. PR作成済み
> 3. 当該PRの `/pr-review-respond` によるレビュー対応が完了している

上記3条件を満たす各チケットの worktree に対してのみ呼ぶ:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/worktree-cleanup.sh" {チケットのworktree_path}
```

既定（フラグ省略）の dirty時削除拒否は、上記3条件による選定を通過したチケットに対する**セカンダリの安全網**（レビュー対応の最終コミットのpush漏れ等、想定外の未コミット差分が残っていた場合の最終防御）として働く。3条件を満たすが一時的にdirtyな場合はエラーで停止するため、原因を確認してから再実行する。`--skip-if-dirty` は、3条件を満たす対象群を一括ループする際に一時的なdirtyが混在するケース向けの補助フラグであり、3条件そのものの代替（failure・判断待ちチケットの保護手段）としては使わない。出力JSON（`removed`/`skipped`/`dirty`）の**フィールド定義の正本は、プラグイン配下の `scripts/README.md`「worktree-setup.sh / worktree-cleanup.sh の出力仕様」**（ここには複製しない。Read する場合は `<base>/../../scripts/README.md` として解決すること）。

> **注意**: ユーザーが後から追加の修正を行う可能性がある場合は、worktreeの削除を保留してもよい。ユーザーに確認してからクリーンアップすることを推奨する。

---

## Worktree管理方針

| Issue数 | worktree使用 | 削除タイミング | 削除フェーズ |
|---------|-------------|--------------|------------|
| 単一Issue | 不使用 | - | - |
| 複数Issue | リードが `scripts/worktree-setup.sh` で作成し ticket-worker が使用 | 全PRのレビュー対応完了後、またはユーザーの明示的な指示 | Phase 11（`scripts/worktree-cleanup.sh`） |

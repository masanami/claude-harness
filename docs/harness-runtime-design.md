# harness runtime 設計（Issue #201）

> **状態: 設計（2026-09-21 に問い Q1〜Q15・N1〜N4 を決定済み）**。本文書は Issue #201 の決定（2026-09-20〜21）を前提に、実装に入る前に確定させるべき設計を置く。問いの決定の記録は §11 にある。**「未決」と書いた箇所だけが本文書で決めていないもの**で、§11 に記録してある。
>
> **2026-09-29 更新**: 複数 Issue の並列実行は flywheel の責務にするとオーナーが決めた。PR-5（`fanout`・`plan-parallel`・`para-impl` ワークフロー）は実装を見送り、§11.3 の「検討」へ移した。決定の記録は §11.4。
>
> **2026-10-25 追記**: ワークフロー定義を上書きの YAML で調整する設計（Issue #309）は [harness-runtime-overrides.md](harness-runtime-overrides.md) に置いた（2026-10-25 に問いを決定済み）。
>
> **2026-10-25 追記**: ワークフローの形と run の現在地を表示する設計（Issue #308）は [harness-runtime-visualization.md](harness-runtime-visualization.md) に置いた（2026-10-25 に問いを決定済み）。
>
> - 正本は Issue #201 のコメント群。食い違ったら Issue が正。
> - 本文書は設計の置き場であり、`skills/`・`agents/`・`scripts/` の挙動は変えない（実装は §10 の段階計画に従い別 PR で行う）。

---

## 0. 前提（決定済み・蒸し返さない）

| 論点 | 決定 | 出典 |
| --- | --- | --- |
| 主動機 | セッションを越える永続化・resume・観測 | 2026-09-20 方針の書き直し §2 |
| 設計の主対象 | **クラッシュ復旧ではなく、計画された複数ラウンドの再開**。最小状態は ラウンド・残予算・ブランチ（作業ツリー）・ゲート | 2026-09-21 決定④ |
| 配布形態 | 独立した CLI が本体＋薄いプラグイン。CLI の `setup` が `claude plugin marketplace add` / `claude plugin install` を呼ぶ | 2026-09-21 決定① |
| リポジトリ | claude-harness の中 | 2026-09-21 決定① |
| 実装言語 | Go。既存の bash スクリプトは移植せず子プロセスとして呼ぶ | 2026-09-21 決定② |
| ステップ定義 | 式を持たない YAML。遷移条件はステップが返した型付きの値か終了状態との一致だけ。ステップの種類は Go のコードで持つ | 2026-09-21 決定③ |
| LLM と遷移の境界 | LLM は意味判断を型付き出力で返し、runtime が決定的な遷移へ写像する。不正値・未知値は fail-closed | 2026-08-23 最終決定 §5（2026-09-20 で維持） |
| flywheel との関係 | runtime は flywheel へ依存しない。flywheel は harness 内部の step・判断値を理解しない | 2026-08-23 §3（維持） |
| 非目標 | UI・daemon・scheduler・remote worker・汎用 DSL・provider 選択 | 2026-08-23 §4・2026-09-20 §8 |

本設計の承認の場で 2026-09-21 に決まったこと（Q1〜Q15）は §11 に記録した。そのうち上の決定の**理由**に影響するものが 1 つある。Q4（CLI がスクリプトと YAML をバイナリに埋め込んで持つ）を採ったため、決定③の理由の 1 つ「YAML なら workflow の修正でバイナリを出し直さずに済む」は**失われた**。オーナーはこれを承知のうえで Q4 を採った。**決定③（式を持たない YAML）そのものは変わらない**。残る理由（実行前に検証できる・差分が読める・式の評価器＝DSL を作らずに済む・内部のグラフをデータとして持つ）だけで決定③は成り立つ（§6.5）。

### 0.1 本文書で**空けておく**もの

- **flywheel が harness を呼ぶときの起動形（接続契約）**。flywheel `docs/architecture.md` §10（接続ツールの宣言。claude-flywheel#95）の実装が入ってから確定させる。先に決めると、flywheel 側が harness 固有の起動形を本体に抱える。本文書が決めるのは「runtime が**出せなければならない情報**」（§5.6）までで、その**書式・引数・終了コードの割り当て**は空ける。
  - **2026-09-28 更新（#274）**: flywheel が `cli` 形態の接続ツールとの契約（接続契約 v1。flywheel `docs/features/m3-invoker-delegation.md` §クリティカル設計決定 3・決定 M3H2）を定めた。**契約は flywheel が定め、harness が合わせる**ので、flywheel に harness 固有の形を抱えさせないという上の趣旨はそのまま保たれる。harness は契約 v1 を `harness contract` の入口で出す（§5.6.1）。空けておくのは、契約 v1 に無いこと（v2 以降の形）だけになった。

### 0.2 実測値（本文書の数字はこのクローンで測り直した値。2026-09-21・`4483c52`）

| 対象 | 値 | 測り方 |
| --- | --- | --- |
| `scripts/*.sh`（直下） | 27 本 | `ls scripts/*.sh \| wc -l` |
| bash テスト | 44 本 | `ls scripts/tests \| wc -l` |
| `skills/` `agents/` `scripts/` の `.md`/`.sh`（`*/tests/*` 除外） | 19,394 行 | `find … -not -path '*/tests/*' \| xargs cat \| wc -l` |
| 実装委譲フローの散文（`skills/impl/SKILL.md`・`skills/para-impl/SKILL.md`・`references/join-gate.md`・`references/star-parallel.md`・`agents/ticket-worker.md`） | **82,139 B**（261＋184＋64＋170＋79 行） | `wc -c` |
| PR CI | 測った時点では未設置（`.github/` が存在しない）。その後 #349 で ubuntu の PR CI を追加した（現状は §6.3） | — |
| リリース自動化 | 無し（版上げは `chore(release): bump plugin version` の手動 PR） | `git log` |
| 単一の bash テスト入口 | 無し（各テストを `bash scripts/tests/xxx.sh` で個別に実行） | `scripts/README.md`「テスト」 |

---

## 1. 設計の骨格

```text
人間の端末 / 薄いスキル / （将来）flywheel の接続ツール宣言
          │  harness run / status / resume / approve / cancel
          ▼
┌──────────── harness CLI（Go・単一バイナリ） ────────────┐
│ workflow-core                                          │
│   YAML 読み込みと静的検証 → 状態機械 → イベントログ      │
│   ステップ種類（Go）: command / llm / select / gate /    │
│     workspace / pull-request / fanout / plan-parallel   │
│   予算の累計・ラウンドの区切り・子プロセスの監視          │
└────────────────────────────────────────────────────────┘
      │ 子プロセス                     │ 子プロセス
      ▼                                ▼
 scripts/*.sh（既存・移植しない）   claude -p（既存の skills/agents をそのまま使う）
```

原則（Issue 本文の線引きを構造で強制する形）:

- **メソドロジーは文章**（`agents/`・`skills/` の観点・規律・判断基準は残す）
- **制御フローは YAML＋Go のステップ種類**（順序・分岐・fan-out・合流・上限・ゲート）
- **機械処理はスクリプト**（`worktree-setup`・`ci-wait`・`quality-check-runner` 等を子プロセスとして呼ぶ）

図のステップ種類のうち `fanout`・`plan-parallel` は PR-5 とともに実装を見送った（§11.4）。複数 Issue の並列実行は flywheel が持ち、runtime は 1 run ＝ 1 Issue の `ticket` だけを動かす。

### 1.1 ステップの粒度（Q6 で決定）

**runtime の 1 ステップ ＝ 1 回の子プロセス起動**（スクリプト 1 回、または `claude -p` 1 回）とする。

- `feature-implementer` の**内側のループ**（`/quality-check` 最大 3 回・`/self-review` の反復・`design-deviation-verifier` の多数決）は、最初の段階では**エージェント定義の散文に残す**。これらは 1 つの Claude セッション内の Task ネストで閉じており、外へ出すには `/self-review` 自体の移行（Issue 本文の旧 Phase 2 相当）が要る。今回の主対象（ラウンドをまたぐ状態）には効かない。
- 外側のループ（Phase 4→8 の差し戻し・CI 待ち・レビュー待ち・人の承認待ち・合流）は**すべて runtime へ移す**。ここが「再開のたびに親が組み立て直している」部分である。
- 帰結として **`ticket-worker` は廃止する**（責務は「`/impl` を呼ぶ」「CI の loop-until-green」「返却」で、いずれも runtime が持つ）。Task ネストは `ticket-worker`（深度1）→ `feature-implementer`（深度2）→ `code-reviewer`（深度3）から、`feature-implementer` がセッションの主体（深度0）になる形へ 1 段浅くなる。`claude -p --agent claude-harness:feature-implementer` で**主体に据えられることを PR-3 で実測した**（2026-09-26・`claude` 2.1.283・インストール済みのプラグインを名前空間付きで指定。空のディレクトリで「作業はせず、あなたのエージェント名だけを答えて」に「機能実装エージェント（feature-implementer）」と答え、結果の `modelUsage` のモデルがセッション既定〔`claude-opus-5-5`〕ではなくエージェント定義の `model: sonnet` に当たる `claude-sonnet-5` だった）。
  - **実測で分かった事実（#282）**: `--agent` と `--json-schema` を併せて使うと、エージェントの `tools` に `StructuredOutput` が無い限り `structured_output` が付かない（2026-09-29・`claude` 2.1.284。runtime 側の `--allowedTools` では足せない）。`feature-implementer` の `tools` に足した。実測の記録は docs/harness-runtime-shadow.md §7.1。
  - **2026-09-29 更新**: `/para-impl` を散文のまま残すと決めた（§11.4 D4）。散文の `/para-impl` は `ticket-worker` 経由で各 worktree の `/impl` を呼ぶので、PR-7 では `ticket-worker` を削除しない（§10）。上の「廃止」を今後どう扱うかは未決（§11.4 の U1）。

---

## 2. 現行フローの制御フロー棚卸し

`skills/impl/SKILL.md`・`skills/para-impl/SKILL.md`・`references/star-parallel.md`・`references/join-gate.md`・`agents/ticket-worker.md`・`agents/feature-implementer.md`・`scripts/specs/worktree-setup.md`・`scripts/specs/ci-wait.md`・`skills/pr-review-respond/SKILL.md`（ラウンドの区切りに関わる停止点のみ）を読んで洗い出した。**Issue に書かれていない分岐・停止条件を含む**（★印）。

「判断」列: **決** ＝決定的に決まる（コード・スクリプトで判定できる）／ **意** ＝ LLM の意味判断が要る。

### 2.1 `/impl`（1チケット）

| # | 制御 | 種類 | 判断 | 現行の所在 |
| --- | --- | --- | --- | --- |
| I1 | Issue がちょうど 1 件でなければ実行せず `/para-impl` を案内して停止 | 停止条件 | 決 | 「責務外」 |
| I2 | base の決定: `--base` ＞ Issue 本文の `Base:` 行 ＞ 既定ブランチ | 分岐 | 決 | 「base の決定」 |
| I3 | base が統合ブランチなら remote 存在確認、無ければ停止して作成を促す | 停止条件 | 決 | 同上 |
| I4 | E2E 対象判定（認証・権限・クリティカルパス） | 分岐の材料 | 意 | 「Phase 1〜2 相当」 |
| I5 | `--worktree` の有無だけで経路が分岐（有: Phase 3 スキップ・Phase 6 を `/create-e2e` までに切る） | 分岐 | 決 | 「呼び出し元」表 |
| I6 | Phase 4 `feature-implementer` の返却 4 種: 通常完了 / `failure` / `skip` / 逸脱検知停止 | 分岐 | 意（返却は型付きにできる） | Phase 4「例外ケース」 |
| I7 | `skip` は進んでよいが `pass` として扱わず、未検証の事実を PR 本文・報告へ明記 | 値の受け渡し | 決 | 同上 |
| I8 | 逸脱検知 → 人に判断を仰ぐ（headless では「判断待ち」で返却） | ゲート | 意→人 | 同上 |
| I9 | Phase 5 `/commit`（内部で safety net の `/quality-check`） | 順序 | 意（メッセージ作成） | Phase 5 |
| I10 | Phase 6 は E2E 対象のときだけ（I4 の値で分岐。**直前のステップではなく 2 段前の値**） | 分岐 | 決（値は I4） | Phase 6 |
| I11 | E2E 失敗 → Phase 4 へ戻る。★**単一 Issue 経路ではこの戻りに上限が書かれていない**（並列経路は `ticket-worker` の「Phase 4→8 最大 3 回」が効く） | retry | 決 | Phase 6 |
| I12 | `/explain-e2e` は Phase 1 が対話前提。並列経路ではリードがメインセッションで実施 | 実行主体の分岐 | — | Phase 6 注記 |
| I13 | Phase 7: `residualFindings` は `converged` の値に関わらず**全件**を PR 本文へ転記。クロスリポジトリ確証も転記 | 値の受け渡し | 決 | Phase 7 |
| I14 | Phase 8: CI 失敗 → Phase 4 へ戻る。★単一経路は `gh pr checks --watch`、並列経路は `ci-wait`（2 経路で CI 確認の手段が違う） | retry | 決 | Phase 8 |
| I15 | 合流ゲート: 起動したサブエージェントを最終応答前にすべて合流 | 合流 | 決 | 「合流ゲート」→ `join-gate.md` |

### 2.2 `/para-impl`（fan-out）

> **2026-09-29 注記**: 下の P1〜P13 のうち並列の部分（P3〜P11）は flywheel の責務になった（§11.4）。`/para-impl` は散文のまま残るので、この棚卸しは現行の散文の記録として、また §3.5（見送った書き下ろし）の材料として残す。

| # | 制御 | 種類 | 判断 | 現行の所在 |
| --- | --- | --- | --- | --- |
| P1 | 引数: Issue 群・`--base`・`--max-parallel`・`--serial`（繰り返し可） | 入力 | 決 | 「パース方法」 |
| P2 | Issue 数 1 → リードが `/impl` を直接（worktree なし）／複数 → star 型 | 分岐 | 決 | 「ルーティング」 |
| P3 | `--max-parallel` 有 → 受け取った天井・直列グループのとおり（判断し直さない・上位層へ戻らない）／無 → 自分で決める | 分岐 | 決／意 | Phase 2 |
| P4 | Issue 数 ≥ 5 のときだけ `issue-conflict-predictor` を Issue ごとに並列 spawn し、予測ファイル集合の交差を突き合わせ（lockfile 除外） | 分岐＋fan-out | 決（閾値）＋意（予測） | `star-parallel.md` |
| P5 | 予測で追加直列化してよいのは天井を**下回る方向だけ**。受け取ったグループの解除は不可。追加の事実と理由を報告 | 制約 | 決 | Phase 2 規律 4 |
| P6 | 迷ったら停止せず保守側（直列化）へ倒す | 既定値 | 決 | Phase 2 規律 5 |
| P7 | 直列ペアの後続起動条件: base＝統合ブランチ → 先行 PR をリードが `/pr-merge` で自律マージしてから／base＝既定ブランチ → 人にマージを依頼し確認してから。★**headless では後続をスキップして再開手順を報告**（＝ラウンドの区切りがあるのに状態を持てず、捨てている） | 依存・ゲート | 決 | 「直列化の判断」 |
| P8 | worktree の払い出しは**逐次**（共有 `.git` の競合。スクリプト側 mkdir ロックは第二層） | 順序 | 決 | 「worktree・ブランチ準備」 |
| P9 | worker を 1 メッセージでまとめて並列 spawn、同時数は天井以下、残りは合流後に起動 | fan-out | 決 | 「worker への委譲」 |
| P10 | worker 返却の 6 分類（通常完了 / failure / 判断待ち / 衝突検知 / 未受領 / ネスト未解消） | 合流・分岐 | 決（分類は返却の型） | 「worker からの返却の処理」表 |
| P11 | 統合時にコンフリクトしたらリードが解決 | 分岐 | 意 | 同上 |
| P12 | Phase 10 cleanup の対象は 3 条件（通常完了・PR 作成済み・レビュー対応完了）をすべて満たすものだけ。dirty 判定は第二層 | 停止条件 | 決 | Phase 10 |
| P13 | 完了報告: 天井・直列グループの出所と追加直列化（0 件でも明記） | 出力契約 | 決 | Phase 9 |

### 2.3 `ticket-worker`（並列経路の外側ループ）

| # | 制御 | 種類 | 判断 |
| --- | --- | --- | --- |
| W1 | `ci-wait` の `ci`: `green`/`none` → 完了、`red` → Phase 4 へ**スコープ付き修正**で差し戻し（`failure_log_excerpt` を注入・Step a〜e を再帰開始しない）、`timeout` → `ci-wait` を 1 回だけ再試行し、なお `timeout` なら `failure` | 分岐・retry | 決 |
| W2 | Phase 4→8 は最大 3 回。**新情報（CI/E2E 失敗ログ）の無い再委譲はしない**。初回 Phase 4 が `failure` なら再委譲せず即 `failure` | retry 上限 | 決 |
| W3 | 逸脱で停止したら再試行しない（再試行で直らない） | 停止条件 | 決 |
| W4 | 2 回目以降は PR 作成を冪等に（`pr_exists` なら push のみ） | 冪等性 | 決 |

### 2.4 PR 後のラウンド（`/impl` の外。ラウンドの区切りとして必要）

2026-09-21 の実測で再開の中身とされた「レビュー対応のラウンド・検証での差し戻し・質問への回答」は、`/impl` の完了後に起きる。`/impl` は完了報告で `/pr-review-respond`・`/pr-merge` を**案内するだけ**で、その間の状態を持たない。

| # | 制御 | 所在 |
| --- | --- | --- |
| R1 | レビューが付くまで待つ（外部待ち） | 暗黙（どこにも書かれていない） |
| R2 | `/pr-review-respond`: `qcFailed: true` なら Step 7 以降へ進まず停止して人に判断を仰ぐ | Step 5 |
| R3 | `/pr-review-respond`: `design_change`/`critical` 分類は人間ゲート | Step 7 |
| R4 | 修正 push 後は CI を再確認（`ticket.yaml` では品質ゲートも通す。#339） | 暗黙 |
| R5 | マージ: base＝統合ブランチは自律（`/pr-merge`）、既定ブランチは人間ゲート。**2026-11-20 に改めた（#388。オーナーの決定）**: 上は「マージしてよい」（`ready`）を受けた後の道として残す。そこへ、「入れてよい」（`land`）と通した中身（先頭のコミット）を受け、PR の先頭が一致したときだけ、機械が宛先（統合ブランチでも既定ブランチでも）へ入れる道を足す。通した側（flywheel）の承認が、人の承認に当たる。リポジトリごとに許す設定は持たない（§5.6.2・[harness-runtime-overrides.md](harness-runtime-overrides.md) §6） | `/impl` Phase 7 注記・`star-parallel.md` Phase 9-8。改めた分は §11.9 |

---

## 3. 式を持たない YAML での書き下ろし

### 3.1 YAML の文法（v1）

YAML に書けるのは次だけ。**条件式・演算・文字列の組み立て・繰り返し構文は無い**。

| 要素 | 形 | 意味 |
| --- | --- | --- |
| `schema` | `harness.workflow/v1` | スキーマ版（§7.3 の版照合の対象） |
| `inputs` | 名前 → 型（`integer`/`string`/`array`/`object`）・`required` | run の入力。起動時に検証 |
| `limits` | 名前付きの**整数・金額リテラル** | 上限値（予算・差し戻し回数）。ステップと遷移から名前で参照する |
| `steps.<id>.kind` | Go に登録された種類名 | 振る舞いは Go 側 |
| `steps.<id>.with` | 名前 → **参照 1 つ**またはリテラル | ステップ入力。参照の文法は §3.3 |
| `steps.<id>.add_dirs` | **文字列の参照**またはリテラルの列（`llm` だけ） | `claude` の `--add-dir` へ渡すフォルダ。作業ディレクトリの外のファイルを読ませる（§5.6.2）。解決した値が空の文字列なら渡さない |
| `steps.<id>.output` | JSON Schema ファイル | 出力の検証。**`outcome`（enum）を必ず持つ**＝遷移のキー |
| `steps.<id>.on` | `outcome の値` → 遷移先 | **一致だけ**。すべての enum 値を網羅していなければ読み込み時に拒否 |
| 遷移先 | ステップ id ／ `{goto, with, limit, exhausted, note}` ／ `{gate: <id>}` ／ `{fail: <理由>}` ／ `{done: <理由>}` ／ `{retry: <n>, exhausted: …}` | `limit` は `limits` の名前。回数は Go が数える。`note: optional` は `$gate.note` を渡す `goto` の添え書きを任意にする（§3.3。#377） |
| `timeout`・`budget_usd` | リテラル | ステップ単位の上限 |

終了状態も `outcome` として同じ表で扱う。runtime が付与する予約値: `step_error`（非 0 終了・起動失敗）・`step_timeout`（ステップの `timeout` 超過）・`invalid_output`（スキーマ不一致・未知の enum 値）・`budget_exhausted`。予約値はステップの出力の enum 値と衝突してはならず、`harness validate` が衝突を拒否する（例: `ci-wait` は `ci: "timeout"` を返すので、予約値の側に `step_` を付けて分けた）。**予約値を `on` に書かなければ、既定で run を `failed` にする**（fail-closed。書けば明示的に別の遷移へ送れる）。

**#388 の設計で足す文法（§5.6.2。`detail`・`interrupted` と `$gate.approved_ref` は S3-2〔#392〕、ゲートの `refresh` は S3-5〔#395〕で実装済み、残りは実装はこれから。スキーマ版は `harness.workflow/v1` のまま）**: 最上位の `facts`（名前 → `$steps.<段>.<欄>` の配列。接続契約の `facts` に出す値の宣言）と `release_on`（`cancelled`・`failed` の配列。その状態で終わるときに、自分が作った作業ツリーを片付ける）。ゲートの `refresh`（`pr-head`。待っている間の PR の先頭を `status` で取り直す）。ゲートへの遷移 `{gate: <id>}` の `detail`（参照 1 つ。開いたゲートに添える、戻った理由の文）。input 型のゲートから出る `goto` の `interrupted: { fail: <理由> }`（その遷移で始まるラウンドの間に runner が居なくなったら、`interrupted` のゲートを開かず失敗で終える）。どれも比較・論理結合・加工を持たず、下の「式にしないための線引き」の内である。

`retry` と `limit` の回数は Go が数える。数え方の単位: `limit`（差し戻し）は **unit 単位でラウンドをまたいで**累計する（§4.2）。`retry` は**ラウンド単位**で数え、ゲートを抜けて新しいラウンドに入ると 0 に戻る（例: `ci-pending` ゲートから resume した `ci` は、再び 1 回の再試行を持つ）。

#### 式にしないための線引き（Q12 で決定）

YAML と Go のステップ種類が許す判定は**一致だけ**である。遷移のキーは「ステップの `outcome`（enum）の値が表のどの行と一致するか」、`select` は「参照 1 つが指す enum 値をそのまま outcome にする」だけで、どちらも比較（大小・範囲）・論理結合（and / or / not）・加工（演算・連結・集計・関数）を持たない。**今後の要求で比較・論理結合・加工を YAML 側に足す必要が出たら、それは式の導入とみなして止める**。その場合はまず Go 側のステップ種類の追加で解けるかを検討し（`plan-parallel` の `predict_min_issues` のように、閾値はリテラル引数として種類の中で比較する。`plan-parallel` は見送ったが、書き方の例としては有効）、それでも足りなければオーナーの判断を仰ぐ（決定③の確認事項どおり）。`harness validate` は `when:`・`if:` のような条件キーや、参照の文法（§3.3）に無い形を未知のキーとして拒否する（§6.3）。

### 3.2 追加するステップ種類（Go）

式を足さずに書き切るため、次の 8 種類を Go 側に置く（新しい振る舞いは YAML の表現力ではなく種類の追加で解く、という決定③どおり）。このうち `fanout`・`plan-parallel` は PR-5 とともに実装を見送った（§11.3・§11.4）。表には検討の材料として残す。

| kind | 振る舞い | 解いている制御 |
| --- | --- | --- |
| `command` | `scripts/` のスクリプトを argv で起動。stdout JSON を `output` で検証。`outcome` は JSON の指定フィールド、または `exit:` の終了コード表（リテラル）から得る | I2・I3・W1 |
| `llm` | `claude -p` を起動。`--json-schema` で型付き出力、`--session-id` を runtime が事前採番、`--max-budget-usd` を**残予算と `budget_usd` の小さいほう**で付与、`--output-format json` の結果から費用を累計。`session: new \| continue:<step>` で再開方針を指定 | I4・I6・I9・I11 |
| `select` | 参照 1 つが指す **enum 値をそのまま outcome にする**（副作用なし） | I10（2 段前の値での分岐） |
| `gate` | ラウンドの区切り。`input` 型（resume 時に型付きの入力を受け、その値が outcome）と `observe` 型（resume 時に外部の実状態を確認し、その結果が outcome。人の申告を信じない）がある。`decider: human \| parent \| any`。任意の `contract_kind: review` で、接続契約にレビュー待ちとして見せる（§5.6.1・#372） | I8・P7・R1〜R3・R5 |
| `workspace` | `acquire`: 呼び出し元が worktree を渡していれば検証して `provided`、無ければ `worktree-setup` を呼んで `created`/`reused`。払い出しは run 内で直列化。`release`: 自分が作ったものだけを `worktree-cleanup` で削除（渡されたものは消さない） | I5・P8・P12 |
| `pull-request` | push → PR 作成（既存なら push のみ）。本文の**転記節（振る舞いの一覧・残指摘の全件・未検証の明記・クロスリポジトリ確証）は型付きの値から Go が生成**する。LLM が書くのは題名と要約だけ | I7・I13・W4 |
| `fanout`（見送り） | 子ワークフローを項目ごとに起動。`max_parallel`・`serial_groups`・後続の起動条件（`advance_on`）を持つ。各項目は独立に gate で止まってよく、全項目が終端に達したら `all_terminal`、ゲート待ちが残れば run を `waiting` にする | P9・P10・P7 |
| `plan-parallel`（見送り） | `max_parallel` が入力にあれば**検証して写すだけ**（判断し直さない）。無ければ計画用の `llm` を呼ぶ。Issue 数が `predict_min_issues`（リテラル）以上なら先に予測の fan-out を行う。計画結果は「受け取った直列グループを緩めていない・天井を超えていない」ことを Go が検証し、追加直列化の差分を出力に残す | P3〜P6・P13 |

**#388 の設計で足すもの（§5.6.2。`workspace` の `acquire` の `key` は S3-1〔#391〕、`pull-request` の `action` の `sync`・`push`・`land` は S3-3〔#393〕で実装済み。ほかはこれから）**: 種類は増やさず、`pull-request` に `action`（`publish`〔既定。上の行の動き〕・`sync`〔宛先の最新をマージのコミットで取り込む〕・`push`・`land`〔先頭の一致を確かめて、満たすときだけ宛先へ入れる〕・`adopt`〔すでにある PR を受ける〕）を足す。`workspace` の `acquire` は、Issue の番号の代わりに名前の鍵（`key`）を受け、ブランチを checkout しない作業ツリー（`mode: detached`）も作れるようにする。

### 3.3 値の受け渡し: 参照だけを許し、加工を許さない

**書き切れる**。文法は次の 4 形だけで、演算・連結・添字計算・既定値の指定は持たない。

```text
$inputs.<名前>
$steps.<step id>.<output のフィールドパス>     # 同一 unit 内で最後に成功した実行の値
$edge.<名前>                                   # 遷移の with で渡された値（遷移先のステップ内でのみ有効）
$gate.note                                     # input 型ゲートの resume で添えられた自由記述（そのゲートから出る遷移の with でのみ有効）
```

`$gate.note` は **LLM への入力としてだけ**渡せる。遷移のキーにも `select` の値にも使えない（遷移のキーは `outcome` の enum だけ。§3.1 の線引き）。`harness validate` は `$gate.note` が遷移の `with` 以外に現れたら拒否する。

`$gate.note` を `with` で渡す遷移は、既定で添え書きを**必須**にする（resume・approve に `--note` が無ければ `input <値> passes $gate.note to the next step; give --note` で拒否し、何も記録しない）。添え書きが無くても進めてよい遷移は、`goto` に **`note: optional`** を書く（#377）。

```yaml
review:
  kind: gate
  type: input
  on:
    respond: { goto: respond, with: { note: $gate.note }, note: optional }   # 添え書きは任意
respond:
  kind: llm
  with: { pr: $steps.publish.pr_number, note: $edge.note }                   # 段の with は $edge.note で受ける
```

- `note: optional` を書いた遷移は、`--note` が無くても拒否しない。そのとき `$gate.note` は**空文字**（`""`）に解決する（null は持ち込まない）。値は resume ごとに決まり、前の resume の添え書きは次の resume に残らない（段へ入る遷移が `$edge` の値を毎回置き換える）。
- 書かない遷移（`design-deviation` の `follow-decision` など）は今までどおり `--note` を必須にし、拒否の文言も変えない。`$gate.note` をすべての遷移で任意にはしない（人の指示文が要る遷移の歯止めを残す）。
- 受け付ける値は `optional` だけで、ほかの値・文字列でない値は読み込み時に拒否する。`goto` 以外の遷移（`gate`・`fail` 等）には書けない（未知のキー）。`with` が `$gate.note` を渡さない遷移に書いたら、意味が無いので読み込み時に拒否する（`note: optional is only valid on a transition whose with passes $gate.note`）。
- 段の `with` と遷移の `with` は合わさらない: 遷移の `with` は `$edge.<名前>` を作るだけで、段は自分の `with` に `$edge.<名前>` を書いて受け取る（§3.3 の検査: 段へ入るすべての遷移がその名前を渡す）。

**`$gate.approved_ref`（#388 の設計。§5.6.2。S3-2〔#392〕で実装済み）**: 参照の 5 つ目の形。input 型のゲートの resume に `--approved-ref` で添えられた、通した中身の識別（先頭のコミット）で、`$gate.note` と同じく、そのゲートから出る `goto` の `with` でだけ書ける。添えられていなければ空の文字列に解決する（`note: optional` に当たる宣言は持たない）。遷移のキーにも `select` の値にも使えない。渡せる先は、`pull-request` の `action: land` の段の `with.approved_ref` だけである（[harness-runtime-overrides.md](harness-runtime-overrides.md) §6.2 の規則 7）。

- **読み込み時に全参照を検証する**: 参照先ステップの `output` スキーマにそのフィールドが在ること、型が受け手の `with` と一致することを、実行前に機械的に調べる（決定③の「実行前に検証できる」を参照にも効かせる）。
- **「その経路でまだ実行されていないステップ」への参照が要る箇所は、遷移の `with` へ寄せる**（例: CI 失敗ログは `ci → fix` の遷移に載せる。`fix` の定義が `$steps.ci` を直接読むと、E2E 失敗から来た経路では値が無い）。これで null の扱いを文法に持ち込まずに済む。
- **加工が要る箇所は、値を作る側（LLM の出力スキーマ、スクリプトの出力、Go の種類）に移す**。棚卸しで見つかった加工の要求と行き先:

| 加工の要求 | 行き先 |
| --- | --- |
| ブランチ名 `{type}/issue-{番号}-{説明}` の組み立て | `analyze`（LLM）が**完成したブランチ名**を出力する。形式検証は既存の `worktree-setup` が行う（パターン外は拒否） |
| Issue 本文の `Base:` 行の抽出 | 新設スクリプト `resolve-ticket`（§3.4）。既存に該当スクリプトは無い（`collect-impl-context.sh` は `#N` 参照の抽出で用途が違う） |
| PR 本文への残指摘の全件転記・`skip` の明記 | `pull-request` 種類が型付き値から生成（転記を LLM に任せると「件数への丸め」が起きうる——I13 が散文で禁止している事故を構造で消す） |
| LLM へ渡す入力の埋め込み | プロンプトは Markdown ファイル。`with` の値は**JSON のデータブロックとして**プロンプトに添付し、文字列置換で本文へ埋め込まない（外部由来データの境界を保つ。`/pr-review-respond` Step 2 のデータブロック分離と同じ考え方） |

### 3.4 書き下ろし: `ticket`（1 チケット）

```yaml
schema: harness.workflow/v1
id: ticket
description: 1チケット（=1 Issue）の実装フロー。PR 作成後のレビュー・マージのラウンドまでを含む
inputs:
  issue:    { type: integer, required: true }
  base:     { type: string }        # 省略可。resolve-ticket が I2 の優先順で決める
  worktree: { type: string }        # 呼び出し元がスロットを払い出した場合だけ
limits:
  budget_usd: 40                    # この unit 全ラウンドの累計上限（仮の値）
  rework: 3                         # Phase 4→8 の差し戻し上限（W2）

steps:
  resolve:
    kind: command
    run: resolve-ticket             # 新設: gh issue view＋Base: 行の抽出＋統合ブランチの remote 存在確認
    with: { issue: $inputs.issue, base: $inputs.base }
    output: schemas/resolve-ticket.json   # outcome: ok|base_missing, base, base_kind: default|integration, title
    on:
      ok: analyze
      base_missing: { fail: base_missing }          # I3: 作成を促して止まる（手順は output に載る）

  analyze:
    kind: llm
    prompt: prompts/ticket-analyze.md
    with: { issue: $inputs.issue }
    output: schemas/ticket-analysis.json  # outcome: ok, e2e_target: yes|no, branch, critical_design
    budget_usd: 2
    on: { ok: workspace }

  workspace:
    kind: workspace
    action: acquire
    with: { issue: $inputs.issue, branch: $steps.analyze.branch,
            base: $steps.resolve.base, provided: $inputs.worktree }
    on:
      provided: implement
      created:  implement
      reused:   implement
      conflict: { fail: worktree_conflict }         # 別ブランチの worktree・未登録ディレクトリ

  implement:
    kind: llm
    agent: claude-harness:feature-implementer
    prompt: prompts/ticket-implement.md
    session: new
    with: { issue: $inputs.issue, critical_design: $steps.analyze.critical_design }
    output: schemas/implement-result.json # outcome: pass|skip|failure|deviation, pr_title, summary,
                                          # residual_findings[], cross_repo_attestation, deviation_report
    budget_usd: 15
    timeout: 90m
    on:
      pass:      commit
      skip:      commit                             # I7: 未検証は pull-request が本文に明記する
      failure:   { fail: quality_gate }             # W2: 初回 failure は再委譲しない
      deviation: { gate: design-deviation }         # I8

  fix:                                              # W1: スコープ付き修正（Step a〜e を開始しない）
    kind: llm
    agent: claude-harness:feature-implementer
    prompt: prompts/ticket-fix.md
    session: continue:implement
    with: { failure: $edge.failure }
    output: schemas/fix-result.json       # outcome: pass|failure|deviation
    budget_usd: 8
    on:
      pass:      commit
      failure:   { fail: quality_gate }
      deviation: { gate: design-deviation }         # W3: 逸脱は再試行しない

  commit:
    kind: llm
    prompt: prompts/ticket-commit.md      # /commit を呼ぶ（safety net の /quality-check を含む）
    session: continue:implement
    output: schemas/commit-result.json    # outcome: committed|failure
    budget_usd: 2
    on: { committed: e2e-route, failure: { fail: commit } }

  e2e-route:
    kind: select
    value: $steps.analyze.e2e_target      # I10: 2 段前の値での分岐を select で解く
    on: { yes: e2e, no: publish }

  e2e:
    kind: llm
    prompt: prompts/ticket-e2e.md         # /create-e2e まで。/explain-e2e は runtime の外（§3.7）
    session: continue:implement
    output: schemas/e2e-result.json       # outcome: pass|fail, failure_summary, scenarios, traceability
    budget_usd: 8
    on:
      pass: publish
      fail: { goto: fix, with: { failure: $steps.e2e.failure_summary },
              limit: rework, exhausted: { fail: e2e } }            # I11 に上限 3 を与える（Q8）

  publish:
    kind: pull-request
    with:
      base: $steps.resolve.base
      closes: $inputs.issue
      title: $steps.implement.pr_title
      summary: $steps.implement.summary
      quality: $steps.implement.outcome
      residual_findings: $steps.implement.residual_findings
      cross_repo: $steps.implement.cross_repo_attestation
    on: { opened: ci, updated: ci }

  ci:
    kind: command
    run: ci-wait
    with: { pr: $steps.publish.pr_number }
    output: schemas/ci-wait.json          # scripts/specs/ci-wait.md の JSON。outcome ← ci
    outcome_field: ci
    on:
      green: review
      none:  review                                   # CI 未設定は green 相当
      red:   { goto: fix, with: { failure: $steps.ci.failure_log_excerpt },
               limit: rework, exhausted: { fail: ci_red } }
      timeout: { retry: 1, exhausted: { gate: ci-pending } }   # Q10: 失敗にせずラウンドを区切る

  ci-pending:                                        # CI を待ちきれなかった（新情報が無いので fix へは送らない。W1）
    kind: gate
    type: input
    decider: any
    requested_action: CI の結果から直すべき失敗を読み取れなかった（時間内に終わらなかった、または失敗ログが空だった）。CI を確かめてから recheck を渡して resume（止めるなら abort）
    inputs: [recheck, abort]
    on: { recheck: ci, abort: { fail: ci_timeout } }

  review:                                            # ラウンドの区切り R1
    kind: gate
    type: input
    decider: any
    requested_action: PR のレビューを待つ。対応が要れば respond、マージしてよければ ready を渡して resume
    inputs: [respond, ready]
    on: { respond: respond, ready: merge-route }

  respond:
    kind: llm
    prompt: prompts/ticket-respond.md     # /pr-review-respond を呼ぶ
    session: new
    output: schemas/respond-result.json   # outcome: pushed|no_change|needs_human
    budget_usd: 8
    on:
      pushed:      ci                                 # R4: 修正 push 後は CI から
      no_change:   review
      needs_human: { gate: review-human }             # R2 qcFailed・R3 design_change/critical

  review-human:
    kind: gate
    type: input
    decider: human                        # R2・R3 を 1 つのゲートのまま扱う（N2 で決定。PR-5 までに見直す）
    requested_action: レビュー対応で人の判断が要る（内容は respond の出力を参照）
    inputs: [respond, abort]
    on: { respond: respond, abort: { fail: aborted_by_human } }

  merge-route:
    kind: select
    value: $steps.resolve.base_kind
    on: { integration: merge, default: human-merge }

  merge:
    kind: llm
    prompt: prompts/ticket-merge.md       # /pr-merge（統合ブランチ宛のみ。本番非反映・可逆）
    session: new
    output: schemas/merge-result.json     # outcome: merged|blocked
    budget_usd: 3
    on: { merged: cleanup, blocked: { gate: review-human } }

  human-merge:                                       # R5: ready の後の既定ブランチへのマージは runtime が行わない（land の道は下の ⑬・§5.6.2）
    kind: gate
    type: observe
    decider: human                        # observe 型なので TTY を要求しない（N1 で決定）
    observe: pr-state                     # resume 時に gh で PR の実状態を確認
    requested_action: この PR のマージは人が行う（既定ブランチ宛と、上書きで統合ブランチ宛も人のマージにした場合）。マージ後に resume
    on: { merged: cleanup, open: { gate: human-merge }, closed: { fail: pr_closed } }

  design-deviation:
    kind: gate
    type: input
    decider: human                        # Q9: input 型の human ゲートは TTY 必須（§5.3）
    requested_action: クリティカル設計の逸脱を検知（implement / fix の deviation_report を参照）
    inputs: [follow-decision, abort]
    on:
      follow-decision: { goto: fix, with: { failure: $gate.note } }  # 人の指示文を修正ステップへ
      abort: { fail: aborted_by_human }

  cleanup:
    kind: workspace
    action: release                       # 自分が作った worktree だけを消す（P12 の 3 条件は到達経路で満たされる）
    on: { released: { done: merged }, kept: { done: merged }, dirty: { done: merged_worktree_dirty } }
```

> **PR-4 の実装（`runtime/workflows/ticket.yaml`）で上の書き下ろしから足したもの**（遷移表・決定は変えていない）: ① `ci` は `ci-wait` を直接ではなく、`runtime/workflows/scripts/ci-wait-pr.sh` 経由で呼ぶ（`ci-wait.sh` は位置引数を取り、`command` 種類は `--<名前> <値>` で渡すため。PR が見つからない〔`pr_exists: false`〕ときは `ci: none` と区別できないので失敗にする）。② `resolve-ticket` は `runtime/workflows/scripts/resolve-ticket.sh` に置いた（`command` の `run` は `<workflow-dir>/scripts/` と `plugin/scripts/` のどちらか一方にだけ在る名前を指す。S1 の埋め込み対象〔`runtime/workflows/`〕に含まれる）。③ `human-merge` に観測する PR の番号を `with: { pr: $steps.publish.pr_number }` で渡す。④ `publish` に `implement` の `unverified`（未検証の事項）を渡す。`respond`・`merge` に PR 番号（`merge` には base も）を渡す。⑤ `resolve`・`ci`・各 `llm` ステップに `timeout` を付けた。⑥ `workspace` で払い出した後のステップは作業ツリーの中で動く（§4.1 Workspace。`release` の後は run を開始したディレクトリに戻る）。 ⑦ `implement` の出力に `review_incomplete`（`/self-review` が `self_review: incomplete` で終わった）を足し、`{ fail: self_review_incomplete }` へ送る（#299。§11.6 の E6）。 ⑧ `publish` の `closes`・`refs` を、`resolve` が Issue 本文の `Closes: なし` 行・`Refs: #N` 行から決めた値にする（`pull-request` 種類の `closes` は省略可・0 で closing キーワードを書かない。読めない行は `links_invalid` で止める。#305）。 ⑨ `e2e` の後・`publish` の前に、品質ゲートを機械で回す `quality`（`command`。`runtime/workflows/scripts/quality-gate.sh`）を置き、`e2e-route.no`・`e2e.pass` をそこへ向ける。宣言 `.claude-harness/quality-gate.json` を PR の宛先から読み、結果を回したコミットの SHA と一緒に出力に残す。`fail` は `{ goto: fix, limit: rework, exhausted: { fail: quality_gate_red } }`、宣言が無ければ `{ fail: quality_gate_undeclared }`。あわせて `commit` は `/commit`（I9 の safety net の `/quality-check`）を使わず git で直接コミットする。pre-commit 等で同じゲートが回るリポジトリは上書きで `quality` を省ける（`overridable.skips: [quality]`。[harness-runtime-overrides.md](harness-runtime-overrides.md) §5.2。#326）。 ⑩ `respond.pushed` を `ci` から `quality` へ向け、レビュー対応の push の後も `quality → publish → ci` を通す（上の書き下ろしの `pushed: ci` を置き換える。PR が既にあるので `publish` は `updated` で本文を書かない。run の記録の SHA を PR の head とそろえるため。#339）。 ⑪ `ci` に `base: $steps.resolve.base` を渡し、PR の宛先の CI の運用の宣言 `.claude-harness/ci.json` が `{"trigger": "after-merge"}`（PR では CI が走らず、既定ブランチへのマージの後だけ走る）なら、`ci-wait-pr.sh` が CI を待たずに `ci: skipped`（`none` とは別の値）を返し、`skipped: review` で進む。宣言が無い・`per-push`・壊れた宣言では今の動き（#341 の約 2 分の `none` の確定を含む）のまま。宣言の読み手は `plugin/scripts/ci-trigger.sh`（`/pr-merge` は宣言を読まず、宣言に関わらず即時マージ）（[runtime/README.md](../runtime/README.md) の「CI の運用の宣言」。#363）。 ⑫ `review`・`review-human` の `respond` を `{ goto: respond, with: { note: $gate.note }, note: optional }` にし、`respond` の `with` に `note: $edge.note` を足す。呼び出し元が差し戻しの理由を `--note` で添えると `respond` の段へ届き、PR にレビューコメントが無くても添え書きに対応する（`no_change` で `review` へ戻らない）。対応したら要旨と対応を自分の PR に 1 件コメントする（`runtime/workflows/prompts/ticket-respond.md`）。添え書きが無ければ空文字で、今までどおり PR のコメントだけを読む（§3.3。#377）。
>
> **#388 の設計で足すもの（⑬ は S3-1〔#391〕、⑭・⑮ は S3-3〔#393〕、⑰ は S3-5〔#395〕で実装済み。ほかは実装はこれから。定義の全体は §5.6.2 の「`ticket` の遷移」）**: ⑬ 入力に `task_file`・`task_id`・`uses_integration`・`challenge_id` を足し、`issue` を任意にする。`resolve` が入力の組み合わせを確かめ（`input_invalid`・`integration_unsupported`）、名前の鍵（`key`）を出す。`analyze`・`workspace`・`implement` は `$inputs.issue` ではなく `resolve` の出力を読む。 ⑭ `commit` の後・`e2e-route` の前に、宛先の最新をマージのコミットで取り込む `sync`（`pull-request` の `action: sync`）と、衝突を直す `sync-resolve`（`llm`）を置く（`commit.committed` を `sync` へ向ける）。 ⑮ `review` の `inputs` に `land` を足し（`[respond, ready, land]`）、`land: { goto: land, with: { approved_ref: $gate.approved_ref } }` で `land`（`pull-request` の `action: land`）へ送る。`land` は、一致して宛先の最新を含めば入れて `cleanup` へ、宛先が動いていれば `land-sync` → `land-push` で取り込んで `review` へ、一致しない・入れられないなら理由（`detail`）を添えて `review` へ戻る。`ready` の後の `merge-route`・`merge`・`human-merge` は変えない。 ⑯ 最上位に `facts: { self_review: [...] }` を書き、`fix`・`respond` の出力にも `self_review` を足す。 ⑰ `review` に `refresh: pr-head` を書く。
>
> `$gate.note` は `input` 型ゲートの resume で人が添えた自由記述。**遷移には使わない**（遷移のキーは `inputs` の enum だけ）。LLM への入力としてだけ渡す（§3.3。Q12 で決定）。
>
> `ci-pending` は `decider: any`（外部待ちで、解決に意思決定を含まない）なので TTY を要求しない。`recheck` で `ci` に戻ると、`retry` はラウンド単位で数えるため再び 1 回の再試行を持つ（§3.1）。`limit: rework` の累計は戻らない。

### 3.5 書き下ろし: `para-impl`（fan-out）

> **2026-09-29 注記: PR-5 を見送ったため、この書き下ろしは実装しない**（§11.3・§11.4）。検討の材料として残す。複数 Issue の並列実行は flywheel がスロットを払い出して `ticket` を 1 本ずつ起動する形で行い（§5.4）、`/para-impl` は散文のまま残る。下の P7・P2・P11 の記述も、この書き下ろしを実装した場合の話である。

```yaml
schema: harness.workflow/v1
id: para-impl
inputs:
  issues:       { type: array, items: integer, required: true }
  base:         { type: string }
  max_parallel: { type: integer }                  # 上位層から来たら判断し直さない（P3）
  serial:       { type: array, items: { type: array, items: integer } }

steps:
  plan:
    kind: plan-parallel
    with: { issues: $inputs.issues, base: $inputs.base,
            max_parallel: $inputs.max_parallel, serial: $inputs.serial }
    predict_min_issues: 5                          # P4 の閾値はリテラル引数（式ではない）
    predictor: { agent: claude-harness:issue-conflict-predictor, budget_usd: 1 }
    planner:   { prompt: prompts/para-plan.md, budget_usd: 2 }
    output: schemas/parallel-plan.json    # outcome: ok, units[{issue, base}], max_parallel,
                                          # serial_groups, added_serialization[{pair, reason}], source
    on: { ok: tickets }

  tickets:
    kind: fanout
    workflow: ticket
    items: $steps.plan.units
    max_parallel: $steps.plan.max_parallel
    serial_groups: $steps.plan.serial_groups
    advance_on: merged                    # 直列グループの後続は先行 unit が merged で終わってから起動（P7）
    on:
      all_terminal: { done: completed }   # 個々の成否は unit の状態に残る（P10・P13 は status が出す）
```

- **P7 の headless 問題が消える**: 既定ブランチ base の直列ペアでは、先行 unit が `human-merge` ゲートで止まり、後続 unit は「未起動（先行待ち）」として状態に残る。run は `waiting` で終わり、人がマージして `resume` すれば後続が起動する。現行の「後続をスキップして再開手順を報告」が不要になる。
- **P2（1 件か複数か）の分岐は無くす**（Q7 で決定）: 1 件も `fanout` の 1 項目として扱い、単一経路も worktree で動かす。単一経路と並列経路の差（worktree の有無・CI 確認の手段・`/explain-e2e` の実施者）が消え、I14 の 2 経路も 1 本になる。**単一経路の利用者には「メインのチェックアウトではなく worktree で作業することになる」変化がある**。移行時に利用者へ見える変更として §8.1 に載せる。
- **P11（統合時のコンフリクト解決）**: 本 YAML には書いていない。`pull-request` 種類が mergeable 状態を観測して `conflict` outcome を返し、解決用の `llm` ステップへ送る形で書ける（種類の追加で解ける）が、現行でも発生時の手順が散文 1 行しかなく、入出力を定義できる材料が無い。PR-5 で実例を取ってから足す。

### 3.6 書き切れたか（結果）

| 棚卸し項目 | 表現 | 式が要ったか |
| --- | --- | --- |
| I1・P1 | `inputs` の型検証（`issue` は integer 1 つ） | 不要 |
| I2・I3 | `command`（新設 `resolve-ticket`）＋ outcome 表 | 不要 |
| I4・I6・I9 | `llm` の型付き出力 → outcome 表 | 不要 |
| I5 | `workspace` 種類の内部（入力の有無で分岐するのは Go） | 不要（種類で解いた） |
| I7・I13 | `pull-request` 種類が型付き値から本文を生成 | 不要（種類で解いた） |
| I8・R2・R3 | `gate`（input 型） | 不要 |
| I10 | `select` 種類 | 不要（種類で解いた） |
| I11・I14・W1・W2 | 遷移の `limit`（回数は Go が数える）・`retry`・`ci-pending` ゲート | 不要 |
| I12 | **runtime の外**に置く（§3.7） | — |
| I15・P10 | runtime が子プロセスを直接監視する（§4.5） | 不要 |
| P3〜P6・P13 | `plan-parallel` 種類（閾値はリテラル引数）。見送り（§11.4） | 不要（種類で解いた） |
| P7・R5 | `fanout` の `advance_on` ＋ `gate`（observe 型）。`fanout` は見送り。R5 は `ticket` の `human-merge` で解いた | 不要 |
| P8・P12 | `workspace` 種類（払い出しの直列化・自分が作ったものだけ消す） | 不要 |
| P9 | `fanout`。見送り（§11.4） | 不要 |
| P11 | 未記述（材料不足。種類の追加で解ける見込み）。PR-5 とともに見送り（§11.3） | 不要の見込み |
| W3・W4 | outcome 表（deviation → gate）・`pull-request` の冪等性 | 不要 |

**結論: 最初の対象は式なしで書き切れた。** ただし 4 種類（`select`・`workspace`・`pull-request`・`plan-parallel`）を Go 側に足す前提である（`plan-parallel` は 2026-09-29 に見送った。§11.4）。式の代わりに足したものの中で、**式に近づいているのは `select` だけ**（参照 1 つの値をそのまま outcome にする＝一致だけ。比較演算・複数値の組み合わせは持たない）。Q12 で `select` と `$gate.note` を許すと決めた。根拠は、一致だけで比較・組み合わせを持たず、「式を足さず Go 側のステップ種類の追加で解く」という承認済みタスク案の方針そのものであること。どこまでを許すかは §3.1「式にしないための線引き」に書いた。

### 3.7 runtime の外に置くもの

- **`/explain-e2e` の Phase 1**（対話前提）。runtime は `e2e` の出力（シナリオ一覧・トレーサビリティ表）を成果物として保存し、run の要約に「次の操作（非ブロッキング）」として載せる。PR 作成の前提条件ではない（`/impl` Phase 7 のとおり）ので、ゲートにはしない（Q14 で決定）。現行の単一経路では `/impl` が `/explain-e2e` まで実施していたので、これも利用者に見える変更になる（§8.1）。
- **`feature-implementer` の内側のループ**（§1.1）。
- **入れ子の Task の合流規律**: runtime が監視できるのは自分が起動した `claude -p` までで、その中の Task は見えない。`join-gate.md` の「ネストへの伝播」条項は Claude セッション内では引き続き必要である（§8 の段階 (B) で縮む量・§9 の M5 にはこれを残した量で数える）。

---

## 4. 永続状態モデル

### 4.1 エンティティ

```text
Run ──< Unit ──< Round ──< StepExecution
 │        │        └── gate_opened / gate_resolved
 │        ├── Workspace（1:1）
 │        └── Budget（unit 単位）
 └── Budget（run 単位の上限・任意）
Event（すべての変化の追記ログ。状態はこの畳み込みで再構成できる）
```

| エンティティ | 主なフィールド | 決定④の 4 要素との対応 |
| --- | --- | --- |
| **Run** | `run_id`・`workflow`（id・スキーマ版・定義のハッシュ）・`inputs`・`status`（汎用: `running`/`waiting`/`succeeded`/`failed`/`cancelled`）・作成と更新の時刻・起動元（`cli`/`skill`/その他の自己申告） | — |
| **Unit** | `unit_key`（例: `issue-123`）・現在のステップ・`status`・先行待ちの unit（直列グループ） | fan-out の 1 項目。単独 `ticket` の run は unit が 1 つ |
| **Round** | `round_no`・開始の契機（`start` / どのゲートをどの入力で抜けたか）・このラウンドで走ったステップ実行・ラウンドの費用・終わり方（どのゲートで止まったか／終端） | **ラウンド**（何ラウンド目か・各ラウンドの入力と結果） |
| **Budget** | `limit_usd`・`spent_usd`・`unknown_cost_count`・ステップ実行ごとの内訳 | **残予算**（累計と上限。再開のたびに数え直さない） |
| **Workspace** | `repo_root`・`worktree_path`・`branch`・`base`・`base_kind`・`provided_by`（`runtime`/`caller`）・各ラウンド終了時の `head_sha`・`pr_number`/`pr_url` | **ブランチ・作業ツリー** |
| **Gate**（Unit が現在待っているもの） | `gate_id`・`type`（`input`/`observe`）・`decider`・`requested_action`・許される入力・再開方法・開いた時刻。解決時は `input`・`note`・`actor`・`channel`・時刻 | **ゲート**（何を待っているか） |
| **StepExecution** | `step_id`・`attempt`・`round_no`・開始／終了・outcome（予約値を含む）・検証済みの出力 JSON・Claude の `session_id`・`cost_usd`・ログと成果物のパス | 「完了済み step を再実行しない」の根拠 |

**#388 の設計で足す記録（§5.6.2。`head_sha`・`merge_commit` は S3-3〔#393〕、`approved_ref`・`detail` は S3-2〔#392〕、開いたゲートの `refresh` と `workspace` の `head` は S3-5〔#395〕で実装済み。ほかは実装はこれから）**: Workspace に `head_sha`（PR のいまの先頭。取り込みの後・外からの push の後も追従する）と `merge_commit`（宛先へ入れた後のコミット）。Gate の解決に `approved_ref`、開いたゲートに `detail`・`refresh`。Run に、定義の `facts`・`release_on` の写しと、unit ごとの `facts` の値。Round の契機に、`interrupted` の印（失敗の理由の語）。

### 4.2 ラウンドの定義

**ラウンド ＝ ゲートとゲートの間**。run 開始でラウンド 1 が始まり、unit がゲートで止まるとラウンドが閉じ、`resume`（ゲートの解決）で次のラウンドが始まる。

- 成功基準の「中断後に完了済み step を再実行せずに resume できる」は、**「ゲートの解決後、そのゲートの遷移先から実行を再開し、閉じたラウンドのステップ実行は再実行しない」**と読む（決定④の読み替えどおり）。
- 差し戻し回数（`limit: rework`）は**ラウンドをまたいで unit 単位で数える**。レビュー後の修正（`respond` → `quality` → `publish` → `ci`。`quality`・`ci` が落ちて `fix` へ送るときは上限の内）はゲートを通るたびに外部入力を要するので上限を付けていない（無限ループにならない）。

### 4.3 予算の扱い

- **1 unit の累計**を持つ。`llm` ステップ起動時に `--max-budget-usd = min(ステップの budget_usd, 残予算)` を付ける。`--max-budget-usd` は起動ごとに効き、`--resume` ではカウンタが 0 に戻る（Tom の運用で実測済みの性質）ので、**累計の責任は runtime が持つ**。
- 費用は `claude -p --output-format json` の結果の **`total_cost_usd`**（USD の数値）から得る（PR-3 で実測・2026-09-26・`claude` 2.1.283。同じ結果に `session_id`〔`--session-id` で渡した値がそのまま返る〕・`structured_output`〔`--json-schema` の型付き出力〕・`is_error`・`subtype`〔成功は `success`〕・モデル別の `modelUsage.<model>.costUSD` がある）。**`--resume` した実行の `total_cost_usd` はセッションの累計**だった（1 回目 $0.2145 → 同じセッションを `--resume` した 2 回目が $0.3514。`modelUsage` の出力トークン 165 が 1 回目 54＋2 回目 111 の和）。そのため `session: continue` の実行は、同じセッションの前回の報告との差をその実行の費用として数える（差が負なら報告が不整合として費用不明に倒す）。`--resume` した 2 回目の結果の `session_id` は 1 回目に `--session-id` で渡した値と同じだった（`--fork-session` は付けていない）。**得られなかった実行は、そのステップの上限額（実際に付与した `--max-budget-usd` の値）を消費したものとして数える**（fail-closed。Q15 で決定。`unknown_cost_count` に記録）。
- 残予算がステップの最低額を下回ったら、起動せず `budget_exhausted` を outcome にする（既定で `failed`。YAML で人間ゲートへ送ることもできる）。

### 4.4 Claude セッションの扱い

- `llm` ステップは **runtime が `--session-id <uuid>` を事前に採番して起動**する（`claude --help` で存在確認済み）。起動前にイベントとして記録するので、runtime が途中で落ちても `session_id` は失われない（クラッシュ復旧の副次効果。これ以上の作り込みはしない）。
- `session: continue:<step>` は、そのステップの最新実行の `session_id` を `--resume` で引き継ぐ。差し戻しの修正で実装時の文脈を保つか、状態から組み立てた新しいブリーフで始めるかは費用と品質のトレードオフである。**YAML の `session` でステップごとに指定でき、差し戻し系（`fix`・`commit`・`e2e`）の既定は `continue`（`--resume` で継続）とする**（Q11 で決定）。PR-4 の shadow run で M1・M3（§9）を比べ、既定を見直す。
- **再開のブリーフは runtime が状態から決定的に組み立てる**（どのブランチ・何ラウンド目・残予算・直前ラウンドの結果・人の指示文）。現状これを親の LLM が散文とログから毎回組み立てており、差し戻し対応の費用が実装本体を上回った例がある（Issue #201 2026-09-21 実測）。ここが導入効果の本体である。

### 4.5 子プロセスの監視と合流

- runtime は起動した子プロセス（スクリプト・`claude -p`）を自分で待つ。**起動台帳は runtime の状態そのもの**になり、`join-gate.md` の起動台帳・決定表・中断報告のうち、**runtime 直下の子に関する部分は散文が不要になる**。
- `harness run` / `resume` は、全 unit がゲートか終端に達するまでプロセスとして生存する（daemon は持たない）。
- **切り離した run（#347・2026-11-10）**: `harness run --detach` と `harness contract start` は、run を始めた後、`harness` 自身の実行ファイルを新しいセッションの子プロセス（runner）として起動し直して run を進めさせ、run ID を返してすぐ戻る。runner も daemon ではなく、全 unit がゲートか終端に達したら終わる。呼び出し元のプロセスの寿命・待ち時間の上限・シグナルから切り離すためである（Claude Code の Bash ツールの既定の上限 600000 ミリ秒で `harness run` が止められ、run がシグナルによる取り消しとして記録された実例が 2 件ある。#346 は起動に `timeout: 7200000` を付けるつなぎだった）。runner の出力は run ディレクトリの `runner.log`、二重起動は run ID ごとの `runner.lock`（`flock`）で防ぐ。runner の生存は PID と開始時刻（`pid_start`）で確かめ、PID の再利用を見分ける。`harness run` の既定は同期のまま。
- **切り離した再開（#359・2026-11-11）**: `harness resume --detach`・`harness approve --detach` と `harness contract resume`（常に）は、ゲートの解決（入力の検証・`observe` 型の観測・解決と遷移の記録）だけを呼び出し元のプロセスで同期に行い、その後の進行を上と同じ runner に渡してすぐ戻る。拒否はその場で返り、何も記録しない。`runner.lock` は解決の前に取り（別の runner が持っていれば解かずに止まる）、解決を記録した後に放して runner に渡す。解決の記録で run がゲートか終端に着いたなら runner は起動しない。runner が引き継げなかった場合は、ゲートを解いた後の run が runner の居ない `running` として残り、下の規則どおり `interrupted` ゲートで待つ（新しい状態・遷移は作らない）。`resume`・`approve` の既定は同期のまま。再開の後ろの段（レビュー対応の `respond`・マージへ進める `ready` など）で、前面の `resume` が呼び出し元の上限で止められ、run がシグナルによる取り消しとして記録された実例（2026-11-11）による。
- runtime が落ちた場合（副次）: 次の `resume` / `status` で「`running` のまま生存プロセスが無い」ステップ実行を `interrupted` とし、その unit を `interrupted` ゲートへ送る（自動の再実行はしない。LLM ステップは部分的なコミットを残しうるため冪等ではない）。ステップとステップの間で落ちた（実行中のステップが無い）unit も同じゲートへ送り、`running` のまま残さない（#347。`rerun` は次に実行するはずだったステップを新しいラウンドで実行する）。runtime の生存は PID と開始時刻で確かめる。

### 4.6 置き場と形式（Q1・Q2 でオーナーが決定: L2・F1）

**決定: 置き場は L2（`$XDG_STATE_HOME/claude-harness/`、未設定なら `~/.local/state/claude-harness/`。環境変数 `HARNESS_STATE_DIR` で上書き可）、形式は F1（run ごとの `events.jsonl`〔正本〕＋ `state.json`）**。以下は判断材料として残す比較である。

**置き場**（前提: プラグインのディレクトリには置かない＝更新で失われる。Issue 2026-09-21 決定①）

| 案 | 置き場 | 利点 | 欠点 |
| --- | --- | --- | --- |
| L1 | リポジトリの git common dir 配下（`<git-common-dir>/claude-harness/runs/`） | どの worktree からも同じ場所。リポジトリと寿命が揃う。追跡されない | クローンを消すと履歴も消える（flywheel は作業用クローンを作り直しうる）。`harness runs` で全リポジトリを横断できない |
| **L2** | ユーザー単位の状態ディレクトリ（`$XDG_STATE_HOME/claude-harness/`、未設定なら `~/.local/state/claude-harness/`）。run はリポジトリのパスを記録 | CLI 本体と同じ「ユーザーにインストールされる道具」の単位。`harness runs` で横断一覧ができる。クローンの作り直しに耐える | リポジトリを消しても run が残る（掃除の操作が要る）。コンテナ内では別の置き場になる |
| L3 | 作業ツリー内の `.harness/`（gitignore） | 見つけやすい | worktree ごとに分かれ、fan-out の親子が別の場所になる。`.gitignore` の追加を利用先へ要求する |

**採った案: L2**（環境変数 `HARNESS_STATE_DIR` で上書き可）。根拠: 観測を「実行主体の外から」行う主体（人の端末・将来の flywheel）は、どのリポジトリかを知らなくても run を引けるほうがよい。Issue の CLI 例も `harness runs`（横断一覧）を想定している。

**形式**

| 案 | 形式 | 利点 | 欠点 |
| --- | --- | --- | --- |
| **F1** | run ごとのディレクトリ: 追記専用の `events.jsonl`（正本）＋畳み込んだ `state.json`（一時ファイル＋rename で原子的に置換）＋ `logs/`・`artifacts/` | 人が `jq`/`tail` で読める（本リポジトリの道具立てと同じ）。追記専用なので途中で落ちても壊れにくい。cgo 不要。状態の再構成を往復テストで固定できる | run 横断の問い合わせは全ディレクトリの走査になる |
| F2 | SQLite 1 ファイル | 横断の問い合わせ・並行アクセスに強い | 人が直接読めない。Go では cgo（mattn）か純 Go 実装（modernc）の選択が要り、クロスビルドに影響する |
| F3 | run ごとに JSON 1 ファイルを書き換え | 最も単純 | 履歴（ラウンドの経過）が残らず、観測・監査の要求を満たさない |

**採った案: F1**。同じ run への同時書き込みは run ディレクトリのロック（`worktree-setup.sh` と同じ mkdir 方式）で直列化する。run 数が増えて `harness runs` が遅くなったら、索引ファイルを足す（形式は変えない）。

---

## 5. CLI の面（harness 内部の設計。接続契約ではない）

### 5.1 コマンド（概念。Issue 2026-08-23 §2 の例を引き継ぐ）

| コマンド | 役割 |
| --- | --- |
| `harness run <workflow> [入力]` | run を開始し、全 unit がゲートか終端に達するまで進める |
| `harness status <run> [--json]` | 状態の観測（どの unit が・どのステップで・何を待ち・何が失敗したか・残予算・ラウンド） |
| `harness runs [--json]` | run の一覧 |
| `harness resume <run> [--unit <key>] [--input <値>] [--note <文>]` | ゲートを解決して次のラウンドへ。**TTY を要求するゲート（§5.3）は解決できず、`approve` を案内して止まる** |
| `harness approve <run> [--unit <key>] --input <値> [--note <文>]` | TTY を要求するゲートの解決。端末が接続されていなければ拒否し、接続されていれば対象の要約を表示して確認の入力を求める |
| `harness cancel <run>` | 停止（子プロセスの停止と記録） |
| `harness validate [<workflow>]` | YAML の静的検証（§6.3） |
| `harness setup` | `claude plugin marketplace add` / `claude plugin install` を呼ぶ（決定①） |
| `harness version [--json]` | CLI 版・対応するプラグイン版の範囲・対応スキーマ版 |

### 5.2 非対話でゲートに達したとき

成功扱いにも無限待機にもせず、**状態・要求操作・再開方法を構造化 JSON と終了コードで返して終了する**（Issue 成功基準）。「待機中」と「失敗」と「成功」は別の終了コードにする。

再開方法は `status --json`（と同じ JSON を出す `run`・`resume`・`approve`・`cancel`）の `waiting[].resume_command` と、テキスト表示・`harness graph --run` の `resume:` 行に出す（どちらも同じ値を写す）。形はゲートの種類で 3 つに分かれる。

| ゲート | `resume_command` |
| --- | --- |
| `type: observe`（`human-merge` 等） | `harness resume --detach <run> --unit <key>` |
| TTY を要求する（§5.3。`design-deviation`・`review-human`） | `harness approve <run> --unit <key> --input <値|…> [--note <text>]  # from a terminal, by a person` |
| それ以外（`review`・`ci-pending`・`interrupted` 等） | `harness resume --detach <run> --unit <key> --input <値|…> [--note <text>]` |

- **`resume` の案内は `--detach` 付き（#359 の追補・2026-11-12）**: 案内をそのまま実行する呼び出し元（`/impl` の報告を読んだ親・Claude Code の Bash ツール）には待ち時間の上限があり、同期の `resume` は再開の後ろの段で止められて run がシグナルによる取り消しになる（§4.5 の切り離した再開の実例）。`observe` 型も `--detach` で解決できる（観測は解決の一部として同期に行い、観測の結果でゲートに戻れば runner を起動せずにその場で返る）。`resume` の既定（フラグなし）は同期のままで、変えたのは案内の文字列だけである。
- **`approve` の案内は同期のまま**: 人が端末で打つ前提で、呼び出し元の時間の上限が無いため。切り離したいときは人が `approve --detach` を手で付けられる。
- `--detach` を知らない古い CLI では案内の `resume` が使えないので、プラグインと CLI は合わせて更新する。

### 5.3 ゲートの解決経路と安全性（Q9 でオーナーが決定）

flywheel は承認を**人間の直接操作に限り**、CLI の承認は端末（TTY）が無ければ拒否する設計を採っている（flywheel `docs/architecture.md` §9。理由: Claude から承認コマンドが呼べると、自走中の Claude が自分で承認できる経路が開く）。**決定: harness では `decider: human` のゲートにだけ TTY を必須にする**。`decider: parent`（CLAUDE.md の判定表で親が決めてよい問い）と `any`（レビュー待ちのような外部待ち）は TTY を要求しない。

- 本文の YAML で TTY を要求するゲートは `design-deviation`・`review-human`（どちらも `type: input`・`decider: human`）。
- **TTY を要求するのは `input` 型の human ゲートだけで、`type: observe` かつ `decider: human` のゲート（`human-merge`）には要求しない**（N1 でオーナーが決定・2026-09-21）。observe 型では resume が判断を運ばず、外部の実状態（PR がマージされたか）を runtime が確かめるだけだからである。
- 解決の記録には `actor`・`channel`（`tty` / `non-tty`）を必ず残す（§4.1 の Gate）。
- **`land`（#388 の設計。§5.6.2）は `decider: any` のレビュー待ちで受け、TTY を要求しない**。通した側（flywheel）が、人の承認を取ったうえで、通した中身の識別を付けて返す答えだからである（R5 を改めた決定）。harness の側の歯止めは、端末ではなく「PR の先頭が、添えられた識別と一致するときだけ入れる」ことで、これは上書きで外せない（[harness-runtime-overrides.md](harness-runtime-overrides.md) §6.2 の規則 7）。識別を添えない・古い識別を添えた `land` では、何も入らない。
- 同じマシン・同じユーザーで動くプロセスによる意図的な回避（疑似端末の作成など）までは防げない。防ぐのは「Claude が通常の道具立てで human ゲートを解決してしまうこと」である（flywheel §9 と同じ範囲）。

### 5.4 スロット（worktree）の払い出し主体

flywheel §11 は「スロットを flywheel が払い出すか、接続ツールに任せるか」を宣言で選べるようにするとしている。`workspace` 種類は両方を受ける（`inputs.worktree` があれば `provided`、無ければ自分で作る）。`release` は自分が作ったものだけを消す。

**2026-09-29 更新（§11.4）**: 複数 Issue の並列実行は flywheel の責務になった。flywheel が同じリポジトリに複数の作業ツリー（worktree のスロット）を払い出し、課題ごとに `harness run ticket` を 1 本ずつ起動して `inputs.worktree` を渡す。**これが並列の通常の経路になる**。runtime は複数 Issue のスケジューリング（並列度・直列化・fan-out）を持たない。`workspace` 種類は渡された作業ツリーを `provided` で受け、`release` でも消さない（現行の実装どおり）。スロットの解放は払い出した flywheel が行う。

並列にするかの判断材料として、harness は**衝突の予測だけを返す読み取り専用の口**を用意する（#288）。決定は flywheel、材料の提供は harness という分担である。口の形は #288 で決めた（§5.4.1・§11.5）。**flywheel 側の呼び出しの宣言（`connectors.json` のどこに書き、invoker がいつ呼ぶか）は未定**で、flywheel の S2 以降の分解で決まる。

#### 5.4.1 衝突の予測の口 `harness predict-conflicts`（#288）

```text
harness predict-conflicts [--max-budget-usd USD] [--workflow-dir DIR] [--scripts-dir DIR] <issue> <issue>...
```

- **入口は接続契約 v1 と別のコマンドにする**。予測は委譲（run の開始・再開）ではなく、契約 v1 の出力（`artifacts` 等）には予測を載せる場所が無い。`run`・`status`・`contract` の出力と終了コードは変えない。終了コードは契約 v1 と同じく「JSON を出力できたか」だけを表す（0 = 出力した。標準出力へ書けなかったときだけ 1）。
- **flywheel が契約として定めたら、harness が `contract` 側に合わせた入口を足す**（§5.6.1 と同じ流れ。契約は flywheel が定め、harness が合わせる）。それまでの出力は harness が定めるが、汎用の語彙だけにする（harness の step id・ワークフロー名・判断値を出さない）。形の版は `schema` に持つ。
- **読み取り専用**: 作業ツリー・ブランチ・Issue を変更しない。探索は起動した cwd が属するチェックアウトの現状（ルートで行う）に対して行い、fetch も switch もしない。読んだ HEAD を `head_sha` に出す。対象のリポジトリは cwd の GitHub リポジトリ（`gh repo view`）。
- **実装**: Issue ごとに `conflict-predict-issue` ワークフローの run を 1 本起動する（`command` の `fetch-issue` で `gh issue view` → `llm` で `agent: claude-harness:issue-conflict-predictor`。道具は Read・Glob・Grep と型付きの出力を返す StructuredOutput だけなので、予測のステップは構造上ファイルを変更できない。StructuredOutput は `--agent` と `--json-schema` の併用で型付きの出力を得るために要る〔§1.1・#282〕）。同時に 4 本まで（止められたら、まだ起動していない Issue は起動せず `failed` にする）。組の突き合わせと依存の向きは Go で決定的に出す。run は状態の置き場（§4.6）に残り、失敗した Issue の `detail` の run ID から `harness status` で辿れる。
- **入力**: Issue 番号 2〜20 件（正の整数・重複なし。`#12` も可）。範囲外・不正な値・不正な `--max-budget-usd` は何も起動せず、`error` を入れた JSON を返す。
- **予算**: `--max-budget-usd` は口全体の上限で、既定は件数 × 1 件分（1 件分はワークフローの `limits.budget_usd` の 1 USD）。**起動前に 1 件分ずつ確保**し、残りが 1 件分を下回った Issue は起動せず `budget_exhausted` にする（fail-closed）。1 run の費用は付与した上限（1 件分）を超えないので、合計は上限を超えない。費用が得られなかった実行は付与した上限額を消費したものとして数える（§4.3・Q15）。

**出力**（`schema: harness.conflict-prediction/v1`）:

| フィールド | 中身 |
| --- | --- |
| `schema` | `harness.conflict-prediction/v1` |
| `repository`・`head_sha` | 対象のリポジトリ（`<owner>/<name>`）と、探索したチェックアウトの HEAD。解決できなかったら `null` |
| `complete` | 全 Issue の予測が得られたか |
| `error` | 口全体を実行できなかった理由（そのとき run は起動していない）。それ以外は `null` |
| `issues[]` | 入力の順。`issue`・`status`（`predicted` / `failed` / `budget_exhausted`）・`predicted_files`（リポジトリルート相対。先頭の `./` と重複を除く）・`depends_on`（本文が挙げた他 Issue。自分自身と重複を除く）・`detail`（`predicted` 以外の理由）・`cost_usd` |
| `pairs[]` | 入力の順の全組。`issues`（2 つ）・`status`（両方の予測があれば `predicted`、無ければ `unknown`＝判断できない）・`shared_files[]`（両方の予測に現れるファイル。**除外せずすべて出す**。lockfile 等のマージが容易なベース名には `merge_friendly: true`、git が無視するパス〔`git check-ignore`。生成物の写し等。追跡されているファイルは当たらない〕には `ignored: true`。除外するかは呼び出し元が決める）・`dependency`（`stated[]` はどちらの予測の `depends_on` が相手を挙げたか、`first` は片方向だけのとき先に入れるべき側。無い・相互なら `null`）・`evidence[]`（根拠: 双方の予測そのもの） |
| `budget` | `limit_usd`（口全体の上限）・`per_issue_usd`（1 件分） |
| `cost_usd`・`unknown_cost_count` | 合計の費用と、費用不明の実行の数 |

確からしさ（`confidence`）は v1 に入れない。エージェントの出力の形を変えることになり、子の `claude` はインストール済みのプラグインからエージェントを解決するので、プラグインのリリースまで届かない（§11.5）。

**散文の `/para-impl` との関係**: 独立に並べ、エージェント定義（`issue-conflict-predictor`）だけを共有する。**`/para-impl` はこの口を呼ばない**（`references/star-parallel.md` の「衝突予測ヒント」はそのまま。§11.4 D4）。`merge_friendly` の対象は `/para-impl` が交差から除く lockfile の例と同じ系統だが、口は除外せず印を付けるだけである。エージェントの `tools` に足した StructuredOutput は、`/para-impl` の呼び方（Task）では使わない道具が 1 つ増えるだけである（`feature-implementer` と同じ。#282）。

### 5.5 観測

`status --json` と run ディレクトリ（F1 の場合）だけで、実行主体の外から現在地が分かる。現行ログ（起動と終了の境界だけ）では「中断」と「計画された再開」を区別できなかった（Issue 2026-09-21 実測 §3）が、Round の「開始の契機」フィールドがこれを構造として記録する。

### 5.6 runtime が出せなければならない情報（書式は空ける）

Issue 2026-08-23 §3 の薄い契約: **run ID・汎用の状態・要約・人に求める操作・成果物の参照・中止と再開に必要な情報**。runtime はこれらを `status --json` で必ず出せるようにする。**フィールド名・コマンドの引数・終了コードの割り当てを flywheel 向けの契約として固定するのは、flywheel §10 の実装後**とする。harness 固有の step id・判断値はこの面に出さない（`requested_action` は人が読む文と、汎用の操作種別だけ）。

### 5.6.1 flywheel の接続契約 v1 との対応（#274・2026-09-28）

正本は flywheel `docs/features/m3-invoker-delegation.md` §クリティカル設計決定 3・§IF / API（`.flywheel/connectors.json` の `form: cli`）。食い違えば flywheel 側が正。

**入口**: 既存の `run`/`status`/`resume`/`cancel` とは別の `harness contract start|status|resume|cancel` にする。契約 v1 の終了コードは「JSON を出力できたか」だけを表し（0 = 出力した）、§5.2 の「待機・失敗・成功を終了コードで分ける」と意味が違う。同じコマンドにフラグで 2 つの意味を持たせると取り違えの元になるため、入口を分け、人向けの出力と終了コード（§5.1・§5.2）は変えない。`contract` の各コマンドは既存のコマンドをそのまま呼び（run の開始・再開・状態の畳み込みは共有）、その結果（`status --json` と同じ畳み込んだ状態）を写すだけである。

| 契約 v1 のコマンド | harness | 引数（既存コマンドと同じ。`--accept-kind` だけは contract に固有。下の「レビュー待ち `review`」） |
| --- | --- | --- |
| `start` | `harness contract start` → `run --detach`（#347。常にすぐ戻る） | `[--workflow-dir DIR] [--scripts-dir DIR] [--input NAME=VALUE]... <workflow>` |
| `status` | `harness contract status` → `status --json` | `[--accept-kind KIND]... <run-id>` |
| `resume` | `harness contract resume` → `resume --detach`（#359。常にすぐ戻る） | `[--accept-kind KIND]... [--unit KEY] [--input VALUE] [--note TEXT] <run-id>` |
| `cancel` | `harness contract cancel` → `cancel` | `<run-id>` |

`cancel` の出力は契約 v1 が求めていないが、同じ形の JSON（停止後の状態）を出す。

**`start` は常にすぐ戻る（#347・2026-11-10）**: `contract start` は run を切り離して始め（§4.5）、run の終わりやゲートを待たずに、その時点の状態（多くは `state: running`・`requested_action: null`）の JSON を返す。進み具合と終わり（ゲートでの待機を含む）は `contract status` で読む。契約の版は v1 のまま（出力のキーと値の集合は変えていない）。flywheel の宣言の引数の配列では、差し込む値（ワークフロー名・入力・run ID・回答）はすべて独立した要素になる。

**`resume` も常にすぐ戻る（#359・2026-11-11）**: `contract resume` はゲートを解いた後の進行を切り離し（§4.5）、その時点の状態の JSON を返す。多くは `state: running`・`requested_action: null` で、速い runner なら次のゲートの `waiting`、解決で終端に着けばその終端の状態になる。拒否（受け付けない入力・`decider: human` のゲート・終わった run・版の不一致）は従来どおり、run の状態のまま理由を `summary` に添えて返る。続きは `contract status` で読む。契約の版は v1 のまま。

**出力**: `{"contract_version": 1, "run_id", "state", "summary", "requested_action", "artifacts", "cost_usd"}` を 1 つ出す。

| フィールド | 写し方 |
| --- | --- |
| `run_id` | run の ID。run を始められなかった `start` と、引数から run ID を読めなかった場合は `null` |
| `state` | run の汎用状態（§4.1 の `running`・`waiting`・`succeeded`・`failed`・`cancelled`）そのもの |
| `summary` | `workflow <id>: <state>` に、終端の理由・待っているゲート・runner が居ないこと・費用不明の実行の数・コマンドが失敗した理由を添えた 1 行 |
| `requested_action` | 終端でなく、ゲートで待っている unit があるときだけ（下の表。版の不一致で続けられないときは下の線引き）。それ以外は `null` |
| `artifacts` | unit ごとに PR（`pr`。URL、無ければ `#<番号>`）・作業ブランチ（`branch`）・最新のラウンドで push した head（`commit`）。無ければ `[]` |
| `cost_usd` | run の累計費用（unit の累計予算 `spent_usd` の和）。予算を持たない run（`llm` ステップが無い）は `0`。run の状態を読めなかった場合だけ `null` |

**ゲート → `requested_action`**（ゲートの内部名は `text` の説明文にだけ入る。flywheel は `kind`・`decider` だけを値として読めばよい）:

| ゲートの型 × decider | `kind` | `decider` | 本文の YAML の例 | `text` が案内する解決 |
| --- | --- | --- | --- | --- |
| `input` × `human`（TTY を要求する。§5.3） | `approve`（`resolvable_by: terminal` を添える） | `human` | `design-deviation`・`review-human` | 人が端末から `harness approve <run> --unit <u> --input <値>` |
| `input` × `parent` | `answer` | `parent` | — | `harness contract resume <run> --unit <u> --input <値>` |
| `input` × `any` | `answer` | `parent` | `ci-pending`・組み込みの `interrupted` | 同上 |
| `input` × `parent`・`any` で、定義に `contract_kind: review`（#372） | 呼び出し元が `--accept-kind review` を宣言したときだけ `review`。宣言が無ければ `answer` | `parent` | `review` | 同上（`answer` と同じ） |
| `observe` × `human` | `observe` | `human` | `human-merge` | 人が外部で操作した後、`harness contract resume <run> --unit <u>` で観測し直す |
| `observe` × `parent`・`any` | `observe` | `parent` | — | 同上（外部の状態の変化を待つ） |

- `input` × `human` を `answer` でなく `approve` にするのは、解決の経路が端末からの `approve`（確認の入力つき）に限られるためである。どちらでも flywheel は回答しない（契約 v1）。
- `requested_action` は `kind`・`decider`・`text` に加えて、任意の項目 `resolvable_by` を持ちうる（下の「解き方 `resolvable_by`」）。harness が出すのは、上の表の `input` × `human`（端末が要るゲート）だけである。
- `requested_action` は任意の項目 `options`（文字列の配列）も持ちうる（下の「選択肢 `options`」）。harness が出すのは、上の表の `input` 型のゲート（`approve`・`answer`・`review`）で、選択肢の一覧を持つときだけである。
- harness の `decider: any` は「TTY を要求しない・誰が resume してもよい」ゲートで、自走中に進めるのは呼び出し元（flywheel）である。そのため契約上は `parent` で出す（契約 v1 の `any` は使わない）。
- 契約 v1 の `requested_action` は 1 つだけである。fan-out の run で複数の unit がゲートで待つ場合は、`approve` → `answer` → `observe` の順（同順位は unit の順）で 1 つを選び、ほかに待っている unit の数を `text` に添える（現行のワークフローの unit は 1 つなので、この場合は起きない）。`--accept-kind review` を宣言した呼び出しだけは、この順の `answer` の直後に `review` を差し込み、`approve` → `answer` → `review` → `observe` の順にする（下の「レビュー待ち `review`」）。

**レビュー待ち `review`（#372・2026-11-15）**: 「成果物（PR など）を出して、それを見てもらう待ち」を表す汎用の `kind`。flywheel が、レビュー待ちの run を接続ツール固有の名前（ゲート名）を読まずに見分けるために足した（flywheel#598）。契約の版は v1 のまま（v2 にしない）。

- **宣言の仕方（ゲートの定義）**: ワークフローの YAML の `gate` ステップに任意のキー `contract_kind` を書く。書ける値は `review` だけで、ほかの値（`approve`・`answer` 等）は読み込み（`harness validate` と run の開始）でエラーにする。`review` を書けるのは、`answer` になるゲート（`input` 型で `decider` が `parent` か `any`）だけで、`observe` 型と `decider: human` の `input` 型に書けばエラーにする（解決の仕方が `answer` と同じであることが前提のため）。書かなければ上の表のまま。runtime はゲート名で `kind` を決めない（`review` という名前のゲートでも、`contract_kind` が無ければ `answer`）。上書き（`docs/harness-runtime-overrides.md` §5.3）では変えられない。組み込みの `ticket` ワークフローでは `review` ゲートにだけ書き、`ci-pending`・組み込みの `interrupted`・`human-merge`・`decider: human` の系統には書かない。
- **出す順番（壊さないための順番）**: 呼び出し元が `review` の受け付けを宣言したときだけ `review` を出す。宣言が無ければ、`contract_kind: review` のゲートも今までどおり `answer` で出す（`decider`・`text`・解決の仕方は同じ）。今の flywheel は `answer`・`approve`・`observe` 以外の `kind` を契約の出力の誤りとして扱うが、宣言しないので `review` を受け取らない。そのため **harness を先に Release しても今の flywheel は壊れない**。flywheel は、宣言のフラグを `.flywheel/connectors.json` の commands に足した時点から `review` を受け取る（flywheel#598）。
- **受け付けの宣言のフラグ**: `harness contract status` と `harness contract resume` の `--accept-kind KIND`（`--accept-kind=KIND` も可。繰り返してよい。位置は run ID の前でも後でもよい）。`KIND` は契約の `kind`（`answer`・`approve`・`observe`・`review`）に限り、それ以外は引数の誤りとして `state: failed`・`run_id: null` の JSON を返す（綴りの誤りで黙って `answer` に倒さない）。`answer`・`approve`・`observe` は宣言しなくても出るので、書いても何も変わらない。宣言はその呼び出しの出力にだけ効き、run には記録しない（同じ run でも、宣言した `status` は `review`、宣言しない `status` は `answer` を返す）。`start` と `cancel` は受け付けない（`start` の直後の待機と `cancel` の出力は宣言なしの形で出る。レビュー待ちは `start` の直後には来ない）。
- **複数の待ちの順位**: 宣言した呼び出しは `approve` → `answer` → `review` → `observe`（宣言の無い順を保ったまま `review` を `answer` の直後に差し込む。オーナーの決定 Q3。#374 で直した）。宣言の無い呼び出しは今の `approve` → `answer` → `observe` のままで、`contract_kind: review` のゲートは `answer` として同じ順位（unit の順）で選ぶ。
- **run の記録**: ゲートを開いたとき（`gate_opened`）に定義の `contract_kind` を写し、`status --json` の `waiting[].contract_kind`（と `harness graph --run`）に出す（書かれていないゲートには出さない）。`contract` は `status --json` を読み直して写すので、定義を読み込まない。この版より前の harness で開いたゲートには値が無く、宣言しても `answer` で出る（次にゲートを開いたときから `review`）。

**解き方 `resolvable_by`（#378・2026-11-16）**: 待ちが「答えを `resume` で返せば解けるか」を表す、`requested_action` の任意の項目。flywheel が、端末でしか解けない承認へ回答で `resume` を送り、断られて保留を重ねることを避けるために足した（オーナーの決定。masanami/flywheel#631）。flywheel は接続ツール固有の語を本体に書かないので、`text` を読んで分けることはしない。

- **後方互換**: 任意の項目で、契約の版は v1 のまま（v2 にしない）。この項目を知らない呼び出し元は読み飛ばせばよい。
- **値（閉集合）**: `answer`（答えを `harness contract resume` で返せば解ける）と `terminal`（人が接続ツールの外の端末で解く必要があり、`resume` では解けない）の 2 つ。
- **受け手の扱い**: 項目が無いときは `answer` として扱う。閉集合の外の値は、安全側に `terminal` として扱う。
- **harness が出すもの**: `terminal` を出すのは、端末が要るゲート（`input` × `human`。`requires_tty`。`resume` は engine が断る）の `approve` だけである。`resume` で解けるゲート（`answer`・`review`・`observe`。人が外部で操作した後に `resume` で観測し直す `observe` × `human` を含む）では項目そのものを出さず、`answer` を明示しても出さない（既存の出力を変えない）。複数の待ちから 1 つを選ぶ場合も、選ばれた待ちの値がそのまま出る（端末が要るゲートが待っていれば `approve` が最優先で選ばれ、`terminal` が出る）。版の不一致で続けられないときの `observe` × `human`（下の「JSON を出せない失敗の線引き」の版の不一致の項）にも出さない。

**選択肢 `options`（#384・2026-11-16）**: 待っているゲートが受け付ける選択肢を表す、`requested_action` の任意の項目（文字列の配列）。flywheel が、保留へのオーナーの答えを選択肢の値と添え書き（`--note`）に分けて `resume` へ渡すために、選択肢の一覧を `text` を読まずに得られるよう足した（オーナーの決定で選択肢の正本をこの項目にした。masanami/flywheel#592）。

- **後方互換**: 任意の項目で、契約の版は v1 のまま（v2 にしない）。この項目を知らない呼び出し元は読み飛ばせばよい。
- **値**: `harness contract resume <run> --unit <u> --input <値>`（端末が要るゲートでは `harness approve … --input <値>`）に渡せる値の一覧。engine が `--input` を照らし合わせる一覧（ゲートの定義の `inputs`。run の記録では `status --json` の `waiting[].inputs`）と同じもので、並びも定義の順である。各値はそのまま `--input` に渡せる。
- **出さない場合**: 選択肢が無いときはキーごと省く。`observe` 型のゲート（`--input` を受け付けない）・選択肢の一覧を持たないゲート・`requested_action` が `null` の出力（`state` が `waiting` 以外）・版の不一致で続けられないときの `observe` × `human` が該当する。
- **`kind` との関係**: `--accept-kind review` を宣言して `kind` が `review` になっても値は同じ。端末が要るゲートの `approve`（`resolvable_by: terminal`）にも出すが、その値は `resume` では解けず、人が端末の `harness approve` に渡すものである（`resolvable_by` を先に見ること）。
- **`text` の「choices: …」**: 同じ一覧から作る説明文で、互換のため残す。選択肢の値は `text` を解析せず、この項目から読む。

**費用（`cost_usd`）と Q15**: 費用を得られなかった実行は、付与した上限額（`--max-budget-usd`）を消費したものとして unit の累計に入っている（§4.3・Q15 の fail-closed）。`cost_usd` はその累計のまま出し、`null` にしない。`null` にすると呼び出し元は「不明」を自分で上限額へ倒す手段を持たず、費用を少なく見る側へ倒れうるためである。費用不明の実行を含むこと（`unknown_cost_count`）は `summary` に書く。

**JSON を出せない失敗の線引き**: 標準出力へ JSON を書けなかったときだけ非 0（1）で終わる。それ以外はすべて JSON を出して 0 で終わる。

- run の状態を読めた場合は、コマンドが失敗しても `state` は run の状態のまま出す（失敗の理由は `summary` に添える）。例: `decider: human` のゲートへの `contract resume` は拒否され、`state: waiting` と `approve` の `requested_action` が返る。終わった run への `resume`・`cancel` は、その終端の状態が返る。コマンドの失敗で run の状態を `failed` と偽らないためである。
- 版の不一致（プラグイン版が範囲外・開始時の版の定義を使えない。§7.3・N3。既存コマンドは終了コード 5）で run を続けられない場合も `state` は run の状態のまま出すが、`requested_action` はゲートの操作でなく `{kind: observe, decider: human}` にする（#283）。`text` は何をすべきか（プラグインか CLI の更新。N3 なら開始時の版での `resume` か `cancel`）と、その後に `harness contract status <run>`（または `resume`）で確かめ直すことを案内し、理由は `summary` にも添える。ゲートの操作を出したままだと、呼び出し元はそれに従って同じ `resume` を繰り返し、更新するまで解消しない同じ拒否に当たり続けるためである。拒否された `contract resume` に加え、`contract status` も待機中の run には同じ判定をする（プラグイン版の照合と、定義を読み込まずにできる判定＝スキーマ版と展開ディレクトリの有無まで。何も書かない）。定義の読み込みでしか分からない不一致は `resume` したときに出る。実行中の run の `status` には出さず（runner が進めている。runner が居なければ `resume` で出る）、終わった run には出さない。
- run の状態を読めない場合（引数の誤り・ワークフロー定義の誤り・run が見つからない・状態の読み込みの失敗）は `state: failed`・`cost_usd: null`・`requested_action: null` を出す。run を始める前の `start` の失敗の `run_id` は `null`、run ID を渡されたコマンド（見つからない run 等）はその ID。
- 既存コマンドの標準エラー（人向けの説明）はそのまま標準エラーへ流す。

### 5.6.2 flywheel の区切り S3 の受け口（#388・2026-11-20。設計。S3-2〔ゲートの解き方〕は #392、S3-3〔取り込みと `land`〕は #393、S3-5〔待っている間の先頭の取り直し〕は #395 で実装済み、残りは実装はこれから）

flywheel が、成果を宛先（統合ブランチ・既定ブランチ）へ入れる処理を委譲先へ移す（flywheel `docs/features/core-redesign.md` の節「委譲先との契約（S3 で使う受け口）」。食い違えば flywheel 側が正）。この節は、そのために harness が足すものの設計である。**この節に書いた入力・フラグ・段・キーは、下の「実装の分け方」の PR が入るまで実物に無い（S3-2 の分は #392、S3-3 の分は #393、S3-5 の分は #395 で入った）**（調べた時点の実物は main `c21a1fc`。§5.6.1 までの記述は実物のまま）。

範囲は 2 つに分ける。

| 区分 | 中身 | 細かさ |
| --- | --- | --- |
| A（flywheel の S3a に要る。先に出す） | 取り込み元の無い入力／`land` と中身の一致／取り込んで入れずに待つ／`facts`／PR の URL を受けて既定ブランチへ上げる依頼 | 実装できる細かさ |
| B（flywheel の S3b で使う。後に出す） | 統合先を作る／統合ブランチを既定ブランチへ上げる | A が邪魔をしないことが分かる粗さ（「B の粗い設計」） |

#### 入力（`ticket`）

```yaml
inputs:
  issue:            { type: integer }   # 必須でなくする。取り込み元の Issue
  base:             { type: string }
  worktree:         { type: string }
  task_file:        { type: string }    # タスクの文面のファイルの絶対パス（UTF-8 の Markdown）
  task_id:          { type: string }    # T-<番号>
  uses_integration: { type: string }    # true | false（A では true を失敗で止める）
  challenge_id:     { type: string }    # 課題の識別（A では受けるだけで使わない。B で統合先の鍵にする）
```

- **値が空の文字列の入力は「無い」と読む**（どの型でも）。`parseInputs`（`runtime/internal/cli/cli.go`）が、型を見る前に `NAME=` を読み飛ばす（`run_started.inputs` に入れない）。いまは `issue=`（integer）が誤りになり、`base=` は「指定あり」として `base_missing` になる（実コード確証・high）。同じ名前を 2 度渡す誤りの検査は、空でも数える。
- **宣言の無い入力は、いまと同じく誤りにする**（`input "x" is not declared`）。そのため flywheel は、宣言に新しい差し込みを書く前に、この版の harness を入れる（契約の「新旧の組み合わせ」の節と同じ順）。
- **`task_file` と `issue` の少なくとも片方が要る**。YAML の文法は入力どうしの条件を持たない（§3.1 の線引き）ので、`resolve` の段（`resolve-ticket.sh`）が確かめ、満たさなければ `input_invalid` で止める（run は始まり、すぐ `failed` になる。`start` の時点では止まらない）。確かめること:

  | 条件 | 結果 |
  | --- | --- |
  | `issue` も `task_file` も無い | `input_invalid` |
  | `task_file` があり、絶対パスでない・読めるファイルでない | `input_invalid` |
  | `task_id` があり、`T-<1 以上の整数>` の形でない | `input_invalid` |
  | `issue` も `task_id` も無い（名前を決める鍵が無い） | `input_invalid` |
  | `uses_integration` が `true`・`false`・無し以外 | `input_invalid` |
  | `uses_integration` が `true` | `integration_unsupported`（A。B で外す） |

- **両方あるとき**は、文面のファイルが作業の範囲の正本で、Issue は PR が閉じる対象としてだけ使う。`resolve` は Issue の本文から `Closes: なし` 行・`Refs:` 行だけを読み（PR と Issue のつながりの宣言なので）、**`Base:` 行は読まない**（宛先は `base` の入力か、既定ブランチ。統合先は `uses_integration` で決めるものにする）。`task_file` が無いときの `Base:` 行の扱いは、いまと同じ。
- **文面のファイルは解釈しない**。`resolve` は在ることだけを確かめ、`analyze`・`implement` へパスを渡す（文面のファイルは作業ツリーの外にあるので、読めるように `add_dirs` でフォルダも渡す。下の「S3-1 の実装の記録」）。両方の指示文は「`inputs.task_file` が空でなければ、そのファイルを読んで要件の正本にする（`gh issue view` で範囲を決めない）。空なら、いまと同じく Issue を読む」に改める。`critical_design` は、文面のファイルがあるときは、その文面から写す。
- `resolve` の出力（`schemas/resolve-ticket.json`）に足す欄: `key`（名前の鍵。下）・`task_file`（無ければ空文字）・`scope`（`issue` / `task_file`）。`issue` は無ければ `0`。後ろの段は、省かれうる `$inputs.issue` を直接読まず、`$steps.resolve.issue`・`$steps.resolve.task_file`・`$steps.resolve.key` を読む（null を文法に持ち込まない。§3.3）。`outcome` に `input_invalid`・`integration_unsupported` を足す。

#### 名前と場所（Issue の番号から切り離す）

名前の鍵 `key` を 1 つ決め、作業ツリーの場所とブランチの名前の両方に使う。

| 入力 | `key` | 作業ツリー | ブランチ |
| --- | --- | --- | --- |
| `task_id` がある（`T-12`） | `task-12` | `<root>/task-12` | `{type}/task-12-{説明}` |
| `task_id` が無い（`issue` = 388） | `issue-388` | `<root>/issue-388`（いまと同じ） | `{type}/issue-388-{説明}`（いまと同じ） |

- 同じ Issue を取り込み元に持つタスクが 2 つ同時に走っても、`task_id` が違えば鍵が違うので重ならない。
- `plugin/scripts/worktree-setup.sh` の第 1 引数を「Issue の番号（数字だけ。いまの呼び方）か、鍵（`issue-<n>`・`task-<n>`・`pr-<n>`）」にする。数字だけなら鍵は `issue-<数字>` で、**出力も動きもいまと同じ**（`/para-impl` の `claude-harness-run worktree-setup {issue番号} …` を壊さない）。ブランチの名前の検査は `{type}/<鍵>-{説明}` にする。出力の JSON に `key` を足し、`issue` は鍵が `issue-<n>` のときだけ数、ほかは `null`。
- `workspace` の `acquire` の `with` に `key`（string・任意）を足し、`issue` を任意にする。どちらも無ければ `step_error`。`key` があれば `key` を、無ければ `issue` を `worktree-setup.sh` に渡す。
- `analyze` の出力のブランチの名前は `{type}/{inputs.key}-{説明}`。`schemas/ticket-analysis.json` の正規表現を `(issue|task)-[0-9]+` に広げる（鍵と合っているかの検査は、いまと同じく `worktree-setup.sh`）。
- 所有の印（`ownerFile`。`runtime/internal/engine/workspace.go`）は「同じ場所を別の run が作り直しうる」前提のまま要る（同じ `task_id` の run のやり直し）。変えない。
- **残る重なり**: `T-<番号>` は flywheel のストアごとの番号なので、2 つのワークスペースが同じリポジトリへ同じ番号のタスクを同時に出すと、場所が重なる。場所が別のブランチで登録済みなら、いまと同じく `worktree_conflict` で止まる（黙って相乗りしない）。

#### ゲートの解き方: `--approved-ref`・`$gate.approved_ref`・`detail`

> **S3-2（#392）で実装済み**。実装で設計の文面から足した・決めたこと（設計の決定は変えていない）:
>
> - `approve` に `--approved-ref` を渡すと、使い方の誤り（終了コード 2。`approve takes no --approved-ref`）にする。フラグは `cmdResolve` が `resume` と共有しているので、渡されても黙って捨てずに拒否する。
> - `detail` に書ける参照は `$steps.<段>.<欄>`（遷移元の段か、必ず成功している先行の段）と、必須の `$inputs.<名前>` の、string の値だけ。`$edge`・`$gate` は遷移では運べないので拒否する（読み込み時）。リテラルは参照 1 つの規則（§3.3）で拒否する。
> - 採った遷移の `interrupted` の理由と、`detail` を解決した文は、`transition` イベントにも `interrupted`・`detail` として残る（任意の欄。`round_started` の契機と `gate_opened` へ写す元になる）。
> - 契約の `requested_action.text` は、ゲートの固定の文（先頭の文）の後ろに ` Detail: <detail>` を足し、`summary` の末尾に `; detail: <detail>` を足す。`graph --run` の `waiting` にも `detail` を出す（`status --json` の `waiting[]` と同じ形）。
> - 「記録上の runner が呼び出し元自身」のときの後始末は `engine.AbandonMarked`（印のあるラウンドの unit だけを失敗で終え、印の無いラウンドと、別の生きたプロセスが runner のときは何も記録しない）。`resolveDetached` が `detach` の失敗で呼ぶ。
> - `detail` を持つ `gate` の遷移はステップ id だけの形ではないので、`overridable.routes` に宣言できず（§6.2 の規則 2 の隣の、元からある「ステップ id だけの形」の検査）、上書きで `detail` を足したり外したりできない。試験で固定した。
> - 【要確認】の確かめ（実物の `gh` 2.67.0・このリポジトリの PR #390〔マージ済み〕・#385）: **確かめた** ― マージ済みの PR の `headRefOid`（`ca8a341…`）は、その PR の最後のコミット（`gh pr view --json commits` の末尾）と同じで、マージのコミット（`mergeCommit.oid`＝`aa798dd…`）とは別である（squash のため）。`gh pr checks <pr> --json bucket,name,state` は、チェックがあれば標準出力が JSON の配列で終了コード 0、0 件なら標準出力が空・標準エラーが `no checks reported on the '<branch>' branch`・終了コード 1（`fetch_pr_checks` の読み方どおり）。`gh pr merge --match-head-commit` は 2.67.0 の help にある。**確かめていない（S3-3 の `land` の段で確かめる）** ― `--match-head-commit` が食い違うときの終了の仕方、マージの待ち行列のあるリポジトリでの直後の PR の状態、rebase マージのリポジトリでの扱い（確かめるには書き込める検証用のリポジトリが要り、公開リポジトリの PR を作らないため）。

| 足すもの | 形 |
| --- | --- |
| フラグ | `harness resume` と `harness contract resume` に `--approved-ref SHA`。`approve` には足さない |
| 解く要求 | `engine.Resolution` に `ApprovedRef`。空の文字列は「無い」 |
| 記録 | `gate_resolved` に任意の `approved_ref`（空なら省く）。`status --json` のゲートの履歴に出る |
| 参照 | `$gate.approved_ref`。`$gate.note` と同じく、input 型のゲートから出る `goto` の `with` でだけ書ける。**添えられていなければ空の文字列**（`note: optional` に当たる宣言は要らない。空は「一致しない」として後ろの段が扱う） |
| 遷移のキー | `{gate: <id>}` の遷移に任意の `detail`（参照 1 つ）。ゲートを開くときの記録（`gate_opened.detail`）に入り、開き直すたびに置き換わる（書かない遷移で開けば、無い） |
| 遷移のキー | input 型のゲートから出る `goto` に任意の `interrupted: { fail: <理由> }`。その遷移で始まるラウンドの間に runner が居なくなったら、`interrupted` のゲートを開かず、その理由で失敗で終える（下の「`land` の後は `interrupted` へ移らない」） |

- 直す所は、`contract.go` の 3 つ（`acceptKinds` に渡す値を取る引数の名前、`contractByRun` の `flagSpec`、usage）と、`cli.go` の `cmdResolve` の `flagSpec`（実コード確証・high）。
- flywheel は、`land` でない答え（`respond` など）にも `--approved-ref ""` を付けて呼びうる（値の無い差し込みは空の文字列）。空は無いものとして読み、空でない値を `$gate.approved_ref` を読まない遷移へ添えたときは、記録だけして使わない（拒否しない）。
- `--note` を必須にする検査（`readsNote`）は、いま「`$gate` の参照を渡す遷移」で見ている。`$gate.note` を渡す遷移だけを見るように直す（`$gate.approved_ref` だけを渡す `land` に `--note` を求めない）。
- `detail` は、`status --json` の `waiting[].detail` に出し、契約では `requested_action.text` の先頭の文の後ろと、`summary` の末尾に足す。ゲートの `requested_action` は定義の固定の文なので、「なぜ戻ったか」を運ぶ口がいまは無い（実コード確証・high）。
- **`land` を受け付けてから終わるかレビュー待ちへ戻るまで `running`**: いまの作りで満たせる（実コード確証・high）。`contract resume` は、ゲートの解決・遷移・次のラウンドの開始を呼び出し元のプロセスで記録してから戻る（`ResolveGate`）。記録の後はゲートが閉じていて、`state` は `running`。受け付ける前のレビュー待ちを返すのは、解決を拒否したとき（受け付けない値・別の runner が進めている）だけで、そのときは何も記録していない。
- **終わった実行への `resume`**: いまの作りで、終わりの状態をそのまま返す（§5.6.1。実コード確証・high）。同じ `approved_ref` の `land` を 2 度受けても、2 度目は、進行中なら「別の runner が進めている」で拒否、終わっていれば終わりの状態、レビュー待ちへ戻っていれば新しい `land` として最初から確かめ直す。
- **`land` の後は `interrupted`（契約では `answer`）へ移らない**: いまの決まり（§4.5）では、runner が落ちた run は、次の `status`・`resume` で組み込みの `interrupted` ゲートへ送られる。契約は「`land` の後、別の種類の待ちへ移らない」ことを求めるので、`land` で始まるラウンドだけは、失敗で終える。
  - **印**: `review.land` の遷移に `interrupted: { fail: interrupted_after_land }` を書く。段の名前も理由の語も Go に書かない。印は、ゲートを解いたときの `round_started` の契機（`trigger`）に理由の語として記録する（`status` は定義を読み込まないので、状態から読めるようにする）。効くのは、そのラウンドが閉じる（次のゲートが開く・run が終わる）まで。`rerun` でやり直したラウンドには付かない（そもそも `interrupted` ゲートを開かないので、起きない）。
  - **`status`・`resume` の後始末**（`engine.InterruptEvents`）: runner が生きておらず、いまのラウンドの契機に印がある unit は、実行中だった段を打ち切り（`step_finished` の `interrupted`。費用の扱いはいまと同じ）、`interrupted` ゲートの代わりに、失敗への遷移と `run_finished`（`failed`・印の理由）を記録する。段と段の間で落ちた（実行中の段が無い）ときも同じ。子プロセスがまだ生きている段には、いまと同じく `status` は触らない（`resume`・`cancel` が止めてから記録する）。
  - **runner を起動できなかったとき**（`resolveDetached` の `detach` の失敗。`cli.go`）: いまは「runner の居ない `running`」のまま返し、次の `status` に任せている。印のあるラウンドでは、その場で同じ後始末を記録してから返す（`contract resume` の応答が `failed` になる）。このとき記録上の runner は呼び出し元のプロセス自身で、生きているので、`InterruptEvents` の「runner が生きていれば何もしない」を飛ばす口（自分が runner として諦める）を足す。印の無いラウンドの動きは変えない。
  - **2 度入れない**: 失敗で終えた後の `resume` は、終わりの状態を返す（上）。`land` の段が入れた直後に落ちた場合も run は `failed` で終わり、入ったかどうかは flywheel が上流で確かめる（入っていれば実行済み、入っていなければ承認を取り消して見せる）。
  - **定義の検査**: `$gate.approved_ref` を渡す遷移は、`interrupted` を書かなければならない（書き忘れた定義を読み込みで拒否する）。`interrupted` を書けるのは、input 型のゲートから出る `goto` だけ。

#### 新しい段: `pull-request` の `action`

`pull-request` の種類に、`workspace` と同じ形の `action` を足す。書かなければ `publish`（いまの動き: push して PR を作る）。**決定的な Go の段**で、LLM を呼ばない。`command`（スクリプト）にしないのは、`command` の段が作業ツリーと PR の記録（成果物の元。§4.1 Workspace）を書けないためである（記録できるのは Go の種類だけ。実コード確証・high）。

| `action` | `with` | `outcome` | すること |
| --- | --- | --- | --- |
| `publish`（既定） | いまと同じ | `opened`・`updated` | いまと同じ |
| `sync` | `base`・`expect_head`（任意） | `current`・`synced`・`conflict`・`unresolved`・`not_merge_only`・`diverged`・`head_moved`・`unavailable` | 宛先の最新を、マージのコミットで作業ブランチへ取り込む（push はしない） |
| `push` | `pr`・`base` | `pushed`・`unchanged`・`rejected`・`unavailable` | 作業ブランチを、強制せずに push し、PR の先頭を記録する |
| `land` | `pr`・`base`・`approved_ref` | `landed`・`behind`・`mismatch`・`blocked`・`closed`・`merged_other`・`base_changed`・`not_confirmed` | 先頭の一致と、宛先の最新を含むことを確かめ、満たすときだけ PR を宛先へ入れる |
| `adopt` | `ref` | `adopted`・`unsupported_ref`・`not_open`・`not_default_base`・`fork`・`draft`・`other_repo` | すでにある PR を、この run の成果物として受ける（`reflect` 用） |

`sync`・`push`・`land` は、返す文（人が読む 1〜2 文）を出力の `detail` に入れる。`land` は、確かめた PR の先頭を出力の `head_sha` にも入れる。

**一時的な失敗（`gh`・`git fetch`・`git push` が、ネットワークや認証で通らない）の扱い**は、「そのとき手元と PR の中身を変えていないなら、理由を添えてレビュー待ちへ戻す。変えた後なら、失敗で終える」で決めた。`land` の後の失敗で終わった実行は、flywheel が上流で確かめる（入っていなければ承認を取り消して見せる）ので行き止まりにはならないが、レビュー待ちへ戻せる所は戻す方が、実行を作り直さずに済む。段ごとの当てはめは、下の各段に書く。

**`sync`**（rebase・強制 push をしない）:

1. 作業ツリーに未コミットの変更があり、マージの途中（`MERGE_HEAD`）でもない → `step_error`。
2. マージの途中のまま入った（衝突を直す段が終えなかった）→ `unresolved`。
3. 自分の直前の出力が `conflict` だった（衝突を直す段の後の再入）→ いまの `HEAD` が、親をちょうど 2 つ持ち、第 1 の親が `conflict` を返したときの先頭（`head_before`）で、第 2 の親がそのときの宛先の先頭（`base_sha`）であることを確かめる。違えば `not_merge_only`（取り込みのコミットの外に変更を足した）。合えば次へ。
4. `git fetch origin <base>`。作業ブランチが origin にあれば fetch し、手元が origin より遅れているだけなら早送りする。枝分かれしていれば `diverged`。fetch が通らなければ `unavailable`（ここまで、手元の中身は変えていない）。
5. `with.expect_head` があり、上の 3 を通っていない（最初に入った）とき、手元の `HEAD` が `expect_head` と同じことを確かめる。違えば `head_moved`（push していない手元のコミットを、取り込みと一緒に出さない）。**語は 2 つあり、層が違う**: `head_moved` は `sync` の `outcome`、`local_head_mismatch` は、その `outcome` を `{ fail: local_head_mismatch }` へ送って run を失敗で終えるときの理由（下の「失敗の理由」の表）。どちらも正しく、食い違いではない。
6. `HEAD` が `origin/<base>` の先頭を含んでいる → `current`。
7. `git merge --no-ff --no-edit origin/<base>`。通れば `synced`。衝突したら、マージの途中のまま `conflict`（`head_before`・`base_sha` を出力に残す）。

衝突は、LLM の段（指示文 `prompts/sync-resolve.md`）が直す。指示は「衝突の印が付いたファイルだけを直し、`git add` して `git commit --no-edit` でマージを終える。ほかのファイルを変えない・別のコミットを作らない・push しない・`git merge --abort` や rebase をしない」。終えたら `sync` へ戻り、上の 3 で機械が形を確かめる（3 を通った再入では、5 は確かめない。3 が「第 1 の親が、最初に入ったときの先頭」を確かめている）。直す段へ入る遷移は `limit: sync_resolve` で数える（数えられない循環を作らない。§3.1）。**取り込みのコミットの中身が衝突の解消だけかどうかは、harness は判定しない**（flywheel が上流の比較で判定する。契約）。

`expect_head` を渡すのは `land` の後の取り込み（`land-sync`）だけで、値は `land` の段が一致を確かめた PR の先頭（`$steps.land.head_sha`）。最初の `sync` には渡さない（まだ PR が無く、手元の作業ブランチが正本）。`unavailable` は、`land-sync` ではレビュー待ちへ戻し（何も変えていない）、最初の `sync`・`reflect` の用意の `sync` では失敗で終える（戻るレビュー待ちがまだ無い）。

**`push`**: `git push --porcelain origin HEAD:refs/heads/<作業ブランチ>`（強制しない）。既定ブランチと PR の宛先そのものへは push しない（`publish` と同じ検査）。

| 結果 | いつ | `detail` の文 |
| --- | --- | --- |
| `pushed` | push が通り、origin の先頭が変わった | 「宛先 `<base>` の先頭 `<宛先の先頭>` を取り込み、PR の先頭は `<前の先頭>` から `<新しい先頭>` になった。宛先へは入れていない」 |
| `unchanged` | origin の先頭が、手元の `HEAD` とすでに同じ（push するものが無い） | 「PR の先頭は `<先頭>` のまま（宛先 `<base>` の先頭 `<宛先の先頭>` を、すでに含んでいる）。宛先へは入れていない」 |
| `rejected` | origin が拒否した（porcelain の状態が `!`。取り込みの間に、外から push された） | —（失敗で終える） |
| `unavailable` | 3 回試しても、origin へ届かない（参照ごとの状態の行が出ない） | —（失敗で終える） |

- コミットは短くせず、全部の桁で書く。宛先の先頭は、手元の `origin/<base>`（直前の `sync` が fetch したもの）。
- `pushed`・`unchanged` では、PR の番号・URL・先頭を記録する。
- **`unavailable` をレビュー待ちへ戻さない理由**: この時点で、手元には push していない取り込みのコミットがある。戻すと、次の `land` の後の `land-sync` が、`sync` の 5 の確かめ（手元の `HEAD` が PR の先頭と同じ）に当たって、どのみち失敗で終わる。手元を巻き戻す処理は足さない。
- `unchanged` が出るのは、主に `reflect` の用意（PR がすでに既定ブランチの最新を含んでいる）。`land` の後では、`behind` と確かめた後なので、ふつうは `pushed` になる。

**`land`**（上から順。最初に当たったものを返す）:

| # | 確かめること | 結果 | 契約の `land` の後の動き |
| --- | --- | --- | --- |
| 1 | PR を読む（`gh pr view --json state,headRefOid,baseRefName,mergeCommit,isDraft`）。3 回試しても読めない | `blocked`（理由を `detail` に） | 4（理由を出して待つ。中身は変えていない） |
| 2 | PR の宛先が `with.base` と違う（入った後の PR も含む） | `base_changed`（失敗） | 続けられない |
| 3 | すでに入っている（`MERGED`）で、入った先頭が `approved_ref` と同じ | `landed` | 1 の続き（片付けへ） |
| 4 | すでに入っているが、先頭が `approved_ref` と違う | `merged_other`（失敗） | 続けられない |
| 5 | 入らずに閉じている | `closed`（失敗） | 続けられない |
| 6 | `approved_ref` が空、または PR の先頭と違う | `mismatch` | 3（入れずに、いまの先頭を出して待つ） |
| 7 | 宛先と PR の先頭を fetch し（`git fetch origin <base>` と `refs/pull/<番号>/head`）、PR の先頭が宛先の最新を含んでいない（`git merge-base --is-ancestor` の終了コード 1） | `behind` | 2（取り込んで待つ） |
| 7' | 7 の fetch が通らない・祖先の判定が 0 でも 1 でもない終了コードで終わった | `blocked`（理由を `detail` に） | 4 |
| 8 | 下書きの PR・失敗か未完了のチェックがある・チェックを読めない | `blocked` | 4（理由を出して待つ） |
| 9 | `gh pr merge <pr> --squash --match-head-commit <approved_ref>` が通った → PR を読み直す（下） | `landed`・`not_confirmed` | 1・続けられない |
| 10 | 9 が通らなかった → 1〜7' をもう一度確かめ、当たればその結果。どれにも当たらなければ `blocked`（`gh` の標準エラーを `detail` に） | — | 2・3・4 |

- **2 を 3 より前に置く**: 宛先を付け替えられて、別のブランチへ入った PR を `landed` にしない。入った後の PR の `baseRefName` は、入った先のブランチである。
- 6 と 9 で、先頭の一致を 2 度確かめる（9 は GitHub の側の条件）。7 と 9 の間に宛先が動く隙間は残る（契約が認めている）。
- **7 で PR の先頭も fetch する**: 外から push された先頭は、手元に無いことがある。無いまま祖先を判定すると、コマンドの失敗（終了コード 128 など）を「含んでいない」と読み違える。`behind` にするのは終了コード 1 のときだけで、ほかは 7'。
- **9 の後の読み直し**: 入れる命令が通っても、マージの待ち行列や、リポジトリの側の自動マージで「まだ入っていない」ことがある。PR を読み直し（数回・合わせて 10 秒ほどまで）、`MERGED` で、宛先が `with.base`、入った先頭が `approved_ref` と同じなら `landed`。そうでなければ `not_confirmed`（失敗 `merge_not_confirmed`）。入ったかどうかは flywheel が上流で確かめる。`--auto` は付けない。
- **1・7' を `blocked` にする理由**: ここまで、手元も PR も変えていないので、理由を添えてレビュー待ちへ戻せる（上の「一時的な失敗」）。flywheel からは「入れられなかった」（契約の 4）に見える。
- 記録: どの結果でも、PR のいまの先頭を記録する（`mismatch` の後の成果物が、いまの先頭になる）。`landed` では、入れた後のコミット（`mergeCommit.oid`）も記録する。
- 8 のチェックは、PR の宛先の CI の運用の宣言が `after-merge`（§3.4 ⑪）なら見ない。ほかは `gh pr checks --json bucket` の `fail`・`cancel`・`pending` が 1 件でもあれば「通っていない」とする。**チェックが 0 件の PR は「通っていない」に数えない**（`ci-wait.sh` の `none` と同じ扱い）。`gh pr checks` は、未完了・失敗のチェックがあると 0 でない終了コードを返し、0 件のときは標準出力を空にして標準エラーに `no checks reported` を出すので、成否は終了コードではなく「標準出力が JSON の配列か」で決め、0 件は標準エラーの文で見分ける（`plugin/scripts/lib/common.sh` の `fetch_pr_checks` と同じ読み方。実コード確証・high）。どちらでもなければ「読めない」で `blocked`。flywheel は `land` の前に自分でチェックを確かめるので、ここは足しの確かめである。
- `--delete-branch`・`--auto`・`--admin` は付けない。入れ方は squash に固定する（`docs/branching-strategy.md` の既定。リポジトリの設定が squash を許さなければ 10 で `blocked`）。
- 実物の `gh` で確かめたこと・確かめていないこと（S3-3〔#393〕。実物の `gh` 2.67.0・このリポジトリ）:
  - **確かめた** ― `gh pr view <n> --json state,headRefOid,baseRefName,mergeCommit,isDraft` は、入った PR で `mergeCommit` が `{"oid": …}`、`headRefOid` が最後のコミット（squash のため、入ったコミットとは別）、`baseRefName` が入った先のブランチ（PR #390 で確認）。開いている PR の `mergeCommit` は `null`（`land` は null を「無い」と読む）。`gh pr merge` の help に `--squash`・`--match-head-commit SHA`・`--auto`・`--admin`・`--delete-branch` がある（`land` は最初の 2 つだけを付ける）。`gh pr checks <pr> --json …` は、チェックが無ければ標準出力が空・標準エラーが `no checks reported on the '<branch>' branch`（`land` はこの文だけを 0 件と読む）。偽の `gh` は同じ形を出す（`checks.none`）。
  - **確かめていない** ― 書き込める検証用のリポジトリが要り、公開リポジトリの PR を作らないため、実物では確かめていない: `--match-head-commit` が食い違うときの終了の仕方（`land` は終了コードが 0 でなければ 10 へ進み、確かめ直して当たらなければ `gh` の標準エラーを `detail` に入れて `blocked` にする。終了コードの値には依らない）。マージの待ち行列のあるリポジトリで、`gh pr merge` が通った直後の PR の状態（`land` は約 10 秒、1 秒おきに読み直し、`MERGED` にならなければ `merge_not_confirmed`）。squash を許さないリポジトリでの `gh pr merge` の失敗（10 の `blocked` で見せる）。
  - 試験は偽の `gh`（`runtime/internal/engine/testdata/scripts/fake-gh.sh`）と、実の `git` の bare の origin で書いた。偽の `gh` が出す JSON の形は、上の実物の出力に合わせてある。

#### `ticket` の遷移

```yaml
limits:
  sync_resolve: 3                       # 取り込みの衝突を LLM に直させる回数（unit の累計）
facts:
  self_review: [$steps.implement.self_review, $steps.fix.self_review, $steps.respond.self_review]

steps:
  commit:
    on: { committed: sync, failure: { fail: commit } }          # いまは committed: e2e-route

  sync:                                 # 最初のレビュー待ちの前の取り込み
    kind: pull-request
    action: sync
    with: { base: $steps.resolve.base }
    on:
      current: e2e-route
      synced:  e2e-route
      conflict: { goto: sync-resolve, limit: sync_resolve, exhausted: { fail: sync_conflict } }
      unresolved:     { fail: sync_conflict }
      not_merge_only: { fail: sync_not_merge_only }
      diverged:       { fail: branch_diverged }
      head_moved:     { fail: local_head_mismatch }    # expect_head を渡さないので、ここでは出ない
      unavailable:    { fail: remote_unavailable }

  sync-resolve:
    kind: llm
    prompt: prompts/sync-resolve.md
    session: continue:implement
    with: { base: $steps.resolve.base }
    output: schemas/sync-resolve-result.json                    # outcome: resolved|failure, summary
    on: { resolved: sync, failure: { fail: sync_conflict } }

  review:
    requested_action: PR のレビューを待つ。対応が要れば respond。この中身を宛先へ入れてよければ land（--approved-ref に通した先頭のコミット）。呼び出し元の側で反映まで済ませたなら ready
    inputs: [respond, ready, land]
    refresh: pr-head                    # 待っている間の PR の先頭を status で取り直す（下の「成果物」）
    on:
      respond: { goto: respond, with: { note: $gate.note }, note: optional }
      ready: merge-route                # 変えない
      land:  { goto: land, with: { approved_ref: $gate.approved_ref }, interrupted: { fail: interrupted_after_land } }

  land:
    kind: pull-request
    action: land
    with: { pr: $steps.publish.pr_number, base: $steps.resolve.base, approved_ref: $edge.approved_ref }
    on:
      landed:   cleanup
      behind:   land-sync
      mismatch: { gate: review, detail: $steps.land.detail }
      blocked:  { gate: review, detail: $steps.land.detail }
      closed:       { fail: pr_closed }
      merged_other: { fail: merged_unapproved }
      base_changed: { fail: pr_base_changed }
      not_confirmed: { fail: merge_not_confirmed }

  land-sync:                            # sync と同じ action。遷移先だけが違う
    kind: pull-request
    action: sync
    with: { base: $steps.resolve.base, expect_head: $steps.land.head_sha }
    on:
      current: land-push
      synced:  land-push
      conflict: { goto: land-sync-resolve, limit: sync_resolve, exhausted: { fail: sync_conflict } }
      unresolved:     { fail: sync_conflict }
      not_merge_only: { fail: sync_not_merge_only }
      diverged:       { fail: branch_diverged }
      head_moved:     { fail: local_head_mismatch }
      unavailable:    { gate: review, detail: $steps.land-sync.detail }

  land-sync-resolve:                    # sync-resolve と同じ指示文。session は new（レビュー待ちは長い）
    kind: llm
    prompt: prompts/sync-resolve.md
    session: new
    with: { base: $steps.resolve.base }
    output: schemas/sync-resolve-result.json
    on: { resolved: land-sync, failure: { fail: sync_conflict } }

  land-push:
    kind: pull-request
    action: push
    with: { pr: $steps.publish.pr_number, base: $steps.resolve.base }
    on:
      pushed:    { gate: review, detail: $steps.land-push.detail }
      unchanged: { gate: review, detail: $steps.land-push.detail }
      rejected:    { fail: push_rejected }
      unavailable: { fail: push_failed }
```

- **最初の取り込みの置き場**は `commit` の後・`e2e-route` の前にする。品質の検査（`quality`）より前なので、検査は取り込んだ後のコミットに対して回る。`quality` の直前に置かないのは、`quality` へ入る 3 本の遷移（`e2e-route.no`・`e2e.pass`・`respond.pushed`）が上書きの候補を宣言していて（[harness-runtime-overrides.md](harness-runtime-overrides.md) §5.2）、間に段を挟むと「`quality` を省く」上書きが取り込みも省く形になるためである。`fix` の後も `commit` を通るので、差し戻しのたびに取り込み直す。`respond` の後（`respond.pushed → quality`）には挟まない（契約が求めるのは最初のレビュー待ちの前だけ。宛先が動いていれば `land` の 7 が拾う）。
- **`land` の後の取り込みは、`quality`・`ci` を通さない**（`land-sync` → `land-push` → `review`）。契約は「`land` の後、レビュー待ちへ戻るほかの待ちへ移らない」ことを求め、`quality`・`ci` の先には `fix`（中身を変える）・`design-deviation`・`ci-pending`（別の待ち）がある。チェックの完了は flywheel が待つ。
- `land` の後に `summary`・`requested_action.text` へ出る文は、戻った遷移の `detail`（`mismatch`・`blocked` は `land` の、取り込んだ後は `land-push` の、取り込みの fetch が通らなかったときは `land-sync` の）。
- `ready` の後（`merge-route` → `merge` か `human-merge`）は変えない。`/pr-merge`（`merge` の段）にも手を入れない。
- 入った後の片付けは、いまの `cleanup`（終わりの理由は `merged`）。
- 段の数は 21 から 27 になる（`runtime/internal/cli/graph_test.go` の固定の数）。

#### 成果物（`artifacts`）と PR の先頭の記録

いまの `commit` の要素は「最新のラウンドで `publish` が push した先頭」（`Workspace.HeadSHAs`）で、取り込みの後・外からの push の後は古いままになる（実コード確証・high）。次のとおり改める。

- `Workspace` に `head_sha`（PR のいまの先頭。1 つ）と `merge_commit`（入れた後のコミット）を足す。`pull-request` の `publish`・`push`・`land`・`adopt` が、`workspace` イベントで書く。`head_sha_by_round` はいままでどおり `publish` が書き、読む側（契約）は `head_sha` があればそれを、無ければ（この版より前に始めた run）`head_sha_by_round` の最新を使う。
- 契約の `commit` の要素は、`merge_commit` があればそれ（宛先へ入れて終わった run。契約の「入れた後の中身の識別」）、無ければ `head_sha`。**`role` の無い `commit` は、いつもちょうど 1 つ**（PR を出す前は 0）。
- **待っている間に外から push されたとき**: ゲートの任意のキー `refresh: pr-head`（input 型にだけ書ける。値はこの 1 つ）を足す。`harness status`（`contract status` も同じ道）は、この印のあるゲートで待っている unit について、`gh pr view --json headRefOid` で先頭を読み、記録と違えば `workspace` イベント（`action: head`）を足してから出力する。読めなければ何も足さず、いまの記録のまま出す（標準エラーに理由）。`status` が書くのは、落ちた runner の後始末（§4.5）と同じ扱いである。これが無いと、flywheel は「委譲先の言う中身」と上流の先頭が食い違ったまま `land` を返せない（S3a の「`content_mismatch`」）。
  - `gh` はロックの外で呼ぶ（時間がかかりうる）。書き込みは `AppendIf` の中で、**同じ unit が、同じゲートで、同じ `opened_at` のまま待っている**ことを確かめ直したときだけ行う（読んでいる間に `resume` がゲートを解いた・解いた後に同じゲートへ戻ってきた、のどちらでも書かない。後者は、後ろの段が新しい先頭を記録している）。記録と同じ先頭なら、何も書かない。
- **`workspace` イベントを、実行中の段の外で書く場面**: いまの畳み込みは、実行中の段が無い unit への `workspace` イベントを誤りにする（`applyWorkspace`。実コード確証・high）。次の 2 つだけを許し、ほかはいまと同じく誤りにする。

  | `action` | 許す状態 | 許さない例 |
  | --- | --- | --- |
  | `head` | run が終わっていない。unit に実行中の段が無く、ゲートで待っていて、そのゲートに `refresh` の印がある。unit に PR の記録がある | `running` の unit・印の無いゲート・終わった run・PR の記録の無い unit |
  | `released`（終わりの片付け。下の「`reflect`」） | run が終わっていない。unit に実行中の段が無い。unit に、払い出して、まだ返していない作業ツリーの記録がある。そのうえで、次のどれか: 取り消しの要求（`cancel_requested`）が記録済み／unit がすでに `failed`（失敗への遷移の後・`run_finished` の前）／unit が `running`（runner がシグナルで止められ、実行中だった段を打ち切った後。このとき `cancel_requested` は無い） | 取り消しの要求が無いまま、ゲートで待っている unit・`succeeded` の unit・作業ツリーの記録が無い、または返した後の unit |

  実行中の段の中で書く `acquired`・`released`・`pr` の決まりは変えない。`head` は、段の中（`push`・`land`）では `pr` のイベントで書くので、段の中の `head` は誤りにする。2 つの場面とも、イベント → 状態の往復テスト（`runstate` の往復テスト）の対象に入れ、許さない例が誤りになることも確かめる。
- `adopt` は作業ツリーの払い出しより前に PR を記録するので、`workspace` の `acquired` の畳み込みは、前の記録に作業ツリーの場所が無いときも PR の記録を持ち越す（いまは場所が同じときだけ）。
- `artifact` に `role`（`omitempty`）を足すのは B（A では出さない）。

#### `facts`

- **契約の出力**: 任意のキー `facts`（名前 → 値。どちらも文字列）。値が 1 つも無ければキーごと省く。状態によらず出す。契約の版は 1 のまま。
- **「レビュー待ちの出力には毎回出す」の範囲**: 値を返す段（作業の段）を持ち、`facts` を宣言したワークフローの話で、いまは `ticket` だけである。`ticket` のレビュー待ちは、必ず `implement` が成功した後に来るので、`facts.self_review` はいつも出る。**`reflect` は `facts` を宣言しない**（作業の段が無く、返す値が無い）ので、`reflect` の出力に `facts` は出ない。flywheel が `required_facts` を照らすのは、タスクの実行のレビュー待ちだけで、反映の依頼には照らさない。
- **宣言**: ワークフローの最上位に `facts:`（名前 → 参照の配列）。参照は `$steps.<段>.<欄>` だけで、欄は出力のスキーマにある文字列であること（読み込みで検査する）。契約の Go には段の名前を書かない（§5.6）。上書きには書けない。
- **値**: 並べた段のうち、**最後に成功して終わり、その欄を返した段**の値。`run_started` に宣言の写し（名前 → 段と欄）を記録し、畳み込みが `step_finished` のたびに unit の `facts` を更新する（`contract` は定義を読み込まずに `status --json` から写せる）。この版より前に始めた run には宣言の写しが無く、`facts` は出ない。
- **`self_review`**（`complete`・`incomplete`・`not_run`）を返す段:

  | 段 | 変えること |
  | --- | --- |
  | `implement` | 変えない（欄は必須。#381 の `self-review-route` もそのまま） |
  | `fix` | `schemas/fix-result.json` に `self_review` を任意の欄として足す。指示文に「直して `/quality-check` を通した後、直した差分に `/self-review` を実行し、実行したら `self_review` を返す。`outcome: pass` で返すときは、必ず実行して返す」を足す |
  | `respond` | `schemas/respond-result.json` に `self_review` を任意の欄として足す。指示文に下の決まりを足す |

- **スキーマでは、どちらも任意の欄にする**（`outcome` による条件つきの必須を使わない。`fix` も同じ形に合わせる）。「返さなければ前の値のまま」は、上の畳み込み（欄を返した段だけが値を置き換える）で扱う。実行したのに返さない、を防ぐのは指示文で、返さなければ前の値が残り、flywheel の `required_facts` が拾う。
- **`respond` の指示文に足す決まり**:
  - `/pr-review-respond` を終えた後、この段で変えた分（この段で足したコミットと、未コミットの変更）に `/self-review` を実行し、指摘を直したらコミットする（push は後ろの `publish`）。
  - **`/self-review` を実行したら、push の有無に関わらず `self_review` を返す**（`no_change`・`needs_human` でも返す）。実行していなければ返さない。
  - **添え書き（`inputs.note`）が「自己レビューの実行」だけを求めていて、実行した結果、直すものが無かったときは、`no_change` を返してよい**（`self_review` を添える）。いまの決まり「添え書きが空でなければ `no_change` にしない」の例外にする。flywheel が `required_facts` を満たさないレビュー待ちを差し戻す添え書きは、この形（満たしていない名前と値の一覧）で、直すものが無いときに `needs_human`（端末が要る待ち）へ落とさないためである。直すものがあれば、直して `pushed`。
  - この段で変えた分が無く、添え書きも自己レビューを求めていなければ、`/self-review` を実行しない（値は前のまま）。
- `/pr-review-respond` のスキルは変えない。スキルの「`/self-review` を実行しない」は、スキルの中から 1 件ずつ呼ぶ修正の委譲（再入の回避）の決まりで、スキルを終えた後に段が `/self-review` を呼ぶことは妨げない（`plugin/skills/pr-review-respond/SKILL.md`。実コード確証・high）。
- **取り込みでは値を変えない**: `sync-resolve`・`land-sync-resolve` と `pull-request` の段を `facts` に並べない。
- `fix`・`respond` の `self_review` が `complete` でなくても、harness は止めない（値を返すだけ）。満たさないレビュー待ちを差し戻すのは、flywheel の宣言（`required_facts`）である。`implement` の後の歯止め（#381）は変えない。

#### PR を受けて既定ブランチへ上げる依頼: `reflect`

```yaml
schema: harness.workflow/v1
id: reflect
description: すでにある PR を、既定ブランチの最新を取り込んで検証し、land を受けたら既定ブランチへ入れる
inputs:
  artifact_ref: { type: string, required: true }   # PR の URL（統合ブランチの名前は B）
  challenge_id: { type: string }                   # 受けるだけ（B で統合先の鍵）
limits:
  budget_usd: 10
  sync_resolve: 3
release_on: [cancelled, failed]                    # 取り消し・失敗で終わるとき、自分が作った作業ツリーを片付ける
overridable:
  routes:
    sync.current: [quality, push]                  # push は quality の省略
    sync.synced:  [quality, push]
  skips: [quality]

steps:
  adopt:
    kind: pull-request
    action: adopt
    with: { ref: $inputs.artifact_ref }
    on:
      adopted: workspace
      unsupported_ref:  { fail: integration_reflect_unsupported }   # PR の URL でない（A）
      not_open:         { fail: pr_not_open }
      not_default_base: { fail: pr_not_default_base }
      fork:             { fail: pr_from_fork }
      draft:            { fail: pr_draft }
      other_repo:       { fail: pr_other_repo }
  workspace:
    kind: workspace
    action: acquire
    with: { key: $steps.adopt.key, branch: $steps.adopt.branch, base: $steps.adopt.base, mode: detached }
    on: { created: sync, reused: sync, provided: sync, conflict: { fail: worktree_conflict } }
  sync:           # ticket の sync と同じ（expect_head なし）。current・synced → quality、conflict → sync-resolve（session: new）、unavailable → { fail: remote_unavailable }
  sync-resolve:
  quality:        # ticket と同じ command（quality-gate）。fail → { fail: quality_gate_red }、undeclared → { fail: quality_gate_undeclared }
  push:           # pushed・unchanged → { gate: review, detail: $steps.push.detail }、rejected → { fail: push_rejected }、unavailable → { fail: push_failed }
  review:
    kind: gate
    type: input
    decider: any
    requested_action: 既定ブランチへ上げる用意ができた。この中身を入れてよければ land（--approved-ref に通した先頭のコミット）。やめるなら、この run を cancel
    inputs: [land]
    contract_kind: review
    refresh: pr-head
    on: { land: { goto: land, with: { approved_ref: $gate.approved_ref }, interrupted: { fail: interrupted_after_land } } }
  land:           # ticket の land と同じ。behind → land-sync（expect_head: $steps.land.head_sha）→ land-push → review
  land-sync:
  land-sync-resolve:
  land-push:
  cleanup:        # workspace release。released・kept → { done: landed }、dirty → { done: landed_worktree_dirty }
```

`sync` から下の、中身が `ticket` と同じ段は、遷移先だけを注記にして略した（`with` の `pr`・`base` は `adopt` の出力を読む）。

- **`adopt`**: `ref` が `https://<host>/<owner>/<repo>/pull/<番号>` の形でなければ `unsupported_ref`。`gh pr view <ref> --json number,url,state,baseRefName,headRefName,headRefOid,isCrossRepository,isDraft` と `gh repo view --json nameWithOwner,defaultBranchRef` で、起動したリポジトリの PR であること（`other_repo`）・開いていること（`not_open`）・宛先が既定ブランチであること（`not_default_base`）・フォークからでないこと（`fork`。相手のブランチへ取り込みを push できる保証が無い）・下書きでないこと（`draft`）を確かめる。出力は `pr_number`・`pr_url`・`branch`・`base`・`head_sha`・`key`（`pr-<番号>`）。PR を記録する。
- **作業ツリーは、ブランチを checkout しない形（detached）で作る**。`workspace` の `acquire` の `with` に `mode`（リテラル `detached` だけ）を足し、`worktree-setup.sh --detach <鍵> <ブランチ> <base>` を呼ぶ（名前の形を検査しない・ブランチが origin に無ければ失敗・`git worktree add --detach <場所> origin/<ブランチ>`）。上げる PR のブランチは、作った側の作業ツリー（`/impl`・`/para-impl` の `issue-<n>`）で checkout されたまま残っていることが多く、同じブランチを 2 つの作業ツリーで checkout できないためである。push は `push` の段が `HEAD:refs/heads/<ブランチ>` へ行う。`mode: detached` と `provided` は一緒に使えない。
- **用意の検証は、検査だけ**（`quality` が落ちたら失敗で終える）。`fix` の段を持たない。直すと、通した中身に関係のない変更が足されるためである。
- **`options` は `land` だけ**。`respond`・`ready` は受けない。成果物は PR・ブランチ・先頭のコミット（`role` 無しを 1 つ）。
- **取り消し・失敗で終わるときの片付け**: ワークフローの最上位の任意のキー `release_on`（終わりの状態の配列。書ける値は `cancelled` と `failed`）。`reflect` は `[cancelled, failed]` を書く。`succeeded` は書けない（入れた後の片付けは、`cleanup` の段が行う）。
  - `run_started` に写しを記録する（`status`・`cancel` は定義を読み込まないので、状態から読めるようにする）。
  - **終わりを記録する側が、終わりのイベント（`run_cancelled`・`run_finished` の `failed`）を書く前に片付ける**。この run が作った作業ツリー（所有の印で確かめる）を `worktree-cleanup.sh --force` で消し、`workspace` イベント（`released`）を残してから、終わりを書く。終わりを記録する側は 4 つある: runner（段の結果が失敗への遷移になったとき・取り消しを拾ったとき）、runner が居ないときの `harness cancel`、`status`・`resume` の後始末（上の「`land` の後は `interrupted` へ移らない」で失敗にするとき）、runner を起動できなかった `resume`。4 つとも同じ関数を通す（定義を読み込まず、状態の `scripts_dir`・`cwd`・作業ツリーの記録だけで動く形にする）。
  - 消せなくても、終わりは成立させる（理由を `released` の記録か標準エラーに残す）。`--force` にするのは、取り込みの途中（マージの途中）で止まった作業ツリーも残さないためで、ここに push していない価値のあるものは無い（PR のブランチは origin にあり、取り込みは、やり直せば作り直せる）。
  - 既定ブランチへは入れず、PR は閉じない（PR はこの run が作ったものではない）。push 済みの取り込みのコミットは残る。
  - **`ticket` には書かない**（取り消し・失敗の後に、人が作業ツリーを見て続きを直す、いまの動きを変えない）。
- `reflect` も `ticket` と同じ場所（起動したリポジトリの作業ツリーの置き場）に `pr-<番号>` を作る。同じ PR への依頼が 2 本重なると、後の方は `worktree_conflict` にならず `reused` になる（同じ detached の作業ツリー）ので、`acquire` は、別の run の所有の印がある detached の作業ツリーを `conflict` にする。

#### 失敗の理由（足すもの）

| 理由 | ワークフロー | いつ |
| --- | --- | --- |
| `input_invalid` | `ticket` | 入力の組み合わせ・形が受けられない（上の表） |
| `integration_unsupported` | `ticket` | `uses_integration` が `true`（A。B で外す） |
| `sync_conflict` | 両方 | 取り込みの衝突を直せなかった・回数を使い切った・マージの途中のまま戻った |
| `sync_not_merge_only` | 両方 | 衝突を直す段が、取り込みのコミットの外に変更を足した |
| `branch_diverged` | 両方 | 手元の作業ブランチと origin が枝分かれしている |
| `push_rejected` | 両方 | 強制しない push が拒否された（取り込みの間に、外から push された） |
| `push_failed` | 両方 | 取り込みの後の push が、3 回試しても origin へ届かない |
| `remote_unavailable` | 両方 | レビュー待ちの前の取り込みで、fetch が通らない（`land` の後の取り込みでは、失敗にせずレビュー待ちへ戻す） |
| `local_head_mismatch` | 両方 | `land` の後の取り込みの前に、手元の `HEAD` が、一致を確かめた PR の先頭と違う |
| `interrupted_after_land` | 両方 | `land` を受けてから、レビュー待ちへ戻るか終わるまでの間に、runner が落ちた・起動できなかった |
| `merge_not_confirmed` | 両方 | 入れる命令は通ったが、読み直した PR が「入った・先頭が一致」になっていない |
| `pr_base_changed` | 両方 | PR の宛先が、run の宛先と違う（すでに入った PR も含む） |
| `merged_unapproved` | 両方 | PR がすでに入っていて、入った先頭が `approved_ref` と違う |
| `pr_closed`（いまもある） | 両方 | PR が入らずに閉じている |
| `integration_reflect_unsupported` | `reflect` | `artifact_ref` が PR の URL でない（A。B で外す） |
| `pr_not_open`・`pr_not_default_base`・`pr_from_fork`・`pr_draft`・`pr_other_repo` | `reflect` | 扱えない PR |
| `quality_gate_red`・`quality_gate_undeclared`（いまもある） | `reflect` | 上げる前の検証が落ちた・宣言が無い |

終わりの理由（成功）: `ticket` は `merged`（いまと同じ）、`reflect` は `landed`・`landed_worktree_dirty`。

`land` を受けた後に失敗で終わるのは、上の表の `sync_*`・`branch_diverged`・`push_*`・`local_head_mismatch`・`interrupted_after_land`・`merge_not_confirmed`・`merged_unapproved`・`pr_closed`・`pr_base_changed` と、段の予約値（`step_error` など）。どれも、flywheel が上流で「入ったか」を確かめる前提で、レビュー待ち以外の待ちへは移らない。

#### 守り（上書きで外せないこと）

規則の正本は [harness-runtime-overrides.md](harness-runtime-overrides.md) §6.2 の規則 7。要点:

- **宛先へ入れる操作は、`pull-request` の `action: land` の段の中にしか無く、その段はいつも先頭の一致を先に確かめる**。確かめる所と入れる所を 2 つの段に分けない（間の遷移を付け替えて、確かめずに入れる形が作れない）。
- `approved_ref` は、ゲートの解決（`$gate.approved_ref`）からしか `land` の段へ届かない（定義の検査）。
- `land` の段のキーと遷移、`$gate.approved_ref` を渡す遷移は、上書きできない。`land` の段は `overridable.skips` に挙げられない。
- `--workflow-dir` で定義を丸ごと差し替える道は、いまと同じく規則の外（同 §6.3）。

#### 互換と版

- **契約の版は 1 のまま**。足すのは、任意のキー（`facts`）・選択肢の値（`options` の `land`）・任意のフラグ（`--approved-ref`）・新しい入力とワークフローだけで、いまあるキーと値の意味は変えない。
- **ワークフローのスキーマ版は `harness.workflow/v1` のまま**（`overridable`・`contract_kind`・`note: optional` を足したときと同じ扱い）。足す文法: 最上位の `facts`・`release_on`、ゲートの `refresh`、ゲートへの遷移の `detail`、ゲートから出る `goto` の `interrupted`、参照 `$gate.approved_ref`、`pull-request` の `action`、`workspace` の `with.key`・`with.mode`。定義はバイナリに埋め込む（§6.5）ので、新しい定義を古い CLI が読むことは無い。この版より前に始めた run は、開始時の版の定義で続く（§7.3・N3）ので、`options` に `land` が出ず、`facts` も出ない（flywheel は `land_unavailable` で保留にする）。
- **`issue` だけで始めた実行で変わること**:

  | 変わること | 理由 |
  | --- | --- |
  | レビュー待ちの `options` に `land` が増える | 契約（`land` を受けられる委譲先の印）。いまの flywheel は `land` を返さない |
  | `facts` が出る | 任意のキー。知らない側は読み飛ばす |
  | 最初のレビュー待ちの前に、宛先の最新をマージのコミットで取り込む | 契約の「最初にレビュー待ちへ出す前にも取り込む」。下の「選択肢があった点と、採った案」の 1 |
  | 成果物の `commit` が、待っている間の外からの push に追従する | 上の「成果物」 |

  ほか（`respond`・`ready` の動き、`ready` の後のマージ、名前と場所、失敗の理由）は変えない。
- **プラグインの版**: minor を上げる（5.1.0 → 5.2.0）。プラグインの側で変わるのは `plugin/scripts/worktree-setup.sh`（第 1 引数に鍵を受ける・`--detach`）と、その仕様だけで、数字だけの呼び方の動きは変えない。CLI が受けるプラグインの範囲（`>=4.9.0 <6.0.0`。`runtime/internal/version/version.go`）は変えない。runtime は、埋め込んだ側の `worktree-setup.sh` を使う（§6.5）ので、**新しい CLI は、古いプラグイン（5.1.0）のままでも動く**。flywheel が要るのは CLI のリリース（`runtime/vX.Y.Z`。minor を上げる）である。

#### 実装の分け方

この文書の PR を PR-0 とする。どれも `make check` を通し、`CHANGELOG.md` の「未リリース」に書く。

| PR | 中身 | 依存 | 主に触るファイル | 足す試験 |
| --- | --- | --- | --- | --- |
| S3-1 | 入力と名前: 空の文字列を「無い」と読む。`ticket` の入力 4 つ・`issue` を任意に。`resolve` の検査と出力（`key`・`task_file`・`scope`）。鍵での作業ツリーとブランチ。`analyze`・`implement` の指示文。`uses_integration: true` を止める | — | `runtime/internal/cli/cli.go`（`parseInputs`）・`runtime/internal/workflow/builtin.go`・`runtime/internal/engine/workspace.go`・`runtime/workflows/ticket.yaml`・`scripts/resolve-ticket.sh`・`schemas/resolve-ticket.json`・`schemas/ticket-analysis.json`・`prompts/ticket-analyze.md`・`prompts/ticket-implement.md`・`plugin/scripts/worktree-setup.sh`・`plugin/scripts/specs/worktree-setup.md` | 空の入力（型ごと）。`resolve-ticket.sh` の表のテストに上の表の全行。`test-worktree-setup.sh` に鍵の形と、数字だけの呼び方が変わらないこと。通しのテスト: 文面のファイルと `task_id` だけで PR まで進む・同じ Issue で `task_id` の違う 2 本が別の作業ツリーとブランチになる・`issue` だけの run の場所と名前が変わらない |
| S3-2（#392 で実装済み） | ゲートの土台: `--approved-ref`・`Resolution.ApprovedRef`・`gate_resolved.approved_ref`・`$gate.approved_ref`。ゲートへの遷移の `detail`（`gate_opened.detail`・`waiting[].detail`・契約の `text` と `summary`）。`readsNote` の直し。`goto` の `interrupted`（`round_started` の契機への記録・`InterruptEvents` と `resolveDetached` の後始末） | — | `runtime/internal/cli/contract.go`・`cli.go`（`cmdResolve`・`waitingView`）・`runtime/internal/engine/gate.go`・`engine.go`（`value`・`resolve`・`transitionEvents`）・`runtime/internal/runstate/event.go`・`fold.go`・`runtime/internal/workflow/parse.go`・`validate.go`・`override.go`（`detail` を閉じる）・`cli/detach.go` | 練習用のワークフロー（`engine/testdata/workflows/`）で: 添えた値が次の段へ届く・無ければ空・`--note` を求めない・書けない所に書いた参照を拒否・`detail` が開き直しで置き換わる・契約の出力に出る。`interrupted` の印: 印のあるラウンドで runner が落ちた後の `status`・`resume` が、`interrupted` ゲートを開かずに印の理由で `failed` にする（実行中の段があるとき・段の間のとき）／runner を起動できなかった `resume` の応答が `failed` になる／印の無いラウンドは、いまと同じに `interrupted` ゲートで待つ／失敗で終えた後の `resume` が終わりの状態を返す。往復テスト（イベント → 状態） |
| S3-3（#393 で実装済み） | 取り込みと `land`: `pull-request` の `action`（`sync`・`push`・`land`）。`Workspace.head_sha`・`merge_commit` と契約の `commit`。`ticket.yaml` の `sync`・`sync-resolve`・`land`・`land-sync`・`land-sync-resolve`・`land-push` と `review` の `land`。`prompts/sync-resolve.md`。上書きの規則 7。`README` の種類の説明 | S3-1・S3-2 | `runtime/internal/engine/pullrequest.go`（分けてよい）・`runtime/internal/workflow/builtin.go`・`parse.go`・`validate.go`・`routes.go`・`runstate/event.go`・`fold.go`・`cli/contract.go`（`artifacts`）・`runtime/workflows/ticket.yaml`・`prompts/`・`schemas/`・`engine/testdata/scripts/fake-gh.sh`・`cli/graph_test.go` ほか段の数を固定で持つテスト | `land` の表の 1〜10 を 1 行ずつ（偽の `gh`・実の git の bare origin）: 読めない PR は `blocked`／宛先を付け替えて入った PR は `landed` にならない／外から push された先頭が手元に無くても `behind` と読み違えない・祖先の判定の失敗は `blocked`／チェック 0 件は通す・チェックを読めないときは `blocked`／入れる命令が通った後に `MERGED` でなければ `merge_not_confirmed`。`sync` の 1〜7（`expect_head` と違う手元は `local_head_mismatch`・再入では確かめない・fetch の失敗は、`land` の後ならレビュー待ち）。`push` の 4 つの結果と `detail` の文（宛先の先頭・前後の先頭が入る）。通しのテスト: `land` で一致 → 入って `succeeded`／宛先が動いた → 取り込んでレビュー待ち（新しい先頭・`running` を経る）／一致しない → 入れずにレビュー待ち／チェック失敗 → 理由つきでレビュー待ち／衝突 → 直してレビュー待ち／同じ `land` を 2 度／入った直後に落ちた run が `interrupted_after_land` で終わり、`resume` が終わりの状態を返す（2 度入れない）／`land` の後に、レビュー待ち以外の待ちへ移る道が無いこと（定義のグラフで確かめる）。`$gate.approved_ref` を渡す遷移に `interrupted` が無い定義を拒否。`--match-head-commit` が引数にあること。最初のレビュー待ちの前の取り込み。上書きの規則 7 の拒否（`override_routes_test.go`）。`ready` の道が変わらないこと |
| S3-4 | `facts`: 最上位の `facts`・`run_started` の写し・畳み込み・契約の出力。`fix`・`respond` の `self_review`（スキーマと指示文） | S3-3（`ticket.yaml` の同じ所を触るため。機能の依存は無い） | `runtime/internal/workflow/parse.go`・`validate.go`・`override.go`・`runstate/event.go`・`fold.go`・`engine/engine.go`（`Start`）・`cli/contract.go`・`cli/contract_test.go`（`contractKeys`）・`ticket.yaml`・`schemas/fix-result.json`・`schemas/respond-result.json`・`prompts/ticket-fix.md`・`prompts/ticket-respond.md` | 宣言の検査（無い段・文字列でない欄・上書き）。値が「最後に、その欄を返した段」になること（`implement` → `respond` が返せば `pushed` でも `no_change` でも変わる・返さなければ変わらない・`fix` も同じ・取り込みで変わらない）。`self_review` の無い `respond`・`fix` の出力がスキーマを通ること。`ticket` のレビュー待ちの出力に毎回出ること。宣言の無いワークフローではキーが無いこと |
| S3-5（#395 で実装済み） | 待っている間の先頭の取り直し: ゲートの `refresh: pr-head`・`workspace` イベントの `head`・`status` での取り直し | S3-3 | `runtime/internal/workflow/parse.go`・`validate.go`・`override.go`・`runstate/event.go`・`fold.go`・`engine/gate.go`・`pullrequest.go`・`cli/cli.go`（`cmdStatus`） | 外から push された後の `contract status` の `commit` が新しい先頭になる・`gh` が失敗しても出力は変わらず出る・印の無いゲートでは `gh` を呼ばない・読んでいる間にゲートが解かれた／同じゲートへ戻ってきた（`opened_at` が違う）ときは書かない・記録と同じ先頭なら書かない。往復テスト: 待っているゲートでの `head` を許し、上の表の「許さない例」を誤りにする |
| S3-6 | `reflect`: `action: adopt`・`workspace` の `mode: detached`・`worktree-setup.sh --detach`・最上位の `release_on`・取り消しと失敗のときの片付け・`workflows/reflect.yaml` | S3-3・S3-5（S3-1 の鍵） | `runtime/workflows/reflect.yaml`・`runtime/internal/engine/pullrequest.go`・`workspace.go`・`engine.go`（`cancel`・失敗への遷移）・`gate.go`（`InterruptEvents` の後始末）・`cli/cli.go`（`cmdCancel`・`cmdStatus`・`cmdResolve`）・`workflow/parse.go`・`builtin.go`・`runstate/event.go`・`fold.go`・`plugin/scripts/worktree-setup.sh`・`specs/worktree-setup.md`・`cli/dist_test.go` ほか定義の一覧を固定で持つテスト | `adopt` の結果を 1 行ずつ。通しのテスト: PR の URL → 取り込み → 検証 → レビュー待ち（`options` は `land` だけ・`commit` が 1 つ）→ `land` → 入って片付け → `succeeded`。`land` の前に既定ブランチへ入らないこと。取り消しで作業ツリーが消え、PR が開いたまま残ること（待っているとき・走っているとき）。失敗で終わるとき（用意の検証が落ちた・取り込みの衝突を直せない・`interrupted_after_land`）も作業ツリーが消えること。`ticket` は取り消し・失敗で作業ツリーを残すこと。往復テスト: 終わりの片付けの `released` を許し、上の表の「許さない例」を誤りにする。`facts` が出ないこと。ブランチが別の作業ツリーで checkout されていても進むこと。フォーク・下書き・宛先違い・ブランチの名前の入力で止まること |
| S3-7 | リリース（`chore(release)`）: `CHANGELOG.md`・`plugin/.claude-plugin/plugin.json`。CLI のタグは人が打つ | 全部 | — | — |

A は S3-1〜S3-7。S3-1 と S3-2 は並べて進められる。flywheel の S3a は、S3-7 の後に main へ入る。

**S3-1 の実装の記録（#391）**: この PR で、S3-1 の行の中身が実物になった（それ以外の行は、まだ実物に無い）。実装で、設計の文面から合わせた点と、実物で確かめたこと:

- **スクリプトの引数の名前は `with` の名前のまま（アンダースコア）**: `command` の段は `with` の名前をそのまま `--<名前>` で渡す（`engine.argv`。実コード確証・high）ので、`resolve-ticket.sh` が受けるのは `--task_file`・`--task_id`・`--uses_integration`（`--issue`・`--base` は変わらない）。ハイフンの綴りは受けない。
- **`input_invalid`・`integration_unsupported` は `fail` の理由として足した**（`resolve` の `on`）。終端が 2 つ増えるので、段の終端の一覧を固定で持つテスト（`internal/graph`）の期待値も直した。両方とも、`gh`・`git` を呼ばずに返す（入力の検査は、取り込み元に触れる前に終える）。
- **誤りのときの出力**: `input_invalid`・`integration_unsupported` でも `resolve` の出力は、必須の欄をすべて埋めて返す（`base`・`default_branch`・`title`・`state` は空文字、`closes` は 0、`refs` は空）。`key` は、入力が正しく読めたとき（`integration_unsupported`）だけ入り、`input_invalid` では空文字。
- **`analyze` へ渡す値**: `issue`（無ければ 0）・`task_file`（無ければ空文字）・`key`。`implement` へは `issue`・`task_file`・`critical_design`。指示文は `task_file` が空かどうかで読む先を決める。
- **`workspace` の `acquire`**: `with.issue`・`with.key` はどちらも任意で、`issue` が 0 のときは「無い」と読む。`key` が空でなければ `key` を、そうでなければ `issue` の数字を `worktree-setup.sh` に渡す（どちらも無ければ `step_error`。スクリプトは呼ばない）。
- **`e2e` の段**: `with` に `task_file`（`$steps.resolve.task_file`）を足し、`e2e`・`fix`・`commit` の指示文の「この Issue」を「要件の正本」に直した（実装から続くセッションの段が、Issue を範囲と読まないため）。
- **作業ツリーの外の文面のファイルを、LLM の段が読めるようにした（`add_dirs`）**: `claude -p` は作業ディレクトリの外のファイルを、permission mode によっては読めない。flywheel は文面を `<ワークスペース>/.flywheel/runs/<実行の ID>/task.md` に書いて絶対パスを渡すので、作業ツリーの外になる。実の `claude`（2.1.328）で、作業ディレクトリの外に置いた一時ファイルを `claude -p --output-format json` で Read させて確かめた（`--setting-sources project` でユーザー設定の許可を外した状態でも同じ）: `--permission-mode auto`（`/impl` が既定で渡す値。`HARNESS_CLAUDE_PERMISSION_MODE` で上書き）では読めた。`--permission-mode default`（環境変数を空にして `harness` を直に起動した場合は、runtime が `--permission-mode` を付けないのでこの形）では「作業ディレクトリの外」で Read も shell の読みも拒否された。`--add-dir <フォルダ>` を足すと `default` でも読めた。mode に依らず読めるよう、`llm` の段に任意のキー `add_dirs`（文字列の参照かリテラルの列）を足し、解決した値のうち空でないもの（重複は 1 つ）を `--add-dir` として渡す（入力の名前は Go に書かない）。`resolve` の出力に `task_dir`（`task_file` のあるフォルダ。無ければ空文字）を足し、文面を読む `analyze`・`implement`・`e2e` が `add_dirs: [ $steps.resolve.task_dir ]` を書く（`fix`・`commit` は文面を読まない）。`issue` だけの run は `task_dir` が空で、`--add-dir` は付かない。`add_dirs` は `overridable` の許可リストに無いので、上書きでは付け替えられない（閉じている）。
- **`worktree-setup.sh`**: 第 1 引数が鍵のとき、出力の `issue` は `issue-<n>` のときだけ数で、ほかは `null`。`issue-<n>` の鍵と数字だけの呼び方は、同じ場所・同じ出力（`key` が増えただけ）で、同じ作業ツリーを再利用する（`test-worktree-setup.sh`）。

実物で確かめたこと（設計の【要確認】のうち、S3-1 の範囲のもの）:

| 確かめたこと | 方法 | 結果 |
| --- | --- | --- |
| 実の `gh` で、`resolve-ticket.sh` が読む `gh issue view <n> --json number,title,body,state` と `gh repo view --json defaultBranchRef` が、これまでどおり読めること | この Issue（#391）と、このリポジトリで実行 | 読めた（`number`・`state`・`title` の JSON。既定ブランチ `main`） |
| 実の `git` で、鍵 `task-<n>` の作業ツリー・ブランチが作られ、同じ Issue 番号でも鍵が違えば別の作業ツリーになること。別のブランチで登録済みの場所は、いまと同じく拒否されること | `test-worktree-setup.sh`（一時リポジトリと bare の origin。偽物を使わない） | 通った（`<root>/task-12`・`feature/task-12-…`。`task-12` と `task-13` は別。`task-12` に `fix/task-12-…` を渡すと「already registered for a different branch」で止まる） |
| 実の `git ls-remote` で、鍵が変わっても統合ブランチの存在確認がこれまでどおりであること | 実リポジトリで `git ls-remote --exit-code --heads origin refs/heads/main` | 0（在る）。`resolve-ticket.sh` の呼び方は変えていない |
| 空の入力が、いまはどう読まれるか（設計の「実コード確証」の裏取り） | 変更前の `parseInputs` を読む（`integer` は `strconv.ParseInt("")` が失敗、`string` は空でも `base` を「指定あり」にする）と、変更後の単体テスト | 設計の記述どおり。変更後は、型ごとに空を読み飛ばす（`TestParseInputsReadsAnEmptyValueAsAbsent`） |

**S3-3 の実装の記録（#393）**: この PR で、S3-3 の行の中身が実物になった。実装で、設計の文面から合わせた点・決めたこと（設計の決定は変えていない）:

- **出力のスキーマは action ごとに組み込みの JSON を持つ**（`runtime/internal/workflow/builtin/pull-request-{sync,push,land}.json`。`publish` は `pull-request.json` のまま）。`with` の許可リストも action ごと: `sync` は `base`・`expect_head`（任意）、`push` は `pr`・`base`、`land` は `pr`・`base`・`approved_ref`（`$edge` でだけ受けられる。規則 7）。`publish` の動き・出力は変えていない。
- **出力の欄**: `sync` は `detail`・`head_sha`（取り込んだ後の `HEAD`）・`head_before`・`base_sha`（`conflict` を直した後の形の確かめに使う。いつも出す）。`push` は `detail`・`pr_number`・`pr_url`・`branch`・`head_sha`。`land` は `detail`・`head_sha`（確かめた PR のいまの先頭。読めなければ空）・`merge_commit`（`landed` のときだけ）。
- **`sync` の 1 の「未コミットの変更」は、追跡しているファイルの変更だけ**（`git status --porcelain --untracked-files=no`）。追跡外のファイルは、取り込みの邪魔にならない限り数えない（実装の段が残す一時ファイルで止めない）。取り込みが追跡外のファイルを上書きしてしまうときは、`git merge` の失敗として `step_error`。
- **`sync` の 4 の origin の作業ブランチの確かめ**: `git ls-remote --exit-code --heads origin <作業ブランチ>`（無ければ〔終了コード 2〕PR を出す前なので飛ばす）→ `git fetch origin +refs/heads/<作業ブランチ>:refs/remotes/origin/<作業ブランチ>` → 手元が origin の祖先なら `git merge --ff-only`、origin が手元の祖先なら何もせず、どちらでもなければ `diverged`。宛先の最新は `git fetch origin +refs/heads/<宛先>:refs/remotes/origin/<宛先>` で取り、取り込みは `git merge --no-ff --no-edit origin/<宛先>`。
- **試し直し**: `gh pr view`（`land` の 1）・`git fetch`・`git push` は、通らなければ最大 3 回、1 秒おきに試す。`gh pr merge` の後の PR の読み直しは、約 10 秒まで 1 秒おき。`push` の拒否（`!`）は、試し直しても同じなので試し直さない。`push` の結果は `git push --porcelain` の、参照ごとの状態の行（`<flag>\t<from>:<to>\t<summary>`）で決める: ` `・`*`・`+` は `pushed`、`=` は `unchanged`、`!` は `rejected`、状態の行が出なければ `unavailable`。
- **`land` の 8 の「宛先の CI の運用の宣言」の読み方**は、`ci-wait-pr.sh` と同じ `ci-trigger.sh --base <宛先>`（`HARNESS_SCRIPTS_DIR` の置き場）を呼び、標準出力の JSON の `trigger` が `after-merge` のときだけ「見ない」。読めない・スクリプトが無いときは「見る」側に倒す。チェックは `gh pr checks <pr> --json name,state,bucket` で読み、`bucket` が `fail`・`cancel`・`pending` のものを数える。
- **PR の記録**: `workspace` イベントの `pr` に任意の欄 `head_only`・`merge_commit` を足した。`push`・`land` は `head_only: true` で書き、`Workspace.head_sha` だけを更新して `head_sha_by_round` へは書かない（`publish` だけが書く。この版より前の記録は `head_only` が無いので、これまでどおりラウンドごとの記録も書く）。`pr_url` を省いた記録は、記録済みの URL を消さない。`land` は、どの結果でも（PR を読めたとき）いまの先頭を記録し、`landed` では `merge_commit` も記録する。契約の `commit` の要素は `merge_commit` → `head_sha` → `head_sha_by_round` の最新の順で 1 つだけ。
- **定義の検査（規則 7。`runtime/internal/workflow/landrules.go`）**: `land` の段の `with.approved_ref` は `$edge.<名前>` でなければならず、`land` へ入るすべての遷移はその名前を `$gate.approved_ref` で渡す。`$gate.approved_ref` を渡せる先は `land` の段だけ（行き先の種類・`action`・名前を検査する）。`land` の段から出る遷移と、`$gate.approved_ref` を渡す遷移は `overridable.routes` に宣言できず（上書きでも付け替えられない）、`land` の段は `overridable.skips` に挙げられず、規則 6 の守るステップ（外せない）に入る。`interrupted` の検査は S3-2 のまま。
- **S3-2 の練習用の定義 `gate-ref.yaml` を直した**: `$gate.approved_ref` の行き先が `land` の段だけになったので、`land` の段を `command` の `recorder` から `pull-request` の `action: land`（偽の `gh`。先頭が一致せず `mismatch` になる）に替え、「通した中身が段に届いた」確認は、`recorder` の引数の記録から `land` の出力の `detail`（受け取った値が入る）へ移した。試験の中身（記録・`detail`・`interrupted`）は変えていない。
- **グラフの数**: 段は 21 から 27、遷移の辺は 65 から 100（`sync` 9・`sync-resolve` 2・`review.land` 1・`land` 8・`land-sync` 9・`land-sync-resolve` 2・`land-push` 4）、終端は 17 から 27、`limits` に `sync_resolve` が増えた。`interrupted_after_land` は遷移の辺ではなく `goto` の印なので、終端に数えない。
- **`ticket.yaml` の差分**: 設計の「`ticket` の遷移」の定義のとおり。`sync-resolve`・`land-sync-resolve` に `budget_usd: 4`・`timeout: 30m`（`llm` の段は必須）を足した。

**S3-5 の実装の記録（#395）**: この PR で、S3-5 の行の中身が実物になった。実装で、設計の文面から合わせた点・決めたこと（設計の決定は変えていない）:

- **`refresh` は、開いたゲートの記録（`gate_opened.refresh`）に写す**。畳み込みは定義を読み込まないので、「そのゲートに `refresh` の印がある」を、開いたときに写した値で決める（`contract_kind` と同じ扱い）。定義の検査: 値は `pr-head` だけ、`type: input` のゲートにだけ書ける。上書きで足す・外すことはできない（`steps.<id>.refresh cannot be overridden`）。`ticket` では `review` だけに書く。
- **取り直しは `engine.RefreshHeads`**（`runtime/internal/engine/refresh.go`）。`cmdStatus` が、落ちた runner の後始末（`Interrupt`）の後、状態を出す前に 1 度呼ぶ（`contract status` は `cmdStatus` を呼ぶので同じ道）。終わった run・印の無いゲートでは何もしない（`gh` も呼ばない）。`gh pr view <n> --json headRefOid` を、作業ツリーが残っていればそこで、無ければ run を開始したディレクトリで、30 秒の上限つきで呼ぶ。読めなければ（失敗・JSON でない・`headRefOid` が空）何も書かず、標準エラーに `cannot refresh the PR head …` を出して、いまの記録のまま出力する。
- **書き込みは `AppendIf` の中**で、同じ unit が・同じゲートで・同じ `opened_at` のまま待ち、PR の番号が同じで、記録の先頭がまだ読んだ値と違うときだけ。そうでなければ何も書かない（読んでいる間に別の `status` が同じ先頭を書いた場合も、二重に書かない）。
- **`head` の畳み込み**（`applyHead`）は、設計の表のとおり: run が終わっていない・unit に実行中の段が無い・ゲートで待っている・そのゲートに `refresh` の印がある・unit に PR の記録がある、のときだけ許し、`Workspace.head_sha` だけを更新する（`head_sha_by_round` は書かない）。それ以外（`running` の unit・印の無いゲート・PR の記録の無い unit・段の中・`head_sha` の無いイベント）は誤り。終わった run へのイベントは、これまでどおり畳み込みの共通の検査で誤りになる。`released` の場面は S3-6。
- **使わない実行の動きは変わらない**: 印のある定義は同梱の `ticket` だけで、これより前に始めた run は開始時の定義（印が無い）で続くので `gh` を呼ばない。`gate_opened` の `refresh` は空なら出さない。

実物で確かめたこと（設計の【要確認】のうち、S3-5 の範囲のもの。実物の `gh` 2.67.0・このリポジトリ）:

| 確かめたこと | 方法 | 結果 |
| --- | --- | --- |
| `gh pr view <n> --json headRefOid` の出力の形と、終了コード | このリポジトリのマージ済みの PR #390 | 標準出力は `{"headRefOid":"<40 桁の sha>"}`、終了コード 0。S3-3 で確かめた `land` の読みと同じ欄 |
| 存在しない PR・リポジトリの外で呼んだときの失敗の仕方 | 存在しない番号（`999999`）と、リポジトリの外のディレクトリで実行 | どちらも終了コード 1 で標準出力は空（標準エラーに理由）。`RefreshHeads` は何も書かず、標準エラーへ出す |
| 外から push されたあとに `headRefOid` が新しい先頭になること | **確かめていない** | 書き込める検証用のリポジトリが要り、公開リポジトリの PR を作らないため。`headRefOid` が PR の先頭のコミットであることは S3-3 で確かめた（マージ済みの PR の `headRefOid` が最後のコミットと同じ）。通しの試験は偽の `gh` で、push 後に返す先頭が変わった形を作っている |

#### B の粗い設計（A が邪魔をしないこと）

| B で足すもの | 形（粗い） | A の側の受け |
| --- | --- | --- |
| 統合先を決めて作る | `resolve` が、`uses_integration: true` と `challenge_id` から統合ブランチの名前を決め（規則は B で決める）、無ければ既定ブランチの先頭から作る（作る所は Go の段にする）。`base` をそのブランチ、`base_kind` を `integration` にする | `integration_unsupported` の行を外すだけ。`land`・`sync` は宛先を `with.base` で受けていて、既定ブランチに限っていない |
| `role: integration` の成果物 | `artifact` に `role`（`omitempty`）。`Workspace` に統合ブランチの名前と先頭。`land` が入れた後の先頭を記録する | 成果物の型と記録は足すだけ。`role` の無い `commit` が 1 つ、の決まりは変わらない |
| 統合ブランチを上げる | `reflect` の `adopt` が、ブランチの名前を受けたら、統合ブランチから既定ブランチへの PR を探し、無ければ作る。取り込みは統合ブランチそのものへ push する。入れた後に統合ブランチを消す。取り消しでは消さない | `integration_reflect_unsupported` の行を外す。`push` の「PR の宛先そのものへ push しない」の検査は、統合ブランチが PR の head になるので当たらない。入れ方（squash か、マージのコミットか）は B で決める |
| `ready` の後の統合ブランチ宛ての自動マージ（`merge` の段。LLM） | flywheel が `ready` を返さなくなった後、残すかを決める | A では触らない |

#### 選択肢があった点と、採った案

8 点とも、右の列の案を採った（2026-11-20。#388 に記録）。1 は、Issue の「新しい入力を受けていない実行は、いまと同じに動く」の例外として扱う（上の「互換と版」の表）。

| # | 点 | 選択肢 | 採った案と理由 |
| --- | --- | --- | --- |
| 1 | 最初のレビュー待ちの前の取り込みを、`issue` だけで始めた実行にも入れるか。Issue の「新しい入力を受けていない実行は、いまと同じに動く」に、字のうえでは当たる（PR にマージのコミットが増える。衝突が PR の前に LLM の段で直される） | (a) どの実行にも入れる。(b) 新しい入力（`task_file`・`task_id`）を受けた実行だけ（`resolve` の出力で振り分ける `select` が要る）。(c) 入れて、上書きで外せる遷移を宣言する | (a)。契約の文は条件を付けていない。道が 1 本で、宛先とのずれがレビューの前に分かる。この設計は (a) で書いた |
| 2 | `land` の 8 で、未完了のチェックを「入れられない」にするか | (a) 失敗と未完了の両方。(b) 失敗だけ。(c) 見ない（GitHub の保護の決まりに任せる） | (a)。flywheel は完了を待ってから `land` を返すので、未完了に当たるのはまれ。当たると flywheel は反映の承認を取り消してオーナーへ見せる（`land_refused`）ので、チェックの数え方が flywheel と食い違うリポジトリが出たら (b) へ寄せる |
| 3 | 入れ方（squash に固定） | (a) 固定。(b) リポジトリの宣言（`.claude-harness/`）で選ぶ | A は (a)。flywheel の側の設定（`merge_method`）が無くなるので、squash を許さないリポジトリが出たら (b) を足す |
| 4 | 待っている間の先頭の取り直し（`status` が `gh` を呼んで書く） | (a) 入れる（S3-5）。(b) 入れず、外からの push の後は `respond` を 1 度通してもらう | (a)。(b) では flywheel が `land` を返せないまま回数の上限に当たる |
| 5 | `fix`・`respond` の `self_review` が `complete` でないとき、harness が止めるか | (a) 止めない（値を返すだけ。差し戻しは flywheel の `required_facts`）。(b) `implement`（#381）と同じに、1 度戻して、だめなら失敗 | (a)。PR が出た後の run を失敗で終えると、レビュー待ちへ戻れない |
| 6 | 入れた後の作業ブランチ（origin）を消すか | (a) 消さない（リポジトリの「マージ後に自動で消す」の設定に任せる）。(b) `cleanup` で消す | (a)。`reflect` の PR のブランチは、この run が作ったものではない |
| 7 | `T-<番号>` が、同じリポジトリへ出す 2 つの flywheel のワークスペースで重なること | (a) 受ける（`worktree_conflict` で止まる）。(b) 鍵に `challenge_id` も入れる | (a)。`challenge_id` もストアごとの番号で、入れても解けない |
| 8 | 文面のファイルと Issue の両方があるとき、Issue の本文の `Base:` 行を読まないこと | (a) 読まない（宛先は `base` の入力か既定ブランチ）。(b) 読む（いまと同じ） | (a)。flywheel の S3a は、宛先を反映先（既定ブランチ）と決めて PR の宛先を確かめる（`base_changed`）。Issue の本文で宛先が変わると食い違う |

---

## 6. リポジトリ内の構成

### 6.1 Go モジュールの配置

**`runtime/` に独立した Go モジュールを置く**（`runtime/go.mod`、`runtime/cmd/harness/`、`runtime/internal/…`）。ワークフロー定義は `runtime/workflows/`、プロンプトは `runtime/workflows/prompts/`、出力スキーマは `runtime/workflows/schemas/`、runtime が持つスクリプト（`resolve-ticket` 等。PR-4）は `runtime/workflows/scripts/`。配置の細部（ディレクトリ名）は可逆な内部構造なので本文書で決め、PR-2 で変えてよい。

- X1（§6.2）の移動後のリポジトリ構成:

  ```text
  .claude-plugin/marketplace.json   # source: "./plugin"
  plugin/                           # 配布物（キャッシュへコピーされるのはここだけ）
    .claude-plugin/plugin.json
    skills/ agents/ scripts/ bin/ hooks/
  runtime/                          # Go モジュール（配布物に入らない）
    go.mod cmd/harness/ internal/ workflows/{prompts,schemas}/
  docs/  Makefile  CHANGELOG.md  README.md
  ```

- Go のモジュールをサブディレクトリに置くと、`go install` 用のタグは `runtime/vX.Y.Z` 形式になる（Go のサブディレクトリ・モジュールの規約）。§7.2 の版の分け方と整合する。
- 以降、本文書で `scripts/…` と書いたパスは、X1 の移動後は `plugin/scripts/…` を指す。

### 6.2 プラグインの配布物に Go のソース・バイナリを含めない（Q5 でオーナーが決定: X1）

事実（Claude Code の公式ドキュメント plugin-marketplaces を 2026-09-21 に参照）:

- インストール時は**プラグインのディレクトリだけ**がキャッシュへコピーされる。
- **除外ファイル（ignore）の仕組みは無い**。
- `marketplace.json` の `source` は相対パス・github・git URL・`git-subdir`・npm・zip アーカイブ・コマンドを取れる。

本リポジトリは `source: "./"`（リポジトリ全体がプラグイン）なので、**今のままでは `runtime/` がすべて配布物に入る**。

| 案 | 方法 | 利点 | 欠点 |
| --- | --- | --- | --- |
| **X1** | プラグインの中身を `plugin/` へ移し、`source: "./plugin"` にする（`skills/`・`agents/`・`scripts/`・`bin/`・`hooks/`・`.claude-plugin/plugin.json`）。`runtime/`・`docs/`・開発用の道具はルートに残る | 配布物と開発物の境界がディレクトリで固定され、以後は何を足しても混ざらない。`docs/` が配布物から外れる副次効果（現在も docs は実行時に読めない前提で運用している） | 1 回きりの大きな移動。テストの `REPO_ROOT` 基準のパス、`bin/claude-harness-run` の自己位置解決、docs 内のパス表記の追従が要る |
| X2 | CI が Go を除いた zip を作ってリリースに添付し、`source: {source: archive, url: …}` にする | 作業ツリーの構成を変えない | プラグインの配布がリリース工程に依存する（現在は main がそのまま配布物）。`marketplace.json` の URL を版ごとに更新する必要がある |
| X3 | 除外しない（Go のソースは入るが、バイナリはコミットしないので入らない） | 手間ゼロ | 決定（「含めない方法を決める」）を満たさない。`go.mod` を含むディレクトリが利用者の環境に置かれる |

**決定: X1**。**Go のコードが入る前（PR-1）に単独の PR で**行う（移動と機能追加を同じ PR に混ぜない）。プラグインの利用者から見ると、`marketplace.json` の `source` が変わるだけで、導入済みのプラグインの中身の構成（`skills/`・`agents/`…）は変わらない。移動が既存の導入先へ与える影響（再インストールの要否）は PR-1 で実測し、CHANGELOG に書く（§8.1）。

### 6.3 品質ゲートの入口を 1 つにまとめる

現状、bash テストにも単一の入口が無い。**ルートに `Makefile` を置き `make check` を唯一の入口にする**（X1 によりルートは配布物に入らない。入口の名前は可逆な選択なので本文書で決めた）。

```text
make check
  ├─ bash テスト全件（plugin/scripts/tests/*.sh を順に実行し、失敗したテスト名を集計。1 本でも落ちれば非 0）
  ├─ cd runtime && gofmt -l .（未整形のファイルが 1 つでもあれば非 0）&& go vet ./... && go test ./...
  │    └─ Linux（amd64・arm64）向けの go vet ./... とテストのビルド（make check-go-linux。Linux 上での実行はしない）
  └─ harness validate（runtime/workflows/*.yaml の静的検証。作業ツリーの定義と、埋め込んだ定義の両方）
```

- `go` が無い環境では **skip ではなく失敗**にする（`quality-check-runner` が「ゲートが 1 つも実行されていない」を `pass` にしない理由と同じ。検査していないものを通過と報告しない）。
- `harness validate` が検査するもの: 未知のキーの拒否（`when:` のような式の混入を構文として受け付けない）・`on` が `output` の `outcome` enum を網羅していること・全参照が参照先の出力スキーマに存在し型が合うこと・到達不能なステップ・`limit` が `limits` に定義されていること・`agent`/`run` の参照先が実在すること。
- **CI（ubuntu だけ）**: main 宛の PR ごとに、GitHub Actions が ubuntu で `make check` を回す（定義は `.github/workflows/check.yml`。チェック名は `check / make-check`）。`make check` をそのまま CI の 1 ジョブにしている。
- **macOS のジョブは無い**（Actions の macOS の分数は 10 倍に数えられるため置いていない）。macOS に固有の確認は、PR を出す前に手元の macOS で `make check` を回して行う（README「開発（品質ゲートと CI）」）。
- したがって CI で捕まるのは ubuntu で再現する問題だけである。macOS でだけ起きる問題は CI が green でも残りうる。

### 6.4 OS・アーキテクチャ別のビルドとリリース

- 対象: `darwin/arm64`・`darwin/amd64`・`linux/amd64`・`linux/arm64`。Windows ネイティブは対象外（既存スクリプトが bash 前提のため。WSL は linux として扱える）。
- 置き場: **GitHub Releases**（本リポジトリは public）。
- 起動: **タグの push をトリガーにした GitHub Actions**（GoReleaser 等でクロスビルド・チェックサム付き）。**タグを打つのは人**である。本リポジトリの `.claude/settings.json` の `ask` に `git tag`・`git push --tags`・`gh release`・`gh workflow` が入っており、headless の子セッションからは実行できない（それが意図どおり）。
- 導入: リリースのバイナリを置く（手順は README）＋ `go install github.com/masanami/claude-harness/runtime/cmd/harness@runtime/vX.Y.Z` の併記。その後 `harness setup`。自動更新は持たない（`harness version` が新しい版の存在を案内するところまで。後回し）。
  - **注記（オーナーの決定・2026-09-29・#275）**: `go install` の併記は開発者向けの経路に限る。利用者はリリースのバイナリで導入する（`go install` で入れたバイナリは定義を持たない。次項）。
- **実装で分かった事実（PR-6・#275）**: `go:embed` はパッケージのディレクトリより上（`../plugin/scripts`）を指せない（`invalid pattern syntax`。実測）。そのため §6.5 のとおり、ビルドの前に `make bundle` が写しをモジュールの中（`runtime/internal/bundle/files/`。git には入れない）へ作る。**`go install …@runtime/vX.Y.Z` はモジュールの中のコミット済みのファイルからビルドするので、写しを含まず、定義とスクリプトを持たないバイナリになる**（`harness version` が `embedded: false` を示し、`--workflow-dir` / `--scripts-dir` を求める）。**オーナーの決定（2026-09-29）: `go install` は開発者向けの経路に限定し、利用者の導入はリリースのバイナリで行う**。

### 6.5 CLI が `scripts/` とワークフロー定義をどこから得るか（Q4 でオーナーが決定: S1＝バイナリに埋め込む）

決定①は「CLI は Claude Code の内部ファイルに依存しない」、決定②は「runtime は既存の bash スクリプトを子プロセスとして呼ぶ」、決定③の確認事項は「YAML はプラグイン側、バイナリは CLI 側で別々に更新される」としている。**CLI がプラグインの場所からスクリプトと YAML を読むと、プラグインの場所の解決に `installed_plugins.json`（決定①が壊れやすさの実例に挙げたもの）が要る**。flywheel や CI からスキルを通さずに起動する経路では、スキルの「Base directory」も渡せない。この衝突を S1 で解いた。

| 案 | 方法 | 評価 |
| --- | --- | --- |
| **S1** | リリース時に `scripts/`・`runtime/workflows/` をバイナリへ埋め込み（`go:embed`。ビルド前に CI がモジュール内へコピー）、初回起動時に `~/.local/share/claude-harness/runtime/<CLI版>/` へ展開して使う | CLI が自己完結し、決定①を守れる。版ごとに不変のディレクトリなので、長く走る run の途中でスクリプトだけ新しくなる事故（決定①の「更新と実行中の runtime の衝突」）も起きない。**YAML の修正にリリースが要る**（決定③の理由の 1 つ「バイナリを出し直さずに済む」は失われる。宣言的・事前検証・差分が読める、の利点は残る） |
| S2 | プラグインのディレクトリから読む。場所はスキルからの引数、無ければ `installed_plugins.json` | YAML の更新にリリース不要。ただし決定①が避けた依存そのもの |
| S3 | 環境変数（`CLAUDE_HARNESS_ROOT`）を必須にする | 単純だが利用者の手順が増える。flywheel 側に harness 固有の設定を持たせる経路になる |

**決定: S1**（開発時は `--workflow-dir` / `--scripts-dir` で作業ツリーを指せるようにする）。埋め込むのは `plugin/scripts/`（X1 後のパス）と `runtime/workflows/`。

- **実装で分かった事実（PR-6・#275）**: `harness validate` は `agent:` の参照先（`plugin/agents/<名前>.md`）の実在を確かめるため、`plugin/agents/` も埋め込んで展開する。実行時の子の `claude -p` はこの写しを使わず、インストール済みのプラグインから解決する（下の段落のとおり）。`plugin/scripts/tests/` は埋め込まない。

**S1 の帰結（決定③との関係を曖昧にしないための整理）**:

| 決定③の要素 | S1 を採った後 |
| --- | --- |
| 決定そのもの: 式を持たない YAML で宣言し、ステップの種類は Go で持つ | **変わらない** |
| 理由「再開できる runtime は内部でステップのグラフをデータとして持つ必要がある」 | 残る |
| 理由「式の評価器（実質 DSL）を作らずに済む」 | 残る |
| 理由「宣言的で、実行前に検証できる（読める・差分が追える・遷移の漏れを機械的に調べられる）」 | 残る |
| 理由「汎用 DSL は非目標のまま守れる」 | 残る |
| 理由「Go ではコード定義の変更に再ビルドとリリースが要る。YAML なら workflow の修正でバイナリを出し直さずに済む」 | **失われる**。YAML はバイナリに埋め込まれるので、workflow の修正は CLI のリリースで配る。オーナーはこれを承知のうえで S1 を採った（2026-09-21） |
| 確認事項「YAML はプラグイン側、バイナリは CLI 側で別々に更新される」 | **前提が消える**。YAML は CLI と同じ単位で更新される。YAML のスキーマ版の照合（§7.3）は、開発時の `--workflow-dir` と、`resume` 時に run の記録した定義と現在の定義がずれた場合に効く |

子の `claude -p` が使う `agents/`・`skills/` はインストール済みのプラグインから Claude Code が解決する。**CLI とプラグインの版のずれは §7.3 の照合で止める**。`claude -p --plugin-dir` で CLI 同梱の版を読ませる案もあり得る（`--plugin-dir` の存在は確認済み。インストール済みの同名プラグインとの重複時の挙動は未検証。PR-6 以降の検討事項）。

---

## 7. 版の管理

### 7.1 何が別々に更新されるか

- CLI（バイナリ＋同梱のスクリプトと YAML。§6.5 の S1）
- プラグイン（薄いスキル・`agents/`・プラグイン側の `scripts/`）

### 7.2 版番号の分け方（Q13 で決定）

- プラグイン: 従来どおり `.claude-plugin/plugin.json` の `version`（semver）。
- CLI: 独立した semver。タグは `runtime/vX.Y.Z`。
- 同じ版番号に揃える案は、片方だけの修正でも両方を出し直すことになり、リリース操作（人の手）が倍になるため採らない。

### 7.3 照合（合わなければ更新を案内して止まる）

- CLI は **対応するプラグイン版の範囲** と **対応するワークフロースキーマ版の集合** を内蔵する。
- 薄いスキルは CLI を呼ぶとき自分のプラグイン版を渡す。CLI は範囲外なら**専用の終了コードで止まり**、どちらを更新すべきかを表示する（動き続けない。決定①）。
- `harness run` は YAML の `schema` が対応集合に無ければ読み込まず止まる（S1 を採ったので同梱の YAML は常に一致する。実際に効くのは開発時の `--workflow-dir` で別の定義を読ませた場合）。
- 再開時も照合する: run は開始時のワークフロー定義のハッシュを記録しており、**`resume` 時に定義が変わっていたら既定では止まる**（途中で遷移表が変わった run を黙って続けない）。
- S1 では **CLI を更新すると同梱の定義も変わる**ため、ゲートで待っている run（レビュー待ち等）が更新後の `resume` で止まる。回避策として、run が開始時の CLI 版を記録し、新しい CLI が**開始時の版の展開ディレクトリ（`~/.local/share/claude-harness/runtime/<開始時の版>/`）の定義**を、そのスキーマ版に対応していれば読み込んで続ける（N3 で決定・2026-09-21）。対応していなければ、止まって「開始時の版で `resume` する」か「その run を `cancel` する」かを案内する。
- **#388 の受け口（§5.6.2）と版**: 接続契約の版は 1、ワークフローのスキーマ版は `harness.workflow/v1` のまま。CLI は minor を上げる（flywheel の S3a が要るのは CLI のリリース）。プラグインも minor を上げる（5.1.0 → 5.2.0。変わるのは `worktree-setup.sh` の引数の受け方だけ）が、CLI が受けるプラグインの範囲（`>=4.9.0 <6.0.0`）は変えず、新しい CLI は古いプラグインのままでも動く（runtime は埋め込んだ側のスクリプトを使う。§6.5）。この版より前に始めて待っている run は、上の N3 のとおり開始時の版の定義で続くので、`land` を受けられない（`options` に出ない）。

---

## 8. 既存スキルとの併存手順（Q3 でオーナーが決定: C3）

**決定: C3（期限付きの段階移行 → メジャー版で一括切替）**。以下は判断材料として残す比較と、決定後の手順である。

撤退条件「workflow 定義と既存 SKILL.md の二重管理が避けられない」「kernel と従来経路の二重管理が長期化する」と、成功基準「置き換えた SKILL.md が実際に小さくなっている」の両方を満たす必要がある。

| 案 | 手順 | 二重管理の期間 | リスク |
| --- | --- | --- | --- |
| C1 | 新スキル（例: `/impl-run`）を並べ、旧 `/impl`・`/para-impl` は残す。後で旧を消す | 旧を消すまで無期限 | 旧を消す判断が先送りされやすい（撤退条件に直結） |
| C2 | 既存 `/impl`・`/para-impl` に切り替えフラグを足し、既定を旧→新へ反転し、旧を消す | 反転まで | 1 つのスキルが 2 経路を持つ期間、散文がかえって増える |
| **C3** | **段階を期限付きで区切る**: (A) shadow — スキルは触らず、CLI を人の端末から実チケットに使い比較 → (B) 切替 — メジャー版で `/impl`・`/para-impl` を「CLI を呼ぶ薄いスキル」へ置き換え、`ticket-worker` と散文の制御フローを同じ PR で削除 → (C) 旧経路は git の履歴にだけ残す | (A) の間だけ。(A) では SKILL.md を変えないので二重管理は「未採用の新経路」であって正本の競合ではない | (B) が一度に大きい。戻すときはメジャー版を戻す |
| C4 | 旧方式は対話専用として残し、headless（flywheel 経由）だけ CLI にする | 無期限 | flywheel の起動形は flywheel §10 の実装待ちで、今は入口が無い。二重管理が恒久化する |

**採った案: C3**。(A) の終了条件は**件数と指標の両方**で置く（N4 でオーナーが決定・2026-09-21。例: shadow run が N 件・§9 の指標で劣化なし）。**N と「劣化なし」の閾値の数字は未決**で、PR-4 の shadow 開始時に導入前の値を測り直してから確定する（§11.2）。(B) の PR で `skills/impl/SKILL.md` ほかの縮小を §0.2 の 82,139 B に対する差分として示す。縮まない部分（メソドロジー・`feature-implementer` の内側・入れ子 Task の合流規律）は §3.7 のとおり明示して残す。

**2026-09-29 更新（§11.4）**: 段階 (B) で「CLI を呼ぶ薄いスキル」へ置き換えるのは `/impl` だけにした。`/para-impl` は散文のまま残り、それが使う `ticket-worker` も残す（§10 の PR-7）。上の表の C3 の行は決定時の記述として残す。

段階 (A) の手順（人の端末から `ticket` ワークフローを実チケットに使う方法）と、§9 の指標の導入後の取り方は [`harness-runtime-shadow.md`](harness-runtime-shadow.md) に置いた（PR-4）。

### 8.1 移行時に利用者へ見える変更

段階 (B)（PR-7・メジャー版）で CHANGELOG の「破壊的変更」「利用者が取る操作」に載せる（V9 だけは PR-1 の時点で載せる）。完了承認の場で人間が見直す一覧でもある。

| # | 変更 | 対象の利用者 | 由来 |
| --- | --- | --- | --- |
| V1 | **単一 Issue の `/impl`（と `/para-impl` に 1 件だけ渡した場合）も worktree で作業する**。これまでは作業ツリー（メインのチェックアウト）で `git checkout -b` していたが、切替後は `<リポジトリの 1 つ上>/<リポジトリ名>-worktrees/issue-<番号>`（`worktree-setup` の既定）に作業ブランチが置かれ、メインのチェックアウトは触られない。手元で続きを編集する利用者は worktree へ移動する必要がある | 人が対話で `/impl` を直接使う利用者 | Q7 |
| V2 | 単一経路でも、E2E 失敗による差し戻しが最大 3 回で打ち切られる（これまで上限の記載が無かった） | 単一経路の利用者 | Q8 |
| V3 | CI が時間内に終わらなかったとき、失敗で終わらず `ci-pending` ゲートで止まり、`resume` で CI の再確認から続けられる | `/para-impl` の並列経路の利用者・上位層（flywheel 等） | Q10 |
| V4 | 単一経路でも `/explain-e2e` を自動では実施しない。run の要約に「次の操作」として案内される | 単一経路の利用者 | Q14 |
| V5 | `ticket-worker` エージェントがなくなる。**2026-09-29 の決定で PR-7 では行わない**（`/para-impl` が散文のまま使い続ける。§11.4） | エージェントを名指しで使っていた利用者 | Q6 |
| V6 | 実装委譲の状態が `~/.local/state/claude-harness/`（`$XDG_STATE_HOME` があればその配下）に残る。掃除の操作が要る | 全利用者 | Q1・Q2 |
| V7 | CLI（`harness`）の導入が必要になる（`harness setup` でプラグインも整う）。CLI とプラグインの版が合わないとスキルが止まって更新を案内する | 全利用者 | 決定①・Q4・Q13 |
| V8 | 人間が決めるゲート（設計の逸脱・レビュー対応で人の判断が要る場合）は、端末から `harness approve` で解決する。Claude に指示して解決させることはできない | 全利用者 | Q9 |
| V9 | `marketplace.json` の `source` が `./plugin` になる（PR-1。導入済みの環境で再インストールが要るかは PR-1 で実測） | 全利用者 | Q5 |

---

## 9. 成果の測り方（導入前後で比べる指標）

比較の単位は flywheel 利用先 1 件（Tom）の実行ログ `runs.jsonl`。導入前は Issue #201 2026-09-21 実測の 38 日（2026-08-14〜09-21）を基準にし、導入後も同じ長さの期間で比べる。

| # | 指標 | 導入前の取り方 | 導入後の取り方 | 撤退判定との関係 |
| --- | --- | --- | --- | --- |
| M1 | **再開 1 回あたりの親側の消費**（USD または入力トークン） | 親セッションの記録から、ゲートを抜けてから子を再起動するまでの親のターンの費用。取れなければ代理として「親が書いた再開ブリーフの長さ」 | 同じ区間（`status` を読み `resume` を呼ぶまで） | 決定④の撤退判定そのもの（減らなければ撤退） |
| M2 | **取り違えの件数**（ブランチ・ラウンド数・残予算・過去ブリーフの制約の上書き漏れ） | `delegate_end` の結果文を語で候補抽出し 1 件ずつ目視（2026-09-21 実測と同じ方法） | 同じ方法＋ runtime の検証イベント（照合の不一致を runtime が拒否した件数） | 同上 |
| M3 | 差し戻し対応の費用 ÷ 実装本体の費用 | `delegate_end` の費用記載（267 件中 96 件のみ。部分集計であることを併記） | Round ごとの費用（全件取れる） | 補助 |
| M4 | 再開理由が構造として記録されている割合 | 0%（起動と終了の境界しか無い） | Round の「開始の契機」が入っている割合（目標 100%） | 成功基準「外から観測できる」 |
| M5 | 実装委譲フローの散文の量 | 82,139 B（§0.2 の 5 ファイル） | 同じ 5 ファイル（削除されたものは 0 B）。2026-09-29 の決定で `/para-impl` の 3 ファイルと `ticket-worker` は残るので、縮むのは `skills/impl/SKILL.md` の分になる（§11.4 の U3） | 成功基準「SKILL.md が小さくなっている」 |
| M6 | 偽収束の件数（terminal failure を成功・指摘なしと扱った件数）と headless の完走率 | 既存の記録 | runtime の終端状態 | 成功基準「偽収束しない」「headless benchmark が下回らない」 |

限界: M1・M2 は利用先 1 件・目視分類に依存する。対話で `/impl` を直接使う利用者の値は取れない（2026-09-21 実測の限界と同じ）。

---

## 10. 実装の段階分け

| PR | 内容 | 依存 | この PR で**しない**こと |
| --- | --- | --- | --- |
| PR-0 | 本設計文書 | — | — |
| PR-1 | 配布物の境界（X1: `plugin/` への移動）＋ `make check`（この時点では bash テストだけ）＋ CHANGELOG の V9 | — | Go のコード |
| PR-2 | `runtime/` の骨格: YAML 読み込みと `harness validate`（§3.1 の線引きの検査を含む）・イベントログと状態の畳み込み（F1 の往復テスト）・状態の置き場（L2）・`command` 種類・`run`/`status`/`runs`/`cancel` | PR-1 | LLM 呼び出し |
| PR-3 | `llm` 種類（`--session-id`・`--json-schema`・`--max-budget-usd`・費用の累計と Q15 の fail-closed）・`gate` 種類・`resume`/`approve`（Q9 の TTY 判定）。費用フィールドと `--agent` の実測 | PR-2・N1 | 実チケットでの使用 |
| PR-4 | `select`・`workspace`・`pull-request` 種類、`resolve-ticket` スクリプト、`ticket` ワークフロー（`ci-pending` ゲートを含む）。**shadow run**（C3 の段階 A）。Q11 の既定を M1・M3 で見直す | PR-3・N2 | スキルの変更 |
| PR-6 | リリース用の GitHub Actions とビルド設定（タグは人が打つ）・S1 の埋め込みと展開・`setup`・`version`・版照合（N3 を含む） | PR-2〜 | 自動更新 |
| PR-7 | 切替（C3 の段階 B。メジャー版）: `/impl` を薄いスキルへ（`/impl` の散文の制御フローを削除）、構造テスト（`test-impl-primitive.sh` 等）の組み替え、CHANGELOG に §8.1 の V1〜V8（V5 を除く）。**確かめる事項**: 散文の `/para-impl` の worker（`ticket-worker`）が呼ぶ `/impl` が薄いスキルになっても動くこと（`--worktree` で渡された作業ツリーを `workspace` の `provided` で受ける） | 段階 A の終了条件（N4） | `/para-impl`・`ticket-worker` の変更（散文のまま残す。§11.4） |

PR-5（`fanout`・`plan-parallel` 種類、`para-impl` ワークフロー、P11 のコンフリクト解決）は 2026-09-29 に実装を見送った（§11.3・§11.4）。表から外し、PR の番号は詰めない。衝突の予測を返す読み取り専用の口は #288 で別に扱った（`harness predict-conflicts`。§5.4.1）。

**後回しにするもの**: クラッシュ復旧の作り込み（§4.5 の `interrupted` ゲート以上のもの）・run 横断の索引・自動更新・`/self-review` の内側の移行・`/pr-review-respond` の内部手順の移行（本設計では 1 つの `llm` ステップとして呼ぶだけ）・flywheel 向け接続契約の固定（flywheel §10 の実装待ち）・UI。

---

## 11. 決定の記録と残る未決

### 11.1 決定済み（2026-09-21）

前回版で「未決の問い」として上げた 15 件は、2026-09-21 にすべて推奨どおりに決まった。**Q1〜Q5・Q9 はオーナー（人間）本人の回答**（PR #254 を確認したうえで「すべて推奨どおり。Q4 はバイナリに埋め込む」）。Q6〜Q8・Q10〜Q15 は委譲元（親）の回答。

| # | 問い | 採った案 | 決めた人 | 反映先 |
| --- | --- | --- | --- | --- |
| Q1 | 永続状態の置き場 | L2: `$XDG_STATE_HOME/claude-harness/`（未設定なら `~/.local/state/claude-harness/`。`HARNESS_STATE_DIR` で上書き可） | 人間 | §4.6 |
| Q2 | 永続状態の形式 | F1: run ごとの `events.jsonl`（正本）＋ `state.json`＋ `logs/`・`artifacts/` | 人間 | §4.6 |
| Q3 | 既存スキルとの併存手順 | C3: 期限付きの段階移行（shadow → メジャー版で一括切替） | 人間 | §8 |
| Q4 | CLI がスクリプトと YAML をどこから得るか | S1: バイナリに埋め込み、版ごとのディレクトリへ展開して使う。**決定③の理由のうち「YAML の修正にバイナリの出し直しが要らない」は失われることを承知で採った。決定③そのものは不変** | 人間 | §0・§6.5・§7 |
| Q5 | プラグインの配布物から Go を除く方法 | X1: プラグインの中身を `plugin/` へ移す。Go 導入前に単独の PR（PR-1） | 人間 | §6.1・§6.2・§10 |
| Q6 | ステップの粒度 | 1 ステップ＝子プロセス 1 回。内側のループは散文に残す。`ticket-worker` は廃止 | 親 | §1.1 |
| Q7 | 1 件の場合も worktree＋fan-out 1 項目に統一するか | 統一する。**単一経路の利用者には worktree で作業することになる変化があり、利用者に見える変更として §8.1 V1 に載せた** | 親 | §3.5・§8.1 |
| Q8 | 単一経路の E2E→Phase 4 のループに上限を付けるか | 3 回（並列経路と揃える） | 親 | §3.4・§8.1 |
| Q9 | ゲートの解決経路 | `decider: human` のゲートだけ TTY 必須（observe 型には適用しない。N1） | 人間 | §5.1・§5.3 |
| Q10 | CI の timeout（再試行 1 回後） | `ci-pending` ゲートで止めて resume 可能にする | 親 | §3.4・§8.1 |
| Q11 | 差し戻しで Claude セッションを引き継ぐか | YAML の `session` でステップごとに指定。既定は `--resume` で継続。PR-4 の shadow で見直す | 親 | §4.4 |
| Q12 | `select` 種類と `$gate.note` を許すか | 許す。**許すのは一致だけ。比較・論理結合・加工を足す要求が出たら式の導入とみなして止める** | 親 | §3.1・§3.3・§3.6 |
| Q13 | CLI とプラグインの版番号 | 独立（CLI は `runtime/vX.Y.Z`）＋互換範囲の照合 | 親 | §7.2・§7.3 |
| Q14 | `/explain-e2e` の扱い | runtime の外で、止めない「次の操作」として案内する | 親 | §3.7・§8.1 |
| Q15 | 費用が取れなかった実行の数え方 | そのステップの上限額を消費したとみなす（fail-closed） | 親 | §4.3 |

### 11.2 回答の反映で生じた問いの決定（2026-09-21）

| # | 問い | 採った案 | 決めた人 | 反映先 |
| --- | --- | --- | --- | --- |
| N1 | Q9 の「`decider: human` のゲートは TTY 必須」を、observe 型の human ゲート（`human-merge`）にも適用するか | (a) input 型の human ゲートだけに適用する。observe 型では resume が判断を運ばず、runtime は PR の実状態を確かめるだけなので、TTY で守るものが無い | 人間 | §3.4・§5.3 |
| N2 | `review-human` ゲートにまとめた 2 種類の停止（R2＝修正後の `/quality-check` が 3 回通らない、R3＝`design_change`/`critical` 分類）を分けるか | (a) 1 つの human ゲートのまま。子の推奨は (b)（R2 を `decider: parent` の別ゲートに分ける）だったが、分けると人が見るゲートが 1 つ減る方向であり、実績の無い今は安全側を保つため採らなかった。**PR-5 までに、shadow run の実績（R2 の発生件数と内容）を見て見直す** | 親 | §3.4 |
| N3 | S1 のもとで、ゲート待ちの run がある状態で CLI を更新したときの再開 | (a) 開始時の版の展開ディレクトリの定義を読んで続ける（スキーマ版が対応していれば）。対応していなければ止めて、開始時の版での `resume` か `cancel` を案内する | 親 | §7.3 |
| N4 | C3 の段階 (A)（shadow）の終了条件 | **形は決定**: 件数と指標の両方で置く（例: N＝10 件・M2 が導入前以下・M6 が 0 件・M1 が導入前以下）。**数字は未決**: PR-4 の shadow 開始時に、導入前の値（M1 ほか）を測り直してから確定する | 人間 | §8 |

**残る未決は N4 の数字だけ**（PR-4 で確定）。

### 11.3 空けたまま残すもの（決めない）

- flywheel が harness を呼ぶときの起動形（接続契約）。flywheel `docs/architecture.md` §10 の実装後に確定する（§0.1・§5.6）。
- **PR-5（`fanout`・`plan-parallel` 種類、`para-impl` ワークフロー、P11 のコンフリクト解決）**。2026-09-29 に実装を見送り、検討に格下げした（§11.4）。理由: 複数 Issue の並列実行は flywheel の責務にした。flywheel は同じリポジトリの作業ツリーをスロットとして払い出す（flywheel `docs/architecture.md` §11・masanami/flywheel#73）ので、runtime も並列度・直列化を持つと 2 か所で同じことを決めることになる。§3.2 の表・§3.5 の書き下ろしは検討の材料として残す。

### 11.4 並列実行の責務の移管（2026-09-29）

オーナー（人間）の決定。§11.1・§11.2 の記録は書き換えず、この決定で影響を受ける箇所に注記した。

| # | 決定 | 決めた人 | 反映先 |
| --- | --- | --- | --- |
| D1 | 複数 Issue の並列実行（`/para-impl` の並列部分）は flywheel の責務にする。flywheel が同じリポジトリに複数の作業ツリー（worktree のスロット）を払い出し、課題ごとに `harness run ticket`（または `/impl`）を 1 本ずつ起動する。harness の runtime は複数 Issue のスケジューリング（並列度・直列化・fan-out）を持たない | 人間 | §1・§5.4 |
| D2 | PR-5 は実装を見送り、検討に格下げする | 人間 | §10・§11.3 |
| D3 | harness は衝突の予測だけを返す読み取り専用の口を用意する（#288）。並列にするかの決定は flywheel、判断材料の提供は harness。口の形は #288 で決める | 人間 | §5.4 |
| D4 | `/para-impl` は今の散文のまま残す（runtime 化しない）。flywheel を使わない利用者の並列実装の手段として残る | 人間 | §8・§10 |

D4 の帰結として、PR-7 から `/para-impl` の置き換えと `ticket-worker` の削除を外した（§10。親が確定）。N2 の「PR-5 までに見直す」は、見直しの時期を段階 A の終了判定（N4）までと読み替える（`ticket` の `review-human` の注記は runtime の定義に合わせて据え置く）。

**未決（この決定の反映で生じた問い）**:

- U1: Q6 の「`ticket-worker` は廃止」を今後どう扱うか。`/para-impl` が散文のまま残る限り `ticket-worker` も要る。
- U2: 薄い `/impl` が `ticket` ワークフロー全体（CI・レビュー・マージのラウンドまで）を動かす場合、`ticket-worker` の外側ループ（§2.3 の W1〜W4。CI の loop-until-green）と重なる。`ticket-worker` から呼ばれたときに `/impl` がどこで返るか（`review` ゲートで `waiting` になったときの扱いを含む）を PR-7 までに決める。→ **2026-10-05 に決定（§11.6 の E1）**。
- U3: M5（§9）の測り方。縮まない `/para-impl` の 3 ファイルと `ticket-worker` を比較の対象に含めたままにするか。

### 11.5 衝突の予測の口の形（#288・2026-09-29）

§11.4 D3 の「口の形は #288 で決める」の決定。委譲元（親）の回答。反映先はすべて §5.4.1。

| # | 問い | 採った案 | 決めた人 |
| --- | --- | --- | --- |
| P1 | 入口: 接続契約 v1 の面に足すか、別のコマンドにするか | 別のコマンド `harness predict-conflicts`。出力は汎用の語彙だけにし、`schema` に版を持つ。flywheel が契約として定めたら harness が `contract` 側の入口を足す | 親 |
| P2 | 予測の実装: 既存のエージェントを呼ぶか、ワークフローに書くか | 1 Issue ＝ 1 run の小さなワークフロー（本文の取得 → `issue-conflict-predictor`）を口が N 回起動し、組の突き合わせと依存の向きは Go で決定的に出す | 親 |
| P3 | 散文の `/para-impl` との関係 | 独立に並べ、エージェント定義だけを共有する。`/para-impl` は口を呼ばない | 親 |
| P4 | 出力の確からしさと lockfile | 共有ファイルは除外せずすべて出し、lockfile 等に `merge_friendly` の印。根拠は双方の予測と `depends_on` の出どころ。`confidence` は v1 に入れない（エージェントの出力の形を変えない） | 親 |
| P5 | 予算・入力の上限・対象のチェックアウト | 口全体の上限（既定は件数 × 1 USD）・1 件分に満たなければ起動せず `budget_exhausted`・入力 2〜20 件・cwd のチェックアウトの現状を探索し `head_sha` を出す | 親 |
| P6 | `--agent` と `--json-schema` の併用で型付きの出力が付かない（実物の `claude` 2.1.284 で予測が `invalid_output` になった。§1.1 の #282 と同じ） | `issue-conflict-predictor` の `tools` に StructuredOutput を足す（#282 と同じ直し方）。子の `claude` はインストール済みのプラグインからエージェントを解決するため、口が実物で動くのはこの変更を含むプラグインのリリース後 | 親 |
| P7 | git が無視するパス（生成物の写し）が予測に入る | 除外せず、`git check-ignore` で判定して `ignored: true` の印を付ける | 親 |

**flywheel 側の呼び出しの宣言は未定**（flywheel の M3 仕様 M3P20 は「計画の前に接続ツールへ衝突を予測させる」案を見送ったままで、masanami/flywheel#73 のオーナー方針〔2026-09-29〕との差分は flywheel の S2 以降の分解で仕様へ入る）。

---

### 11.6 PR-7（段階 B の切替）で決めたこと（#299・2026-10-05）

PR-7 の着手前に上げた問いの決定。§11.1〜§11.5 の記録は書き換えていない。

| # | 問い | 採った案 | 決めた人 |
| --- | --- | --- | --- |
| E1 | U2: `ticket-worker` から呼ばれた薄い `/impl` はどこで返るか | どの経路でも、最初のゲートか終端で返る。`--worktree` の経路では `review` ゲートを通常完了として返し、run は `review` で待たせたまま残す（取り消さない）。返却には「CI の red の差し戻しは runtime の中で最大 3 回まで済ませた」と書く。`design-deviation` は判断待ち、`ci-pending` とその他のゲート・`failed`（`quality_gate`・`ci_red`・`e2e` 等）・`cancelled` は `failure` として返す。`--worktree` が無ければ最初のゲートで返り、`harness status`・`resume`・`approve` を案内する。`/impl` に再開用の引数は足さない | 親 |
| E2 | 版の照合と CLI のリリースの順序 | `PluginMaxExclusive` を `6.0.0` に上げ、`PluginMin` は `4.9.0` のまま。順序は「PR-7 をマージ → 人が `runtime/vX.Y.Z` のタグと手動の Release で CLI を配る → プラグイン 5.0.0 のリリース PR」。CLI の版の番号はリリースのときに人が決める | 人間 |
| E3 | 版を上げる場所 | 慣行どおり。PR-7 では `plugin.json` を触らず、CHANGELOG の「未リリース」節に書く | 親 |
| E4 | runtime が起動する `claude -p` の permission mode | runtime に設定（環境変数 `HARNESS_CLAUDE_PERMISSION_MODE`。値をそのまま `--permission-mode` で渡す）を足し、薄い `/impl` は既定で `auto` を渡す。利用者は環境変数で上書きできる | 人間 |
| E5 | 薄い `/impl` で古くなる `/para-impl`・`ticket-worker` の文面 | 実態に合わせる最小限の文面の修正だけを許す（§11.4 の「散文のまま残す」を、この範囲に限って緩める）。挙動（役割分担・ループ・返却の分類）は変えない | 人間 |
| E6 | `self_review: incomplete`（#262）を runtime で扱うか | PR-7 に含める。`implement` の出力に `review_incomplete` を足し、PR へ進めず失敗（`self_review_incomplete`）で止める。旧 `/impl` が行っていた `/self-review` のやり直しは持たない | 人間 |
| E7 | サブエージェント（`ticket-worker`）の中で、数時間かかる `harness run` と合流できるか | 着手前に実測した: サブエージェントの中で 660 秒のバックグラウンド処理を起動し、上限付きの `until` ループ（1 回 60 秒）で状態を確かめ続けて最後まで合流でき、完了通知もターンの内側で届いた。先頭が `sleep` のコマンドは拒否される。runtime に切り離して実行する口は足さない | 親（実測） |

### 11.7 切り離した run（#347・2026-11-10）

§11.6 の E7 は「runtime に切り離して実行する口は足さない」としたが、バックグラウンドの Bash も既定の待ち時間の上限（600000 ミリ秒）で止められ、`harness run` がシグナルによる取り消しとして記録された実例が 2 件出た（#346 はつなぎ）。flywheel の案 B（masanami/flywheel#532）が `contract start` の即時の戻りを要るため、次をオーナーが決めた。§11.6 の記録は書き換えていない。

| # | 決定 |
| --- | --- |
| Q1 | `contract start` は常にすぐ戻る形に変え、`harness run` にだけ `--detach` を足す。`harness run` の既定は同期のまま。接続契約の版は v1 のまま |
| Q2 | `harness` 自身を新しいセッションの子プロセスとして起動し直して切り離す。出力は run ディレクトリのログ（`runner.log`）へ流し、二重起動は run ID ごとのロック（`runner.lock`）で防ぐ。常駐のデーモン・launchd・systemd は使わない |
| Q3 | `status` を読むときに PID と開始時刻で runner の生存を確かめる。新しい状態（orphaned 等）と心拍のファイルは使わない。死んだ runner の run は、当初の「`failed`（実行プロセスの消失）として返す」を、終端の `failed` は再開できないという既存の規則と合わないため問い直し、オーナーの回答（2026-11-10、案 A）で §4.5 に寄せた: ステップの間で落ちた場合も含めて `interrupted` ゲート（`waiting`・`rerun`／`abort`・契約では `answer` × `parent`）で待たせ、`running` のまま残さない。`failed` は使わない。再開は `contract resume --input rerun` |
| Q4 | run を起動するスキル（`/impl`）を同じ PR で書き換える（`harness run --detach` で始め、`harness status` で合流する。`timeout: 7200000` の指示は外す） |

### 11.8 切り離した再開（#359・2026-11-11）

§11.7 は始めの起動だけを切り離した。ゲートで止まった run の再開（`resume`・`approve`・`contract resume`）は呼び出し元のプロセスの中で進めたままで、review ゲートで前面から実行した `resume --input respond` が 12 分後にシグナルによる取り消し（`run_cancelled`・`actor: signal`）で止まった実例が出た（2026-11-11）。flywheel の案 B（masanami/flywheel#532）の後半は `contract resume` で判断待ちに答えるので、再開もすぐ戻る必要がある。計画で次を決めた。

| # | 決定 |
| --- | --- |
| R1 | `resume`・`approve` に `--detach` を足す。既定は同期のまま。`contract resume` はフラグを持たず、常に切り離す。runner は §11.7 の Q2 と同じもの（`runner.lock`・`runner.log`） |
| R2 | ゲートの解決は呼び出し元で同期に行い、拒否はその場で返す。解いた後の進行だけを runner に渡す。`runner.lock` は解決の前に取るので、別の runner が持っていればゲートを解かずに止まる（従来の `resume` と同じ）。runner が引き継げなかった場合は §4.5 の既存の規則（`interrupted` ゲート）に従い、新しい状態・遷移は作らない |
| R3 | `/impl` の再開の案内（`respond`・`ready`・`recheck` などの `harness resume`）を `--detach` 付きにし、再開の後は `harness status` で合流する（始めの起動と同じ形） |

### 11.9 flywheel の区切り S3 の受け口（#388・2026-11-20）

flywheel が、成果を宛先へ入れる処理を委譲先へ移すために足す受け口の決定。設計は §5.6.2。§11.1〜§11.8 の記録は書き換えていない。

| # | 決定 | 決めた人 |
| --- | --- | --- |
| L1 | **R5 を改める**: 「既定ブランチへのマージは人が行う」は、`ready` を受けた後の道（`human-merge`）として残す。そこへ、`land` と通した中身を受け、PR の先頭のコミットが一致したときだけ、機械が宛先（統合ブランチでも既定ブランチでも）へ入れる道を足す。flywheel の側の承認が、人の承認に当たる。リポジトリごとに許す設定は足さない | 人間 |
| L2 | `land` を受け付けてから、宛先へ入れ終えるかレビュー待ちへ戻るまで、`status` は `running` を返す | 人間（flywheel の S3a の仕様） |
| L3 | タスクの実行（`facts` を宣言するワークフロー。いまは `ticket`）のレビュー待ちの出力には、毎回 `facts` を出す（反映の依頼 `reflect` は `facts` を宣言せず、出さない）。1 つの実行が既定ブランチ宛てに出す成果物は 1 つ | 人間（同上） |
| L4 | 進める順: 取り込み元の無い入力・`land`・取り込んで待つ・`facts`・PR を受けて上げる依頼を先（A）、統合先と統合ブランチを上げる分を後（B）にする | 人間 |
| L5 | 一致の確かめと入れる操作は、LLM の散文ではなく Go の 1 つの段（`pull-request` の `action: land`）で行い、入れる操作にも `gh pr merge --match-head-commit` を付ける。上書きで外せない（[harness-runtime-overrides.md](harness-runtime-overrides.md) §6.2 の規則 7） | 親 |
| L6 | 通した中身は、`contract resume` の `--approved-ref` → ゲートの解決の記録 → `$gate.approved_ref` で後ろの段へ渡す。`ready`・`respond` の意味は変えない | 親 |
| L7 | 名前と場所は、`task_id` があればそこから、無ければ Issue の番号から決める。値が空の文字列の入力は「無い」と読む | 親 |
| L8 | `facts` は、ワークフローの定義の最上位に宣言し、契約の Go に段の名前を書かない | 親 |
| L9 | `land` を受けた後は、レビュー待ち以外の待ちへ移らない。runner が落ちた・起動できなかったときも `interrupted` のゲートを開かず、失敗（`interrupted_after_land`）で終える。入れる命令が通った後に入ったことを確かめられないときも、失敗（`merge_not_confirmed`）で終える。失敗で終わった実行は、flywheel が上流で確かめる | 親 |
| L10 | `reflect` は、取り消しでも失敗でも、自分が作った作業ツリーを片付ける。`ticket` は、いまのまま残す | 親 |

選択肢があった点は §5.6.2 の「選択肢があった点と、採った案」。

## 12. 未検証事項

- #388 の受け口（§5.6.2）: ~~マージ済みの PR の `headRefOid` が「入ったときの先頭」であること~~・~~`gh pr checks --json` の終了コードと 0 件のときの出力~~ → S3-2（#392）で実物の `gh` 2.67.0 で確かめた（§5.6.2 の「ゲートの解き方」の冒頭の注）。残り: `gh pr merge --match-head-commit` が通らないときの終了の仕方、マージの待ち行列のあるリポジトリで入れる命令が通った直後の PR の状態、マージのコミットを含む PR ブランチを rebase マージのリポジトリで入れられるか。S3-3（`land` の段）の PR で確かめる。

- ~~`claude -p --agent claude-harness:feature-implementer` でプラグインのエージェントをセッションの主体に据えられるか~~ → PR-3 で実測済み（§1.1）。
- ~~`claude -p --output-format json` の結果に含まれる費用・`session_id` のフィールド名~~ → PR-3 で実測済み（§4.3）。
- 散文の `/para-impl` の worker が呼ぶ `/impl` が、薄いスキルになっても動くこと（`--worktree` で渡された作業ツリーを `workspace` の `provided` で受ける）。PR-7 で確かめる（§10）。→ **PR-7 で一部を確かめた**: リードが作った作業ツリーの中から `--input worktree=` で `ticket` を起動すると `provided` で受け、リードのブランチのまま PR を作って `review` で止まる（偽の claude・gh での Go テスト `TestTicketRunsInAWorktreeProvidedByTheLead`）。サブエージェントの中で 10 分を超える処理と合流できる（§11.6 の E7）。**実物の claude で `ticket-worker` → `/impl` → `harness run` を通した確認はしていない**。
- `--plugin-dir` で読ませたプラグインと、インストール済みの同名プラグインが併存したときの挙動。
- プラグインのキャッシュへのコピー範囲・除外機構が無いことは公式ドキュメントの記述に基づく（実機でのコピー範囲は未確認）。
- X1（`plugin/` への移動）が導入済みの環境に与える影響（再インストールの要否）。PR-1 で実測する。
- 本文 YAML の予算値（`budget_usd`）は仮の値。Tom の実測（実装委譲 1 件 $10〜12）を目安に置いただけで、較正は shadow run で行う。

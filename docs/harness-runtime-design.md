# harness runtime 設計（Issue #201）

> **状態: 設計（2026-09-21 に問い Q1〜Q15 を決定済み）**。本文書は Issue #201 の決定（2026-09-20〜21）を前提に、実装に入る前に確定させるべき設計を置く。問い Q1〜Q15 の決定の記録は §11 にある。**「未決」と書いた箇所だけが本文書で決めていないもの**で、その一覧も §11 にある。
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

### 0.2 実測値（本文書の数字はこのクローンで測り直した値。2026-09-21・`4483c52`）

| 対象 | 値 | 測り方 |
| --- | --- | --- |
| `scripts/*.sh`（直下） | 27 本 | `ls scripts/*.sh \| wc -l` |
| bash テスト | 44 本 | `ls scripts/tests \| wc -l` |
| `skills/` `agents/` `scripts/` の `.md`/`.sh`（`*/tests/*` 除外） | 19,394 行 | `find … -not -path '*/tests/*' \| xargs cat \| wc -l` |
| 実装委譲フローの散文（`skills/impl/SKILL.md`・`skills/para-impl/SKILL.md`・`references/join-gate.md`・`references/star-parallel.md`・`agents/ticket-worker.md`） | **82,139 B**（261＋184＋64＋170＋79 行） | `wc -c` |
| PR CI | 無し（`.github/` が存在しない） | — |
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

### 1.1 ステップの粒度（Q6 で決定）

**runtime の 1 ステップ ＝ 1 回の子プロセス起動**（スクリプト 1 回、または `claude -p` 1 回）とする。

- `feature-implementer` の**内側のループ**（`/quality-check` 最大 3 回・`/self-review` の反復・`design-deviation-verifier` の多数決）は、最初の段階では**エージェント定義の散文に残す**。これらは 1 つの Claude セッション内の Task ネストで閉じており、外へ出すには `/self-review` 自体の移行（Issue 本文の旧 Phase 2 相当）が要る。今回の主対象（ラウンドをまたぐ状態）には効かない。
- 外側のループ（Phase 4→8 の差し戻し・CI 待ち・レビュー待ち・人の承認待ち・合流）は**すべて runtime へ移す**。ここが「再開のたびに親が組み立て直している」部分である。
- 帰結として **`ticket-worker` は廃止する**（責務は「`/impl` を呼ぶ」「CI の loop-until-green」「返却」で、いずれも runtime が持つ）。Task ネストは `ticket-worker`（深度1）→ `feature-implementer`（深度2）→ `code-reviewer`（深度3）から、`feature-implementer` がセッションの主体（深度0）になる形へ 1 段浅くなる。`claude -p --agent claude-harness:feature-implementer` で主体に据えられるかは**未検証**（`--agent` フラグの存在は `claude --help`〔2.1.278〕で確認済み。プラグインのエージェントを名前空間付きで指定できるかは PR-3 で実測する）。

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
| R4 | 修正 push 後は CI を再確認 | 暗黙 |
| R5 | マージ: base＝統合ブランチは自律（`/pr-merge`）、既定ブランチは人間ゲート | `/impl` Phase 7 注記・`star-parallel.md` Phase 9-8 |

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
| `steps.<id>.output` | JSON Schema ファイル | 出力の検証。**`outcome`（enum）を必ず持つ**＝遷移のキー |
| `steps.<id>.on` | `outcome の値` → 遷移先 | **一致だけ**。すべての enum 値を網羅していなければ読み込み時に拒否 |
| 遷移先 | ステップ id ／ `{goto, with, limit, exhausted}` ／ `{gate: <id>}` ／ `{fail: <理由>}` ／ `{done: <理由>}` ／ `{retry: <n>, exhausted: …}` | `limit` は `limits` の名前。回数は Go が数える |
| `timeout`・`budget_usd` | リテラル | ステップ単位の上限 |

終了状態も `outcome` として同じ表で扱う。runtime が付与する予約値: `step_error`（非 0 終了・起動失敗）・`step_timeout`（ステップの `timeout` 超過）・`invalid_output`（スキーマ不一致・未知の enum 値）・`budget_exhausted`。予約値はステップの出力の enum 値と衝突してはならず、`harness validate` が衝突を拒否する（例: `ci-wait` は `ci: "timeout"` を返すので、予約値の側に `step_` を付けて分けた）。**予約値を `on` に書かなければ、既定で run を `failed` にする**（fail-closed。書けば明示的に別の遷移へ送れる）。

`retry` と `limit` の回数は Go が数える。数え方の単位: `limit`（差し戻し）は **unit 単位でラウンドをまたいで**累計する（§4.2）。`retry` は**ラウンド単位**で数え、ゲートを抜けて新しいラウンドに入ると 0 に戻る（例: `ci-pending` ゲートから resume した `ci` は、再び 1 回の再試行を持つ）。

#### 式にしないための線引き（Q12 で決定）

YAML と Go のステップ種類が許す判定は**一致だけ**である。遷移のキーは「ステップの `outcome`（enum）の値が表のどの行と一致するか」、`select` は「参照 1 つが指す enum 値をそのまま outcome にする」だけで、どちらも比較（大小・範囲）・論理結合（and / or / not）・加工（演算・連結・集計・関数）を持たない。**今後の要求で比較・論理結合・加工を YAML 側に足す必要が出たら、それは式の導入とみなして止める**。その場合はまず Go 側のステップ種類の追加で解けるかを検討し（`plan-parallel` の `predict_min_issues` のように、閾値はリテラル引数として種類の中で比較する）、それでも足りなければオーナーの判断を仰ぐ（決定③の確認事項どおり）。`harness validate` は `when:`・`if:` のような条件キーや、参照の文法（§3.3）に無い形を未知のキーとして拒否する（§6.3）。

### 3.2 追加するステップ種類（Go）

式を足さずに書き切るため、次の 8 種類を Go 側に置く（新しい振る舞いは YAML の表現力ではなく種類の追加で解く、という決定③どおり）。

| kind | 振る舞い | 解いている制御 |
| --- | --- | --- |
| `command` | `scripts/` のスクリプトを argv で起動。stdout JSON を `output` で検証。`outcome` は JSON の指定フィールド、または `exit:` の終了コード表（リテラル）から得る | I2・I3・W1 |
| `llm` | `claude -p` を起動。`--json-schema` で型付き出力、`--session-id` を runtime が事前採番、`--max-budget-usd` を**残予算と `budget_usd` の小さいほう**で付与、`--output-format json` の結果から費用を累計。`session: new \| continue:<step>` で再開方針を指定 | I4・I6・I9・I11 |
| `select` | 参照 1 つが指す **enum 値をそのまま outcome にする**（副作用なし） | I10（2 段前の値での分岐） |
| `gate` | ラウンドの区切り。`input` 型（resume 時に型付きの入力を受け、その値が outcome）と `observe` 型（resume 時に外部の実状態を確認し、その結果が outcome。人の申告を信じない）がある。`decider: human \| parent \| any` | I8・P7・R1〜R3・R5 |
| `workspace` | `acquire`: 呼び出し元が worktree を渡していれば検証して `provided`、無ければ `worktree-setup` を呼んで `created`/`reused`。払い出しは run 内で直列化。`release`: 自分が作ったものだけを `worktree-cleanup` で削除（渡されたものは消さない） | I5・P8・P12 |
| `pull-request` | push → PR 作成（既存なら push のみ）。本文の**転記節（残指摘の全件・未検証の明記・クロスリポジトリ確証）は型付きの値から Go が生成**する。LLM が書くのは題名と要約だけ | I7・I13・W4 |
| `fanout` | 子ワークフローを項目ごとに起動。`max_parallel`・`serial_groups`・後続の起動条件（`advance_on`）を持つ。各項目は独立に gate で止まってよく、全項目が終端に達したら `all_terminal`、ゲート待ちが残れば run を `waiting` にする | P9・P10・P7 |
| `plan-parallel` | `max_parallel` が入力にあれば**検証して写すだけ**（判断し直さない）。無ければ計画用の `llm` を呼ぶ。Issue 数が `predict_min_issues`（リテラル）以上なら先に予測の fan-out を行う。計画結果は「受け取った直列グループを緩めていない・天井を超えていない」ことを Go が検証し、追加直列化の差分を出力に残す | P3〜P6・P13 |

### 3.3 値の受け渡し: 参照だけを許し、加工を許さない

**書き切れる**。文法は次の 4 形だけで、演算・連結・添字計算・既定値の指定は持たない。

```text
$inputs.<名前>
$steps.<step id>.<output のフィールドパス>     # 同一 unit 内で最後に成功した実行の値
$edge.<名前>                                   # 遷移の with で渡された値（遷移先のステップ内でのみ有効）
$gate.note                                     # input 型ゲートの resume で添えられた自由記述（そのゲートから出る遷移の with でのみ有効）
```

`$gate.note` は **LLM への入力としてだけ**渡せる。遷移のキーにも `select` の値にも使えない（遷移のキーは `outcome` の enum だけ。§3.1 の線引き）。`harness validate` は `$gate.note` が遷移の `with` 以外に現れたら拒否する。

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
    requested_action: CI が時間内に終わらなかった。CI の完了後に recheck を渡して resume（止めるなら abort）
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
    decider: human                        # R2 を decider: parent の別ゲートへ分けるかは未決（§11 の N2）
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

  human-merge:                                       # R5: 既定ブランチへのマージは runtime が行わない
    kind: gate
    type: observe
    decider: human                        # observe 型に TTY を要求するかは未決（§11 の N1。本文は要求しない読み）
    observe: pr-state                     # resume 時に gh で PR の実状態を確認
    requested_action: 既定ブランチ宛 PR のマージは人が行う。マージ後に resume
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

> `$gate.note` は `input` 型ゲートの resume で人が添えた自由記述。**遷移には使わない**（遷移のキーは `inputs` の enum だけ）。LLM への入力としてだけ渡す（§3.3。Q12 で決定）。
>
> `ci-pending` は `decider: any`（外部待ちで、解決に意思決定を含まない）なので TTY を要求しない。`recheck` で `ci` に戻ると、`retry` はラウンド単位で数えるため再び 1 回の再試行を持つ（§3.1）。`limit: rework` の累計は戻らない。

### 3.5 書き下ろし: `para-impl`（fan-out）

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
| P3〜P6・P13 | `plan-parallel` 種類（閾値はリテラル引数） | 不要（種類で解いた） |
| P7・R5 | `fanout` の `advance_on` ＋ `gate`（observe 型） | 不要 |
| P8・P12 | `workspace` 種類（払い出しの直列化・自分が作ったものだけ消す） | 不要 |
| P9 | `fanout` | 不要 |
| P11 | 未記述（材料不足。種類の追加で解ける見込み） | 不要の見込み |
| W3・W4 | outcome 表（deviation → gate）・`pull-request` の冪等性 | 不要 |

**結論: 最初の対象は式なしで書き切れた。** ただし 4 種類（`select`・`workspace`・`pull-request`・`plan-parallel`）を Go 側に足す前提である。式の代わりに足したものの中で、**式に近づいているのは `select` だけ**（参照 1 つの値をそのまま outcome にする＝一致だけ。比較演算・複数値の組み合わせは持たない）。Q12 で `select` と `$gate.note` を許すと決めた。根拠は、一致だけで比較・組み合わせを持たず、「式を足さず Go 側のステップ種類の追加で解く」という承認済みタスク案の方針そのものであること。どこまでを許すかは §3.1「式にしないための線引き」に書いた。

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

### 4.2 ラウンドの定義

**ラウンド ＝ ゲートとゲートの間**。run 開始でラウンド 1 が始まり、unit がゲートで止まるとラウンドが閉じ、`resume`（ゲートの解決）で次のラウンドが始まる。

- 成功基準の「中断後に完了済み step を再実行せずに resume できる」は、**「ゲートの解決後、そのゲートの遷移先から実行を再開し、閉じたラウンドのステップ実行は再実行しない」**と読む（決定④の読み替えどおり）。
- 差し戻し回数（`limit: rework`）は**ラウンドをまたいで unit 単位で数える**。レビュー後の修正（`respond` → `ci`）はゲートを通るたびに外部入力を要するので上限を付けていない（無限ループにならない）。

### 4.3 予算の扱い

- **1 unit の累計**を持つ。`llm` ステップ起動時に `--max-budget-usd = min(ステップの budget_usd, 残予算)` を付ける。`--max-budget-usd` は起動ごとに効き、`--resume` ではカウンタが 0 に戻る（Tom の運用で実測済みの性質）ので、**累計の責任は runtime が持つ**。
- 費用は `claude -p --output-format json` の結果から得る【未検証: フィールド名は PR-3 で実測して固定する】。**得られなかった実行は、そのステップの上限額（実際に付与した `--max-budget-usd` の値）を消費したものとして数える**（fail-closed。Q15 で決定。`unknown_cost_count` に記録）。
- 残予算がステップの最低額を下回ったら、起動せず `budget_exhausted` を outcome にする（既定で `failed`。YAML で人間ゲートへ送ることもできる）。

### 4.4 Claude セッションの扱い

- `llm` ステップは **runtime が `--session-id <uuid>` を事前に採番して起動**する（`claude --help` で存在確認済み）。起動前にイベントとして記録するので、runtime が途中で落ちても `session_id` は失われない（クラッシュ復旧の副次効果。これ以上の作り込みはしない）。
- `session: continue:<step>` は、そのステップの最新実行の `session_id` を `--resume` で引き継ぐ。差し戻しの修正で実装時の文脈を保つか、状態から組み立てた新しいブリーフで始めるかは費用と品質のトレードオフである。**YAML の `session` でステップごとに指定でき、差し戻し系（`fix`・`commit`・`e2e`）の既定は `continue`（`--resume` で継続）とする**（Q11 で決定）。PR-4 の shadow run で M1・M3（§9）を比べ、既定を見直す。
- **再開のブリーフは runtime が状態から決定的に組み立てる**（どのブランチ・何ラウンド目・残予算・直前ラウンドの結果・人の指示文）。現状これを親の LLM が散文とログから毎回組み立てており、差し戻し対応の費用が実装本体を上回った例がある（Issue #201 2026-09-21 実測）。ここが導入効果の本体である。

### 4.5 子プロセスの監視と合流

- runtime は起動した子プロセス（スクリプト・`claude -p`）を自分で待つ。**起動台帳は runtime の状態そのもの**になり、`join-gate.md` の起動台帳・決定表・中断報告のうち、**runtime 直下の子に関する部分は散文が不要になる**。
- `harness run` / `resume` は、全 unit がゲートか終端に達するまでプロセスとして生存する（daemon は持たない）。
- runtime が落ちた場合（副次）: 次の `resume` / `status` で「`running` のまま生存プロセスが無い」ステップ実行を `interrupted` とし、その unit を `interrupted` ゲートへ送る（自動の再実行はしない。LLM ステップは部分的なコミットを残しうるため冪等ではない）。

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

### 5.3 ゲートの解決経路と安全性（Q9 でオーナーが決定）

flywheel は承認を**人間の直接操作に限り**、CLI の承認は端末（TTY）が無ければ拒否する設計を採っている（flywheel `docs/architecture.md` §9。理由: Claude から承認コマンドが呼べると、自走中の Claude が自分で承認できる経路が開く）。**決定: harness では `decider: human` のゲートにだけ TTY を必須にする**。`decider: parent`（CLAUDE.md の判定表で親が決めてよい問い）と `any`（レビュー待ちのような外部待ち）は TTY を要求しない。

- 本文の YAML で TTY を要求するゲートは `design-deviation`・`review-human`（どちらも `type: input`・`decider: human`）。
- **`type: observe` かつ `decider: human` のゲート（`human-merge`）の扱いは未決**（§11 の N1）。observe 型では resume が判断を運ばず、外部の実状態（PR がマージされたか）を runtime が確かめるだけだからである。本文では「**TTY を要求するのは `input` 型の human ゲートだけ**」という読みを**仮に採って**書いている。
- 解決の記録には `actor`・`channel`（`tty` / `non-tty`）を必ず残す（§4.1 の Gate）。
- 同じマシン・同じユーザーで動くプロセスによる意図的な回避（疑似端末の作成など）までは防げない。防ぐのは「Claude が通常の道具立てで human ゲートを解決してしまうこと」である（flywheel §9 と同じ範囲）。

### 5.4 スロット（worktree）の払い出し主体

flywheel §11 は「スロットを flywheel が払い出すか、接続ツールに任せるか」を宣言で選べるようにするとしている。`workspace` 種類は両方を受ける（`inputs.worktree` があれば `provided`、無ければ自分で作る）。`release` は自分が作ったものだけを消す。

### 5.5 観測

`status --json` と run ディレクトリ（F1 の場合）だけで、実行主体の外から現在地が分かる。現行ログ（起動と終了の境界だけ）では「中断」と「計画された再開」を区別できなかった（Issue 2026-09-21 実測 §3）が、Round の「開始の契機」フィールドがこれを構造として記録する。

### 5.6 runtime が出せなければならない情報（書式は空ける）

Issue 2026-08-23 §3 の薄い契約: **run ID・汎用の状態・要約・人に求める操作・成果物の参照・中止と再開に必要な情報**。runtime はこれらを `status --json` で必ず出せるようにする。**フィールド名・コマンドの引数・終了コードの割り当てを flywheel 向けの契約として固定するのは、flywheel §10 の実装後**とする。harness 固有の step id・判断値はこの面に出さない（`requested_action` は人が読む文と、汎用の操作種別だけ）。

---

## 6. リポジトリ内の構成

### 6.1 Go モジュールの配置

**`runtime/` に独立した Go モジュールを置く**（`runtime/go.mod`、`runtime/cmd/harness/`、`runtime/internal/…`）。ワークフロー定義は `runtime/workflows/`、プロンプトは `runtime/workflows/prompts/`、出力スキーマは `runtime/workflows/schemas/`。配置の細部（ディレクトリ名）は可逆な内部構造なので本文書で決め、PR-2 で変えてよい。

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
  ├─ cd runtime && go vet ./... && go test ./...
  └─ harness validate（runtime/workflows/*.yaml の静的検証）
```

- `go` が無い環境では **skip ではなく失敗**にする（`quality-check-runner` が「ゲートが 1 つも実行されていない」を `pass` にしない理由と同じ。検査していないものを通過と報告しない）。
- `harness validate` が検査するもの: 未知のキーの拒否（`when:` のような式の混入を構文として受け付けない）・`on` が `output` の `outcome` enum を網羅していること・全参照が参照先の出力スキーマに存在し型が合うこと・到達不能なステップ・`limit` が `limits` に定義されていること・`agent`/`run` の参照先が実在すること。
- 本リポジトリには PR CI が無い。`make check` をそのまま CI の 1 ジョブにできる形にしておく（CI の追加は §6.4 のリリース用ワークフローと一緒に人が判断する）。

### 6.4 OS・アーキテクチャ別のビルドとリリース

- 対象: `darwin/arm64`・`darwin/amd64`・`linux/amd64`・`linux/arm64`。Windows ネイティブは対象外（既存スクリプトが bash 前提のため。WSL は linux として扱える）。
- 置き場: **GitHub Releases**（本リポジトリは public）。
- 起動: **タグの push をトリガーにした GitHub Actions**（GoReleaser 等でクロスビルド・チェックサム付き）。**タグを打つのは人**である。本リポジトリの `.claude/settings.json` の `ask` に `git tag`・`git push --tags`・`gh release`・`gh workflow` が入っており、headless の子セッションからは実行できない（それが意図どおり）。
- 導入: リリースのバイナリを置く（手順は README）＋ `go install github.com/masanami/claude-harness/runtime/cmd/harness@runtime/vX.Y.Z` の併記。その後 `harness setup`。自動更新は持たない（`harness version` が新しい版の存在を案内するところまで。後回し）。

### 6.5 CLI が `scripts/` とワークフロー定義をどこから得るか（Q4 でオーナーが決定: S1＝バイナリに埋め込む）

決定①は「CLI は Claude Code の内部ファイルに依存しない」、決定②は「runtime は既存の bash スクリプトを子プロセスとして呼ぶ」、決定③の確認事項は「YAML はプラグイン側、バイナリは CLI 側で別々に更新される」としている。**CLI がプラグインの場所からスクリプトと YAML を読むと、プラグインの場所の解決に `installed_plugins.json`（決定①が壊れやすさの実例に挙げたもの）が要る**。flywheel や CI からスキルを通さずに起動する経路では、スキルの「Base directory」も渡せない。この衝突を S1 で解いた。

| 案 | 方法 | 評価 |
| --- | --- | --- |
| **S1** | リリース時に `scripts/`・`runtime/workflows/` をバイナリへ埋め込み（`go:embed`。ビルド前に CI がモジュール内へコピー）、初回起動時に `~/.local/share/claude-harness/runtime/<CLI版>/` へ展開して使う | CLI が自己完結し、決定①を守れる。版ごとに不変のディレクトリなので、長く走る run の途中でスクリプトだけ新しくなる事故（決定①の「更新と実行中の runtime の衝突」）も起きない。**YAML の修正にリリースが要る**（決定③の理由の 1 つ「バイナリを出し直さずに済む」は失われる。宣言的・事前検証・差分が読める、の利点は残る） |
| S2 | プラグインのディレクトリから読む。場所はスキルからの引数、無ければ `installed_plugins.json` | YAML の更新にリリース不要。ただし決定①が避けた依存そのもの |
| S3 | 環境変数（`CLAUDE_HARNESS_ROOT`）を必須にする | 単純だが利用者の手順が増える。flywheel 側に harness 固有の設定を持たせる経路になる |

**決定: S1**（開発時は `--workflow-dir` / `--scripts-dir` で作業ツリーを指せるようにする）。埋め込むのは `plugin/scripts/`（X1 後のパス）と `runtime/workflows/`。

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
- S1 では **CLI を更新すると同梱の定義も変わる**ため、ゲートで待っている run（レビュー待ち等）が更新後の `resume` で止まる。回避策として、run が開始時の CLI 版を記録し、新しい CLI が**開始時の版の展開ディレクトリ（`~/.local/share/claude-harness/runtime/<開始時の版>/`）の定義**を、そのスキーマ版に対応していれば読み込んで続ける形を**仮に採る**（§11 の N3）。対応していなければ、止まって「開始時の版で `resume` する」か「その run を `cancel` する」かを案内する。

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

**採った案: C3**。(A) の終了条件は事前に数字で置く（例: shadow run が N 件・§9 の指標で劣化なし）。**N と「劣化なし」の閾値はまだ決めていない**（§11 の N4）。(B) の PR で `skills/impl/SKILL.md` ほかの縮小を §0.2 の 82,139 B に対する差分として示す。縮まない部分（メソドロジー・`feature-implementer` の内側・入れ子 Task の合流規律）は §3.7 のとおり明示して残す。

### 8.1 移行時に利用者へ見える変更

段階 (B)（PR-7・メジャー版）で CHANGELOG の「破壊的変更」「利用者が取る操作」に載せる（V9 だけは PR-1 の時点で載せる）。完了承認の場で人間が見直す一覧でもある。

| # | 変更 | 対象の利用者 | 由来 |
| --- | --- | --- | --- |
| V1 | **単一 Issue の `/impl`（と `/para-impl` に 1 件だけ渡した場合）も worktree で作業する**。これまでは作業ツリー（メインのチェックアウト）で `git checkout -b` していたが、切替後は `<リポジトリの 1 つ上>/<リポジトリ名>-worktrees/issue-<番号>`（`worktree-setup` の既定）に作業ブランチが置かれ、メインのチェックアウトは触られない。手元で続きを編集する利用者は worktree へ移動する必要がある | 人が対話で `/impl` を直接使う利用者 | Q7 |
| V2 | 単一経路でも、E2E 失敗による差し戻しが最大 3 回で打ち切られる（これまで上限の記載が無かった） | 単一経路の利用者 | Q8 |
| V3 | CI が時間内に終わらなかったとき、失敗で終わらず `ci-pending` ゲートで止まり、`resume` で CI の再確認から続けられる | `/para-impl` の並列経路の利用者・上位層（flywheel 等） | Q10 |
| V4 | 単一経路でも `/explain-e2e` を自動では実施しない。run の要約に「次の操作」として案内される | 単一経路の利用者 | Q14 |
| V5 | `ticket-worker` エージェントがなくなる | エージェントを名指しで使っていた利用者 | Q6 |
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
| M5 | 実装委譲フローの散文の量 | 82,139 B（§0.2 の 5 ファイル） | 同じ 5 ファイル（削除されたものは 0 B） | 成功基準「SKILL.md が小さくなっている」 |
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
| PR-5 | `fanout`・`plan-parallel` 種類、`para-impl` ワークフロー、P11 のコンフリクト解決 | PR-4 の shadow 結果 | スキルの変更 |
| PR-6 | リリース用の GitHub Actions とビルド設定（タグは人が打つ）・S1 の埋め込みと展開・`setup`・`version`・版照合（N3 を含む） | PR-2〜 | 自動更新 |
| PR-7 | 切替（C3 の段階 B。メジャー版）: `/impl`・`/para-impl` を薄いスキルへ、`ticket-worker` と散文の制御フローを削除、構造テスト（`test-impl-primitive.sh`・`test-para-impl-join-gate.sh` 等）の組み替え、CHANGELOG に §8.1 の V1〜V8 | 段階 A の終了条件（N4） | — |

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
| Q9 | ゲートの解決経路 | `decider: human` のゲートだけ TTY 必須（observe 型の扱いは N1） | 人間 | §5.1・§5.3 |
| Q10 | CI の timeout（再試行 1 回後） | `ci-pending` ゲートで止めて resume 可能にする | 親 | §3.4・§8.1 |
| Q11 | 差し戻しで Claude セッションを引き継ぐか | YAML の `session` でステップごとに指定。既定は `--resume` で継続。PR-4 の shadow で見直す | 親 | §4.4 |
| Q12 | `select` 種類と `$gate.note` を許すか | 許す。**許すのは一致だけ。比較・論理結合・加工を足す要求が出たら式の導入とみなして止める** | 親 | §3.1・§3.3・§3.6 |
| Q13 | CLI とプラグインの版番号 | 独立（CLI は `runtime/vX.Y.Z`）＋互換範囲の照合 | 親 | §7.2・§7.3 |
| Q14 | `/explain-e2e` の扱い | runtime の外で、止めない「次の操作」として案内する | 親 | §3.7・§8.1 |
| Q15 | 費用が取れなかった実行の数え方 | そのステップの上限額を消費したとみなす（fail-closed） | 親 | §4.3 |

### 11.2 残る未決（回答の反映で新たに生じたもの）

本文では推奨案を**仮に採って**書いた。決まったら該当箇所を改める。

| # | 問い | 選択肢 | 推奨（本文で仮に採った案） | 決める人 |
| --- | --- | --- | --- | --- |
| N1 | Q9 の「`decider: human` のゲートは TTY 必須」を、observe 型の human ゲート（`human-merge`: resume が判断を運ばず、PR がマージされたかを runtime が確かめるだけ）にも適用するか | (a) input 型の human ゲートだけに適用 ／ (b) observe 型にも適用（マージ後の `resume` も人が端末で行う） ／ (c) `human-merge` を `decider: any` に改める（人間が行うのはマージ操作そのもので、ゲートの解決ではないと整理し直す） | (a)。マージという判断は GitHub 上で人が済ませており、runtime は実状態を確認するだけなので、TTY で守るものが無い。(b) だと flywheel などがマージ後に自動で再開できなくなる | 人間（Q9 の解釈） |
| N2 | `review-human` ゲートは `/pr-review-respond` の 2 種類の停止をまとめている。R2（修正後の `/quality-check` が 3 回通らない）と R3（`design_change`/`critical` 分類）である。Q9 により両方が TTY 必須になるが、R2 は親が決めてよい種類の判断ではないか | (a) 現状のまま 1 つの human ゲート ／ (b) R2 を `decider: parent` の別ゲート（`review-qc-failed`）に分け、R3 だけを human にする | (b)。R2 は品質ゲートの未通過で、現行の `feature-implementer` の `failure` と同じく親が扱っている判断である。ただし本文の YAML は安全側の (a) のまま書いた | 親（安全性の判断と見るなら人間） |
| N3 | S1 のもとで、ゲート待ちの run がある状態で CLI を更新したときの再開 | (a) 開始時の版の展開ディレクトリの定義を読んで続ける（スキーマ版が対応していれば） ／ (b) 常に止めて、開始時の版の CLI で再開するよう案内する ／ (c) 更新後の定義へ移し替える（遷移表の対応付けが要る） | (a)（§7.3）。展開ディレクトリは版ごとに不変なので、定義の取り違えは起きない | 親 |
| N4 | C3 の段階 (A) の終了条件（shadow run の件数 N と「劣化なし」の閾値） | 例: N＝10 件・M2（取り違え）が導入前以下・M6（偽収束）0 件・M1 が導入前以下 ／ 期間で区切る（例: 4 週間） | 件数と指標の両方で置く（例の値）。数字そのものは PR-4 の shadow 開始時に、M1 の導入前の値を測り直してから確定する | 人間（C3 の具体化） |

### 11.3 空けたまま残すもの（決めない）

- flywheel が harness を呼ぶときの起動形（接続契約）。flywheel `docs/architecture.md` §10 の実装後に確定する（§0.1・§5.6）。

---

## 12. 未検証事項

- `claude -p --agent claude-harness:feature-implementer` でプラグインのエージェントをセッションの主体に据えられるか（フラグの存在のみ確認）。
- `claude -p --output-format json` の結果に含まれる費用・`session_id` のフィールド名。
- `--plugin-dir` で読ませたプラグインと、インストール済みの同名プラグインが併存したときの挙動。
- プラグインのキャッシュへのコピー範囲・除外機構が無いことは公式ドキュメントの記述に基づく（実機でのコピー範囲は未確認）。
- X1（`plugin/` への移動）が導入済みの環境に与える影響（再インストールの要否）。PR-1 で実測する。
- 本文 YAML の予算値（`budget_usd`）は仮の値。Tom の実測（実装委譲 1 件 $10〜12）を目安に置いただけで、較正は shadow run で行う。

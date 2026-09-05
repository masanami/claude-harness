# 変更履歴

本プラグイン（`claude-harness`）の利用者向け変更履歴。**破壊的変更と、それに対して利用者が取る操作**を記録する。

- 記録の開始は **4.0.0** から。3.x 以前は版数だけを上げていたため履歴が無く、経緯は git log と [`docs/adr/`](docs/adr/) を参照する。
- 版数は `.claude-plugin/plugin.json` の `version` が正本。破壊的変更があればメジャーを上げる。
- **設計判断そのものの正本は ADR** であり、本ファイルはそれを利用者の操作へ翻訳したもの。理由を知りたい場合は各項の ADR リンクを辿る。

---

## 未リリース

### 破壊的変更（次のリリースはメジャーを上げる）

- **`quality-check-runner` / `mutation-run` に渡すコマンドをシェル解釈しなくなった（Issue #223・セキュリティ）。** `Bash(claude-harness-run:*)` を allow すると、**その `settings.json` の `deny` を迂回して任意コマンドを実行できた**。両スクリプトが受け取ったコマンド文字列を `bash -c` に渡しており、permission マッチャは外側の `claude-harness-run …` しか見ないため、`Bash(rm -r:*)` / `Bash(git push --force:*)` / `Bash(sudo:*)` が素通りしていた。`doctor` の `settings_launcher_allow` はこの allow を是正として提示するため、**doctor に従うほど deny が無効化される**状態だった。
  - コマンドは空白で argv に分解して**直接実行**する。シェル構文（`;` `&&` `|` `>` `$(…)` `` ` `` クォート グロブ）を含む指定は、**どのゲートも実行せずに exit 4** で拒否する（リテラルとして黙って実行しない）。
  - **シェルを外すだけでは塞がらない**（`rm -rf …` を argv として実行できれば迂回は成立する）ため、実行してよいコマンドを [`scripts/config/command-allowlist.txt`](scripts/config/command-allowlist.txt) に**閉じた一覧**として列挙し、一致しないものは同じく exit 4 で拒否する。一覧の拡張路は**同梱ファイルの編集だけ**（環境変数・CLI フラグ・利用側リポジトリのファイルからは差し替えられない。差し替え可能にすれば、それ自体が任意文字列を通す別経路になるため）。
  - 一覧は**実行されるコマンドを固定する**。`npm run <script>` / `make <target>` / `cargo test` のように**プロジェクト自身の設定ファイルが実行内容を決める**形は許可し、`bundle exec <cmd>` / `uv run <cmd>` / `python3 -m <module>` / `npx --no <pkg>` のように**次のトークンが実行対象そのもの**になる形は「ラッパー」として扱って、**実行対象も一覧に載っていること**を要求する（`bundle exec rspec` ✅ / `bundle exec rm -rf /` ❌）。`cargo run` / `go run` / `cargo install` / `go install` / `dotnet exec` / 素の `node <ファイル>` のように**呼び出し側が実行対象を指名する形**は載せていない。
  - `--env` は **allowlist 方式**。渡せるのは**列挙された6つの変数名だけ**（`WALKTHROUGH_PROJECT_ROOT` / `WALKTHROUGH_OUT` / `WALKTHROUGH_SLOWMO` / `WALKTHROUGH_PAUSE_MS` / `WALKTHROUGH_HEADED` / `BASE_URL`）で、接頭辞一致ではない——`WALKTHROUGH_` で始まる未知の名前も拒否される。`PATH` / `NODE_PATH` / `PYTHONPATH` / `GEM_PATH` / `CLASSPATH` のような「どのプログラムが実際に走るかを変える」変数は処理系ごとに際限なくあり、禁止列挙では取りこぼすため。
  - この allow が**何を許し・何を許さないか**は [`docs/script-launcher.md`](docs/script-launcher.md)「6. このランチャーを allow することの意味」が正本。

### 利用者が取る操作

- **CLAUDE.md の品質コマンドが単一コマンドになっているか確認する。** `npm run lint && npm run lint:css` のようにシェル構文で繋いだコマンドや、パイプ・リダイレクトを含むコマンドは渡せなくなった。**プロジェクト側の1コマンド**（`package.json` の `scripts` / Makefile のターゲット等）にまとめ、それを渡す。`/quality-check` は exit 4 を品質 fail ではなく呼び出し方の誤りとして扱い、書き直しを促す。
- **同梱 allowlist に無いツールチェインを使っている場合**、そのコマンドは渡せない。`make` / `just` などのタスクランナー経由（プロジェクト自身の設定ファイルで定義する形）へ寄せるか、claude-harness へツール追加の PR を出す。**いずれの場合も黙って `pass` にはならない**が、2つの状態は別物なので混同しないこと:
  - **allowlist に無いコマンドを渡した** → **どのゲートも実行せずに exit 4**（stdout に JSON は出ない）。品質失敗でも未検証でもなく、**呼び出し方が契約に反している**状態。コマンドを書き直して再実行する
  - **そのゲートのフラグごと省略した** → そのゲートは `status: "skip"` になる。ゲートが1つも実行されなければ `result: "skip"` / exit 3（Issue #192 の安全網。`pass` に読み替えない）
- **環境変数の前置形（`FOO=bar npm test`）は使えない。** `claude-harness-run --env KEY=VALUE …` を使う。ただし `--env` で渡せるのは allowlist に列挙された変数だけになった（`WALKTHROUGH_PROJECT_ROOT` / `WALKTHROUGH_OUT` / `WALKTHROUGH_SLOWMO` / `WALKTHROUGH_PAUSE_MS` / `WALKTHROUGH_HEADED` / `BASE_URL`）。それ以外は exit 64 で拒否される。
- **`deny` の効く範囲を取り違えないこと。** この allow が保証するのは「**ランチャーへ直接渡した1つの文字列**で deny 対象コマンドへ到達できないこと」であり、許可コマンドが起動する子プロセス（`npm run` が `package.json` の指示で呼ぶもの、`make` のレシピ等）や、`mutation-run` 自身が復元に使う `git` には permission 判定が適用されない。**許可名がどの実体へ解決されるかも保証しない**——一覧が照合するのはコマンド名であり、`PATH` 上へ実行ファイルを置ける主体は `npm` / `jest` を別のバイナリへ差し替えられる（`PATH` の相対エントリ経由の差し替えだけは拒否する）。
- **`.claude/settings.json` に `Bash(bash:*)` などの汎用実行系 allow がある場合、deny による統治はそもそも成立していない。** 本修正はランチャー経由の迂回を塞ぐものであり、汎用実行系の allow はそれとは別に見直す必要がある（`/init-project` が生成する既定の allow には、スクリプトのフォールバック実行形のために現在 `Bash(bash:*)` が含まれる）。

---

## 4.3.0

### 追加

- **`/codex-task` を追加。** 区切られた1タスク（調査・雑務）を Codex へ委譲し、**結論だけ**を JSON で受け取る汎用の委譲経路。用途別スキルを増やすのではなく**汎用1本＋共通ランナー**の形をとる（スキルの `description` は全スキル分が常時ロードされるため、スキルを増やすこと自体が固定のコンテキスト費用になり、削減という目的と逆行する）。節約の実体は出力契約にある——入力は本文でなくパスで渡し、stdout は JSON 1 個に限定し、exit code で complete / partial / failed を分け、非信頼データを shell へ連結しない。
- 分ける軸は**権限（sandbox）**。`investigate` は `codex exec --sandbox read-only`、`chore` は `--sandbox workspace-write`。`danger-full-access` は使わない。`--mode` 未指定は `investigate` へ倒すが、**未知の値は倒さず拒否**する（綴り違いを黙って広い権限へ寄せないため）。
- **`chore` は commit・push・PR 作成を行わず、成果を作業ツリーに残す。** 「本番に影響する不可逆な操作の承認ゲートは委譲先へ渡さない」という規律を、ランナー側で機械的に担保する。commit を検出した場合は `commit_detected` を付けて `partial` に落とす。
- `codex-task-runner` を追加。Codex の自己申告を信用せず、schema 適合（required / 型 / enum / 追加 field 禁止）を local `jq` でも検証し、`investigate` での変更申告（`failed`）、空の `complete`（`failed`）、作業ツリーと変更申告の食い違い（`changes_mismatch` → `partial`）、commit の発生（`commit_detected` → `partial`）、出力サイズ予算超過（`output_budget_exceeded` → `partial`。結果は破棄しない）を決定的に検査する。作業ツリーの照合には ignored ファイルも含める（`.gitignore` 対象パスへの書き込みが照合を素通りしないため）。仕様の正本は [`scripts/specs/codex-task-runner.md`](scripts/specs/codex-task-runner.md)。
- **sandbox の実効権限を起動引数で固定する。** `workspace-write` の権限は利用者の `~/.codex/config.toml` から読まれるため、`sandbox_workspace_write.network_access=false` と `sandbox_workspace_write.writable_roots=[]` を `-c` で固定し、外部接続と対象リポジトリ外への書き込みを禁じる。`chore` の安全性がローカル設定次第で崩れる状態にしない。
- `--output-schema` は**同梱 schema と互換な schema 専用**。制約を狭める差し替え（`pattern` / `minLength` の追加、enum の絞り込み）は通し、契約を広げる差し替え（必須 field の増減・追加 field の許可・enum の拡張）は**起動前に exit 64 で拒否**する。固定契約の検査は変えないため、広げた schema をそのまま実行すると原因不明の `invalid_task_contract` になる。

### 利用者が取る操作

- `/codex-task` を使う場合は、認証済みの Codex CLI と `jq` を導入する（[導入手順](docs/getting-started.md)）。未導入は実行前提エラー（`result: "failed"`、exit 69）として報告され、黙って成功にはならない。
- `chore` モードは実行前に作業ツリーを清浄にしておく（`git status --porcelain` が空）。実行前から変更のあるパスは、Codex の変更申告との突き合わせから外れる。

---

## 4.2.0

### 破壊的変更

- **`/self-review` の収束条件が「指摘ゼロ」から severity しきい値へ変わった。** `converged: true` は**残指摘が無いことを意味しなくなった**（修正しきい値未満の指摘は残りうる）。呼び出し元が `converged` だけを見て残指摘の受け渡しを分岐していた場合は、**`residualFindings` を必ず読むように直すこと**（空でなければ全件が報告・転記される）。severity の順序と 2 つのしきい値（検証しきい値 = high / 修正しきい値 = medium 以上）は `skills/self-review/SKILL.md` の `convergence-canon` ブロック 1 箇所が正本。未知・欠落の severity は high として扱う（fail-closed）。決定と根拠: [ADR 0004 — self-review の収束を severity で切る](docs/adr/0004-self-review-convergence-by-severity.md)
- **`/self-review` から Codex shadow review（Step 2.5）を除去した。** 4.1.0 で追加した Phase 0/1 の比較運用は、21 実行の検証で「別モデルなら別の欠陥を見つける」という前提が支持されず終了した（固有の発見は 1 クラスのみ）。**`/codex-review` 単体は引き続き利用できる**が、`/self-review` から自動で併走することは無くなった。回収した収穫はレビュー観点として `agents/code-reviewer.md` へ統合済み。

### 追加

- **`/self-review sweep`（掃引モード）を追加。** 欠陥クラスのカタログで差分全体を 1 クラス 1 体で並列掃引し、検出 → 反証 → 報告までを行う（修正ループは回さない）。標準モードとは別手順で、共通で使うのは diff 収集・hunk 抽出・severity 語彙のみ。
- **`claude-harness-run doctor` を追加。** 導入先プロジェクトが本プラグインの現行版を使うための前提（PATH 上のランチャー／`.claude/settings.json` の allow ／`CLAUDE.md` の節・プレースホルダ・ドキュメントマップ）を診断する。**検出と提示のみで書き換えは行わない。** `/init-project` の Step 1 からも呼ばれる。stdout に JSON 1 個、exit `0`=ok/warn・`1`=blocking あり・`2`=実行前提の欠落。
- `agents/code-reviewer.md` の観点 D にテスト品質の 4 観点を統合した（組み込みの `/code-review` はテスト・fixture のハンクをスキップするため、テスト品質はここでのみ担保される）。

### 修正

- `/self-review` 標準モードの `residualFindings` の重複除去が `claim` を先頭 64 文字に切り詰めていた。先頭が同じで後半が異なる別々の残指摘が 1 件に潰れて消えるため、**`claim` 全文照合へ修正**した（掃引モード側は既に修正済みだった）。切り詰めの再導入は否定検査で塞いである。

### 利用者が取る操作

- `converged` を残指摘の有無の判定に使っている呼び出し側があれば、`residualFindings` を読む形へ直す（上記の破壊的変更）。
- 既に導入済みのプロジェクトでは `claude-harness-run doctor --project <dir>` を一度実行し、blocking の指摘（ランチャー不在・`Bash(claude-harness-run:*)` の allow 欠落）が出ないことを確認する。出た場合の是正コマンドは診断結果に含まれる。

---

## 4.1.0

### 追加

- `/codex-review`を追加。Codex CLIをread-only sandboxで実行し、code/design lane、finding verifier、集約を1つの構造化review capsuleとして返す。
- `/self-review`から、利用可能な場合にCodex review capsuleをshadow modeで併走できるようにした。現行Claude panelの収束判定・自動修正にはまだ合成しない。
- schema検証、timeout、lane/verifierの部分失敗検出、usage・wall time計測を備えた`codex-review-runner`を追加。部分失敗や不正出力を「指摘なし」として扱わない。

### 運用上の注意

- 本バージョンのCodex reviewはPhase 0/1の比較運用であり、正式なレビューゲートではない。Codexが利用できない場合もClaude reviewは継続し、Codex側は`not_run`として理由を報告する。
- 評価期間中は、品質比較とdefect proxyの測定のため、PR上の外部レビューを従来どおり維持する。

---

## 4.0.0

**GDD（Guarantee-Driven Development / 保証駆動開発）レジームを撤去した。** 保証台帳 `docs/guarantees.md` を駆動文書とし、保証 ID・裁可ラベル・索引ゲートで運用するレジームは**不採用**となり、機構ごと削除された。既定フローは **SDD ＋ コード正・テスト正**に一本化される。

- 決定と根拠: [ADR 0002 — GDD を不採用とし、計装のみ回収する](docs/adr/0002-gdd-not-adopted-salvage-instruments.md)
- 監査スキルの作り直し: [ADR 0003 — `/surface-audit` が `/guarantee-audit` を置き換える](docs/adr/0003-surface-audit-replaces-guarantee-audit.md)
- 既定フローの正本: [`docs/ai-driven-development-strategy.md` 4.4](docs/ai-driven-development-strategy.md)

**フェーズ宣言に依存していた分岐——(4) と (7)——は、`CLAUDE.md` に `## 開発フェーズ` 節が無い／`SDD期` と宣言していたプロジェクトでは元から発動していなかったため、スキルの挙動に変化がない。** 一方 **(1)(2)(3)(5)(6)(8) はフェーズによらず全プロジェクトに影響する**（監査スキルの改名・サブエージェント名の変更・スクリプトの削除・品質ゲートの `skip` 契約・昇格判定の mode 削除・**昇格判定が品質のスキップを許可しなくなったこと**）。とくに **(5) と (8) は GDD を一度も使っていないプロジェクトでも判定結果と exit code に影響する**ため、必ず確認すること。

### 破壊的変更

#### (1) `/guarantee-audit` → `/surface-audit`（改名＋機能の作り直し）

| 旧 | 新 |
|---|---|
| `/guarantee-audit bootstrap`（既存テストから台帳ドラフトを生成） | **廃止** |
| `/guarantee-audit drift`（台帳と実態の乖離を検出） | **廃止** |
| — | `/surface-audit`（**引数なし**。公開面 × テスト担保の診断） |

`/surface-audit` は台帳に依存しない。公開面（HTTP API・CLI・公開ライブラリ API・イベント・永続化スキーマ・UI）をカテゴリ側から列挙し、テストが実際に担保している振る舞いと突き合わせて、**テスト未担保の公開面（GAP）**を報告する。出力はトリアージ前提の候補であり、ファイル生成・修正・Issue 起票はしない。

- モード引数は受け付けない（`/surface-audit bootstrap` のような呼び出しは無効）。
- `skills/guarantee-audit/references/bootstrap-mode.md` / `drift-mode.md` は削除。`/surface-audit` は `SKILL.md` 1本で完結し `references/` を持たない。

#### (2) `agents/guarantee-auditor` → `agents/surface-auditor`

サブエージェント名が変わり、`verify` モード（台帳の約束文と参照先テストの意味整合を判定する）は廃止された。`subagent_type: 'claude-harness:guarantee-auditor'` を指定している自作スキル・自動化は**名称解決エラーになる**。`claude-harness:surface-auditor` へ置き換える（責務は「指定ファイルの読解・分類」であり、台帳との照合は行わない）。

#### (3) スクリプト2本の削除

| 削除したもの | 併せて削除 |
|---|---|
| `scripts/detect-dev-phase.sh` | `scripts/specs/detect-dev-phase.md`、`scripts/tests/test-detect-dev-phase.sh` |
| `scripts/guarantee-index-check.sh` | `scripts/specs/guarantee-index-check.md`、`scripts/tests/test-guarantee-index-check.sh` |

`claude-harness-run detect-dev-phase` / `claude-harness-run guarantee-index-check` を呼ぶ自動化は、ランチャーが対象を解決できず **exit 66**（`script not found`）で落ちる（stderr に `claude-harness-run: script not found: scripts/<名前>.sh` が出る）。

#### (4) `CLAUDE.md` のフェーズ宣言（`## 開発フェーズ`）の廃止

- `/init-project` は `## 開発フェーズ` 節を**生成しなくなった**（`CLAUDE.md.template` から削除）。フェーズの確認・確定の対話工程も無くなった。
- **プラグイン内のどこからもこの宣言を読まない。** 宣言が残っていても、`GDD期` と書かれていても、挙動は変わらない（→ 移行手順 (A)）。
- `scripts/analyze-project.sh` の出力 JSON から **`docs.guaranteesLedger` フィールドが消えた**（`docs` は `{docsDir, designDocs, adrDir}` の3キーになる）。この JSON を消費する自作スキルは該当キーの参照を外す。

#### (5) `scripts/quality-check-runner.sh` が `result: "skip"` / exit 3 を返す（**全プロジェクトに影響**）

`--lint` / `--typecheck` / `--test` が**すべて未指定（または空文字）**で、実行されたゲートが1つも無い実行は、これまで `result: "pass"` / exit 0 だった。**4.0.0 では `result: "skip"` / exit 3 を返す**（Issue #192）。

- **`skip` を `pass` に読み替えてはならない。**「1つも実行していない」は「全ゲート通過」ではない。フラグを渡し忘れた呼び出しが「品質チェック成功」と報告される経路を塞ぐための変更である。
- `fail`（exit 1）と区別しているのは、「検査して落ちた」と「検査していない」が呼び出し側で別の対応になるため。exit 3 でも **stdout には通常どおり JSON が出る**。
- `--auto-fix` はゲート数に数えない（`--auto-fix` だけの実行も `skip`）。
- **一部のゲートだけが skip の場合はこれまでどおり `pass`**（型チェックの無いプロジェクト等）。変わるのは「1つも実行していない」場合だけ。
- 仕様の正本: [`scripts/specs/quality-check-runner.md`](scripts/specs/quality-check-runner.md)

呼び出し側の既定挙動も更新済み: `/quality-check` は総合判定に `⊘ SKIP` を持ち、`/commit` は skip でもコミットを続行するが未検証である旨を報告に明記し、`/para-impl` は skip を `pass` として扱わず PR 本文と完了報告に明記する。

#### (6) `scripts/promotion-decision.sh` の `all-consistent` モードと `guaranteeCheck` の削除

- `promotion-decision.sh all-consistent` は**未知の mode**になった（exit 2 / `{"status":"error","error":"unknown mode"}`）。有効な mode は `ready-for-promotion` のみ。
- `ready-for-promotion` の入力から **`guaranteeCheck` キーが外れ、判定は6項から5項になった**（必須キーは `allMerged` / `criteria` / `qualityCheck` / `e2e` の4キー＋算出）。`guaranteeCheck` を含む入力を渡しても無視される。
- `scripts/lib/common.sh` の `GUARANTEE_ID_PATTERN`（保証 ID `G-{番号}-{枝番}` の書式）も削除した（唯一の利用者が `all-consistent` だったため）。`source` して参照している自作スクリプトは自前で定義する。
- `/promote-verify` の Step 5.5（保証整合チェック）と `skills/promote-verify/references/guarantee-consistency.md` は削除。昇格前検証パッケージから保証整合セクションが無くなる。

#### (7) 共通スキルからの GDD 分岐の削除

`/create-ticket`・`/define-feature`・`/para-impl`・`/quality-check`・`/promote-verify` から「開発フェーズの判定」と GDD 期の追加挙動が消えた。具体的には:

- **`/para-impl` の裁可ゲートが無くなった。** `guarantee:approved` ラベルの有無に関わらず Issue を実装する。`guarantee:proposed` / `guarantee:approved` ラベルはプラグインが読み書きしなくなる（GitHub 側に残っていても無害だが、意味を持たない）。
- **`/create-ticket` は Issue に保証節（`## 保証（Guarantees）`）・裁可ラベル・保証参照行を書かなくなった。** 実装チケットのヘッダから `保証: 親#{番号} の保証節参照` の行が消える。
- **`/define-feature` は機能仕様に `## 宣言予定の保証` 節を作らなくなった**（`templates/feature-spec.md` から削除）。
- `/create-adr promote`（機能仕様の退役時の ADR 昇格判定）から**保証台帳との突き合わせ工程が消えた**。委ね先の語彙は「Issue / 保証台帳 / コード」から「**Issue / コードとテスト**」になり、`要人間判定` の理由から「台帳未登録の公開面」「保証台帳読取不能」が無くなった。
- **`agents/feature-implementer` から Phase 2-5（保証整合確認）が消えた。** 維持する保証への抵触確認・新規宣言のテスト先行・台帳更新の同梱は行わない。停止条件は「クリティカル設計の逸脱検知」のみになり、保証逸脱による停止経路は無くなった。`agents/ticket-worker` への保証節ブロック（`【保証節（GDD期・裁可対象 Issue #{番号} より逐語転記）】`）の受け渡しも廃止。
- `docs/customization.md` の effort 対応表が `guarantee-auditor` / `guarantee-audit` から `surface-auditor` / `surface-audit` に変わった（オーバーライドで effort を指定している場合は名称を追随させる）。
- 削除された参照ファイル: `skills/create-ticket/references/guarantee-section.md`、`skills/define-feature/references/planned-guarantees.md`、`skills/para-impl/references/guarantee-gate.md`、`skills/promote-verify/references/guarantee-consistency.md`。

#### (8) `promotion-decision.sh`: 品質ゲートが1つも実行されていない場合は常にブロックする（**全プロジェクトに影響**）

`ready-for-promotion` の判定式から **`qualityCheck.skipped === true` を許可条件から外した**。実行されたゲートが1つも無い状態は、理由が何であれ `readyForPromotion: false` になる。

| 入力の `qualityCheck` | 3.6.0 まで | 4.0.0 |
|---|---|---|
| `{"skipped": true, "reason": "..."}` | **`true`**（blockers 空） | **`false`** / `blockers: ["quality_not_verified"]` |
| `{"skipped": false, "result": "skip"}` | `false` / `["quality_not_pass"]` | `false` / **`["quality_not_verified"]`**（コードが変わった） |
| `{"result": "pass"}` | `true` | `true`（変更なし） |
| `{"result": "fail"}` | `false` / `["quality_not_pass"]` | 変更なし |

- **なぜ**: `/promote-verify` は「lint/typecheck/test のいずれも特定できなかった場合は `skipped: true` にする」と指示しており、**検査コマンドを特定できなかっただけで、何も検証していない変更が昇格可になっていた**。しかもこの経路は `quality-check-runner` を**呼ばない**ため、(5) で入れた `result: "skip"` / exit 3 の安全網が構造的に届かなかった。
- **「コマンドが存在しない」と「特定できなかった」を区別しない**。`readyForPromotion` は最終ゲートではなくその先に人間承認があるため、ブロックしても人間が状況を見て承認できる（fail-closed の方が安い）。
- **`blockers` の語彙に `quality_not_verified` が増えた**（19 → 20 語）。「検査していない」と「検査して落ちた（`quality_not_pass`）」を分ける。分岐している呼び出し側は追加が必要。
- **一部のゲートだけが未実行の場合は従来どおり `pass`**。`quality-check-runner` は1つも実行していないときだけ `result: "skip"` を返す（→ (5)）。ブロックするのはその場合だけである。
- **E2E（`e2e.skipped`）は変更なし**。スキップは許可条件のまま——E2E が無いプロジェクトは珍しくないため、非対称は意図したもの。
- `/promote-verify` 側も追随済み: 検査コマンドを特定できなかった場合は `{ skipped: false, result: 'skip', reason: "..." }` を渡す（**理由は `reason` に残るが、判定はブロックされる**）。

### 追加・変更（破壊的でないもの）

- **受入基準の粒度規約（1基準 = 1主張 = 1検証）**を既定フローへ移植した（[`docs/ai-driven-development-strategy.md` 4.5](docs/ai-driven-development-strategy.md)）。GDD の運用で得た知見を台帳用語から独立させたもの。`/define-feature` と `spec-critic` に配送済みで、**新たに書く受入基準に前向きに適用**する（既存の一括再分割は求めない）。
- `docs/ai-driven-development-strategy.md` の既定フロー節（4.4）が「機能仕様は保守する。ただし正しさは担保しない」を明文化し、**機能仕様の退役手順（ADR 昇格判定 → 削除 → 被参照の掃引）の正本**になった。GDD レジームを記述していた 5 章が削除され、旧 6 章「リスクと対策」が **5 章へ繰り上がっている**（外部から章節番号で参照している場合は要確認）。
- `docs/gdd-design-draft.md` を削除。
- **ランチャー導入スニペットの解決順を修正**（`README.md` / `docs/getting-started.md` / `docs/script-launcher.md`）。最大バージョンを先に選んでから実体を確認していたため、**最新エントリの実体が消えていると有効な旧候補を飛ばして解決に失敗**していた（`installed_plugins.json` に残ったまま cache ディレクトリが消えた場合に発生。実測で再現）。`bin/claude-harness-run` と同じく**候補を検証してからバージョン降順に最初の1件を採る**形にした（ランチャー本体の挙動は元から正しく、変更していない）。
- **`retirement-sweep` が変更履歴（`CHANGELOG.md`）を除外するようになった**（`--changelog <path>` で差し替え可。既定 `CHANGELOG.md`）。破壊的変更節の「`<path>` を削除した」は**削除された事実の記録**であって被参照ではなく、除外しないと**削除した PR 自身が恒久的な `fail` の原因を作る**（「参照 0 件」を exit code で判定するという目的が成立しなくなる）。ADR の出所記録を `--adr-dir` で除外しているのと同じ扱い。
  - 出力 JSON に **`excluded_files`** を追加した（`excluded_dirs` は従来どおり。除外集合の全体は両者の和）。既存フィールドの意味・名前は変えていない。
  - **除外したヒットは捨てず `excluded` に入り `counts.excluded` に数える**（stderr にも件数を出す）。掃引の範囲は目視できる。
  - **除外は無効化できない**（`--changelog ""` は exit 2。`--adr-dir` と同じ規定）。また**ディレクトリを受け付けない**（単一ファイルの完全一致。木ごと外せる形にすると、設けないと決めた汎用 `--exclude` と同じになる）。
  - **影響**: 変更履歴にしかヒットが無かったリポジトリは `status` が `fail` → `pass`（exit 1 → 0）に変わる。CI で exit code を見ている場合は結果が変わりうる。

### 移行手順

GDD を使っていなかったプロジェクトは **(C) と (D)** を確認すればよい（(A)(B)(E) は該当する対象が存在しない）。GDD 期で運用していたプロジェクトは (A)〜(E) を順に行う。実装コード・テストへの変更は**一切不要**である（GDD の機構は駆動文書・Issue・スキル手順の層にあり、プロダクションコードに触れていない）。

#### (A) `CLAUDE.md` の `## 開発フェーズ` 節を削除する

```bash
# 該当箇所の確認
grep -n -A4 '^## 開発フェーズ' CLAUDE.md
```

見出しと、その下の `- **フェーズ**: ...` / `- 駆動文書: ...` の行、および直前の HTML コメント（`<!-- 値は SDD期 / GDD期 の2値。... -->`）をまとめて削除する。次の見出し（`## 開発原則` 等）は残す。

**これで SDD へ戻る。** 正確には、**4.0.0 はこの宣言をどこからも読まないため、残したままでも挙動は SDD 相当になる**。それでも削除を推奨するのは、`GDD期` と書かれた節が残ると人間と後続エージェントが「台帳運用中」と誤読し、存在しない裁可・索引ゲートを前提に判断するため。削除は編集1回で完結し、他のファイルへの波及は無い。

#### (B) `docs/guarantees.md`（保証台帳）を処理する

**4.0.0 のプラグインはこのファイルを一切読まない。** `analyze-project.sh` は存在を報告しなくなり、`designDocs`（`/init-project` が「整備済みドキュメント」として扱う一覧）にも元から含まれない（名前パターンに合致しないため）。したがって:

- **削除してよい**（推奨）。台帳は非権威になったため、残すとエージェントの Glob/Grep が拾って「守ると約束された振る舞いの一覧」として読む余地が残る。既定フローでは**コードとテストが正**であり、台帳はその二重管理になる。
- **残してもプラグインの挙動は変わらない。** 履歴として保存したい場合は、ファイル冒頭に「**非権威・4.0.0 以降どの機構からも参照されない履歴文書**」と明記する。
- 台帳にしか書かれていない**恒常的な設計決定**がある場合は、削除の前に ADR へ昇格させる（`/create-adr promote` は機能仕様向けの判定モードなので、台帳については `/create-adr <テーマ>` で個別に記録する）。
- 削除する場合は、**被参照の掃引まで行う**（`claude-harness-run retirement-sweep "docs/guarantees.md"`）。仕様は [`scripts/specs/retirement-sweep.md`](scripts/specs/retirement-sweep.md)。

#### (C) 自動化・定期実行の宣言を更新する

**`/guarantee-audit` を定期実行に宣言しているワークスペースは、その宣言が無効になる。** claude-flywheel の `cadence.json`（監査ジョブの宣言）で `/guarantee-audit drift` などを指定している場合、スキルが存在しないため実行できない。

- **これはワークスペース側（claude-flywheel）の設定であり、本プラグインからは直せない。** 導入先で手当てする必要がある。
- 置き換え先は `/surface-audit`（引数なし）。ただし **`drift`（台帳と実態の乖離検出）と `/surface-audit`（テスト未担保の公開面の検出）は別の診断**であり、同じ出力にはならない。定期実行の目的が「台帳の鮮度維持」だったのなら、その目的自体が無くなっている。
- 同様に、`detect-dev-phase` / `guarantee-index-check` を CI・スクリプトから呼んでいる箇所は削除する。

#### (D) `quality-check-runner.sh` を直接呼ぶ自動化の exit code 判定を直す

```bash
# 4.0.0 以降（ランチャー経由でも exit code はそのまま伝播する）
# 終了コードは「裸で実行して次行で $? を読む」形では取れない。CI が set -e を
# 有効にしていると、非0 終了の時点でシェルが終了し case へ到達しないため。
# `|| status=$?` で受けると errexit が発動せず、4系統すべてを分岐できる。
status=0                     # 成功時は `||` 側が走らないので初期化が要る
claude-harness-run quality-check-runner --lint "..." --typecheck "..." --test "..." || status=$?
case "$status" in
  0) ;;                                             # pass
  1) echo "品質ゲート失敗、または CLI 引数不正" ;;  # gates.*.status を見て原因を提示
  2) echo "jq 不在" ;;                              # stdout に JSON は出ない
  3) echo "未検証（ゲートが1つも実行されていない）" ;;  # pass に読み替えない
esac
```

- **CLI 引数不正（未知フラグ・値欠落・`--lint`/`--typecheck`/`--test` の重複指定）は exit 1** であり、exit 2 は jq 不在のみ。`gates.*.status` に `fail` が1つも無いのに exit 1 なら引数不正を疑う。
- `if runner; then ok; fi` のような真偽だけの判定は、exit 3 を「失敗」側へ落とす。これは安全側の挙動なので急ぎの修正は要らないが、`fail` と `skip` を区別して報告するのが正しい対応。

#### (E) `promotion-decision.sh` を直接呼ぶ自動化を直す

- `all-consistent` モードの呼び出しを削除する（呼ぶと exit 2）。
- `ready-for-promotion` へ渡す JSON から `guaranteeCheck` キーを外す（残っていても無視されるが、材料を揃える側の手順から落とす）。
- **`qualityCheck` に `skipped: true` を渡している箇所を直す**（→ (8)）。検査コマンドを特定できなかった場合は `{ "skipped": false, "result": "skip", "reason": "..." }` を渡す——**理由は `reason` に残るが判定はブロックされる**。`skipped: true` のままだと `quality_not_verified` でブロックされ、`readyForPromotion` は `false` になる。
- `blockers` を読んで分岐している場合は **`quality_not_verified` を追加**する（`quality_not_pass` とは別状態。「検査していない」と「検査して落ちた」で対応が違う）。

### 変わらないもの

- 実装コード・テスト・E2E に対する変更は不要（上記のとおり GDD は駆動文書とスキル手順の層だけに存在した）。
- `/tdd-impl`・`/create-e2e`・`/explain-e2e`・`/demo`・`/pr-review-respond`・`/pr-merge`・`/self-review`・`/reduce-debt`・`/init-devcontainer` の挙動に変更は無い。
- ブランチ戦略・承認ゲート（本番影響ベース）・統合ブランチ方式は変更なし。

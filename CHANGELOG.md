# 変更履歴

本プラグイン（`claude-harness`）の利用者向け変更履歴。**破壊的変更と、それに対して利用者が取る操作**を記録する。

- 記録の開始は **4.0.0** から。3.x 以前は版数だけを上げていたため履歴が無く、経緯は git log と [`docs/adr/`](docs/adr/) を参照する。
- 版数は `.claude-plugin/plugin.json` の `version` が正本。破壊的変更があればメジャーを上げる。
- **設計判断そのものの正本は ADR** であり、本ファイルはそれを利用者の操作へ翻訳したもの。理由を知りたい場合は各項の ADR リンクを辿る。

---

## 4.0.0

**GDD（Guarantee-Driven Development / 保証駆動開発）レジームを撤去した。** 保証台帳 `docs/guarantees.md` を駆動文書とし、保証 ID・裁可ラベル・索引ゲートで運用するレジームは**不採用**となり、機構ごと削除された。既定フローは **SDD ＋ コード正・テスト正**に一本化される。

- 決定と根拠: [ADR 0002 — GDD を不採用とし、計装のみ回収する](docs/adr/0002-gdd-not-adopted-salvage-instruments.md)
- 監査スキルの作り直し: [ADR 0003 — `/surface-audit` が `/guarantee-audit` を置き換える](docs/adr/0003-surface-audit-replaces-guarantee-audit.md)
- 既定フローの正本: [`docs/ai-driven-development-strategy.md` 4.4](docs/ai-driven-development-strategy.md)

**フェーズ宣言に依存していた分岐——(4) と (7)——は、`CLAUDE.md` に `## 開発フェーズ` 節が無い／`SDD期` と宣言していたプロジェクトでは元から発動していなかったため、スキルの挙動に変化がない。** 一方 **(1)(2)(3)(5)(6) はフェーズによらず全プロジェクトに影響する**（監査スキルの改名・サブエージェント名の変更・スクリプトの削除・品質ゲートの `skip` 契約・昇格判定の mode 削除）。とくに **(5) は GDD を一度も使っていないプロジェクトでも呼び出し側の exit code 判定に影響する**ため、必ず確認すること。

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

### 追加・変更（破壊的でないもの）

- **受入基準の粒度規約（1基準 = 1主張 = 1検証）**を既定フローへ移植した（[`docs/ai-driven-development-strategy.md` 4.5](docs/ai-driven-development-strategy.md)）。GDD の運用で得た知見を台帳用語から独立させたもの。`/define-feature` と `spec-critic` に配送済みで、**新たに書く受入基準に前向きに適用**する（既存の一括再分割は求めない）。
- `docs/ai-driven-development-strategy.md` の既定フロー節（4.4）が「機能仕様は保守する。ただし正しさは担保しない」を明文化し、**機能仕様の退役手順（ADR 昇格判定 → 削除 → 被参照の掃引）の正本**になった。GDD レジームを記述していた 5 章が削除され、旧 6 章「リスクと対策」が **5 章へ繰り上がっている**（外部から章節番号で参照している場合は要確認）。
- `docs/gdd-design-draft.md` を削除。

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
claude-harness-run quality-check-runner --lint "..." --typecheck "..." --test "..."
case $? in
  0) ;;                                  # pass
  1) echo "品質ゲート失敗" ;;            # fail（gates.*.status を見て原因を提示）
  2) echo "jq 不在 / 引数不正" ;;        # stdout に JSON は出ない
  3) echo "未検証（ゲートが1つも実行されていない）" ;;  # pass に読み替えない
esac
```

`if runner; then ok; fi` のような真偽だけの判定は、exit 3 を「失敗」側へ落とす。これは安全側の挙動なので急ぎの修正は要らないが、`fail` と `skip` を区別して報告するのが正しい対応。

#### (E) `promotion-decision.sh` を直接呼ぶ自動化を直す

- `all-consistent` モードの呼び出しを削除する（呼ぶと exit 2）。
- `ready-for-promotion` へ渡す JSON から `guaranteeCheck` キーを外す（残っていても無視されるが、材料を揃える側の手順から落とす）。

### 変わらないもの

- 実装コード・テスト・E2E に対する変更は不要（上記のとおり GDD は駆動文書とスキル手順の層だけに存在した）。
- `/tdd-impl`・`/create-e2e`・`/explain-e2e`・`/demo`・`/pr-review-respond`・`/pr-merge`・`/self-review`・`/reduce-debt`・`/init-devcontainer` の挙動に変更は無い。
- ブランチ戦略・承認ゲート（本番影響ベース）・統合ブランチ方式は変更なし。

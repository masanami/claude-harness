---
name: para-impl
description: "GitHub Issueを分析し、設計→TDD実装(エージェント内でQC通過まで)→コミット→E2E→PR→CI確認の1チケットフローを実装フェーズの人間ゲートなしで実行する。複数Issue指定時は並列実行する。GDD期は裁可済み（guarantee:approved）の Issue だけを実装し、保証節を実装エージェントへ引き継ぐ。Triggers on: '/para-impl', '並列実装', 'Issueを実装して'"
argument-hint: "<Issue番号> [Issue番号...] [--base <統合ブランチ>]"
model: opus
# effort: 設計〜TDD実装〜PRの自走フローを担うため high。
effort: high
---

# Issue実装指示書

**あなたは実装を統括するリードエージェントです。**

GitHub Issueを分析し、1チケット実行フロー（設計→TDD実装→必須ゲート→コミット→E2E→PR→CI確認）に沿って実装を進めます。**クリティカル設計の意思決定は要件チケット側で完了している前提**のため、実装フェーズには人間ゲートを置きません。Issueが複数の場合は star 型（orchestrator-worker）で `ticket-worker` サブエージェントに並列委譲します。

---

## 入力パラメータ

GitHub Issue番号（複数可）: $ARGUMENTS

### パース方法

`$ARGUMENTS` を以下のルールで解釈する:

- **数値**: Issue番号として扱う（複数指定可）
- **`--base <統合ブランチ>`**: 統合ブランチ方式のオプション（下記）。切り出して保持し、残りを Issue 番号として扱う
- 例:
  - `1` → 単一Issue実装
  - `1 2 3` → 3件のIssueを並列実装（star 型）
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
| 複数 | **star 型並列実装**: **`skills/para-impl/references/star-parallel.md` を後掲の配送経路で読み出し**てから Phase 3 へ（`claude-harness-run read-plugin-doc "skills/para-impl/references/star-parallel.md"`。Read 直読みは後掲の注記のとおりランチャー未導入時のフォールバックに限る）。リードがオーケストレーターとなり、各 `ticket-worker` が独立に「1チケットの実装フロー」を実行 |

> **参照ファイルの読み出し（重要）**: 参照ファイルは導入先プロジェクトではなく**プラグイン配下**にある。プラグイン配下は導入先プロジェクトの作業ディレクトリの外にあるため、Read ツールでの読み出しは利用側に allow 設定が無いと拒否される（headless 委譲では許可する相手がいないため、既定で読めない）。読み出しは allowlist 済みの配送経路`claude-harness-run read-plugin-doc "<読む対象のプラグインルート相対パス>"`（**本スキルは参照ファイルを複数持つ。読む箇所で指定されたパスをそのまま渡すこと — 特定の1本に決め打ちしない**）で行い、stdout に出た本文を使う。**非0 終了は「読まなくてよかった」ではない** — 本文を得られていないまま手順を推測して続行せず、stderr のメッセージを添えてその場で停止し報告すること（読めないまま完走すると、書式や停止条件だけが外れた成果物が「成功」に見える）。**exit 0 でも終端マーカー `=== read-plugin-doc END ... complete ===` が無ければ本文は完結していない** — `MORE` マーカーが出ていれば示された `--from-line` で続きを取得し、END も MORE も無ければ出力が切り詰められたとみなして同様に停止すること。`=== read-plugin-doc ... ===` の行と `read-plugin-doc:` で始まる行は配送の制御情報であり本文ではない（テンプレートを埋めて書き出す際に成果物へ含めない）。`claude-harness-run: command not found` の場合のみ Read ツールへフォールバックし、スキル起動時にコンテキストへ与えられる「Base directory for this skill」を起点に `<base>/<読む対象のスキル相対パス>` として解決する（Read も拒否された場合は同様に停止して報告し、ランチャー導入を案内すること）。
<!-- 正本: docs/plugin-path-conventions.md -->

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

### 裁可ゲート（GDD期のみ）

開発フェーズ（SDD期 / GDD期）を判定し、GDD期は対象 Issue（実装チケットなら親）の裁可を確認してから Phase 2 へ進む。

> **開発フェーズの判定（重要）**: フェーズは必ず `claude-harness-run detect-dev-phase` の出力だけで判定し、`CLAUDE.md` を自分で grep しないこと（判定規約の重複実装を防ぐため）。stdout に `{"phase":"sdd"|"gdd"|"invalid","reason":"...","source":"..."}` が1個返る。フェーズ依存の追加挙動は **`phase` が `gdd` のときだけ**行い、`sdd`（宣言なしを含む）では一切挙動を変えない。**`phase` が `invalid`（exit 1）、またはスクリプトを実行できない・stdout が JSON としてパースできない（exit 2 等）場合は、`sdd` とみなさない**。フェーズ依存の処理を停止し、`reason` と `source`（および stderr のメッセージ）を添えて「要人間判定」としてユーザーに報告すること（不正な宣言や実行失敗によって GDD のゲート群が暗黙に無効化される事故を防ぐため）。`claude-harness-run: command not found` の場合のみ `bash "<プラグインルート>/scripts/detect-dev-phase.sh"` にフォールバックする（パスは引用符で囲む。プラグインルートはスキル起動時の「Base directory for this skill」から解決した絶対パス。`${CLAUDE_PLUGIN_ROOT}` は表記上のプレースホルダであり環境変数ではない）。
<!-- 正本: docs/ai-driven-development-strategy.md 5.2 / docs/plugin-path-conventions.md -->

**判定器への入力は「実装が到達する base」の内容にする（本スキル固有・重要）**: 本スキルの実装が到達するのは現在の作業ツリーではなく `{base}`（「base 統合ブランチの決定」で確定したブランチ。既定はリポジトリの既定ブランチ）であり、`{base}` の checkout は Phase 3 まで行われない。引数なしの実行は**手元の checkout** の `CLAUDE.md` を読むため、手元と `{base}` の宣言が異なると判定を取り違える（例: `{base}` は GDD 宣言・手元は宣言なし → 裁可ゲートが素通りし、未裁可の Issue が実装される）。したがって判定は次の手順で行う（**判定器を迂回しない**——フェーズの解釈は常にスクリプトの出力のみであり、ここで変えるのは判定器への入力だけ）:

1. `git fetch origin {base}` を実行する（失敗した場合は判定不能として中断する。`sdd` に読み替えない）
2. `git cat-file -e "origin/{base}:CLAUDE.md"` で `CLAUDE.md` の存在を確認する。存在しない場合は判定器の `no_claude_md` と同じ意味（宣言なし＝`sdd`）として扱い、従来どおりゲートなしで進む（この存在確認はフェーズ文法の解釈ではない。`CLAUDE.md` の中身を自分で読む・grep することは引き続き行わない）
3. 存在する場合は `git show "origin/{base}:CLAUDE.md"` を一時ファイルへ書き出し、`claude-harness-run detect-dev-phase "<一時ファイルのパス>"` で判定する（`invalid`・実行不能の扱いは上記の定型文のとおり）
4. base が Issue ごとに異なる場合は base ごとに判定し、**`gdd` の base に属する Issue にのみ裁可ゲートを適用する**（1件でも `invalid`・判定不能の base があれば全体を中断する）。**混在時に `gdd` 側で裁可ゲートの停止が出た場合も、停止は起動全体——`sdd` の base に属する Issue を含む全 Issue——に適用する**（部分実行しない。`guarantee-gate.md` 1-c と同じ理由）。停止時の報告（1-d）には `sdd` 側の Issue も `判定: 対象外（base が SDD期）` として列挙する（黙って落とさない）

**判定の基準を base に置く理由**: 裁可ゲートが守るのは実装が到達するコードベース（base ブランチ）の開発規律であり、手元 checkout の状態は偶然（別作業の残り・古い既定ブランチ）でありうる。**base が SDD なら手元が GDD 宣言でも従来どおり挙動を変えない**（SDD期不変＝default-OFF の原則は「対象（base）が SDD なら不変」を意味する）。Phase 3 以降の各層（feature-implementer・`/quality-check` の GDD ゲート）は checkout 済みの base 内容を読むため、この判定基準と整合する。

`gdd` の場合のみ、**`skills/para-impl/references/guarantee-gate.md` を前掲の配送経路で読み出し**（`claude-harness-run read-plugin-doc "skills/para-impl/references/guarantee-gate.md"`。Read 直読みは前掲の注記のとおりランチャー未導入時のフォールバックに限り、その場合は「Base directory for this skill」を起点に `<base>/references/guarantee-gate.md` として解決する）、その「Phase 1: 裁可ゲート」に従って対象 Issue（実装チケットなら親）に `guarantee:approved` が付いているかを確認する。無ければ **Phase 2 以降へ進まず処理を止めて人間の裁可を促す**（統合ブランチ存在チェックと同じ「前提未充足での停止」パターンを使う。新しい待ち合わせ機構は作らない。裁可対象の解決・判定表・停止時の報告の正本は同参照ファイル）。`invalid`・判定不能の場合は上記の定型文に従い中断する。`sdd`（フェーズ宣言なしを含む）では本項を実行せず、以降の手順は従来どおり行う（参照ファイルも読み出さない）。

---

## Phase 2: 実行計画

- 依存関係のあるIssueは順序を決定
- 独立したIssueは並列実行対象
- 不明点があればユーザーに確認を求める

---

## 1チケットの実装フロー（Phase 3〜9）

単一Issueはリードエージェントが Phase 3〜9 を実行する。複数Issueでは **Phase 3（worktree・ブランチ作成）をリードが担い**、各 `ticket-worker` が worktree で Phase 4-5〜9 を実行する（worker の Phase 7 は `/create-e2e` まで。`/explain-e2e` は worker 完了後にリードがメインセッションで実施する。**1チケット = 1ブランチ = 1PR**。詳細は `${CLAUDE_PLUGIN_ROOT}/skills/para-impl/references/star-parallel.md` 参照。解決手順は上記参照）。設計→TDD実装（必須ゲート＋セルフレビュー内包）→コミット→E2E→PR→CIの順で進める。**実装フェーズに人間ゲートは無い**。

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

**単一Issueの場合**、`{base}`（「base 統合ブランチの決定」で確定した base。既定はリポジトリの既定ブランチ・通常 `main`）から作業ブランチを切る:

```bash
git fetch origin {base}
git checkout -b {type}/issue-{番号}-{説明} origin/{base}
```

**複数Issue（star型並列実装）の場合**は `scripts/worktree-setup.sh` を使う（`skills/para-impl/references/star-parallel.md` の「worktree・ブランチ準備」参照）。

依存関係のインストールが必要であれば実施する（CLAUDE.md または package.json の構成に従う）。

### Phase 4-5: 設計＋TDD実装＋必須ゲート＋セルフレビュー（一気通貫）

`feature-implementer` エージェントを **一度だけ呼び出し**、Phase 1〜5 を一気通貫で実行させる（実装フェーズに人間ゲートは無い）。

リードは要件チケット本文の **「クリティカル設計決定」セクション**をエージェントに渡し、その方針に従って実装するよう指示する。委譲プロンプトには**合流ゲート伝播条項**（`references/join-gate.md` の「ネストへの伝播」に定義。逐語で転記する）も含める。

**GDD期**（Phase 1 の裁可ゲートを通過している場合）は、さらに**裁可対象（親）Issue の保証節（新規宣言＋維持）を委譲プロンプトに含める**（読み取り文法・同一性の検証・記載形式の正本は `references/guarantee-gate.md`「Phase 4-5: 保証節の注入」。合流ゲート伝播条項の規定は変更せず並記で追加する）。**裁可対象（親）が複数の実装チケットに分解されている場合は、今回の起動が1チケットだけでも、注入の前に新規宣言の担当割当（分解の全体像から決定的規則で各 ID をちょうど1チケット・全数検証）を解決し、各チケットには担当分の新規宣言＋全維持保証を渡す**（割当の要否は起動形態でなく親の分解の構造で決める。同参照ファイル「新規宣言の担当割当」が正本）。SDD期はこの注入を行わない（従来どおり）。

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
| `failure`（`/quality-check` 3回反復しても通らない） | 当該チケットをスキップ。並列モードでは他 worker は継続 |
| クリティカル設計の逸脱検知で Phase 2 停止（GDD期の保証逸脱——維持する保証への抵触——、保証節の読み取り不能・フェーズ判定 `invalid` による停止も同じパスで返る） | エージェントの警告内容をユーザーに提示し、判断を仰ぐ（**この動作は同パスで返るすべての停止に適用する**。headless の場合は「判断待ち」として完了報告に明記する） |

### Phase 6: コミット

```text
/commit
```

`/commit` は **コミット規約に従ったコミット実行に責務を絞った**スキル。内部では safety net として `/quality-check` を再走させ、Conventional Commits 形式でコミットを作成する。Phase 4-5 で必須ゲート・`/self-review` を通過済みのため、ここでの `/quality-check` は通過前提で速やかに完了する。

> コード簡潔化が必要な場合は **`/simplify`** を Phase 6 の前に別途呼ぶ（必須ではない）。

### Phase 7: E2E実装と独立検証（E2E対象の場合）

E2E対象機能の場合、Phase 4-5 で feature-implementer が返した E2Eシナリオ一覧に基づき実装する:

1. `/create-e2e` — 設計（Phase 4-5 のシナリオを根拠）→ 実装 → 全テスト実行
2. `/explain-e2e` — Phase 1（テストシナリオ解説）はメインセッションで対話的に、Phase 2（独立検証）は Task ツールによる直接委譲（Verify段階のfan-out・Mutation段階の逐次処理）で実施

- E2E失敗 → **Phase 4-5 に戻る**

> **複数Issue（star 型）の場合**: worker は `/create-e2e` までを実施し、`/explain-e2e` は Phase 1 が対話前提のため worker 完了後に**リードがメインセッションで実施**する。リードは**当該チケットの worktree（保持されている）内のテストコードを対象**に実施する（Phase 2 の `mutation-run.sh` 実行時は当該 worktree の絶対パスへ `cd` してから実行する）。独立検証で問題が見つかった場合は当該 worker を再度 spawn して Phase 4-5 から修正させる。

非E2E対象の場合、このフェーズはスキップする。

### Phase 8: プッシュ・PR作成

PR を作成し、本文に `Closes #番号`（バグ修正は `Fixes #番号`）を含める。Phase 4-5 で必須ゲート・セルフレビューを通過済みのため、**通常PR（非ドラフト）で開く**（AI レビューを即時起動し `/pr-review-respond` へ繋ぐ）。`/explain-e2e` は PR 作成の前提条件ではない——単一Issueでは Phase 7 で実施済み、複数Issue（star 型）では worker の PR 作成後にリードがメインセッションで実施する。

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

> CI の所要時間が長い場合、`--watch` はコマンドのタイムアウトで中断されることがある。**中断は CI 失敗ではない**ので、`gh pr checks {PR番号}` を再実行して最新状態を確認する。

- CI失敗 → 失敗内容を確認して **Phase 4-5 に戻る**
- CIパス → Phase 10（完了報告）へ

---

## 合流ゲート（最終応答前の未合流確認）

**サブエージェント・バックグラウンド処理を1つでも起動した場合、最終応答（Phase 10 の完了報告・中断報告を含む、あらゆるテキスト応答の確定）の前に合流ゲートを必ず評価する。** 完了報告を出せるのはゲート通過に該当した場合だけであり、決定表が指示した中断報告はゲートの評価結果として「ゲート通過」を要件としない。

**定義の正本は参照ファイル `skills/para-impl/references/join-gate.md`** であり、本 SKILL には要点だけを書く。用語（起動台帳・有限タスク／常駐サービス・終端返却・合流済み・未合流・ネスト未解消）・spawn 時手順・合流ゲート伝播条項（委譲プロンプトへ逐語転記する条項の正本）・決定表・中断報告の出力契約は、すべて参照ファイル側にある。**サブエージェント・バックグラウンド処理を起動する前に必ず前掲の配送経路で読み出すこと**（`claude-harness-run read-plugin-doc "skills/para-impl/references/join-gate.md"`。Read 直読みは前掲の注記のとおりランチャー未導入時のフォールバックに限り、その場合はスキル起動時にコンテキストへ与えられる「Base directory for this skill」を起点に `<base>/references/join-gate.md` として解決する）。

---

## Phase 10: 完了報告

**完了報告の前に「合流ゲート」（`references/join-gate.md`）を通過すること**（未合流のサブエージェント・バックグラウンド処理が0件であることの確認。1つも起動していない場合の0件も正常経路としてゲート通過）。

### 単一Issueの場合

1. 実装サマリー
2. PR URL とCIステータス
3. クリティカル設計の逸脱検知でユーザー判断を仰いだ場合はその結果
4. E2E結果（対象機能の場合）— /explain-e2e の解説と独立検証結果
5. **次のアクションの案内**:
   - レビュー対応: `/pr-review-respond {PR番号}`
   - マージ: `/pr-merge {PR番号}`

---

## 成果物

- プロダクションコード
- テストコード（単体・結合・E2E）
- 設計内容（クリティカル/E2E対象時の人間レビュー記録を含む）
- Pull Request（Issueごとに1つ、通常PR→CI緑＋AIレビュー対応→マージ）

---

## 禁止事項

- GDD期に `guarantee:approved` の無い Issue の実装開始（裁可ゲートの迂回）、およびエージェント自身による `guarantee:approved` の付与
- スコープ外の機能追加
- 設計フェーズ（Phase 4-5 の設計成果物出力）の省略
- 要件チケットの「クリティカル設計決定」を無視した実装
- テストなしでのコード追加

---

## ユーザーへの確認タイミング

- **Phase 1: 裁可ゲート未通過（GDD期）**（実装を開始せず、人間の裁可待ちとして停止・報告する）
- Issueの要件が不明確な場合
- 複数の実装アプローチが考えられる場合
- スコープの拡大が必要と判断した場合
- Issue間の依存関係・衝突による直列化の判断が必要な場合
- 直列化した後続チケットの spawn 前（先行 PR の base が既定ブランチで、人間によるマージが必要な場合）
- **Phase 4-5: クリティカル設計の逸脱検知時**（feature-implementer の警告を受けて判断を仰ぐ）
- 実装完了後のレビュー依頼時

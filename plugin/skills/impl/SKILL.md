---
name: impl
description: "単一 Issue の1チケット実装フローを、実装フェーズの人間ゲートなしで実行する。複数Issueの並列化・並列度の決定は担わない。Triggers on: '/impl', 'このIssueを実装して', 'Issueを1件実装して'"
argument-hint: "<Issue番号> [--base <統合ブランチ>] [--worktree <worktreeの絶対パス>]"
model: opus
# effort: 手順は harness の ticket ワークフローが持ち、本スキルは起動・合流・結果の読み取りだけを担うが、返却の書き分けに判断が要るため既定の medium。
effort: medium
---

# 1チケットの実装フロー（`harness` の `ticket` ワークフローを呼ぶ）

**あなたは1つの Issue の実装を `harness` CLI に実行させ、その結果を呼び出し元へ返す主体です。**

1チケット（= 1 Issue）の実装フロー（ブランチ準備 → 設計＋TDD実装＋必須ゲート＋セルフレビュー → コミット → E2E → PR → CI → レビュー → マージ）の手順・分岐・差し戻しの上限は、**`harness` CLI の `ticket` ワークフローが持つ**。本スキルは手順を持たず、**起動・合流・結果の読み取りと返却だけ**を行う。**1チケット = 1ブランチ = 1PR**。

**`harness` が使えないときに、実装フローを自分で組み立てて代わりに進めない**（フローの正本は `ticket` ワークフローだけ。手順を2箇所に持つと必ずずれる）。

---

## 責務外（重要）

本スキルは **Issue を1件しか受け取らない**。複数 Issue の**並列度の決定・直列化・worktree の払い出し・worker の spawn・合流の集約**は**すべて `/para-impl` の責務**であり、本スキルは一切行わない。**Issue 番号を2件以上渡された場合は実行せず、`/para-impl` を使うよう案内してその場で停止する**（自分で並列化を始めない）。

---

## 呼び出し元（実行主体）

| 経路 | 呼び出し元 ＝ 本スキルの実行主体 | `--worktree` | 返る場所 |
|---|---|---|---|
| **単一 Issue 経路** | `/para-impl` のリードエージェント（メインセッション。Issue が1件のとき） | 渡されない | 最初のゲートか終端（下記「結果の読み取り」） |
| **並列経路（star 型）** | **`ticket-worker` サブエージェント**（リードから割り当てられた worktree 内） | **渡される** | `review` ゲート（PR 作成・CI 確認の後）か終端 |
| **人間が直接** | メインセッション（`/impl 123`） | 渡されない | 単一 Issue 経路と同じ |

**経路の分岐は `--worktree` の有無ただ1つで決まる**（経路名で分岐しない）。`--worktree` が在れば、その作業ツリーを `ticket` ワークフローへ渡し（runtime は呼び出し元の作業ツリーとブランチをそのまま使い、消さない）、無ければ runtime が `<リポジトリの1つ上>/<リポジトリ名>-worktrees/issue-<番号>` に作業ツリーを作る（メインのチェックアウトは触らない）。

---

## 入力パラメータ

$ARGUMENTS

- **数値**: Issue 番号として扱う。**ちょうど1件**。2件以上なら上記「責務外」に従い停止する
- **`--base <統合ブランチ>`**: 実装 base（ブランチ分岐元・PR の宛先）。省略時は Issue 本文の `Base:` 行、無ければリポジトリの既定ブランチを runtime が使う
- **`--worktree <絶対パス>`**: 作業 worktree の絶対パス

---

## 手順

### 1. `harness` の確認

```bash
command -v harness
```

見つからなければ**その場で停止**し、`harness` の導入（GitHub Releases の `runtime/vX.Y.Z` のバイナリ。手順は claude-harness リポジトリの `runtime/README.md`「導入」）と `harness setup` を案内する。

### 2. プラグイン版の取得

スキル起動時にコンテキストへ与えられる「Base directory for this skill」は `<プラグインルート>/skills/impl` である。Read ツールで `<プラグインルート>/.claude-plugin/plugin.json` を読み、`version` の値を得る（以下 `{プラグイン版}`）。CLI はこの版が自分の対応範囲かを照合する。**読めなければ推測で埋めず、その場で停止して報告する**。

### 3. 起動

`--worktree` があればその絶対パス、無ければ現在のリポジトリのルートを `{起点}` として、Bash ツールで **`run_in_background: true`** を指定して起動する（`ticket` は数十分〜数時間かかり、前面の Bash の上限 10 分に収まらない）:

```bash
cd "{起点}" && HARNESS_PLUGIN_VERSION="{プラグイン版}" HARNESS_CLAUDE_PERMISSION_MODE="${HARNESS_CLAUDE_PERMISSION_MODE:-auto}" harness run --input issue={番号} ticket
```

- `--base` があれば `--input base={base}`、`--worktree` があれば `--input worktree={worktreeの絶対パス}` を `ticket` の前に足す
- `HARNESS_CLAUDE_PERMISSION_MODE` は runtime が起動する `claude -p` に `--permission-mode` で渡るモード。利用者が環境変数で設定していればその値、無ければ `auto` になる（コマンドの `${...:-auto}` のまま渡す。値を自分で書き換えない）

起動したタスクの出力の標準エラーに `harness: run <run-id> started (<run ディレクトリ>)` の行が出る。この `<run-id>` を以降で使う。この行が出ずにタスクが終わった場合は、終了コードで分ける:

| 終了コード | 意味 | 本スキルの動作 |
|---|---|---|
| 5 | プラグインと CLI の版が合わない | 停止。標準エラーの文言（どちらを更新すべきか）をそのまま報告する |
| 2 | 使い方の誤り・ワークフロー定義の不正 | 停止。標準エラーをそのまま報告する |
| その他 | run を始められなかった | 停止。標準エラーをそのまま報告する |

### 4. 合流（run がゲートか終端に達するまでターンを終えない）

**`harness run` が終わる前に最終応答・返却をしない**（サブエージェントの中では、ターンを終えた時点で呼び出し元へ返却され、後から届く完了通知は受け取れない）。次のコマンドを Bash ツールの前面で（`timeout: 600000` を指定して）、出力が `running` 以外になるまで繰り返す:

```bash
end=$((SECONDS+540)); until [ "$(harness status {run-id} --json | jq -r .status)" != running ] || [ $SECONDS -ge $end ]; do sleep 10; done; harness status {run-id} --json | jq -r .status
```

- 先頭が `sleep` のコマンドは拒否される。上の形（上限付きの `until` ループ）のまま使う
- 起動したタスクの完了通知が先に届いたら、そこで繰り返しをやめてよい
- `harness status {run-id} --json` の `runner_alive` が `false` のまま `running` なら、run を進めるプロセスが落ちている。繰り返しをやめ、`harness status {run-id}` が示す状態（`interrupted` ゲート）を下の表に従って扱う
- 合流できないまま返却せざるを得ない場合は、**run を取り消さず**、`<run-id>` と回収手段（`harness status {run-id} --json`）と「合流できていない」事実を返却に明記する

### 5. 結果の読み取り

`harness status {run-id} --json` を読む（正本はこの JSON。標準出力の途中経過から組み立て直さない）。使う場所:

| 値 | 場所 |
|---|---|
| run の状態・失敗の理由 | `.status`（`waiting` / `failed` / `succeeded` / `cancelled`）・`.reason`・`.units[0].reason` |
| 待っているゲート | `.waiting[0]`（`gate`・`requested_action`・`inputs`・`requires_tty`・`resume_command`） |
| PR | `.units[0].workspace.pr_url`・`.units[0].workspace.pr_number` |
| 作業ツリーとブランチ | `.units[0].workspace.worktree_path`・`.units[0].workspace.branch` |
| 実装の結果 | `.units[0].outputs.implement`（`outcome`・`summary`・`residual_findings`・`unverified`・`cross_repo_attestation`・`deviation_report`） |
| CI | `.units[0].outputs.ci`（`ci`・`failure_log_excerpt`）。差し戻しに使った回数は `.units[0].limits_used.rework` |
| E2E | `.units[0].outputs.e2e`（`scenarios`・`traceability`。E2E 対象のときだけ在る） |
| 費用 | `.units[0].budget`（`spent_usd`・`limit_usd`） |

状態ごとの扱い:

| run の状態 | `--worktree` あり（並列経路） | `--worktree` なし |
|---|---|---|
| `waiting` で `review` ゲート | **通常完了**として返す | 完了として報告し、下記「次のアクションの案内」を出す |
| `waiting` で `design-deviation` ゲート | **判断待ち**として返す（`deviation_report` を添える） | `deviation_report` をユーザーに提示し、判断は端末から `harness approve` で行うよう案内する |
| `waiting` で `ci-pending` ゲート | **`failure`** として返す（CI を待ちきれなかった。または CI が失敗ログの無い失敗で終わった） | 状態を報告し、CI を確かめてから `harness resume {run-id} --input recheck`（やめるなら `abort`）を案内する |
| `waiting` でその他のゲート（`interrupted` 等） | **`failure`** として返す（ゲート名と `requested_action` を添える） | 状態と `resume_command` を報告する |
| `failed` | **`failure`** として返す（`reason` を添える） | 同左を報告する |
| `cancelled` | **`failure`** として返す | 同左を報告する |
| `succeeded` | 完了として返す | 完了として報告する |

`failed` の主な `reason`: `quality_gate`（必須ゲートを通過できない）・`self_review_incomplete`（セルフレビューのレビュアーと合流できなかった）・`ci_red`（CI の red を差し戻しの上限まで直しても green にならない）・`e2e`（E2E の失敗を差し戻しの上限まで直しても通らない）・`base_missing`（統合ブランチが remote に無い。`.units[0].outputs.resolve` の案内に従い作成を促す）・`worktree_conflict`（渡された・既存の作業ツリーが使えない）。

**`decider: human` のゲート（`requires_tty: true`）を自分で解決しない**（`harness approve` は端末からしか通らない。Claude に解決させない設計）。**`review` ゲートに `ready` を自動で渡さない**（統合ブランチ宛では runtime がマージまで進む。マージ順は呼び出し元の判断）。

---

## 完了報告 / 呼び出し元への返却

**`harness run` との合流（上記 4）を済ませてから返す。**

1. run ID と run の状態（待っているゲート、または終端の理由）
2. 実装サマリー（`outputs.implement.summary`）
3. PR URL と CI ステータス（`outputs.ci.ci`）
4. `/quality-check` の結果（`outputs.implement.outcome`。`skip` は `pass` として扱わず、未検証である事実を明記する）と `/self-review` の `residualFindings`（`outputs.implement.residual_findings`）の**全件**。空でなければ件数へ丸めず全件を載せる（`converged: true` でも省略しない）。未検証の事項（`unverified`）も全件
5. クリティカル設計の逸脱を検知した場合はその内容（`deviation_report`。並列経路では「判断待ち」）
6. E2E結果（対象機能の場合）。`outputs.e2e` のシナリオ一覧・完了条件トレーサビリティ表
7. クロスリポジトリ依存の確証結果（`cross_repo_attestation`。該当する場合）
8. **`--worktree` がある場合**: 「CI の red の差し戻しは runtime の中で最大3回まで済ませた（使った回数 `limits_used.rework`）。`ci_red` で失敗した場合は、同じ修正を差し戻しても直らない」と明記する。run は `review` ゲートで待たせたまま残す（取り消さない）
9. **次のアクションの案内**（`--worktree` が無い場合）:
   - レビュー対応: `harness resume {run-id} --input respond`
   - マージへ進める: `harness resume {run-id} --input ready`（統合ブランチ宛は runtime がマージする。既定ブランチ宛は人がマージした後に `harness resume {run-id}`）
   - 人の判断が要るゲート: 端末から `harness approve {run-id} --input <値> [--note <指示>]`
   - E2E 対象だった場合: `/explain-e2e`（テストシナリオ解説と独立検証。本スキルは実施しない）

---

## 禁止事項

- `harness` を使わずに実装フローを自分で進めること
- **複数 Issue を受け取って自分で並列化すること**（並列化は `/para-impl` の責務）
- `decider: human` のゲートの解決、`review` ゲートへの `ready` の自動投入
- 合流前の返却、合流できない場合の run の取り消し

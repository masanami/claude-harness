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

`--worktree` があればその絶対パス、無ければ現在のリポジトリのルートを `{起点}` として、次のコマンドを Bash ツールの前面で実行する。`--detach` により、run を進めるプロセスは呼び出し元から切り離されて run がゲートか終端に達するまで動き続け、このコマンドは run ID を標準出力に 1 行出してすぐ終わる:

```bash
cd "{起点}" && HARNESS_PLUGIN_VERSION="{プラグイン版}" HARNESS_CLAUDE_PERMISSION_MODE="${HARNESS_CLAUDE_PERMISSION_MODE:-auto}" harness run --detach --input issue={番号} ticket
```

- **`--detach` を外して起動しない**（外すと run はこの Bash のプロセスの中で進み、Bash が上限で止められると run も取り消される）

- `--base` があれば `--input base={base}`、`--worktree` があれば `--input worktree={worktreeの絶対パス}` を `ticket` の前に足す
- `HARNESS_CLAUDE_PERMISSION_MODE` は runtime が起動する `claude -p` に `--permission-mode` で渡るモード。利用者が環境変数で設定していればその値、無ければ `auto` になる（コマンドの `${...:-auto}` のまま渡す。値を自分で書き換えない）

終了コード 0 なら、標準出力の 1 行が `<run-id>` である。これを以降で使う。0 以外なら run を進めていない（run を始めた後に切り離せなかった場合は、標準エラーに `harness: run <run-id> started` の行と理由が出る）。終了コードで分ける:

| 終了コード | 意味 | 本スキルの動作 |
|---|---|---|
| 5 | プラグインと CLI の版が合わない | 停止。標準エラーの文言（どちらを更新すべきか）をそのまま報告する |
| 2 | 使い方の誤り・ワークフロー定義の不正 | 停止。標準エラーをそのまま報告する |
| その他 | run を始められなかった | 停止。標準エラーをそのまま報告する |

### 4. 合流（run がゲートか終端に達するまでターンを終えない）

**run がゲートか終端に達する前に最終応答・返却をしない**（サブエージェントの中では、ターンを終えた時点で呼び出し元へ返却される）。次のコマンドを Bash ツールの前面で（`timeout: 600000` を指定して）、出力が `running` 以外になるまで繰り返す:

```bash
end=$((SECONDS+540)); until [ "$(harness status {run-id} --json | jq -r .status)" != running ] || [ $SECONDS -ge $end ]; do sleep 10; done; harness status {run-id} --json | jq -r .status
```

- 先頭が `sleep` のコマンドは拒否される。上の形（上限付きの `until` ループ）のまま使う
- `.status` が `cancelled` で終わった run を同じ作業ツリーで起動し直す場合は、**起動し直す前に、取り消された run の ID と費用（`.units[0].budget.spent_usd`）を返却に残す**
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
| 品質ゲート（機械） | `.units[0].outputs.quality`（`result`・`commit_sha`・`base`・`declaration`・`gates`・`failure_excerpt`・`message`）。PR を作る前に runtime が回した結果。上書きで省いたリポジトリでは無く、`.workflow.skipped_steps` に `quality` が出る。上書きが 2 行のうち 1 行だけ（例: `e2e-route.no` だけを `publish` へ付け替え）だと、付け替えた側の経路の run では `outputs.quality` が無いのに `skipped_steps` にも出ず、`.workflow.changes` にだけ付け替えが出る。`outputs.quality` が無いときは「品質ゲートを機械で回していない」と報告する |
| CI | `.units[0].outputs.ci`（`ci`・`failure_log_excerpt`）。差し戻しに使った回数は `.units[0].limits_used.rework` |
| E2E | `.units[0].outputs.e2e`（`scenarios`・`traceability`。E2E 対象のときだけ在る） |
| 費用 | `.units[0].budget`（`spent_usd`・`limit_usd`） |

状態ごとの扱い:

| run の状態 | `--worktree` あり（並列経路） | `--worktree` なし |
|---|---|---|
| `waiting` で `review` ゲート | **通常完了**として返す | 完了として報告し、下記「次のアクションの案内」を出す |
| `waiting` で `design-deviation` ゲート | **判断待ち**として返す（`deviation_report` を添える） | `deviation_report` をユーザーに提示し、判断は端末から `harness approve` で行うよう案内する |
| `waiting` で `ci-pending` ゲート | **`failure`** として返す（CI を待ちきれなかった。または CI が失敗ログの無い失敗で終わった） | 状態を報告し、CI を確かめてから `harness resume --detach {run-id} --input recheck`（やめるなら `abort`）を案内する |
| `waiting` でその他のゲート（`interrupted` 等） | **`failure`** として返す（ゲート名と `requested_action` を添える） | 状態と `resume_command` を報告する（`resume` の形は `--detach` 付き。実行した後は下記「再開と合流」に従って合流する。`approve` の形は人が端末から打つ） |
| `failed` | **`failure`** として返す（`reason` を添える） | 同左を報告する |
| `cancelled` | **`failure`** として返す | 同左を報告する |
| `succeeded` | 完了として返す | 完了として報告する |

`failed` の主な `reason`: `quality_gate`（実装の中の必須ゲートを通過できない）・`quality_gate_red`（PR を作る前に runtime が回した品質ゲートが、差し戻しの上限まで直しても通らない）・`quality_gate_undeclared`（品質ゲートのコマンドの宣言 `.claude-harness/quality-gate.json` が PR の宛先に無い・形が違う・ゲートが 1 つも走らない・コマンドが拒否された。`.units[0].outputs.quality.message` の案内〔宣言を置くか、上書きで省く〕をそのまま伝える）・`commit`（コミットできなかった。コミット対象外のファイルが `.gitignore` に入らずに残っていた場合は、`.units[0].outputs.commit.summary` にファイルの一覧と「コミットに含めてよいか、消してよいか」の問いが載るので、そのまま人へ伝える。答えに従ってファイルを消すか `.gitignore` に入れてから、新しい run で再実行する）・`self_review_incomplete`（セルフレビューのレビュアーと合流できなかった）・`ci_red`（CI の red を差し戻しの上限まで直しても green にならない）・`e2e`（E2E の失敗を差し戻しの上限まで直しても通らない）・`base_missing`（統合ブランチが remote に無い。`.units[0].outputs.resolve` の案内に従い作成を促す）・`worktree_conflict`（渡された・既存の作業ツリーが使えない）。

**`decider: human` のゲート（`requires_tty: true`）を自分で解決しない**（`harness approve` は端末からしか通らない。Claude に解決させない設計）。**`review` ゲートに `ready` を自動で渡さない**（統合ブランチ宛では runtime がマージまで進む。マージ順は呼び出し元の判断）。

---

## 完了報告 / 呼び出し元への返却

**run との合流（上記 4）を済ませてから返す。**

1. run ID と run の状態（待っているゲート、または終端の理由）
2. 実装サマリー（`outputs.implement.summary`）
3. PR URL と CI ステータス（`outputs.ci.ci`）
4. `/quality-check` の結果（`outputs.implement.outcome`。`skip` は `pass` として扱わず、未検証である事実を明記する）と `/self-review` の `residualFindings`（`outputs.implement.residual_findings`）の**全件**。空でなければ件数へ丸めず全件を載せる（`converged: true` でも省略しない）。未検証の事項（`unverified`）も全件
5. クリティカル設計の逸脱を検知した場合はその内容（`deviation_report`。並列経路では「判断待ち」）
6. E2E結果（対象機能の場合）。`outputs.e2e` のシナリオ一覧・完了条件トレーサビリティ表
7. クロスリポジトリ依存の確証結果（`cross_repo_attestation`。該当する場合）
8. **失敗・差し戻しの原因区分**（`failure` として返す・`failed` を報告する場合と、差し戻し〔`limits_used.rework` が 1 以上〕があった場合）: 原因を次の 3 つのどれか 1 つに分け、区分・根拠（どの値・ログからそう判断したか）・対処の向きを書く

   | 区分 | 当てはまるとき | 対処の向き |
   |---|---|---|
   | 文脈不足 | 指示・前提・守るべきテストが足りず、想定と違うものを作った・判断できなかった | 指示（Issue の完了条件・前提）か守るテストを足して再実行する |
   | 権限不足 | 必要なコマンド・ファイル・外部サービスへの操作が拒否された | その権限を与えられるかを検討する（与えないなら手順を変える） |
   | 性能不足 | 文脈と権限は足りているのに、差し戻しの上限まで直しても通らない | 待つ（モデルやツールの更新を待つ。同じ指示での再試行はしない） |

   - 決めきれないときは `文脈不足` を選び、根拠に決めきれなかったことを書く（打てる手がある区分を先に試す）
   - 実装に入る前の失敗（`base_missing`・`worktree_conflict`・版の不一致など run の前提の欠落）は区分の対象外とし、`reason` をそのまま報告する
9. **`--worktree` がある場合**: 「CI の red の差し戻しは runtime の中で最大3回まで済ませた（使った回数 `limits_used.rework`）。`ci_red` で失敗した場合は、同じ修正を差し戻しても直らない」と明記する。run は `review` ゲートで待たせたまま残す（取り消さない）
10. **run の外で終わった作業の明記**（run が取り消された・合流できなかった・runtime の外で手で仕上げた場合。起動し直した run が後で通っても、取り消された run があれば書く）: その事実と run ID（複数あれば全件）を書き、**「セルフレビュー・独立レビュー・E2E を経ていない」ことを未検証の事項として必ず書く**。手で仕上げた変更や PR は、runtime のゲートを通ったものとして報告しない（手で仕上げること自体は禁止事項の「`harness` を使わずに実装フローを自分で進めること」に当たる。呼び出し元の指示で仕上げた場合も、この明記は省かない）
11. **次のアクションの案内**（`--worktree` が無い場合）:
   - レビュー対応: `harness resume --detach {run-id} --input respond`
   - マージへ進める: `harness resume --detach {run-id} --input ready`（統合ブランチ宛は runtime がマージする。既定ブランチ宛は人がマージした後に `harness resume --detach {run-id}`）
   - 再開の後の合流（下記「再開と合流」）
   - 人の判断が要るゲート: 端末から `harness approve {run-id} --input <値> [--note <指示>]`
   - E2E 対象だった場合: `/explain-e2e`（テストシナリオ解説と独立検証。本スキルは実施しない）

---

## 再開と合流

ゲートで待つ run を再開する `harness resume`（`respond`・`ready`・`recheck`・`interrupted` の `rerun` など）は、**`--detach` を付けて Bash ツールの前面で実行する**。`--detach` により、このコマンドはゲートを解いた後の進行を呼び出し元から切り離したプロセスに渡し、run の状態の JSON を標準出力に出してすぐ終わる（始めの起動の `--detach` と同じ。#359）。`--detach` を外すと、run は Bash のプロセスの中で次のゲートか終端まで進み、Bash が上限で止められると run も取り消される。

```bash
cd "{起点}" && HARNESS_PLUGIN_VERSION="{プラグイン版}" HARNESS_CLAUDE_PERMISSION_MODE="${HARNESS_CLAUDE_PERMISSION_MODE:-auto}" harness resume --detach {run-id} --input {値}
```

- 終了コード 0 なら、ゲートは解かれ、run は切り離したプロセスが進めている。直後の状態は `running` とは限らない（速ければ次のゲートで `waiting`）。
- 0 以外なら、ゲートを解いていない（受け付けない入力・終わった run・版の不一致など）か、解いた後の run を渡せなかった。標準エラーをそのまま報告する。渡せなかった run は、次の `harness status` で `interrupted` ゲートで待つ。
- 再開の後は、上記「4. 合流」と同じコマンド（上限付きの `until` ループで `harness status {run-id} --json` の `.status` が `running` 以外になるまで）で合流し、「5. 結果の読み取り」に従って読む。合流の前に返却しない。
- `harness approve` は人が端末から実行する（本スキルは実行しない）。

---

## 禁止事項

- `harness` を使わずに実装フローを自分で進めること
- **複数 Issue を受け取って自分で並列化すること**（並列化は `/para-impl` の責務）
- `decider: human` のゲートの解決、`review` ゲートへの `ready` の自動投入
- 合流前の返却、合流できない場合の run の取り消し

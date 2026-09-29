# harness runtime の shadow run（C3 の段階 A）

> 設計の正本は [`harness-runtime-design.md`](harness-runtime-design.md)（Issue #201）。本文書は §8 の段階 (A)「shadow — スキルは触らず、CLI を人の端末から実チケットに使い比較」の**手順**と、§9 の指標（M1〜M6）の**導入後の取り方**を置く（Issue #269・PR-4）。
> 段階 (A) の終了条件（N4 の数字: shadow の件数 N と「劣化なし」の閾値）は**オーナーが決める**。本文書は数字を決めない。導入前の値の測り直しと数字の案は PR-4 の説明にある。

## 1. 何をするか

- 既存のスキル（`/impl`・`/para-impl`・`ticket-worker`）は**変えない**。runtime（`harness` CLI）の `ticket` ワークフロー（[`runtime/workflows/ticket.yaml`](../runtime/workflows/ticket.yaml)）を、**人の端末から**実チケットに使う。
- 同じ種類のチケットを現行の経路（`/impl`・flywheel の委譲）で扱った記録と、§9 の指標で比べる。
- 比べる期間は導入前と同じ長さ（38 日）。件数 N は N4 で決まる。

## 2. 準備

1. **Go と claude-harness の作業ツリー**: `harness` はまだ配布していない（PR-6 の範囲）。作業ツリーから `go build` する。

   ```bash
   cd <claude-harness の作業ツリー>/runtime
   go build -o "$HOME/.local/bin/harness" ./cmd/harness     # 置き場は任意（PATH の通った場所）
   ```

   同梱の定義（YAML・スクリプト）はまだバイナリに埋め込まれていない（S1 は PR-6）。`--workflow-dir` と `--scripts-dir` で作業ツリーを指す（下の手順の `$HW`・`$HS`）。**shadow の期間中はこの作業ツリーを動かさない**（run は開始時の定義のハッシュを記録しており、定義が変わると `resume` が止まる。§7.3）。

   ```bash
   export HW=<claude-harness の作業ツリー>/runtime/workflows
   export HS=<claude-harness の作業ツリー>/plugin/scripts
   ```

2. **対象リポジトリのクローン**: run は起動したディレクトリのリポジトリで動く。`worktree-setup` が `<クローンの 1 つ上>/<リポジトリ名>-worktrees/issue-<番号>` に作業ツリーを作り、**メインのチェックアウトは触らない**（§8.1 V1）。
3. **Claude Code・gh・jq**: `claude`（プラグイン claude-harness を導入済み。`implement`・`fix` が `--agent claude-harness:feature-implementer` で起動する）、認証済みの `gh`、`jq`。
4. **状態の置き場**: 既定は `~/.local/state/claude-harness/`（`$XDG_STATE_HOME` があればその配下）。shadow の run をまとめて残すなら `HARNESS_STATE_DIR` を shadow 専用のディレクトリに向ける（指標の集計が楽になる）。

   ```bash
   export HARNESS_STATE_DIR="$HOME/.local/state/claude-harness-shadow"
   ```

## 3. 1 件を回す

```bash
cd <対象リポジトリのクローン>
harness run --workflow-dir "$HW" --scripts-dir "$HS" --input issue=<番号> ticket
#   --input base=<統合ブランチ>      省略時は Issue 本文の Base: 行、無ければ既定ブランチ（I2）
#   --input worktree=<絶対パス>      作業ツリーを自分で用意した場合だけ（release はそれを消さない。§5.4）
```

`run`・`resume`・`approve` はゲートか終端に達すると終わる。終了コード: `0` 成功・`1` 失敗・`3` ゲートで待機・`4` 停止。待機（3）のとき stdout の JSON の `waiting[]` に、ゲート・要求操作・受け付ける値・再開のコマンドが入る。

| 止まる場所（ゲート） | 何を待っているか | 解決のしかた |
| --- | --- | --- |
| `ci-pending` | CI が時間内（`ci-wait` の 900 秒×2 回）に終わらなかった。または CI が失敗ログの無い失敗で終わった（`ci: red_no_log`。CI が実行されなかった等。#278） | CI が終わってから（`red_no_log` なら原因を解消して CI を再実行してから）`harness resume <run> --input recheck`（やめるなら `abort`） |
| `review` | PR のレビュー（R1） | 対応が要れば `harness resume <run> --input respond`、マージしてよければ `--input ready` |
| `human-merge` | 既定ブランチ宛 PR の人によるマージ（R5。runtime はマージしない） | 人が GitHub でマージしてから `harness resume <run>`（observe 型: runtime が `gh pr view` で実状態を確かめる。open のままならまた待つ） |
| `review-human` | レビュー対応で人の判断が要る（R2・R3。N2） | **端末から** `harness approve <run> --input respond --note <指示>`（やめるなら `abort`） |
| `design-deviation` | クリティカル設計の逸脱（I8） | **端末から** `harness approve <run> --input follow-decision --note <指示>`（`abort` も可） |
| `interrupted` | runner が落ちて止まったステップ（§4.5） | 作業ツリーを確かめてから `harness resume <run> --input rerun`（`abort` も可） |

- `design-deviation`・`review-human` は `decider: human` の input 型ゲートなので、**端末（TTY）からの `approve` でしか解決できない**（Q9）。Claude に解決させない。
- 途中の様子は `harness status <run> --json`（run ディレクトリ・ラウンド・残予算・作業ツリー・PR 番号）と `harness runs --json`。ログ（プロンプト・claude の出力・git/gh の実行記録・PR 本文）は run ディレクトリの `logs/` にある。
- 止めるときは `harness cancel <run>`（作業ツリーは消さない）。

**shadow run の件数に数えるもの**: 1 Issue につき 1 run。`base_missing`・`worktree_conflict` のように実装へ入る前に止まった run は、原因を直して取り直した run を数え、止まった run は §5 の記録に残す（件数には数えない）。

## 4. 指標の導入後の取り方（§9）

導入後の値は run の状態（`$HARNESS_STATE_DIR/runs/<run>/state.json`・`events.jsonl`）から取る。状態は `events.jsonl` の畳み込みで、`state.json` はその写し。以下の `jq` は `state.json` を読む。

```bash
S="${HARNESS_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/claude-harness}/runs"
```

### M1: 再開 1 回あたりの親側の消費

runtime の外（再開を指示する側）の費用なので、runtime の状態には無い。導入前と同じ区間を、再開を指示する主体の記録から取る。

- **人の端末から回す場合**: 親の LLM は居ないので、親側の消費は 0（人の操作は `status` を読み `resume` を 1 行打つだけ）。代理の値として「再開の指示の長さ」＝ `resume`／`approve` に渡した `--input` と `--note` の文字数を記録する（`gate_resolved` イベントに残る）。

  ```bash
  jq -r 'select(.type=="gate_resolved") | [.ts, .gate_resolved.gate, .gate_resolved.outcome, ((.gate_resolved.note // "") | length)] | @tsv' "$S"/*/events.jsonl
  ```

- **親のエージェント（flywheel の Tom 等）が Bash から `harness` を回す場合**: 親のセッションの記録（Claude Code の transcript）で、`harness run`/`resume` の終了（終了コード 3）を受け取ってから次の `harness resume`／`approve` を呼ぶまでの、親のターンの usage（入力・出力トークン）の和。導入前（`delegate_end` から同じ `session_id` の次の `delegate_start` まで）と同じ区切りで数える。

### M2: 取り違えの件数

- 導入前と同じ方法（再開の記録の結果文から語で候補を抽出し、1 件ずつ目視）で数える。
- 加えて runtime の検証が拒否した件数: `resume` が「定義が変わった」「別のゲートが開き直した」「予約値を on に書いていない」等で止めたもの。`harness` の stderr と `events.jsonl` に拒否の記録が残らない（状態を変えずに拒否する）ので、shadow の記録（§5）に 1 件ずつ書く。

### M3: 差し戻し対応の費用 ÷ 実装本体の費用

ステップ実行ごとの費用（`cost_usd`。`--resume` の実行はセッションの累計の差で数えてある。§4.3）が全件取れる。実装本体 ＝ `implement`、差し戻し対応 ＝ `fix`・`respond` と、それらの後の `commit`・`e2e`。

```bash
jq -r '
  .run_id as $r | .units[0] as $u
  | [$u.rounds[].steps[]] as $xs
  | ($xs | map(select(.step=="implement") | .cost_usd // 0) | add // 0) as $impl
  | ($xs | map(select(.step=="fix" or .step=="respond") | .cost_usd // 0) | add // 0) as $rework_direct
  | ([$xs | to_entries[] | select(.value.step=="commit" or .value.step=="e2e")
       | select(any($xs[:.key][]; .step=="fix" or .step=="respond")) | .value.cost_usd // 0] | add // 0) as $rework_follow
  | [$r, $impl, ($rework_direct + $rework_follow), (if $impl > 0 then (($rework_direct + $rework_follow) / $impl) else null end), $u.budget.unknown_cost_count]
  | @tsv' "$S"/*/state.json
```

`unknown_cost_count` が 0 でない run は、費用が取れなかった実行を上限額で数えている（fail-closed。Q15）ので、比では上振れしている。

### M4: 再開理由が構造として記録されている割合

各ラウンドの開始の契機（`trigger`: `start`／どのゲートをどの入力で抜けたか）が入っている割合。runtime はすべてのラウンドに記録するので 100% になるはずで、欠けがあれば不具合として扱う。

```bash
jq -r '[.units[].rounds[]] | "\(map(select(.trigger.kind != null and .trigger.kind != "")) | length)/\(length)"' "$S"/*/state.json
```

### M5: 実装委譲フローの散文の量

導入前と同じ 5 ファイル（削除されたものは 0 B）。段階 (A) の間はスキルを変えないので導入前と同じ値のまま。段階 (B)（PR-7）の差分として示す。

```bash
wc -c plugin/skills/impl/SKILL.md plugin/skills/para-impl/SKILL.md \
  plugin/skills/para-impl/references/join-gate.md plugin/skills/para-impl/references/star-parallel.md \
  plugin/agents/ticket-worker.md
```

### M6: 偽収束の件数と headless の完走率

- **完走率**: 終端に達した run のうち `succeeded` の割合（`cancelled` は分母から外し、理由を §5 に書く）。

  ```bash
  jq -r '[.run_id, .status, .reason] | @tsv' "$S"/*/state.json
  ```

- **偽収束**: 成功扱いの run（`succeeded`）の中に、実際には終わっていないものがあるか。1 件ずつ次を確かめる: PR が実際にマージされている（`gh pr view <workspace.pr_number> --json state`）／`implement` が `skip` だった run の PR 本文に「未検証」の節がある／`residual_findings` の件数と PR 本文の「残指摘（全 N 件）」が一致する。

## 5. shadow の記録

run ごとに次を 1 行ずつ残す（置き場は shadow を回す人が決める。flywheel から回すなら journal）。

| 項目 | 例 |
| --- | --- |
| 日付・リポジトリ・Issue・run id | 2026-10-01 masanami/claude-harness #300 `20261001-...` |
| 終わり方（status・reason）と通ったゲート | succeeded / merged。`review` 1 回・`ci-pending` 0 回 |
| 費用（unit の `budget.spent_usd`・`unknown_cost_count`）と M3 | $11.20・0・0.35 |
| 再開の回数と、各再開で人（親）がしたこと（M1） | 2 回。`ready`・merge 後の `resume` |
| runtime が拒否した操作・取り違え（M2） | なし |
| 現行経路と比べて気付いたこと | E2E 差し戻しが 1 回で収束 |

## 6. Q11（差し戻しのセッションの引き継ぎ）の見直しの準備

`fix`・`commit`・`e2e` の既定は `session: continue:implement`（`--resume` で実装時の文脈を引き継ぐ。Q11）。shadow の M1・M3 で見直す（§4.4）。見直しに要る値は、どれも run の状態に残る:

- ラウンドごとの費用: `units[].rounds[].cost_usd`
- ステップ実行ごとの費用・引き継ぎ方: `units[].rounds[].steps[]` の `cost_usd`・`session_id`・`resume`（`true` なら `--resume` で引き継いだ）・`cost_reported_usd`（claude が報告したセッションの累計）

```bash
jq -r '.run_id as $r | .units[0].rounds[] | .no as $n | .steps[] | select(.session_id != null)
  | [$r, $n, .step, (if .resume then "continue" else "new" end), .session_id, .cost_usd] | @tsv' "$S"/*/state.json
```

比べ方: 同じ期間の一部の run を、`fix`・`commit`・`e2e` を `session: new` にした定義で回す。定義は作業ツリーの `runtime/workflows` を別のディレクトリへ写して書き換え、`--workflow-dir` でそちらを指す（run は開始時の定義のハッシュを記録するので、途中で定義を替えた run は `resume` できない。1 つの run の中では混ぜない）。`fix` 1 回あたりの費用（M3 の分子）と、差し戻し後に `commit` が失敗した・`fix` が同じ失敗を繰り返した件数を比べる。

## 7. 既知の制約（shadow で確かめること）

- `worktree-setup` が払い出し先の衝突を知らせる手段は stderr の文言だけで、runtime はその文言で `conflict` を見分けている（一致しなければ `step_error`。fail-closed）。
- `pull-request` 種類は、作業ブランチの open な PR が在れば push だけで終わり、本文を書き換えない（W4）。差し戻し後の残指摘の変化は PR 本文に反映されない。
- 予算（`budget_usd: 40` とステップごとの上限）は仮の値（§12）。shadow の実績で較正する。
- masanami/flywheel の Actions が Billing でジョブを起動しない間は、`ci` が `red` を返して `fix` へ差し戻し続ける（#278）。暫定で `red` の遷移を `review` へ替えた定義を使い、検証は親のローカルの `make check` で代える（§8.4）。#278 の修正後は、失敗ログが空の `red` は `ci-wait-pr.sh` が `red_no_log` に替え、`fix` へ送らず `ci-pending` で止まる（固定したコミットがこの修正を含むときは、この暫定の変更は要らない）。
- claude CLI 2.1.283 は `schemas/*.json` の draft 2020-12 の `"$schema"` 行を拒否し、llm ステップが起動しない（#279）。暫定で `"$schema"` 行を外した定義を使う（§8.4）。

## 8. 親エージェント（flywheel の Tom）から回す場合

§1〜§7 は人の端末から回す前提の手順。ここでは flywheel の親エージェント（Tom）が Bash から `harness` を回すときの差分を置く（#276）。書いていないことは §1〜§7 に従う。

### 8.1 固定

- shadow の期間中は claude-harness の `main` を別の作業ツリー（`git worktree add`）に固定し、そこから `go build` した `harness` を使う。`$HW`・`$HS` もこの作業ツリーを指す。
- 固定したコミットを記録する。初回は `660de1e`。
- 通常の開発に使うクローンとは分ける。PR-6 等の開発でクローンの `main` が動いても、固定した作業ツリーは動かさない（§2 の 1、§7.3）。

### 8.2 状態の置き場

`HARNESS_STATE_DIR` を親のワークスペースの Git 管理外に向ける（例: `.flywheel/shadow/state`）。

### 8.3 対象

- 親の課題台帳で計画承認（FR-13）済みの、masanami/flywheel の 1 チケット実装（従来 `/impl` で委譲していたもの）を承認順に回す。
- 1 Issue につき 1 run（§3）。

### 8.4 定義を変えるとき

- 原則は固定した作業ツリーの定義をそのまま使う。
- 変える必要があれば、定義ディレクトリを丸ごと別の場所へ写して書き換え、`--workflow-dir` でそちらを指す（§6 と同じやり方）。1 つの run の中では混ぜない。
- **変更点と理由は run の記録（§5）に必ず書く**。

初回（flywheel#85）で入れた変更は次の 3 点。

| 変更 | 理由 |
| --- | --- |
| `limits.budget_usd` を 40 → 100、`implement` の `budget_usd` を 15 → 60 | その課題の承認済み予算上限に合わせる。L サイズは原本の値で打ち切られる見込みのため |
| `ci` の `red` を `fix` への差し戻しから `review` へ | masanami/flywheel の Actions が Billing でジョブを起動しない間の暫定。検証は親のローカルの `make check` で代える（#278） |
| `schemas/*.json` から `"$schema"` 行を外す | claude CLI 2.1.283 が draft 2020-12 の `$schema` を拒否して llm ステップが起動しない（#279） |

### 8.5 予算の対応

- 親の台帳の承認済みタスク案の「予算上限」（実装枠）を、unit の `budget_usd` に使う。
- 親のサイクル予算の起動前評価には、実装枠＋レビュー対応枠の総枠で入れる。

### 8.6 起動と記録

- 親は `harness run`・`resume` を**ハーネスの追跡内のバックグラウンド実行**で起動する。終了（`0`／`1`／`3`／`4`）を受け取ってから次の操作をする。
- 親の実行イベントログには `delegate_start`／`delegate_end` で挟んで 1 件とする。実行スキルは `harness run ticket`、結果に run id を書く。

### 8.7 ゲートの対応（親の承認ゲートとの対応）

| ゲート | 親がすること |
| --- | --- |
| `review` | 親が自分の検証（ローカルの品質ゲート）をしてから、オーナーの完了確認（FR-32）へ出す。オーナーが直しを求めたら PR にその内容を残してから `harness resume <run> --input respond`。承認されたら `--input ready` |
| `human-merge` | オーナーの昇格承認（FR-22）を受けて親が既定ブランチへマージし、その後 `harness resume <run>`（runtime が実状態を確かめる） |
| `design-deviation`・`review-human` | **オーナーが端末から `approve` する**（TTY 必須。親は代行しない）。Claude Code の対話セッションなら `! harness approve ...` で打てる |
| `ci-pending` | CI の完了後に親が `harness resume <run> --input recheck` |
| `interrupted` | 親が作業ツリーを確かめてから `harness resume <run> --input rerun` |

### 8.8 記録の置き場と M1

- run ごとの §5 の行は、親のサイクルジャーナルに書く。
- M1（再開 1 回あたりの親側の消費）は、親セッションの transcript（`~/.claude/projects/<プロジェクト>/<セッション>.jsonl`）から取る。`harness` の終了を受け取ってから次の `resume`／`approve` を呼ぶまでの、親のターンの usage（入力・出力トークン）の和（§4 M1 の 2 つ目の箇条書きと同じ区切り）。

### 8.9 実装前に止まった run

§3 の規則どおり件数に数えず、§5 の記録に残す。初回は `analyze` で #279 により止まった run が 1 件ある。

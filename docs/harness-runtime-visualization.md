# ワークフローの形と run の現在地の表示（Issue #308）

> **状態: 設計（2026-10-25 に問い A1〜A3・B1〜B5 を決定済み）**。harness runtime（Issue #201・[harness-runtime-design.md](harness-runtime-design.md)）のワークフロー定義の形（ステップ・遷移・ゲート・終端）と、run を指定したときの現在地（いまのステップ・待っているゲート・ラウンド）を出すコマンドの設計を置く。実装は別の Issue で行い、本文書は `runtime/`・`plugin/` の挙動を変えない。決定の記録は §10 にある。
>
> - 正本は Issue #308。食い違ったら Issue が正。
> - 上書き（Issue #309・[harness-runtime-overrides.md](harness-runtime-overrides.md)）の決定は前提として変えない。

新しいサブコマンド `harness graph` を足し、ワークフローの形を JSON（`schema: harness.workflow-graph/v1`）で出す。この JSON を正本にし、CLI のテキストと Mermaid のテキストはそこから作る。`--run <run-id>` を付けると、その run が実際に使った定義（元の定義のハッシュと上書きの写しから組み立て直したもの）の形に、現在地（いまのステップ・待っているゲート・ラウンド・通ったステップ・使った上限）を重ねる。上書きで到達できなくなったステップは消さずに `skipped` の印を付けて残す。この JSON と Mermaid は harness が自分の利用者に向けて出すもので、接続契約にも flywheel の宣言にも載せない（オーナーの決定 A1・A2）。flywheel から見た claude-harness は接続ツールの 1 つ（プラグイン）であり、flywheel の画面にフローを出すときの形は flywheel#265 で flywheel が接続ツール共通の形として定め、harness はその形に合わせて出す側に回る。単体で開ける HTML は出さない（A3）。

位置づけ: runtime 化（#201）と上書き（#309）の次に来る追加で、flywheel 側の開発フローの可視化（masanami/flywheel#265・移行〔M5〕の後）より先に、claude-harness 単体で使える形にする。flywheel#265 が挙げた論点「flywheel が harness の YAML のスキーマを知らずに可視化できるか」は、flywheel が共通の形を定めることで解く（A2）。本文書の JSON はその形を先取りしない。

---

## 1. いまは形を知るには YAML を読むしかない

run の現在地は `harness status <run> --json` で読める（`runtime/internal/cli/cli.go` の `statusView`。unit ごとの `current_step`・`gate`・`rounds[]`・`limits_used`・`budget` と、待っているゲートの `waiting[]`。実コード確証・high）。だが、そのステップの次にどこへ進みうるか、どのゲートが人の判断を要するかは、`runtime/workflows/ticket.yaml` を読まないと分からない。形を出すコマンドは無い（`Main` のサブコマンドは `run`・`status`・`runs`・`resume`・`approve`・`cancel`・`validate`・`contract`・`predict-conflicts`・`setup`・`version`・`help`。実コード確証・high）。

形の材料は Go の中にすでに揃っている。`workflow.LoadAndValidate` が読み込んだ `Workflow` は、ステップ（`Steps` の先頭が開始ステップ）・種類ごとのフィールド・`on` の遷移（`Transition` の `Kind` は `step`・`goto`・`gate`・`fail`・`done`・`retry` の 6 種、`goto` は `Limit` と `Exhausted` を持てる）を持つ。ゲートは `GateType`（`input`・`observe`）と `Decider`（`human`・`parent`・`any`）を持ち、observe 型の outcome は Go に登録された観測（`pr-state` 等）から引ける。`validate.go` の `buildGraph` は到達可能性と「その経路で必ず実行済みか」の検査のために同じ遷移を辺の集合へ組み直している（以上 `runtime/internal/workflow/workflow.go`・`validate.go`。実コード確証・high）。

同梱の定義の規模は、`ticket.yaml` がステップ 19 個（`command` 2・`llm` 7・`gate` 5・`select` 2・`workspace` 2・`pull-request` 1。ゲートのうち `decider: human` は `review-human`・`human-merge`・`design-deviation` の 3 個）、`conflict-predict-issue.yaml` と `list-tests.yaml` は数ステップである（実コード確証・high）。

## 2. 決定の一覧

| 論点 | 決定 | 決定者 | 節 |
| --- | --- | --- | --- |
| JSON の形 | 節点（ステップと終端）と辺の一覧。辺の種類は Go の遷移の種類をそのまま使い、上限つきの `goto` と `retry` の尽きたときの行き先は別の辺にする。`schema: harness.workflow-graph/v1` | 親（B4） | §3 |
| 予約値の既定の失敗と組み込みの `interrupted` ゲート | 辺にせず、ステップの属性と定義全体の属性で表す | 親（B4） | §3.4 |
| run の現在地の重ね方 | `run` の項に `status --json` と同じ名前のフィールドで写す。`status --json` の形は変えない。runner の居ない実行中の run を `interrupted` に記録し直さない（読み取りのコマンドは状態を変えない） | 親（B1） | §4 |
| run を指定したときの定義 | run の記録（元の定義のパスとハッシュ・上書きの写し）から `resume` と同じ手順で組み立て直す。組み立て直せなければ表示しない | 親（B2） | §5.2 |
| 上書きで到達できなくなったステップ | 消さずに `skipped: true` を付けて残し、入ってくる辺を持たない | 親（B3） | §5.3 |
| コマンドの面 | 新しいサブコマンド `harness graph`。`--format text\|json\|mermaid`（`--json` は `--format json` の別名）。既定は `text` | 親（B1・B5） | §7 |
| 接続契約に載せるか | 載せない（契約 v1 の出力は変えない） | オーナー（A1） | §8.2 |
| flywheel の UI との分担 | flywheel の画面に出す形は flywheel#265 で flywheel が接続ツール共通の形として定め、harness はその形に合わせて出す。`harness graph` の JSON・Mermaid は harness の利用者向けの出力で、flywheel の取り決め（契約・宣言）ではない | オーナー（A2。当初の D1 を改めた） | §8.3 |
| HTML | 出さない（出力は text・json・mermaid） | オーナー（A3） | §6.3 |

文書の置き場は、#309 と同じく設計書の外の新しい文書にした（作成者の判断。仮定）。設計書の冒頭と上書きの文書からこの文書へリンクする。

## 3. 形の JSON は節点と辺の一覧にし、harness の文法を知らなくても描ける語彙にする

### 3.1 全体

```json
{
  "schema": "harness.workflow-graph/v1",
  "workflow": {
    "id": "ticket",
    "description": "1チケット（=1 Issue）の実装フロー。…",
    "source": "embedded",
    "path": "<元の定義の YAML の絶対パス>",
    "hash": "<元の定義の YAML の sha256>",
    "effective_hash": "<上書きを重ねた定義のハッシュ（#309 §7.1）>",
    "cli_version": "0.x.y",
    "overrides": [],
    "changes": []
  },
  "entry": "resolve",
  "limits": [{"name": "budget_usd", "value": 40}, {"name": "rework", "value": 3}],
  "builtin_gates": [{"id": "interrupted", "type": "input", "decider": "any", "inputs": ["rerun", "abort"]}],
  "nodes": [ … ],
  "edges": [ … ],
  "run": null
}
```

| フィールド | 中身 |
| --- | --- |
| `schema` | 形の版。閉じた値で、今は `harness.workflow-graph/v1` だけ |
| `workflow` | どの定義を描いたか（§5）。`source` は `embedded`・`workflow-dir`。`overrides`・`changes` は #309 の run の記録（§7.1 の `run_started.workflow`）と同じ形で、上書きが無ければ空の配列。#309 の実装前も、空の配列として常に出す |
| `entry` | 開始ステップの id（`steps` の先頭） |
| `limits` | 元の定義の `limits` に上書きを重ねた値（宣言順） |
| `builtin_gates` | 定義に書かれていないが、どのステップからも入りうる組み込みのゲート（§3.4） |
| `nodes` | ステップと終端（§3.2）。ステップは定義の順、終端はその後に初出の順 |
| `edges` | 遷移（§3.3）。ステップの順、その中は `on` の順 |
| `run` | `--run` を付けたときだけ値を持つ（§4）。付けなければ `null` |

形の JSON に入れるのは、遷移を読むのに要るものと、上書きで変えられる数値（`budget_usd`・`timeout`）だけにする。`prompt`・`with`・`output` のような実行の中身は入れない。描く側がステップの中身を解釈し始めると、harness の文法に依存することになるためである。

### 3.2 節点（`nodes`）

```json
{"id": "implement", "kind": "llm", "description": null, "agent": "claude-harness:feature-implementer",
 "budget_usd": 15, "timeout": "90m", "skipped": false}
{"id": "review", "kind": "gate",
 "gate": {"type": "input", "decider": "any", "requires_tty": false, "inputs": ["respond", "ready"],
          "observe": null, "requested_action": "PR のレビューを待つ。…"},
 "skipped": false}
{"id": "e2e-route", "kind": "select", "select": {"value": "$steps.analyze.e2e_target"}, "skipped": false}
{"id": "fail:quality_gate", "kind": "fail", "reason": "quality_gate"}
{"id": "done:merged", "kind": "done", "reason": "merged"}
```

- ステップの `kind` は YAML の種類（`command`・`llm`・`gate`・`select`・`workspace`・`pull-request`）。終端は `fail`・`done` で、id は `fail:<理由>`・`done:<理由>` にする。ステップ id の文法は `^[a-z][a-z0-9-]*$`（`parse.go` の `reStepID`。実コード確証・high）で `:` を含まないので、ステップと終端の id はぶつからない。同じ理由の終端は 1 つの節点にまとめる（`ticket.yaml` では `fail:quality_gate` に `implement.failure` と `fix.failure` の 2 本が入る）。
- ゲートは `gate` の項を持つ。`decider` と `requires_tty`（`workflow.RequiresTTY` と同じ判定）があれば、描く側は人が判断するゲートを強調でき、ゲートの名前を知る必要が無い。observe 型は `observe` に観測の名前を入れ、`inputs` は `null` にする。
- `select` は `select.value` に参照の文字列をそのまま入れる。分岐そのものは他の種類と同じく `edges` の outcome で表す（`e2e-route` の `yes` → `e2e`・`no` → `publish`）。値の意味の説明は描く側に任せず、参照の文字列を表示するだけにする。
- `budget_usd`・`timeout` は持つ種類だけに入れる（`llm` は両方、`command` は `timeout`）。上書きで値が変わったステップは、`workflow.changes` の `key`（`steps.<id>.budget_usd` 等）で引ける。

### 3.3 辺（`edges`）

```json
{"from": "resolve",   "outcome": "ok",        "kind": "step", "to": "analyze"}
{"from": "implement", "outcome": "deviation", "kind": "gate", "to": "design-deviation"}
{"from": "implement", "outcome": "failure",   "kind": "fail", "to": "fail:quality_gate"}
{"from": "e2e",       "outcome": "fail",      "kind": "goto", "to": "fix", "carries": ["failure"], "limit": "rework"}
{"from": "e2e",       "outcome": "fail",      "kind": "fail", "to": "fail:e2e", "exhausted": {"limit": "rework"}}
{"from": "ci",        "outcome": "timeout",   "kind": "retry", "to": "ci", "retry": 1}
{"from": "ci",        "outcome": "timeout",   "kind": "gate", "to": "ci-pending", "exhausted": {"retry": 1}}
{"from": "merge-route", "outcome": "integration", "kind": "step", "to": "merge",
 "overridable": ["merge", "human-merge"], "overridden": null}
```

- `kind` は Go の遷移の種類（`TransitionKind`）をそのまま使う: `step`・`goto`・`gate`・`fail`・`done`・`retry`。Issue の論点に挙がった「limit」は Go では種類ではなく `goto` の属性（`limit` と `exhausted`）なので、辺の種類に足さず、`goto` の辺の `limit` と、尽きたときの辺の `exhausted` で表す。
- 上限つきの `goto` と `retry` は、通常の行き先と尽きたときの行き先の 2 本の辺にする。尽きたときの辺は `exhausted` に何が尽きたか（`{"limit": "rework"}` か `{"retry": 1}`）を持つ。1 本の辺に 2 つの行き先を持たせると、描く側が辺を分けて描く処理を持つことになる。
- `carries` は、その遷移が次のステップへ渡す値の名前（遷移の `with` の名前。`$edge.<名前>` で読まれる）。値そのものや参照先は入れない。
- `overridable` は、元の定義の `overridable.routes`（#309 §5.2）がその遷移に宣言した候補。宣言の無い遷移は `null`。上書きで付け替えた辺は `overridden` に `{"from": "<元の行き先>", "layer": "repo|arg"}` を持ち、`to` は付け替えた後の行き先になる。#309 の実装前は両方 `null`。

### 3.4 既定の失敗と `interrupted` ゲートは辺にしない

YAML の `on` に書かれていない予約値（`step_error`・`step_timeout`・`invalid_output`・`budget_exhausted`）は run を `failed` にする（fail-closed。`workflow.go` の `ReservedOutcomes`。実コード確証・high）。runner が落ちたステップは組み込みの `interrupted` ゲートで待つ（`InterruptedGate`）。どちらも全ステップに当てはまるので、辺として出すと `ticket.yaml` では予約値だけで最大 76 本（19 ステップ × 4）増え、形が読めなくなる。

そこで、予約値の既定の失敗はステップの属性 `fail_closed`（`on` に書かれていない予約値の一覧）で表し、`on` に書かれた予約値（例: `budget_exhausted` を別の遷移へ送る定義）だけを辺にする。`interrupted` は定義全体の属性 `builtin_gates` に 1 つ置き、辺にしない。描く側は既定ではどちらも描かず、テキスト表示では凡例に 1 行で書く（§6.1）。run の現在地が `interrupted` のときは、`run` の項にそのことを出す（§4）。

```json
{"id": "analyze", "kind": "llm", …, "fail_closed": ["step_error", "step_timeout", "invalid_output", "budget_exhausted"]}
```

## 4. run の現在地は `status --json` と同じ名前で重ね、`status --json` の形は変えない

`--run <run-id>` を付けると、`run` の項に現在地を入れる。値はすべて `status` が使う畳み込んだ状態（`state.json`）と、`status` の `waiting()` から写す。

```json
"run": {
  "run_id": "…",
  "status": "waiting",
  "reason": null,
  "runner_alive": null,
  "units": [{
    "key": "…",
    "status": "waiting",
    "current_step": "review",
    "round": 3,
    "waiting": {"gate": "review", "type": "input", "decider": "any", "requires_tty": false,
                "inputs": ["respond", "ready"], "resume_command": "harness resume … --input <respond|ready> …"},
    "visited": [
      {"step": "implement", "executions": 1, "last_outcome": "pass"},
      {"step": "ci", "executions": 2, "last_outcome": "green"}
    ],
    "limits_used": {"rework": 1},
    "budget": {"limit_usd": 40, "spent_usd": 21.3, "remaining_usd": 18.7, "unknown_cost_count": 0}
  }]
}
```

- `current_step`・`limits_used`・`budget`・`waiting` の中身は `status --json` と同じ名前・同じ意味にする。`round` は `rounds[]` の数（`status` のテキスト表示の `round N` と同じ）。`status` を読む利用者が二つの語彙を覚えずに済む。
- `visited` は全ラウンドのステップ実行（`rounds[].steps[]`）をステップごとに数え、最後の outcome を添えたもの。予約値や `interrupted` で終わった実行は、その値（`step_error`・`interrupted` 等）が `last_outcome` に入る。どの辺を通ったかは `(from, outcome)` から引ける。上限が尽きて `exhausted` の辺を採ったかは、ステップ実行の記録ではなく遷移のイベント（`events.jsonl` の `transition` の `exhausted`）にしか残らない（`runstate/event.go`。実コード確証・high）。v1 では辺の通過を出さず、ステップの通過と回数だけにする。
- 実行中のまま runner が居ない run を、`graph` は `interrupted` に記録し直さない（`status` は `engine.Interrupt` で記録し直す）。`graph` は読み取りのコマンドで、状態を変えない。`run.runner_alive` に `false` を出し、`waiting` は `null` のままにする。その後に `status` か `resume` を呼べば、実行中だったステップが `interrupted` で終わり、組み込みの `interrupted` ゲートが開く（`engine/gate.go`。`current_step` は実行中だったステップのまま。実コード確証・high）。
- `status --json` に形を足す案は採らない。`status` は `contract status` が写す元で（設計書 §5.6.1）、形を足すと契約の出力の材料が増え、呼ばれるたびに定義を読み込むことになる。

## 5. どの定義を描くか: run を指定しなければ今の定義、指定すればその run が使った定義

### 5.1 run を指定しないとき

`run`・`validate` と同じ手順で定義を決める。埋め込み（`<data>/runtime/<CLI の版>/workflows/<id>.yaml`）か `--workflow-dir` の `<id>.yaml` を読み、#309 の実装後はリポジトリの `.claude-harness/overrides/<id>.yaml` と `--override <ファイル>` を重ねる。描くのは上書きを重ねた後の形で、`workflow.changes` と辺の `overridden` で元の値を読めるようにする。元の形だけを描く引数（`--no-overrides` のようなもの）は v1 では持たない。#309 が層 1 を無視させる引数を v1 で持たないと決めた（#309 §3）ので、それに揃える。

### 5.2 run を指定したとき（B2）

run の記録から、`resume` と同じ手順（`engine.Reopen`）で定義を組み立て直す。`workflow.path` から元の定義を読んで `workflow.hash` と照合し、#309 の実装後は run ディレクトリの上書きの写しを重ねて `effective_hash` と照合する。今の埋め込みや今の `--workflow-dir` は使わない。CLI を更新した後でも、開始時の版の展開ディレクトリ（読み取り専用で残る。設計書 §6.5）から読む。

照合が合わない・定義を読めない場合は、形を描かずに終了コード 1 で止まり、`harness status <run>` で現在地だけは読めることを標準エラーで案内する。`--workflow-dir` で始めた run の定義をその後に書き換えると、ここに当たる。別の定義の形に run の現在地を重ねると、無い辺を通ったように見えたり、通った辺が消えたりするためである。

| 案 | 中身 | 選ぶと利用者に見えること |
| --- | --- | --- |
| R1（採用） | `resume` と同じ手順で組み立て直す。合わなければ描かない | `resume` できる run はいつでも描ける。定義を書き換えた `--workflow-dir` の run は描けない（`status` は読める） |
| R2 | run の開始時に形の JSON を run ディレクトリへ書き出し、それを読む | 定義を消しても書き換えても、終わった run の形を後から描ける。run の記録が 1 つ増え、形の JSON の版を上げたときに古い run の写しを読む処理が要る |
| R3 | 照合せず、今の定義に重ねる | いつでも描けるが、描いた形が run の使った形と違っても気付けない |

R1 を採ったのは、`resume` が使う定義と表示する定義を同じ経路で決められ、#309 が上書きの写しを run ディレクトリに残す（#309 §7）ので、上書きのある run も同じ手順で描けるからである。R2 は、埋め込みの定義が版ごとのディレクトリに残る（設計書 §6.5）ので、救えるのは `--workflow-dir`（開発用）の run だけになる。

### 5.3 上書きで到達できなくなったステップ（B3）

#309 §6.2 の規則 5 は、上書きの付け替えでだけ到達できなくなったステップを `skipped_steps` として `validate` の出力と run の記録に出す。形の JSON では、そのステップを節点に残して `skipped: true` を付け、入ってくる辺は描かない（付け替えた後の定義には無いため）。出ていく辺は残し、テキスト表示と Mermaid では破線・灰色で描く。

| 案 | 中身 | 選ぶと利用者に見えること |
| --- | --- | --- |
| K1（採用） | 節点に残し `skipped: true`。出ていく辺も残す | 上書きで何を飛ばしたかが図の上で分かる。付け替えた辺の `overridden` と合わせて「どこからどこへ付け替えて、何が飛んだか」を読める |
| K2 | 節点ごと出さない | 図は上書き後の実際の経路だけになるが、何を飛ばしたかは `workflow.skipped_steps` の一覧を別に読むしかない |

v1 の `ticket.yaml` が宣言する付け替えのうち、`e2e-route.no` → `e2e` では `publish` が `e2e.pass` から到達できるので `skipped` は出ない。`merge-route.integration` → `human-merge` では、`merge` へ入る辺がこの 1 本だけなので `merge` が `skipped` になる（§9 の例）。

## 6. 人が読む表示: 既定は CLI のテキスト、Mermaid は引数で出す

### 6.1 CLI のテキスト（既定）

ステップを定義の順に 1 行ずつ並べ、行き先を outcome ごとに書く。端末の幅に収まらない行は折り返す。

```text
workflow ticket (embedded, cli 0.x.y)  entry: resolve
limits: budget_usd=40 rework=3
legend: [human] decided by a person  [tty] needs a terminal  ! fail  = done  ~ goto with a limit
        not shown: unhandled step_error/step_timeout/invalid_output/budget_exhausted fail the run;
        a step left running by a dead runner waits at the built-in gate interrupted

  resolve           command       ok -> analyze | base_missing ! base_missing | links_invalid ! links_invalid
  analyze           llm  $2 20m   ok -> workspace
  ...
  e2e               llm  $8 60m   pass -> publish | fail ~ fix (rework<=3, then ! e2e)
  ...
  review            gate input any            respond -> respond | ready -> merge-route
  review-human      gate input human [tty]    respond -> respond | abort ! aborted_by_human
  merge-route       select $steps.resolve.base_kind   integration -> merge | default -> human-merge
```

`--run` を付けると、行の先頭に印を付け、末尾に現在地の要約を足す（`>` いまいるステップ・`*` 通ったステップと回数）。

```text
* ci                command 20m   green -> review | ...                      (x2, last green)
> review            gate input any            respond -> respond | ready -> merge-route
run …: waiting at review (decider any) round 3, rework 1/3, spent 21.30/40.00 USD
  resume: harness resume … --unit … --input <respond|ready> [--note <text>]
```

テキストの文言は既存の `status` のテキスト表示と同じく英語にする（CLI の出力は英語。`cli.go` の表示文。実コード確証・high）。

### 6.2 Mermaid のテキスト（`--format mermaid`）

`flowchart TD` の 1 文書を出す。GitHub の Markdown は ` ```mermaid ` のコードブロックを図として表示するので、PR 本文や Issue に貼れば図になる。

- 節点の形は種類で分ける: `llm` は角丸、`command`・`workspace`・`pull-request` は四角、`gate` は六角形、`select` はひし形、終端は円。人のゲート（`decider: human`）にはクラス `human` を付けて色を変える。
- 辺には outcome を書く。上限つきの `goto` は `fail (rework<=3)`、尽きたときの辺は点線にする。
- `--run` を付けると、いまいるステップにクラス `current`、通ったステップにクラス `visited` を付ける。`skipped` のステップは破線のクラス `skipped` にする。
- この出力は人が端末・Markdown で見るためのもので、flywheel との取り決めではない（§8.3）。
- Mermaid の節点 id は `n0`・`n1` … に置き換え、ステップ id は表示の文字にだけ使う（ステップ id に含まれる `-` や将来の文字が Mermaid の文法とぶつからないようにする）。

### 6.3 単体で開ける HTML は出さない（A3）

HTML を出すと、ブラウザで開くだけで図が見える。ただし Mermaid のテキストを図にするには Mermaid の JS が要り、その入手の仕方が 3 通りある。

| 案 | 中身 | 選ぶと利用者に見えること |
| --- | --- | --- |
| H1（採用） | HTML は出さない。テキストと Mermaid のテキストだけ | 図を見るには Mermaid のテキストを GitHub の Markdown・Mermaid を描けるエディタに貼る。harness は何も取得せず、バイナリの大きさも変わらない |
| H2 | HTML に Mermaid の JS を CDN から読む `<script>` を書く | ファイルを開けば図になるが、開くたびに外部の CDN へ取りに行く（ネットワークが要り、外部への送信が起きる）。版の固定と改ざんの検知（SRI）の管理が要る |
| H3 | Mermaid の JS をバイナリに埋め込み、HTML に入れる | ネットワーク無しで開ける。`mermaid.min.js` は 12.2.0 で約 5.5 MB（flywheel のクローンの `node_modules` で計測。実コード確証・high）あり、HTML 1 つとバイナリがその分大きくなる。Mermaid の更新を harness のリリースで追う必要がある（ライセンスは MIT） |
| H4 | harness が Go で配置を計算して SVG を書く | 外部の JS が要らないが、グラフの配置の実装を harness が持つことになる |

オーナーは H1 を採った。Issue の目的（形を機械可読に出し、表示はそこから作る）はテキストと Mermaid で満たせ、HTML は外部の JS の扱い（取得・同梱・自前の配置）の判断を必ず伴うためである。出力の形式は text・json・mermaid の 3 つになる。

## 7. コマンドの面: 新しいサブコマンド `harness graph`

```text
harness graph [--format text|json|mermaid] [--json] [--workflow-dir DIR] [--scripts-dir DIR] [--override FILE] <workflow>
harness graph [--format text|json|mermaid] [--json] --run <run-id>
```

- `<workflow>` と `--run` はどちらか一方だけを受け付ける（`--run` のときは定義を run の記録から決めるので、`--workflow-dir`・`--override` は使い方の誤り）。`--override` は #309 の実装とともに足す。
- `--json` は `--format json` の別名にする（`status`・`runs`・`version` が `--json` を持つため）。
- 出力先は標準出力だけにする。ファイルへの書き出し（`--output`）は持たない（リダイレクトで足りる）。
- 終了コード: 0 = 出力した、1 = run が見つからない・run の定義を組み立て直せない（§5.2）、2 = 使い方の誤り・定義の不正（`run` が定義の不正で返す値と同じ。`cli.go` の `cmdRun` は `LoadAndValidate` の失敗で `ExitUsage`。実コード確証・high）。run が待機中・停止済みでも 3・4 は返さない。`graph` は run を進めないので、run の状態は出力の `run.status` で読む。版の不一致（5）も返さない（`HARNESS_PLUGIN_VERSION` の照合は run を進めるコマンドだけが行う。README の「版の照合」）。

| 案 | 面 | 選ぶと利用者に見えること |
| --- | --- | --- |
| C1（採用） | 新しいサブコマンド `harness graph` | 形を見る入口が 1 つになり、定義だけでも run つきでも同じコマンドで見られる |
| C2 | `harness validate --graph <workflow>` と `harness status --graph <run>` | 既存のコマンドに引数が増える。`validate` は複数の定義を検査して `ok`／`NG` を出すコマンドで、`status` は契約の出力の元なので、出力の意味が引数で変わる |
| C3 | `harness workflow show <workflow>` のような 2 語のコマンド | 将来の `workflow` 系のコマンド（一覧・差分）をまとめられるが、今ある 2 語のコマンドは `contract` だけで、それは入口を分ける理由（終了コードの意味が違う）があった |

C1 を採った（B1）。`validate` と `status` の出力と終了コードの意味を変えずに済み、`predict-conflicts` と同じく役割ごとにサブコマンドを分ける既存の形に揃う。名前は `graph` にした。

## 8. 接続契約に載せず、flywheel の画面の形は flywheel が接続ツール共通に定める（A1・A2）

### 8.1 いまの契約と、形を出すことの食い違い

flywheel の接続契約 v1 は `start`・`status`・`resume`・`cancel` の 4 つのコマンドで、出力は `contract_version`・`run_id`・`state`・`summary`・`requested_action`・`artifacts`・`cost_usd` だけである（flywheel `docs/features/m3-invoker-delegation.md` §クリティカル設計決定 3・設計書 §5.6.1。ドキュメント由来・high）。flywheel の設計書 §10 は「接続ツール内部の手順や判断値は core に持ち込まない」とし、設計書 §5.6 も「harness 固有の step id・判断値はこの面に出さない」としている。

形の JSON はステップ id と outcome（判断値）そのものを含む。flywheel が harness 固有のこの形を読むと、上の線引きを崩し、flywheel が接続ツールの 1 つ（harness）に依存することになる。そのため形の JSON は harness の利用者向けの出力にとどめ、flywheel の取り決めには載せない（§8.2・§8.3）。

### 8.2 契約 v1 には載せない（A1）

| 案 | 中身 | 選ぶと利用者に見えること |
| --- | --- | --- |
| G1（採用） | 契約 v1 には載せない。`harness graph` は harness の利用者向けのコマンドとして出す | claude-harness の利用者が `harness graph` で形を見る。契約 v1 の出力は変わらない。flywheel の画面に出すときの形と呼び方は flywheel#265 で flywheel が決める（§8.3） |
| G2 | 契約 v1 の `status` の出力に形（または形の要約）を足す | flywheel は今の `contract status` を読むだけで形が手に入る。契約の出力のフィールドが増え（契約の変更）、呼ばれるたびに定義を読み込む。step id が契約の出力に入る |
| G3 | 契約に新しいコマンド（`graph`）を足して契約の版を上げる | 形を読むことが契約の一部になり、接続ツール（harness 以外も）が形を出す義務を負う |

オーナーは G1 を採った。契約は flywheel が定め、harness が合わせる（設計書 §0.1）ので、harness 側から契約を先に変えない。

### 8.3 flywheel の画面に出す形は flywheel が接続ツール共通に定め、harness が合わせる（A2）

オーナーの方針（2026-10-25）は、flywheel から見た claude-harness を接続ツールの 1 つ（プラグイン）という関係に保ち、flywheel が harness 固有の JSON の形・コマンド・名前を前提にする設計にしない、である。これに従い、flywheel の画面にフローを出すときの形は flywheel#265 で flywheel が接続ツール共通の形として定め、harness はプラグインとしてその形に合わせて出す側に回る。

`harness graph --format json`（`harness.workflow-graph/v1`）は harness が自分の利用者向けに出す出力で、flywheel の取り決め（契約・宣言）ではない。`--format mermaid` も同じく、人が端末や Markdown（PR・Issue）で見るためのものである。どちらの書き方も flywheel に断らずに変えてよい。

flywheel の共通の形が決まったときに harness が合わせやすいよう、形の JSON の語彙は harness の YAML の内部語に寄せすぎない。節点（ステップと終端）・辺（行き先と outcome）・ゲートの決める主体（`decider`）・端末の要否（`requires_tty`）は、どの接続ツールのフローにもある一般的な概念で表す（§3）。flywheel の形をここで先取りして決めることはしない。合わせ方（`harness graph` の出力を写すか、別の出力を足すか）は flywheel の形が決まってから決める。

当初の決定 D1（flywheel が harness の JSON を読んで自分で描く）と、検討した D2（harness の Mermaid を flywheel がそのまま描く）は、どちらも flywheel が harness 固有の出力を前提にするので採らない。

## 9. 例: `ticket` を上書きで `merge-route.integration` → `human-merge` に付け替えたとき

```text
harness graph --override route.yaml ticket      # route.yaml に steps.merge-route.on.integration: human-merge
```

- 辺 `merge-route --integration--> human-merge` に `overridden: {"from": "merge", "layer": "arg"}` が付く。
- `merge` へ入る辺は `merge-route.integration` だけなので、`merge` は到達できなくなり `skipped: true` になる。`merge` から出る `merged -> cleanup`・`blocked -> review-human` は破線で残る。
- `cleanup` は `human-merge.merged` からも到達できるので `skipped` にならない。`review-human` は `respond.needs_human` からも到達できるので、#309 §6.2 の規則 3（人のゲートへ到達できなくならない）にも当たらない。

## 10. 決定の記録（2026-10-25）

設計の段階で出した問いを、オーナー（人間）が決めるものと親（Tom）が決めてよいものに分けて回答を受けた。本文はこの決定に揃えてある。

### 10.1 オーナーが決めたこと

| # | 問い | 選択肢 | 決定 | 理由・補足 |
| --- | --- | --- | --- | --- |
| A1 | 形を接続契約に載せるか | (G1) 載せない (G2) 契約 v1 の `status` の出力に足す (G3) 契約に `graph` コマンドを足して版を上げる | G1 | 契約は flywheel が定め、harness から先に変えない（§8.2） |
| A2 | flywheel の画面にフローを出すときの形 | (D1) flywheel が harness の JSON を読んで描く (D2) harness の Mermaid をそのまま描く | flywheel#265 で flywheel が接続ツール共通の形を定め、harness がそれに合わせて出す | 当初は D1 に決めたが、2026-10-25 にオーナーの方針（flywheel から見た harness は接続ツールの 1 つで、harness 固有の形・コマンド・名前を前提にしない）で改めた。`harness graph` の JSON・Mermaid は harness の利用者向けの出力（§8.3） |
| A3 | 単体で開ける HTML を出すか | (H1) 出さない (H2) CDN の Mermaid を読む HTML (H3) Mermaid を埋め込んだ HTML (H4) Go で SVG を描く | H1 | 出力は text・json・mermaid の 3 つ。外部の JS の取得・同梱を持たない（§6.3） |

### 10.2 親が決めたこと

| # | 問い | 決定 | 理由 |
| --- | --- | --- | --- |
| B1 | コマンドの面と名前 | 新しいサブコマンド `harness graph`（C1） | `validate`・`status` の出力と終了コードの意味を変えない（§7） |
| B2 | run を指定したとき、どの定義を描くか | `resume` と同じ手順で組み立て直し、合わなければ描かない（R1） | 表示と `resume` が同じ定義を使う。run に形を書き出しても救えるのは開発用の `--workflow-dir` の run だけ（§5.2） |
| B3 | 上書きで到達できなくなったステップ | 節点に残して `skipped: true`（K1） | 何を飛ばしたかが図の上で分かる（§5.3） |
| B4 | JSON の細部 | 上限つきの `goto` と `retry` の尽きたときの行き先は別の辺。予約値の既定の失敗と `interrupted` は属性 | 描く側が辺を分ける処理を持たずに済み、`ticket.yaml` で最大 76 本の辺が増えるのを避ける（§3.3・§3.4） |
| B5 | 表示の既定と引数の形 | `--format text\|json\|mermaid`、既定 `text`、`--json` は `--format json` の別名 | 形式を足しても引数が増えず、`--json` で既存のコマンドと揃う（§7） |
| — | runner の居ない実行中の run を `graph --run` が `interrupted` に記録し直すか | 記録し直さない | 読み取りのコマンドは状態を変えない（§4） |

## 11. 実装の段階分け（参考。Issue は別に起票する）

| 段 | 内容 | 依存 |
| --- | --- | --- |
| 1 | `harness graph <workflow>` の JSON とテキスト（§3・§6.1・§7）。`overrides`・`changes` は空、`overridable`・`overridden` は `null` | なし |
| 2 | `--run`（§4・§5.2）と Mermaid（§6.2） | 段 1 |
| 3 | 上書きの反映（`--override`・`changes`・`overridden`・`skipped`。§5.1・§5.3） | 段 1・#309 の段 1〜2 |

## 12. 未検証事項

- `graph --run` は runner の居ない実行中の run を記録し直さないので、直後の `status` とは見え方が変わる（`graph` は実行中のまま `waiting` が無い、`status` の後は `interrupted` ゲートで待つ）。テキスト表示で `runner_alive: false` を読み手に分かる形で出せるかは実装時に確かめる【要確認】。段 2（#316）で確かめた: テキストは実行中だったステップに `>` を付け、要約を `run <id>: running at <step>, round N` とし、その下に「runner が居ないので誰も進めていない。graph はそれを記録しない。`harness status` か `harness resume` を呼ぶと、そのステップを interrupted で終えて組み込みの `interrupted` ゲートで待つ」と英語で 1 文書く（Mermaid は同じ文を `%%` のコメントに入れる）。runner の居ない run を作り、`graph --run` が記録を変えないこと・直後の `status` の後に `graph --run` が `interrupted` ゲートで待つと出すことをテストで固めた（`runtime/internal/cli/graph_run_test.go`）。
- 端末の幅が狭いときのテキスト表示の折り返し方（§6.1）は段 1（#315）で決めた: `$COLUMNS` か端末の幅に収まらない行を遷移の区切り（` | `）でだけ折り返し、続きの行は遷移の欄に揃える。欄に揃えると残りが 24 桁を下回る幅では 6 桁の字下げに落とす。1 つの遷移は切らず、それだけで幅を超える場合ははみ出させる。パイプ・リダイレクト先では折り返さない（`runtime/internal/graph/text.go`）。端末の幅を `TIOCGWINSZ` で取る経路は段 2（#316）で macOS の疑似端末（`script -q /dev/null` の下で `stty cols` を変え、`$COLUMNS` を消して `harness graph ticket`）で確かめた: 幅 60 では 56 行に折り返し、60 桁を超えたのは切れない 1 語（凡例の `step_error/step_timeout/invalid_output/budget_exhausted`）だけ、幅 200 とパイプでは 24 行のまま。Linux（`tty_linux.go`）は実物で確かめていない【要確認】。
- Mermaid の 12.x で、`ticket.yaml` の 19 ステップ・53 本（尽きたときの辺 3 本を含む）の辺が読める配置になるか。実物で描いて確かめていない【要確認】。段 2（#316）で、手元にあった Mermaid 11.16.0（`@mermaid-js/mermaid-cli` 11.9.0 の `mmdc`）で PNG に描いて確かめた（12.x は手元に無く未確認のまま）: 節点 32 個（ステップ 19・終端 13）と線 47 本（同じ節点の間の素の辺を 1 本にまとめた。`workspace` の `provided / created / reused` → `implement` 等）が上から下へ流れる配置になり、ラベルと上限（`fail (rework<=3)`）・点線の尽きたときの辺・人のゲートの色は読めた。`implement` の `deviation`・`failure` の 2 本と `merge-route` の `default` は図を縦に横切る長い線になり、終端の円はラベルの長さに応じて大きくなる。
- 上書きの反映（§5.1・§5.2・§5.3）で実装時に決めた細部は段 3（#317）で次のとおりにした（作成者の判断。仮定）。`workflow.overrides` の要素は run の記録の `overrides[]` と同じ `layer`・`path`・`sha256`・`copy` で、`--run` を付けないときは写しが無いので `copy` を `null` にする。`--run` のときは run の記録の値（読んだファイルのパスと写し）を出し、`status --json` の `workflow.overrides` と同じになる（組み立て直した定義が指すのは写しのパスなので、それは出さない）。上書きの記録が無い run（上書きなしで始めた run・上書きを記録する前の版で始めた run）は、段 2 までと同じく元の定義をそのまま描く。`overridable` は上書きの有無に依らず、元の定義が宣言した遷移に常に出す。`skipped` のステップから別の `skipped` のステップへ入る辺は、出ていく辺として残す（入ってくる辺を描かないのは、到達できるステップから入る辺が付け替えで無くなったため）。テキストでは見出しに `overrides:`・`changes:` の行を足し（上書きが無ければ出さない）、付け替えた遷移に `(override <層>, was <元の行き先>)` を添え、`skipped` のステップは行の先頭に `-`、遷移の印を破線の形（`..>`・`..!`・`..=`・`..~`）にして、凡例に `- skipped by an override  ..> transition of a skipped step` を足す（`skipped` が無ければ足さない）。端末の色は使わない（パイプ先でも同じ表示にするため）。Mermaid では上書きと効いた値を `%%` のコメントに書き、付け替えた辺を太線（`==>`）にして同じ注記をラベルに添え（同じ節点の間の素の辺とはまとめない）、`skipped` のステップから出る線を点線（`-.->`）にして `linkStyle` で灰色にする。§9 の例はテキスト・Mermaid・JSON の 3 形式で `runtime/internal/cli/graph_override_test.go` に固めた。上書きで走った run の `graph --run` が、元の上書きのファイルを書き換えても写しから同じ形を描くこと、写しを書き換えると `resume` と同じ照合で描かずに 1 で止まることも同じファイルで確かめた。

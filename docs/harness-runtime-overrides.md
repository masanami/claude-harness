# ワークフロー定義の上書き（Issue #309）

> **状態: 設計（2026-10-25 に問い O1〜O4・P1〜P5 を決定済み）**。harness runtime（Issue #201・[harness-runtime-design.md](harness-runtime-design.md)）のワークフロー定義を、ディレクトリ丸ごとの差し替え（`--workflow-dir`）ではなく、小さな上書きの YAML で調整できるようにする設計を置く。実装は別の Issue で行い、本文書は `runtime/`・`plugin/` の挙動を変えない。決定の記録は §10 にある。
>
> - 正本は Issue #309。食い違ったら Issue が正。
> - 実装の都合で決めることは「実装時に決める」と書いた箇所（§5.2・§7.1・§12）だけである。

上書きの YAML は、リポジトリの `.claude-harness/overrides/<ワークフローの id>.yaml` と引数 `--override <ファイル>` の 2 か所から読み、埋め込みの定義 → リポジトリ → 引数の順に重ねる。上書きできるのは数値（`limits` の値・ステップの `budget_usd`・`timeout`）と、元の定義が `overridable.routes` に候補を宣言した遷移先だけで、それ以外のキーは `harness validate` が拒否する。人のゲート（`decider: human`）とそこへ向かう遷移・`fail` への遷移は、どの宣言でも付け替えられない。v1 の `ticket.yaml` が付け替えを許すのは保守側の 2 か所（統合ブランチ宛も人がマージする・E2E 不要の判断でも E2E を書く）だけで、E2E・レビュー待ち・CI 待ちの省略は許さない。run は元の定義のハッシュに加えて上書きの写しを run ディレクトリに残し、`resume` はその写しで同じ定義を組み立て直す。

位置づけ: Issue #201 の runtime 化（段階 B まで実装済み）の次に来る追加で、flywheel の「開発フローを YAML で制御する」検討（masanami/flywheel#265・移行〔M5〕の後）より先に、claude-harness 単体で使える形にする。可視化（#308）は本文書の上書き後の定義を表示の対象にする。

---

## 1. いまは定義を丸ごと写すしかなく、写しは原本から遅れる

定義を変える手段は `--workflow-dir` でディレクトリ全体を差し替えることだけである（`runtime/internal/cli/cli.go` の `dirs`。実コード確証・high）。`--workflow-dir` は README・CLI のヘルプで「開発用」と書かれている。

Tom（flywheel エージェント）は承認済みの予算に合わせるため、3 組の写し `/Users/masami/Tom/.flywheel/shadow/workflows-20261012-{s,m,l}` を持っている。原本との意図した差は `ticket.yaml` の 2 行だけである。

| 写し | `limits.budget_usd`（原本 40） | `implement` の `budget_usd`（原本 15） |
| --- | --- | --- |
| S | 30 | 15（変更なし） |
| M | 50 | 30 |
| L | 100 | 60 |

写しは原本から遅れる。2026-10-25 に `origin/main`（`2450f1b`）と L の写しを `diff` で比べたところ、上の 2 行に加えて、#304 で原本に足された `publish` の `behaviors: $steps.implement.behaviors` の行が写しに無かった（実コード確証・high）。写しで走る run の PR 本文には、振る舞いの一覧の節が出ない。どこを変えたかは写しの YAML のコメントを読まないと分からず、原本が変わるたびに 3 組を作り直す必要がある。

run は開始時の定義のハッシュ（`state.json` の `workflow.hash`＝YAML のバイト列の sha256）を記録し、`resume` は `workflow.path` から定義を読み直してハッシュを照合する（`runtime/internal/engine/gate.go` の `Reopen`。実コード確証・high）。上書きを入れると「読み直す定義」が元の定義と上書きの組になるので、この照合の形を変える必要がある（§7）。

## 2. 決定の一覧

| 論点 | 決定 | 決定者 | 節 |
| --- | --- | --- | --- |
| 置き場と優先順 | 埋め込み（または `--workflow-dir`）→ リポジトリの `.claude-harness/overrides/<id>.yaml` → `--override <ファイル>`（1 つ）。キーごとに後ろが勝つ | 親（P1） | §3 |
| 上書きの形 | 定義と同じ入れ子の写像で、変えるスカラーだけを書く部分上書き。ステップは id で指す（`steps` は配列でなく写像） | 親（P3） | §4 |
| 開くキー（数値） | `limits` の全項目・`llm` の `budget_usd`・`timeout`・`command` の `timeout` を Go の規則で一律に開く | 親（P2） | §5.1 |
| 開くキー（遷移） | 元の定義が `overridable.routes` に宣言した遷移だけ、宣言した候補の中で付け替えられる。v1 の `ticket.yaml` が宣言するのは保守側の `merge-route.integration: [merge, human-merge]` と `e2e-route.no: [publish, e2e]` だけ | オーナー（O2） | §5.2 |
| 外せないゲート | `decider: human` のゲートすべてと、そこへ向かう遷移・`fail` への遷移を付け替え不可にする | オーナー（O1） | §6 |
| `--workflow-dir` | 開発用のまま、外せないゲートの規則の外に残す | オーナー（O4） | §6.3 |
| run の記録 | `workflow.hash` は元の定義のハッシュのまま。上書きの写しを run ディレクトリに置き、出どころ・ハッシュ・上書き後の定義のハッシュを記録して照合する | 親（P4） | §7 |
| 予算の上限 | harness 側では持たない（呼び出し元が持つ） | 親（P5） | §5.1 |
| flywheel からの渡し方 | 接続契約を変えず、固定の上書き（リポジトリの置き場か、宣言の `start` の引数に書いた `--override`）だけにする。サイズ別の渡し方は flywheel の S4 の分解で決める | オーナー（O3） | §8 |

文書の置き場は、`harness-runtime-design.md` が 976 行あり上書きの論点がまとまった量になるため、この新しい文書にした（作成者の判断。仮定）。設計書の冒頭からこの文書へリンクする。

## 3. 置き場は 2 か所で、埋め込み → リポジトリ → 引数の順に重ねる

| 層 | 置き場 | 想定する書き手 | 読み方 |
| --- | --- | --- | --- |
| 0. 元の定義 | 埋め込み（`<data>/runtime/<CLI の版>/workflows/<id>.yaml`）、または `--workflow-dir` の `<id>.yaml` | claude-harness | 現行どおり（設計書 §6.5） |
| 1. リポジトリ | run を始めた作業ディレクトリの git の最上位にある `.claude-harness/overrides/<id>.yaml` | 対象リポジトリの持ち主（コミットして共有する） | 在れば読む。無ければ飛ばす |
| 2. 引数 | `harness run`・`harness contract start`・`harness validate` の `--override <ファイル>`（1 つだけ） | 呼び出し元（人・flywheel・Tom） | 指定されたファイルが無ければ止まる |

重ね方は**キーごとに後ろの層が勝つ**。層 1 が `limits.budget_usd: 60` を、層 2 が `steps.implement.budget_usd: 30` を書けば、両方が効く。両方が同じキーを書けば層 2 の値になる。どの層の値が効いたかは run の記録に残す（§7）。

- `--workflow-dir` と併用できる。上書きは `--workflow-dir` で指した定義に重なる。元の定義の `overridable` 宣言（§5.2）も `--workflow-dir` 側のものを使う。`--workflow-dir` は開発用のまま残し、運用での調整は上書きへ移す（`--workflow-dir` が外せないゲートの規則の外にあることは §6.3）。
- リポジトリの置き場の名前は `.claude-harness/overrides/` にした。リポジトリ内に `.claude-harness/` の先例は無い（`git grep` で 0 件。実コード確証・high）。`.claude/` は Claude Code の設定の置き場なので避けた。`.harness/` は設計書 §4.6 の L3（作業ツリー内の状態の置き場）の案と名前が近く紛らわしいので避けた。
- リポジトリの層を持つのは、そのリポジトリの run が呼び出し元（flywheel・人・Tom）によらず同じ調整で走るようにするためである。`--override` だけにすると、各経路が同じパスを渡す必要がある。
- 層 1 は「run を始めた作業ディレクトリ」から探す。flywheel が作業ツリーを払い出して `--input worktree=<パス>` を渡す経路で、harness がどの作業ディレクトリで起動されるかは flywheel の S4（`cli` 形態の起動）で決まる【要確認】。作業ツリーが払い出し元のクローンと同じコミットを指していれば、どちらで読んでも同じファイルになる。
- 層 1 を無視させる引数（`--no-repo-override` のようなもの）は v1 では持たない。必要になったら足す。
- `--override` は v1 では 1 つだけ受け付ける。サイズ別の調整は 1 ファイルで表せる（§9 の例）。

## 4. 上書きは定義と同じ形の部分上書きにし、ステップ単位の差し替えは採らない

### 4.1 ファイルの形

```yaml
schema: harness.workflow-override/v1
workflow: ticket                 # 上書きする定義の id。元の定義の id と一致しなければ拒否する
limits:
  budget_usd: 100
steps:
  implement:
    budget_usd: 60
  merge-route:
    on: { integration: human-merge }   # 元の定義の overridable.routes が候補に挙げた値だけ書ける（§5.2）
```

- 元の定義（設計書 §3.1 の文法）と同じ入れ子の写像で、変えるスカラーだけを書く。書いていないキーは元の定義のまま残る。
- ステップは id で指す。`steps` は YAML の写像（`runtime/internal/workflow/parse.go` の `steps` が写像として読む。実コード確証・high）なので、配列の添字で要素を指す問題は起きない。上書きでステップを足す・消す・並べ替えることはできない（開始ステップは `steps` の先頭のまま）。
- 遷移先として書けるのはステップ id 1 つだけで、`{goto, with, limit}`・`{gate}`・`{fail}`・`{done}` の形は書けない。
- 値に `$` で始まる参照は書けない（数値と、ステップ id だけ）。
- 文法は元の定義と同じ「書けるものだけを列挙する」形で実装する（`runtime/internal/workflow/workflow.go` の冒頭の注記）。未知のキーは、閉じたキー（§5.3）の名前なら「上書きできない」、そうでなければ「未知」として拒否する。

### 4.2 比べた案

| 案 | 形 | 評価 |
| --- | --- | --- |
| **A（採用）** | 定義と同じ形の部分上書き。開いたキーのスカラーだけ | 差分がそのまま読める（Tom の S/M/L は数行になる）。開いたキーの一覧を Go で閉じた集合として持てる |
| B | ステップ単位の差し替え（`steps.implement` を丸ごと書き直す） | 1 キー変えるために `prompt`・`agent`・`on` まで写すことになり、原本から遅れる問題（§1）がステップの中で再発する。差し替えたステップの中のどのキーを変えたかが記録から読めない |
| C | 汎用のパッチ（JSON Patch のような操作列） | 配列の添字・操作の種類を持ち込む。設計書 §3.1 の「式を持たない」線引きの外へ出る |

A は B・C より表現力が小さく、ステップの新設や遷移表の自由な書き換えはできない。それが要る調整は従来どおり `--workflow-dir` か、元の定義の変更（PR）で行う。

## 5. 開くのは数値と、元の定義が宣言した遷移だけ

### 5.1 数値は Go の規則で一律に開く

| キー | 対象 | 検査 |
| --- | --- | --- |
| `limits.<名前>` | 元の定義が持つ `limits` の全項目（`ticket.yaml` では `budget_usd`・`rework`） | 元の定義に在る名前だけ（新しい名前は足せない）。整数の limit は整数、`budget_usd` は正の金額（現行の `budget` 検査） |
| `steps.<id>.budget_usd` | `kind: llm` のステップ | 正の金額 |
| `steps.<id>.timeout` | `kind: llm`・`kind: command` のステップ（元の定義で `timeout` を持てる種類） | 正の時間（元の定義と同じ書式） |

数値を開いても遷移表は変わらない。予算を上げる方向の上書きは費用を増やすが、run は `limits.budget_usd` の累計で止まり（設計書 §4.3）、子の `claude -p` の上限は「残予算とステップの `budget_usd` の小さいほう」のままである。harness 側で予算の上限（例: 上書きで 200 を超えさせない）は持たない。予算の承認と上限の管理は呼び出し元（flywheel の `size_budgets_usd`・`max_run_budget_usd`）が持ち、harness に別の上限を置くと上限が 2 か所に分かれて、どちらで止まったかが分かりにくくなるためである（P5）。

数値を元の定義の宣言で開く案（`overridable.steps.implement: [budget_usd]` のように 1 つずつ書く）は採らなかった。開く範囲が定義から読めるのが利点だが、`ticket.yaml` の `llm` ステップ 7 個について 2 キーずつ書くことになり、宣言の書き漏れで Tom の用途が通らない事故が起きうる。数値は遷移を変えないので、宣言を要求するほどの差は無い（P2）。

### 5.2 遷移の付け替えは、元の定義が `overridable.routes` に宣言した候補の中だけ

元の定義に、トップレベルのキー `overridable` を足す（設計書 §3.1 の文法の追加。`harness.workflow/v1` のまま足せるか、スキーマ版を上げるかは実装時に設計書 §7.3 の照合と合わせて決める）。v1 の `ticket.yaml` の宣言は次の 2 行である（O2）。

```yaml
overridable:
  routes:
    merge-route.integration: [merge, human-merge]   # 統合ブランチ宛も人のマージにできる（保守側への付け替え）
    e2e-route.no: [publish, e2e]                    # analyze が E2E 不要と判断しても E2E を書ける（保守側への付け替え）
```

- キーは `<ステップ id>.<outcome>`、値は遷移先の候補（ステップ id の配列）。元の定義の遷移先は候補に含めなければならない（上書きが無いときの値）。
- 上書きで書ける値は候補のどれか 1 つだけである。
- 候補を宣言できない遷移は §6.2 の規則で決まる。

ステップの「省略」は、このしくみで前段の遷移を後段へ付け替えることとして表す（`skip: true` のような専用のキーは持たない）。省略したときにどこへ進むかが定義に書かれた候補から読め、`outcome` の仮定（省略したステップが何を返したことにするか）を持ち込まずに済むためである。

`ticket.yaml` で付け替えの候補になりうる遷移と、v1 での扱い:

| 遷移 | 元の遷移先 | 付け替えの候補 | 何が変わるか | v1 |
| --- | --- | --- | --- | --- |
| `merge-route.integration` | `merge`（`/pr-merge` で自動マージ） | `human-merge` | 統合ブランチ宛も人がマージする（保守側） | 開く |
| `e2e-route.no` | `publish` | `e2e` | analyze が E2E 不要と判断しても E2E を書く（保守側） | 開く |
| `e2e-route.yes` | `e2e` | `publish` | E2E を書かない（E2E の省略） | 開かない |
| `ci.green`・`ci.none` | `review`（レビュー待ちのゲート） | `merge-route` | PR のレビューを待たずにマージの振り分けへ進む。統合ブランチ宛は `/pr-merge` の自動マージになる（レビュー待ちの省略） | 開かない |
| `publish.opened`・`publish.updated` | `ci`（CI の結果を待つ） | `review` | CI の結果を見ずにレビュー待ちへ進む。CI の失敗を `fix` で直す差し戻し（`ci.red`）と、待ちきれないときの `ci-pending` は通らなくなる（CI 待ちの省略） | 開かない |
| `merge-route.default` | `human-merge` | — | 既定ブランチ宛 PR の人のマージ | 宣言できない（§6.2） |

E2E・レビュー待ち・CI 待ちの省略は v1 では許さないが、用途によっては品質の確認を省いて速さを求める場合がある（オーナー・2026-10-25）。開くときは、上の表の候補を `ticket.yaml` の `overridable.routes` に 1 行足せばよい（例: `e2e-route.yes: [e2e, publish]`）。しくみと §6.2 の規則は v1 で入るので、Go の変更は要らない。開く前に確かめておくこと:

- E2E の省略（`e2e-route.yes → publish`）: `e2e` の差し戻しの経路（`e2e.fail → fix`）が通らなくなる。`publish` は `e2e` の出力を参照していないので、§6.2 の規則 4 には当たらない。
- レビュー待ちの省略（`ci.green`・`ci.none → merge-route`）: CI の後のレビュー待ちを通らなくなる。`merge.blocked → review-human → respond → review` の経路は残るので、`review`・`respond` は到達でき、`skipped_steps` にはならない。`review-human` も到達できるので、§6.2 の規則 3 には当たらない。
- CI 待ちの省略（`publish.opened`・`publish.updated → review`）: PR を作った直後の CI 待ちを通らなくなる。`respond.pushed → ci` は残るので、レビュー対応で push した後は CI を待つ（`ci`・`ci-pending` は到達でき、`skipped_steps` にはならない）。統合ブランチ宛の `/pr-merge` は preflight で CI の失敗をマージの妨げとして判定する（`plugin/skills/pr-merge/SKILL.md` Phase 0-1。実コード確証・high）が、CI が実行中のときの扱いは確かめていない【要確認】。

セルフレビュー（`/self-review`）の省略は、このしくみでは表せない。セルフレビューは runtime のステップではなく、`implement` の中（`feature-implementer` の内側のループ。設計書 §1.1）で動くためである。省略を許すなら、`implement` への入力（`with`）を足してプロンプトへ渡す別の設計が要る。flywheel#265 の「S かつ低リスクはセルフレビューを省略」はこれに当たり、本 Issue の範囲外とする（重要度による自動の切り替えも範囲外。Issue の「やらないこと」）。

### 5.3 開かないキー

次のキーは上書きに書けない。書けば `validate` が「上書きできない」として拒否する。

- 定義の同定と入口: `schema`・`id`・`description`・`inputs`
- ステップの振る舞い: `kind`・`run`・`prompt`・`agent`・`output`・`outcome_field`・`exit`・`session`・`with`・`value`・`action`
- ゲート: `type`・`decider`・`inputs`・`observe`・`requested_action`（`decider` を `human` から `any` へ変えると、TTY を要求しない経路でゲートを解決できてしまう。設計書 §5.3）
- 遷移: `overridable.routes` に宣言の無い `on` のすべて。`limit`・`exhausted`・`retry` の形も変えられない（回数は `limits` の値で変える）
- `overridable` 自体（上書きで候補を広げることはできない）

## 6. 外せないゲート: 人のゲートと、そこへ向かう遷移と、`fail` への遷移

### 6.1 `ticket.yaml` のゲートと停止点の洗い出し

`ticket.yaml`（`origin/main`・`2450f1b`）を読んで、上書きで外れると困るものを洗い出した（実コード確証・high）。扱いはオーナーの決定（O1 → (c)）による。

| 対象 | 形 | 何を守っているか | 扱い |
| --- | --- | --- | --- |
| `human-merge` | `observe` × `human`。`merge-route.default` から入る | 既定ブランチ（本番反映先）へのマージを人が行う（設計書 R5） | 外せない（Issue の要件 3） |
| `design-deviation` | `input` × `human`（TTY 必須）。`implement.deviation`・`fix.deviation` から入る | クリティカル設計からの逸脱を人が判断する | 外せない |
| `review-human` | `input` × `human`（TTY 必須）。`respond.needs_human`・`merge.blocked` から入る | レビュー対応で品質ゲートの失敗や設計変更が出たときに人が判断する | 外せない |
| 品質の失敗での停止 | `implement.failure`・`implement.review_incomplete`・`fix.failure`・`commit.failure` → `fail` | 品質ゲートに通らない変更・セルフレビューと合流できない変更を PR にしない（#262） | 付け替え不可 |
| 入口の検査での停止 | `resolve.base_missing`・`resolve.links_invalid`・`workspace.conflict` → `fail` | 宛先や作業ツリーが不正なまま進まない | 付け替え不可 |
| 差し戻しの上限 | `e2e.fail`・`ci.red` の `limit: rework` | 修正の繰り返しを止める | 形は変えない。回数は `limits.rework` で変えられる（§5.1） |
| `review`・`ci-pending` | `input` × `any` | レビュー待ち・CI を確かめる外部待ち | ゲート自体のキーは閉じる（§5.3）。前段から飛ばすことは v1 では許さない（§5.2） |

`merge` ステップ（`/pr-merge`）のプロンプトは、マージの前に PR の base が既定ブランチでないことを `gh pr view` で確かめ、既定ブランチ宛なら `blocked` を返す（`runtime/workflows/prompts/ticket-merge.md`。実コード確証・high）。これは LLM が守る散文の歯止めで、構造の歯止めは `merge-route` の振り分けである。上書きで構造の歯止めを外せないようにするのが §6.2 の規則である。

### 6.2 規則（Go で持つ。宣言に依らず効く）

`harness validate` と `run` の開始時に、上書きを重ねた定義へ次を課す。

1. **人のゲートは変えられない**: `decider: human` のゲートのキーは上書きに書けない（§5.3 で閉じたキーに加え、数値のキーもゲートには無い）。
2. **人のゲートと `fail` へ向かう遷移は付け替えられない**: 元の定義で遷移先が `decider: human` のゲート（直接のステップ id でも `{gate: <id>}` でも）、または `{fail: …}` である遷移は、`overridable.routes` に宣言できない。宣言があれば元の定義の検査で拒否する。`ticket.yaml` では `merge-route.default`・`implement.deviation`・`fix.deviation`・`respond.needs_human`・`merge.blocked`・`human-merge.open` と、`fail` への遷移すべてが当たる。
3. **人のゲートへ到達できなくならない**: 元の定義で開始ステップから到達できる `decider: human` のゲートは、上書き後の定義でも到達できなければならない。規則 2 があれば通常は満たされるが、付け替えの組み合わせで前段ごと迂回される形を検出するための二重の検査として置く。
4. **上書き後の定義も通常の検査をすべて通る**: 参照の型・「その経路で必ず実行済みか」（`guaranteed`）・数えられない循環・`outcome` の網羅（`runtime/internal/workflow/validate.go`）。付け替えで後段が前段の出力を参照できなくなる形（例: `e2e` を飛ばしたのに `e2e` の出力を読むステップが残る）はここで落ちる。
5. **到達できなくなったステップは「省略」として報告する**: 現行の検査は到達できないステップを誤りにする（`reachability`）。上書き後の定義では、元の定義で到達でき、上書きの付け替えによってだけ到達できなくなったステップを誤りにせず、`skipped_steps` として `validate` の出力と run の記録（§7）に出す。

規則 1〜3 はゲートの名前（`human-merge` 等）を Go に書かず、`decider: human` という性質で決める。`ticket` 以外のワークフローにも同じ規則が効き、新しい人のゲートを足したときに Go を直す必要が無い。`fail` への遷移まで含めたのは、付け替えられると品質ゲートに通らない変更（#262 で塞いだ `review_incomplete` を含む）を PR にする経路が上書き 1 行で開くためである。

### 6.3 `--workflow-dir` はこの規則の外にある

`--workflow-dir` は定義を丸ごと差し替えるので、`human-merge` を消した定義でも、それ自体として正しければ `validate` を通る。§6.2 の規則は「元の定義から上書きで外す」ことを止めるもので、元の定義そのものを差し替える経路は止めない。`--workflow-dir` は開発用のまま、この規則の外に残し、run の記録の `embedded: false` で区別できる状態にとどめる（O4）。上書きが入れば、運用で `--workflow-dir` を使う理由（Tom の S/M/L）は無くなる。

## 7. run の記録: 元の定義のハッシュは変えず、上書きの写しを run に残す

### 7.1 記録するもの

`run_started` イベント（`runtime/internal/runstate/event.go` の `RunStarted`）の `workflow` に次を足す。

```json
"workflow": {
  "id": "ticket", "schema": "harness.workflow/v1",
  "hash": "<元の定義の YAML の sha256。現行と同じ意味>",
  "path": "<元の定義のパス。現行と同じ>",
  "overrides": [
    {"layer": "repo", "path": "<読んだファイルの絶対パス>", "sha256": "…", "copy": "overrides/1-repo.yaml"},
    {"layer": "arg",  "path": "<読んだファイルの絶対パス>", "sha256": "…", "copy": "overrides/2-arg.yaml"}
  ],
  "effective_hash": "<上書きを重ねた定義を正規化した表現の sha256>",
  "changes": [
    {"key": "limits.budget_usd", "from": 40, "to": 100, "layer": "arg"},
    {"key": "steps.implement.budget_usd", "from": 15, "to": 60, "layer": "arg"}
  ],
  "skipped_steps": []
}
```

- `hash` の意味は変えない（元の定義の YAML のバイト列の sha256）。`resume` の照合（設計書 §7.3 と N3）、`definitionsUsable` の判定はそのまま効く。上書きの無い run の記録は現行と同じ形になる（`overrides` は空、`effective_hash` は `hash` と同じ値か省略。どちらにするかは実装時に決める）。
- 上書きのファイルは run の開始時に run ディレクトリ（設計書 §4.6 の F1）の `overrides/` へ写す。リポジトリの `.claude-harness/overrides/` はブランチを切り替えると中身が変わり、`--override` のファイルは呼び出し元が書き換えうる。写しを持てば、`resume` は開始時と同じ上書きで続けられる。
- `changes` は「何を何から何へ変えたか」を層つきで持つ。#308 の可視化と、後から「この run は何で走ったか」を読むときに、YAML 同士を比べずに済む。`limits` の効いた値は現行の `run_started.limits` にも入る（`engine.go` が `WF.Limits` から作る）。
- `status --json` に `workflow.overrides`・`changes`・`skipped_steps` を出す。接続契約 v1 の出力（`harness contract`）の形は変えない。

### 7.2 `resume` での組み立て直し

`Reopen` は次の順で定義を組み立て直す。

1. `workflow.path` から元の定義を読み、`hash` と照合する（現行どおり。違えば止まる）。
2. `overrides[].copy` を run ディレクトリから読み、`sha256` と照合する（違えば止まる。写しを手で書き換えた run を黙って続けない）。元の `path` は読まない。
3. 重ねて検査し（§6.2）、`effective_hash` と照合する。CLI の版が変わって重ね方や正規化が変わった場合はここで食い違うので、止まって開始時の版での `resume` か `cancel` を案内する（N3 と同じ扱い）。

上書き後の定義そのものを run ディレクトリに書き出して `path` をそちらへ向ける案は採らない（P4）。定義の相対パス（`prompt`・`output` の起点＝定義のディレクトリ）がずれるためである。`hash` を上書き後の定義のハッシュに変える案も採らない。`resume` が元の定義を読み直す経路（`path`）と照合の対象がずれ、上書きの無い run とある run で `hash` の意味が変わるためである。

## 8. flywheel から使うとき: 接続契約は変えず、固定の上書きだけにする

接続契約 v1 の `start` は `harness contract start [--workflow-dir DIR] [--scripts-dir DIR] [--input NAME=VALUE]... <workflow>` で、引数は flywheel の `.flywheel/connectors.json` の `commands.start` に配列で宣言する（設計書 §5.6.1・flywheel `docs/features/m3-invoker-delegation.md` §クリティカル設計決定 3。ドキュメント由来・high）。flywheel が引数に差し込める値は閉じた集合で、課題のサイズや予算の額は含まれない（同 §受入基準の `{issue_number}`・`{issue_url}`・`{external_key}`・`{challenge_id}`。ドキュメント由来・high）。flywheel の `cli` 形態の起動は S4 で実装する予定で、いまの flywheel は harness を `harness contract` で呼んでいない（flywheel のクローン `614fb62` の `git grep` で `workflow-dir`・`contract start` の呼び出しは 0 件。実コード確証・high）。

渡し方は 3 通りあり、#309 では F1 だけにした（O3）。

| 案 | 渡し方 | 接続契約・宣言の変更 | サイズ別に変えられるか | 扱い |
| --- | --- | --- | --- | --- |
| F1 | リポジトリの `.claude-harness/overrides/` に置くか、`commands.start` に固定の `--override <パス>` を書く | 要らない（`--override` は harness の `start` の引数を増やすだけで、契約 v1 の出力は変わらない） | できない（1 つのリポジトリ・1 つの宣言で 1 つ） | #309 で実装する |
| F2 | サイズ別のファイルを用意し、flywheel が課題のサイズでパスを選ぶ（`{size}` の差し込み、またはサイズごとの `commands.start`） | flywheel の宣言の形を変える。flywheel は harness のキーを知らず、パスを選ぶだけ | できる | flywheel の S4 の分解で決める |
| F3 | flywheel が `start` に予算の額（例: `--max-budget-usd <額>`）を足し、harness が `limits.budget_usd` の上限として使う | 契約 v1 の `start` の引数を変える | 総額はできる。ステップごとの予算（Tom の M・L が変えている `implement` の 30・60）は表せない | flywheel の S4 の分解で決める |

契約は flywheel が定め、harness が合わせる（設計書 §0.1）ので、F2・F3 は flywheel 側で決める。F3 は総額しか運べないため、決めるときは F2 と組み合わせるか、`ticket.yaml` の `implement` の `budget_usd` の既定を見直すかを一緒に検討する必要がある。

## 9. Tom の S/M/L の写しを上書きに置き換えた例

`--workflow-dir` の写し 3 組は、次の 3 ファイルと `--override` で置き換えられる。原本が変わっても作り直しは要らない（§1 の `behaviors` の欠落も起きない）。

```yaml
# s.yaml
schema: harness.workflow-override/v1
workflow: ticket
limits: { budget_usd: 30 }
```

```yaml
# m.yaml
schema: harness.workflow-override/v1
workflow: ticket
limits: { budget_usd: 50 }
steps: { implement: { budget_usd: 30 } }
```

```yaml
# l.yaml
schema: harness.workflow-override/v1
workflow: ticket
limits: { budget_usd: 100 }
steps: { implement: { budget_usd: 60 } }
```

```text
harness run --override <置き場>/l.yaml --input issue=<番号> ticket
```

## 10. 決定の記録（2026-10-25）

設計の段階で出した問いを、オーナー（人間）が決めるものと親（Tom）が決めてよいものに分けて回答を受けた。本文はこの決定に揃えてある。

### 10.1 オーナーが決めたこと

| # | 問い | 選択肢 | 決定 | 理由・補足 |
| --- | --- | --- | --- | --- |
| O1 | 外せないゲートの範囲 | (a) `human-merge` だけ (b) `decider: human` のゲートすべてと、そこへ向かう遷移 (c) (b) に加えて `fail` への遷移 | **(c)** | 人のゲートを名前でなく性質で決めれば、新しいゲートにも自動で効く。`fail` への遷移を付け替えられると、品質ゲートに通らない変更を PR にする経路が開く（§6.2） |
| O2 | 上書きでステップの省略を許す範囲 | (a) 保守側への付け替えだけ (b) (a)＋E2E の省略 (c) (b)＋レビュー待ちの省略 | **(a)**。`ticket.yaml` の宣言は `merge-route.integration: [merge, human-merge]` と `e2e-route.no: [publish, e2e]` | E2E・レビュー待ち・CI 待ちの省略は v1 では許さない。用途によっては省略して速さを求める場合があるので、後から宣言を足せば開けることと、開いたときに何が起きるかを §5.2 に残した（CI 待ちの省略の行はこの回答で足した） |
| O3 | flywheel から使うときに接続契約・宣言へ手を入れるか | (F1) 契約を変えず固定の上書きだけ (F2) 宣言でサイズ別にファイルを選ぶ (F3) 契約の `start` に予算の額を足す | **F1** | F2・F3 は flywheel の S4 を分解するときに決める（§8） |
| O4 | `--workflow-dir` を外せないゲートの規則の外に置いたままにするか | (a) 開発用のまま残す (b) `contract start` では拒否する (c) 必須の人のゲートを Go に持ち `--workflow-dir` にも課す | **(a)** | 上書きが入れば運用で使う理由が無くなる。(b) は契約の引数を減らす変更、(c) はゲートの名前を Go に持ち込む（§6.3） |

### 10.2 親が決めたこと

| # | 問い | 決定 | 理由 |
| --- | --- | --- | --- |
| P1 | 置き場の名前と優先順 | `.claude-harness/overrides/<id>.yaml`。埋め込み → リポジトリ → `--override`（1 つ）の順で、キーごとに後ろが勝つ | リポジトリに置けば呼び出し元によらず同じ調整で走る。`.harness/` は設計書 §4.6 の L3 と紛らわしい（§3） |
| P2 | 数値のキーの開き方 | Go の規則で一律に開く | 数値は遷移表を変えず、正の値の検査で足りる。宣言させると書き漏れで調整が通らない事故が起きうる（§5.1） |
| P3 | 上書きの形 | 定義と同じ形の部分上書き（案 A） | §4.2 |
| P4 | run の記録と `resume` の照合 | `hash` は元の定義のまま。上書きの写しを run ディレクトリに置き、`effective_hash` で照合する | 上書き後の定義を書き出す案は相対パスの起点がずれる。上書きの無い run の記録と照合は現行のまま変わらない（§7） |
| P5 | harness 側で予算の上限を持つか | 持たない | 予算の承認と上限は呼び出し元が持つ。上限が 2 か所に分かれると、どちらで止まったかが分かりにくい（§5.1） |

## 11. 実装の段階分け（参考。Issue は別に起票する）

| 段 | 内容 | 依存 |
| --- | --- | --- |
| 1 | 上書きの読み込み（2 層）・数値のキー（§5.1）・閉じたキーの拒否（§5.3）・run の記録と `resume`（§7）・`validate --override` の出力（`changes`） | なし。Tom の S/M/L はこの段で置き換えられる |
| 2 | `overridable.routes`（§5.2）・§6.2 の規則・`skipped_steps`・`ticket.yaml` への `merge-route.integration` と `e2e-route.no` の宣言 | 段 1 |
| 3 | `status --json` への `overrides`・`changes`・`skipped_steps` の表示（#308 の可視化の材料） | 段 1 |

## 12. 未検証事項

- flywheel が `cli` 形態で harness を起動するときの作業ディレクトリ（§3 の層 1 をどこから探すか）。flywheel の S4 で決まる【要確認】。
- `overridable` を `harness.workflow/v1` のまま足せるか（埋め込みの定義と `--workflow-dir` の古い定義の混在で、読めない CLI が出ないか）。設計書 §7.3 の照合と合わせて実装時に確かめる【要確認】。
- 上書き後の定義を正規化してハッシュを取る方法（キーの順・数値の書式）。実装時に決める。
- CI が実行中の PR を `/pr-merge` の preflight がどう扱うか（CI 待ちの省略を開くときの判断材料。§5.2）【要確認】。

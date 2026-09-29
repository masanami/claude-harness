# runtime/（harness CLI・開発中）

`harness` は claude-harness の headless workflow runtime。設計は [`docs/harness-runtime-design.md`](../docs/harness-runtime-design.md)（Issue #201）が正本。このディレクトリはプラグインの配布物（`plugin/`）の外にある。CLI はプラグインとは別に、GitHub Releases のバイナリで配る（§6.4。下の「導入」「リリース」）。

## 現在の範囲（PR-2・Issue #259 ＋ PR-3・Issue #261 ＋ PR-4・Issue #269 ＋ PR-6・Issue #275）

- ワークフロー定義（式を持たない YAML・§3.1〜§3.3）の読み込みと `harness validate`（§6.3）
- イベントログ（`events.jsonl` が正本）と状態の畳み込み（`state.json`）・状態の置き場（§4・§4.6）
- ステップ種類は `command`・`llm`・`gate`・`select`・`workspace`・`pull-request`（`fanout`・`plan-parallel` は PR-5）
- 同梱のワークフロー `ticket`（1 チケットの実装フロー。§3.4）。shadow run（§8 C3 の段階 A）の手順と指標の取り方は [`docs/harness-runtime-shadow.md`](../docs/harness-runtime-shadow.md)
- unit の累計予算と費用の fail-closed（§4.3）・ラウンド（ゲートとゲートの間。§4.2）
- `run` / `status [--json]` / `runs [--json]` / `resume` / `approve` / `cancel`（§5.1）
- runner が落ちて running のまま残ったステップ実行は、次の `status` / `resume` で `interrupted` になり、unit は組み込みの `interrupted` ゲートで止まる（§4.5。自動で再実行しない）
- 定義とスクリプトのバイナリへの埋め込みと展開（§6.5 の S1）・`setup`・`version`・版の照合（§7.3。N3 を含む）・リリース用の GitHub Actions（§6.4）

## 構成

| パス | 中身 |
| --- | --- |
| `cmd/harness/` | エントリポイント |
| `internal/workflow/` | YAML の文法（許可リスト）と静的検証 |
| `internal/runstate/` | イベント・畳み込み・run ディレクトリ（追記・原子的な `state.json`・mkdir ロック） |
| `internal/engine/` | 状態機械・`command` / `llm` 種類の実行・ゲートの解決（resume / approve）・中断の検出 |
| `internal/statedir/` | 状態の置き場の決定（L2）と、埋め込んだ定義の展開先の決定 |
| `internal/bundle/` | 埋め込んだ定義・スクリプト（`files/` は `make bundle` が作る写し）と、版ごとのディレクトリへの展開 |
| `internal/version/` | CLI の版・対応するプラグイン版の範囲・読めるワークフロースキーマ版 |
| `internal/cli/` | コマンドの面（approve の TTY 判定・`setup`・`version` を含む） |
| `internal/qualitygate/` | ルートの `Makefile` の検査（go が無ければ失敗すること） |
| `workflows/` | ワークフロー定義（`schemas/` は出力の JSON Schema、`prompts/` は `llm` のプロンプト、`scripts/` は runtime が持つスクリプト） |

## 導入

1. GitHub Releases のタグ `runtime/vX.Y.Z` から、OS・アーキテクチャに合うアーカイブを取り、`checksums.txt` で確かめてから `harness` を PATH の通った場所へ置く。

   ```bash
   v=X.Y.Z; a=darwin_arm64                     # darwin_amd64・linux_amd64・linux_arm64
   gh release download "runtime/v$v" -R masanami/claude-harness -p "harness_${v}_${a}.tar.gz" -p checksums.txt
   grep "harness_${v}_${a}.tar.gz" checksums.txt | shasum -a 256 -c -
   tar -xzf "harness_${v}_${a}.tar.gz" && install -m 0755 harness "$HOME/.local/bin/harness"
   ```

2. `harness setup` でプラグインを整える（`claude plugin marketplace add masanami/claude-harness` と `claude plugin install claude-harness@masanami-harness` を、済んでいなければ呼ぶ。`--scope user|project|local`・`--marketplace <登録元>` を渡せる）。導入済みのプラグインの版が CLI の対応範囲外なら、どちらを更新すべきかを表示して終了コード 5 で終わる（更新はしない）。
3. `harness version` で CLI の版・対応するプラグイン版の範囲・読めるスキーマ版・定義の展開先を確かめる。

- `go install github.com/masanami/claude-harness/runtime/cmd/harness@runtime/vX.Y.Z` でも入るが、**そのバイナリは定義とスクリプトを持たない**（`go:embed` はモジュールの外の `plugin/scripts` を指せず、埋め込む写しは `make bundle` がビルドの前に作るため。`--workflow-dir` / `--scripts-dir` が要る）。自動更新は持たない。

## 定義とスクリプトの置き場（S1）

- リリースのバイナリは `runtime/workflows/`・`plugin/scripts/`（`tests/` を除く）・`plugin/agents/` を埋め込んでいる（`agents/` は `validate` が `agent:` の参照先を確かめるためだけに使う。子の `claude -p` はインストール済みのプラグインから解決する）。
- 初回の `run` / `validate` で `<data>/runtime/<CLI の版>/` へ展開して使う。`<data>` は `$HARNESS_DATA_DIR`、無ければ `$XDG_DATA_HOME/claude-harness`、無ければ `~/.local/share/claude-harness`。展開したファイルは読み取り専用で、印（`.bundle-sha256`）の中身が違うディレクトリは上書きせずに止まる。版を持たないビルドは `dev-<中身の sha256 の先頭 12 桁>` に展開する。
- `--workflow-dir` / `--scripts-dir`（開発用）を渡せばそちらを使う。埋め込んでいないバイナリは、作業ツリーの中なら作業ツリーの `runtime/workflows`・`plugin/scripts` を探して使い、外なら 2 つのフラグを求めて止まる。

## 版の照合（§7.3）

- CLI は独立した semver（タグ `runtime/vX.Y.Z`）。対応するプラグイン版の範囲（現在 `>=4.8.0 <5.0.0`）と、読めるワークフロースキーマ版（`harness.workflow/v1`）を内蔵する。
- 呼び出し元（薄いスキル）は自分のプラグイン版を環境変数 `HARNESS_PLUGIN_VERSION` で渡す。設定されていれば `run`・`resume`・`approve`（`contract start`・`contract resume` を含む）は何もする前に照合し、範囲外なら更新すべき側（プラグイン／CLI）を標準エラーに出して終了コード 5 で終わる。設定されていなければ照合しない（スキルを通さない起動）。
- run は開始時の CLI の版（`cli_version`）と、定義を埋め込みから読んだか（`embedded`）を記録する。ゲートで待っている run を CLI の更新後に `resume` すると、**開始時の版の展開ディレクトリの定義・スクリプトで続ける**（N3。新しい版の定義には切り替えない）。そのディレクトリが無い・スキーマ版を読めない・この CLI が定義を読み込めない場合は、状態を変えずに終了コード 5 で止まり、「開始時の版の harness で `resume` する」か「`harness cancel <run>`」を案内する。開始時と同じ版なら、消えた展開ディレクトリを作り直して続ける。
- 終了コード 5 の標準出力: プラグイン版の不一致は run を読む前に止まるので何も出さない（理由は標準エラー）。版をまたぐ `resume` の拒否は、状態を変えていない run の現在地（`status --json` と同じ JSON）を出す。`contract` の面では、`contract resume` と `contract status` は run の状態（`waiting` 等）のまま、`requested_action` をゲートの操作でなく `observe` × `human`（何を更新すべきかと、その後に `contract status` で確かめ直すことの案内）にし、理由を `summary` に添える（#283。設計 §5.6.1）。`contract start` は run を始めないので `state: failed`・`run_id: null` を出して理由を `summary` に入れる。
- 照合していないこと: 版をまたぐ `resume` では、プラグイン版を**今の CLI** の対応範囲とだけ照合する。run を始めた CLI が対応していた範囲は記録していないので、開始時の定義と今のプラグインの組み合わせは確かめない（#275 で問いとして上げた）。

## リリース（§6.4）

タグ `runtime/vX.Y.Z` の push（**タグを打つのは人**）で `.github/workflows/release-runtime.yml` が起動し、`make check` → `make dist VERSION=X.Y.Z` → GitHub Release の作成を行う。PR・ブランチの push・手動では起動しない。成果物:

| ファイル | 中身 |
| --- | --- |
| `harness_<X.Y.Z>_darwin_arm64.tar.gz` | macOS（Apple Silicon）の `harness` |
| `harness_<X.Y.Z>_darwin_amd64.tar.gz` | macOS（Intel）の `harness` |
| `harness_<X.Y.Z>_linux_amd64.tar.gz` | Linux（x86_64。WSL を含む）の `harness` |
| `harness_<X.Y.Z>_linux_arm64.tar.gz` | Linux（arm64）の `harness` |
| `checksums.txt` | 上の 4 つの sha256（`sha256sum` の書式） |

- 各アーカイブの中身は `harness` の 1 ファイル（`CGO_ENABLED=0`・`-trimpath`・版は `-ldflags` で埋める）。定義とスクリプトは埋め込み済み。
- 手元で作るときは `make dist VERSION=X.Y.Z`（`DIST_DIR`・`PLATFORMS` で置き場と対象を変えられる）。

## 開発時の使い方

品質ゲートはリポジトリのルートで `make check`（bash テスト・gofmt・`go vet`・`go test`・`harness validate`）。`make check` は先に `make bundle`（埋め込む写しを `internal/bundle/files/` へ作る）を行う。`runtime/` で `go test` を直接実行する場合も、定義やスクリプトを変えたら `make bundle` をやり直す（写しが作業ツリーと違えば `internal/bundle` のテストが落ちる）。

```bash
cd runtime
go run ./cmd/harness validate --workflow-dir workflows --scripts-dir ../plugin/scripts  # 作業ツリーの定義を検証（フラグ無しなら埋め込んだ写し）
go run ./cmd/harness run list-tests --input root=.. # command 種類だけのサンプルを実行
go run ./cmd/harness runs --json
go run ./cmd/harness status <run-id> --json
go run ./cmd/harness resume <run-id> --input <値>    # ゲートを解決して次のラウンドへ
go run ./cmd/harness approve <run-id> --input <値>   # 人が端末から解決するゲート（decider: human の input 型）
go run ./cmd/harness cancel <run-id>
go run ./cmd/harness contract status <run-id>        # flywheel の接続契約 v1 の JSON（start・status・resume・cancel）
```

- ワークフロー定義とスクリプトの置き場は `--workflow-dir` / `--scripts-dir` で指す。省略時は埋め込んだ写し（`make bundle` の時点の作業ツリーの内容）を展開して使う（上の「定義とスクリプトの置き場」）。
- 状態は `$HARNESS_STATE_DIR`、無ければ `$XDG_STATE_HOME/claude-harness`、無ければ `~/.local/state/claude-harness` の `runs/<run-id>/` に置かれる（`events.jsonl`・`state.json`・`logs/`）。試すときは `HARNESS_STATE_DIR` を一時ディレクトリへ向けるとよい。
- `llm` 種類が起動する `claude` は `$HARNESS_CLAUDE_BIN`、無ければ PATH の `claude`。`workspace`・`pull-request` 種類と `pr-state` の観測が起動する `git`・`gh` は `$HARNESS_GIT_BIN`・`$HARNESS_GH_BIN`、無ければ PATH のもの（`command` 種類のスクリプトは PATH の `git`・`gh` を使う）。
- 終了コード（0 成功・1 失敗・2 使い方の誤り／定義の不正・3 待機〔ゲートで止まった〕・4 停止・5 版の不一致）は人向けのコマンドの割り当てである。flywheel 向けの接続契約 v1 は別の入口 `harness contract start|status|resume|cancel` が担い、JSON（`contract_version: 1`）を出力できたら終了コード 0 で終わる。待機・成功・失敗は JSON の `state` で表す（§5.6）。
- 待機（3）のとき stdout の JSON の `waiting[]` に、ゲート・決める主体・要求操作（`requested_action`）・受け付ける値・`requires_tty`・再開のコマンドが入る（§5.2）。

## `command` 種類の書き方

```yaml
steps:
  list:
    kind: command
    run: list-test-files              # <workflow-dir>/scripts/<名前>.sh か plugin/scripts/<名前>.sh を bash で起動する（同名が両方に在れば validate が拒否）
    with: { root: $inputs.root }      # --root <値> として渡す（YAML の順。配列はフラグを繰り返す。省略された任意の入力は渡さない）
    output: schemas/list-test-files.json   # stdout の JSON をこのスキーマで検証する
    outcome_field: status             # outcome を取るフィールド（既定 outcome）。代わりに exit: { 0: ok, 1: ng } も書ける
    timeout: 60s
    on:                               # outcome の値 → 遷移先。enum をすべて網羅する（一致だけ。条件式は無い）
      ok: { done: listed }
      no_test_files_found: { fail: no_test_files_found }
```

予約値（`step_error`・`step_timeout`・`invalid_output`・`budget_exhausted`）は `on` に書けば別の遷移へ送れ、書かなければ run は `failed` になる（fail-closed）。

## `llm` 種類の書き方

```yaml
limits:
  budget_usd: 40                      # unit の累計予算（USD）。llm ステップがあれば必須
steps:
  implement:
    kind: llm
    agent: claude-harness:feature-implementer   # 任意。--agent へ渡す（plugin/agents/<名前>.md の実在を検査）
    prompt: prompts/ticket-implement.md         # 本文。with の値と現在地は JSON のデータブロックとして添えて stdin で渡す
    session: new                      # new（--session-id を事前採番）| continue:<step>（その最新の session_id へ --resume）
    with: { issue: $inputs.issue }
    output: schemas/implement-result.json       # --json-schema に渡し（最上位の $schema は落とす）、structured_output をこのスキーマで検証する
    budget_usd: 15                    # --max-budget-usd = min(budget_usd, 残予算)
    timeout: 90m
    on:
      pass: commit
      deviation: { gate: design-deviation }
```

- `session_id` と付与した上限額は `claude` を起動する**前**にイベント（`step_started`）へ記録する（§4.4）。
- 費用は結果の `total_cost_usd` を unit の累計へ加える。`continue` の実行では `claude` がセッションの累計を報告するので、同じセッションの前回の報告との差を数える。**費用が得られない（フィールド欠落・数値でない・JSON でない・非 0 終了・timeout・中断・停止）実行は、付与した上限額を消費したものとして数え、`unknown_cost_count` を増やす**（fail-closed。Q15）。
- 残予算が `min(budget_usd, 0.25 USD)` を下回ったら起動せず、outcome を予約値 `budget_exhausted` にする（`on` に書かなければ run は `failed`）。

## `gate` 種類の書き方

```yaml
  review:
    kind: gate
    type: input                       # input: resume の --input の値が outcome
    decider: any                      # human | parent | any
    requested_action: PR のレビューを待つ。対応が要れば respond、マージしてよければ ready
    inputs: [respond, ready]
    on:
      respond: { goto: fix, with: { failure: $gate.note } }   # $gate.note は resume の --note（遷移の with でだけ読める）
      ready: merge
  human-merge:
    kind: gate
    type: observe                     # observe: resume のたびに登録された観測で外部の実状態を確かめ、その結果が outcome
    decider: human
    observe: pr-state                 # 観測は Go に登録する（pr-state は PR-4）。未登録の名前は validate が拒否する
    requested_action: 既定ブランチ宛 PR のマージは人が行う。マージ後に resume
    on: { merged: cleanup, open: { gate: human-merge }, closed: { fail: pr_closed } }
```

- ゲートに達すると unit のラウンドが閉じ、run は `waiting` になって `harness run` / `resume` は終了コード 3 で終わる（daemon は持たない）。
- `resume` はゲートを解決し、その遷移先から新しいラウンドを始める。閉じたラウンドのステップは再実行しない。run が開始時の定義から変わっていれば続けない（§7.3）。
- **端末（TTY）を要求するのは `type: input` かつ `decider: human` のゲートだけ**（Q9・N1）。`resume` はそれを解決できず `approve` を案内して止まる。`approve` は stdin が端末でなければ何も読まずに拒否し、端末なら対象の要約を表示して `yes` の入力を求める。解決の記録（`gate_resolved`）には `actor`（resume / approve）・`user`・`channel`（tty / non-tty）が残る。TTY の判定は「Claude が通常の道具立てで human ゲートを解決してしまうこと」を防ぐもので、疑似端末を作る（`script` 等）意図的な回避までは防げない（§5.3）。
- runner が落ちて止まったステップは組み込みの `interrupted` ゲート（`decider: any`・`rerun` / `abort`）で待つ。`rerun` はそのステップを新しいラウンドでやり直す。

## `select` 種類の書き方

```yaml
  e2e-route:
    kind: select
    value: $steps.analyze.e2e_target  # 参照 1 つ。参照先の出力スキーマで enum を持つ string（または $steps.<id>.outcome）
    on: { yes: e2e, no: publish }     # enum の値がそのまま outcome（一致だけ。比較・組み合わせは無い。Q12）
```

- 参照先のステップは、select へ至るどの経路でも先に成功していなければならない（validate が確かめる）。`$inputs`・`$edge`・`$gate.note` は選べない（enum が無い）。

## `workspace` 種類の書き方

```yaml
  workspace:
    kind: workspace
    action: acquire                   # provided | created | reused | conflict
    with: { issue: $inputs.issue, branch: $steps.analyze.branch, base: $steps.resolve.base, provided: $inputs.worktree }
    on: { provided: implement, created: implement, reused: implement, conflict: { fail: worktree_conflict } }
  cleanup:
    kind: workspace
    action: release                   # released | kept | dirty
    on: { released: { done: merged }, kept: { done: merged }, dirty: { done: merged_worktree_dirty } }
```

- `acquire`: `provided`（呼び出し元が渡した worktree。在るディレクトリ・作業ツリーの最上位・run を開始したリポジトリと同じリポジトリであることを確かめる）があれば `provided`。無ければ `plugin/scripts/worktree-setup.sh <issue> <branch> <base>` を呼んで `created` / `reused`。払い出し先が別ブランチの worktree・未登録のディレクトリ・別のリポジトリなら `conflict`。払い出しはプロセスの中で直列化する（スクリプトの mkdir ロックは第二層）。
- 払い出した後のステップ（`command`・`llm`・`pull-request`・observe 型ゲートの観測）は作業ツリーの中で動く（`release` の後は run を開始したディレクトリに戻る）。
- `release`: **この run が作ったものだけ**を `worktree-cleanup.sh <path> --skip-if-dirty` で消す（`released`）。「この run が作った」は、作ったときに作業ツリーの git dir へ書いた印（`claude-harness-owner`: run id と unit）で確かめる（払い出し先のパスは同じ Issue の run どうしで同じなので、パスだけでは判定しない）。呼び出し元の作業ツリーが base そのもの・detached なら `conflict`。呼び出し元が渡したもの・この run が作っていない再利用は消さない（`kept`）。未コミットの変更があれば消さない（`dirty`）。
- 出力（`$steps.<id>.worktree_path` 等）の形は Go が決める（`output` は書かない）。

## `pull-request` 種類の書き方

```yaml
  publish:
    kind: pull-request
    with:
      base: $steps.resolve.base       # 必須
      closes: $inputs.issue           # 必須（本文の Closes #N）
      title: $steps.implement.pr_title        # 必須（LLM が書くのは題名と要約だけ）
      summary: $steps.implement.summary       # 必須
      quality: $steps.implement.outcome       # pass | skip（skip は「未検証あり」と明記する。I7）
      residual_findings: $steps.implement.residual_findings   # 全件を転記する（件数へ丸めない。I13）
      unverified: $steps.implement.unverified
      cross_repo: $steps.implement.cross_repo_attestation
    on: { opened: ci, updated: ci }   # 出力: pr_number・pr_url・branch・head_sha
```

- 作業ブランチを `git push -u origin refs/heads/<branch>:refs/heads/<branch>` し、そのブランチの open な PR（fork からの同名ブランチの PR は除く）が在れば push だけで `updated`（本文は書き換えない。W4）、無ければ `gh pr create --body-file` で `opened`。作業ブランチが base そのもの・リポジトリの既定ブランチ・open な PR の base が違う・open な PR が複数、なら push せず／作らず `step_error`（fail-closed）。
- PR 本文（概要・品質ゲート・未検証・残指摘・クロスリポジトリ確証）は with の値から Go が決定的に作る。作った本文は run の `logs/<step>.<n>.body.md` に残る。
- observe 型ゲートの観測 `pr-state`（`with: { pr: <PR 番号> }`）は `gh pr view` で PR の実状態を確かめ、`merged` / `open` / `closed` を返す。

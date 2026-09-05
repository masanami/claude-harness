# quality-check-runner.sh の出力仕様（正本）

`scripts/quality-check-runner.sh [--auto-fix CMD]... [--lint CMD] [--typecheck CMD] [--test CMD]` の stdout JSON。呼び出し側スキル（`/quality-check`）はこの仕様を参照し、フィールド定義を複製しない。

コマンド特定（どのコマンドが lint/型チェック/テスト/auto-fix に当たるか）はプロジェクトごとに意味理解が必要なため呼び出し側（LLM）の責務。このスクリプトは特定済みのコマンド文字列を受け取り、実行して exit code で判定するだけで、コマンドの意味は解釈しない。各フラグは対応するコマンドが特定できなかった場合は省略してよい（`--auto-fix` は0回以上、`--lint`/`--typecheck`/`--test` は0または1回）。

## 渡せるコマンドの形（シェルを介さない）

**CMD はシェルへ渡さない**（Issue #223）。空白で argv に分解して直接実行する。`Bash(claude-harness-run:*)` を allow した利用側で、このスクリプトが settings.json の deny を迂回する任意コマンド実行の経路にならないようにするため。したがって:

- **シェル構文は使えない**（`;` `&&` `||` `|` `>` `<` `$(…)` `` ` `` クォート グロブ `~` など）。1文字でも含まれていれば**どのゲートも実行せずに** exit code 4 で拒否する（リテラルとして黙って実行することはしない）。複数手順を繋げたい場合は、プロジェクト自身のスクリプト（`package.json` の `scripts` / Makefile のターゲット等）にまとめ、その1コマンドを渡す
- **実行してよいコマンドは同梱の閉じた一覧に限る**。argv の先頭トークン列が `scripts/config/command-allowlist.txt` のエントリに一致しなければ、同じく exit code 4 で拒否する（`npm run …` ✅ / `rm -rf …` ❌）。`bundle exec` / `uv run` / `python3 -m` / `npx --no` のように**次のトークンが実行対象そのもの**になるエントリは「ラッパー」として扱い、**残りの argv も一覧に載っていること**を要求する（`bundle exec rspec` ✅ / `bundle exec rm -rf /` ❌）。一覧の拡張はそのファイルの編集だけで、環境変数・CLI フラグからは差し替えられない
- **環境変数の前置（`FOO=bar cmd`）は使えない**。`claude-harness-run --env FOO=bar …` を使う（ただし `PATH` 等、実行系の解決を変える変数はランチャー側で拒否される）
- 引数側に空白を含む値（`--filter "a b"` 等）は渡せない。必要ならプロジェクト側のスクリプトへ寄せる

> **この検査が保証する範囲**: 保証するのは「**呼び出し側が渡した1つの文字列だけで、事前準備なしに deny 対象コマンドへ到達できないこと**」であって、実行されるツールチェイン全体の安全性ではない。許可コマンドが起動する子プロセス（`npm run` が `package.json` の指示で呼ぶもの、`make` のレシピ等）には Claude の permission 判定が適用されない。また**一覧が照合するのはコマンド名**であり、名前から実体への写像は `PATH` が行う——`PATH` 上へ実行ファイルを置ける主体は許可名を差し替えられる（argv[0] は検証時に解決した絶対パスへ固定され、相対パスへの解決は拒否されるが、`PATH` 全体の汚染は防げない）。詳細は `docs/script-launcher.md`「6. このランチャーを allow することの意味」。

**exit code 4（拒否）は stdout に JSON を出さない**。品質が落ちた（`fail`）のでも未検証（`skip`）でもなく、**呼び出し方が契約に反している**状態であり、呼び出し側はコマンドを書き直して再実行する。理由と書き直し方は stderr に出る。判断の背景は `docs/script-launcher.md`「6. このランチャーを allow することの意味」。

stdout JSON:
```json
{
  "result": "pass" | "fail" | "skip",
  "auto_fix": { "applied": bool, "summary": "cmd1 → cmd2" },
  "gates": {
    "lint":      { "status": "pass"|"fail"|"skip", "errors": n|null, "warnings": n|null },
    "typecheck": { "status": "pass"|"fail"|"skip", "errors": n|null },
    "test":      { "status": "pass"|"fail"|"skip", "passed": n|null, "failed": n|null, "skipped": n|null }
  }
}
```

| フィールド | 型 / 値 | 意味 |
|---|---|---|
| `result` | `"pass"` \| `"fail"` \| `"skip"` | 優先順位 `fail` > `skip` > `pass` で判定する。`gates.*.status` のいずれかが `fail` なら `fail`。`fail` が無く**実行されたゲート（`skip` 以外）が1つも無い**なら `skip`（＝何も検査していない。下記「ゲートが1つも無い場合」）。それ以外（1つ以上実行され `fail` 無し）は `pass`。**既知の3値以外の `status`（判定不能）は `fail` 側へ倒す**（fail-closed） |
| `gates.*.status` | `"pass"` \| `"fail"` \| `"skip"` | **exit code のみ**で判定（0 → pass、非0 → fail）。対応フラグ未指定なら `skip` |
| `gates.lint.errors` / `.warnings`、`gates.typecheck.errors`、`gates.test.passed`/`.failed`/`.skipped` | 数値 \| `null` | ツール出力からの best-effort 抽出（ESLintの`X problems (Y errors, Z warnings)`、tscの`Found N errors.`、Jest/Vitest/pytestの`N passed`/`N failed`/`N skipped`等のパターンに対応）。**該当する集計行が複数ある場合は合算する**（下記「件数の集計方針」）。**抽出できない場合は `null`。`status` の判定には使わない** |
| `auto_fix.applied` | bool | `--auto-fix` が1つ以上指定されたか |
| `auto_fix.summary` | string | 実行した auto-fix コマンドを検出順に `" → "` 区切りで連結したもの |

## ゲートが1つも無い場合（`result: "skip"`）

`--lint` / `--typecheck` / `--test` が**すべて未指定（または空文字）**で、実行されたゲートが1つも無い場合は、`result` を `"pass"` ではなく **`"skip"`**（exit code 3）とする。`gates.*` はすべて `status: "skip"` のままで、stdout のJSONは通常どおり出力される。

- **理由**: 全ゲート skip を `pass`（exit 0）にすると、呼び出し側がフラグを渡し忘れた場合に**何も検査していないのに品質チェックが成功したと報告される**（Issue #192。必須ゲートという安全網が素通りする）。「1つも実行していない」は「全ゲート通過」ではない
- **`fail` ではなく専用の `skip` にした理由**: `fail`（exit 1）にすると、実際に lint / 型 / テストが落ちた状態と区別できない。呼び出し側の失敗分析（`gates.*.status == "fail"` を読んで原因を提示する経路）が、分析対象の無い fail を受け取ることになる。**未検証は「検査して落ちた」とは別の状態**として返し、呼び出し側に別扱いを強制する
- **exit code を非0（3）にした理由**: exit code しか見ない呼び出し側（`if runner …; then` 形）にも成功と読ませないため。0（pass）・1（fail / CLI引数不正）・2（jq不在）と重ならない値を割り当てている
- **`--auto-fix` はゲート数に数えない**: auto-fix は「機械的に直せる範囲を直す」手続きであって検査ではないため、`--auto-fix` だけを指定した実行も `result: "skip"` になる（`auto_fix.applied` は `true` のまま）
- **一部のゲートだけが skip の場合は従来どおり `pass`**: 型チェックの無いプロジェクトのように、対応するコマンドが存在しないゲートを省略する呼び出しは正当な構成であり、後方互換を保つ。区別するのは**「1つも実行していない」場合だけ**（どのゲートが実行されなかったかは `gates.*.status` で判別できる）

## 件数の集計方針

npm workspaces・cargo のように**1回の実行で集計行が複数回出力される**ツールチェインでは、最後の1行だけを採用すると実態と乖離する（Issue #154 の実測: 934 tests に対し最後のワークスペース分の `246` を報告していた）。このため**該当する集計行をすべて合算**する。二重計上を避けるため、対象行は次の優先順位で絞り込む:

| ゲート | 優先して集計する行（在る場合） | 無い場合 |
|---|---|---|
| test | 複数形 `Tests` の直後に `:` または空白が続く集計行（Jest の `Tests:` 行、Vitest の `Tests` 行）。単数形の `Test Suites:` / `Test Files` はスイート数なので除外される | 件数パターンを含む全行を合算（pytest の `M passed, N failed`、cargo の `test result: ok. N passed; …` 等） |
| lint | `N problems` を含む集計行（ESLint）。個別の指摘行は除外される | 件数パターンを含む全行を合算 |
| typecheck | `Found N errors` を含む集計行（tsc）のみ。個別の型エラー行は常に除外される | （該当行が無ければ `null`） |

- 単一ワークスペースの出力では従来と同じ値になる（合算対象が1行のため）
- **既知の限界**: 集計行を持つツールと持たないツールが混在する多言語モノレポでは、集計行を持つ側のみが合算される。また上位ツール（turbo 等）が各ワークスペースの集計に加えて総計を出力する形式では二重計上しうる。件数はあくまで参考値であり、**合否判定（`status` / `result`）は exit code のみで行う**ため、この誤差が判定を変えることはない

挙動の要点:

- auto-fix → lint → 型チェック → テストの順に実行する。**前段の失敗で後段をスキップしない**（全ゲートの結果を返す）
- auto-fix コマンドが失敗（非0 exit）しても致命的エラーとはせず、警告を stderr に出して次のコマンドへ進む（機械的に直せる範囲を適用する手続きであり、型エラー・テスト失敗の修正は対象外のため）
- 各コマンドの生の stdout/stderr（`--- <gate>: <cmd> ---` 区切り）は **stderr に転記**する。コマンドが `PATH` 経由で解決された場合は、その直後に `--- <gate> resolved: <絶対パス> ---` を出す（どの実体が起動されたかを事後に追えるようにするため。シェル組み込み・明示パスの場合は出ない）。件数抽出で丸められる詳細（lintエラー箇所・型エラー内容・失敗テストのスタックトレース等）を、失敗時に呼び出し側が原因分析するために使う
- 終了コード: `result` が `pass` なら 0、`fail` なら 1、`skip` なら 3。jq 不在は 2、CLI引数不正（未知フラグ・値欠落・`--lint`/`--typecheck`/`--test` の重複指定）は 1、**コマンドの形が契約に反する場合（シェル構文を含む／allowlist に無い実行系）は 4**（いずれも個別メッセージは stderr）。**exit 2（jq不在）の場合は stdout にJSONが出力されない**ため、呼び出し側は exit code を先に確認してから stdout をJSONとしてパースすること（**exit 3 の場合は stdout にJSONが出力される**）
- `--lint`/`--typecheck`/`--test` はそれぞれ1回のみ指定可（`--auto-fix` は0回以上）。重複指定は無言の上書きを避けるため exit 1 のエラーとする
- bash 3.2（macOS既定）の `set -u` 下での空配列展開の互換性に配慮した実装になっている（`${arr[@]+"${arr[@]}"}` イディオム）

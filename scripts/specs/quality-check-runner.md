# quality-check-runner.sh の出力仕様（正本）

`scripts/quality-check-runner.sh [--auto-fix CMD]... [--lint CMD] [--typecheck CMD] [--test CMD]` の stdout JSON。呼び出し側スキル（`/quality-check`）はこの仕様を参照し、フィールド定義を複製しない。

コマンド特定（どのコマンドが lint/型チェック/テスト/auto-fix に当たるか）はプロジェクトごとに意味理解が必要なため呼び出し側（LLM）の責務。このスクリプトは特定済みのコマンド文字列を受け取り、実行して exit code で判定するだけで、コマンドの意味は解釈しない。各フラグは対応するコマンドが特定できなかった場合は省略してよい（`--auto-fix` は0回以上、`--lint`/`--typecheck`/`--test` は0または1回）。

stdout JSON:
```json
{
  "result": "pass" | "fail",
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
| `result` | `"pass"` \| `"fail"` | `gates.*.status` のいずれかが `fail` なら `fail`、それ以外（全て `pass`/`skip`）は `pass` |
| `gates.*.status` | `"pass"` \| `"fail"` \| `"skip"` | **exit code のみ**で判定（0 → pass、非0 → fail）。対応フラグ未指定なら `skip` |
| `gates.lint.errors` / `.warnings`、`gates.typecheck.errors`、`gates.test.passed`/`.failed`/`.skipped` | 数値 \| `null` | ツール出力からの best-effort 抽出（ESLintの`X problems (Y errors, Z warnings)`、tscの`Found N errors.`、Jest/Vitest/pytestの`N passed`/`N failed`/`N skipped`等のパターンに対応）。**該当する集計行が複数ある場合は合算する**（下記「件数の集計方針」）。**抽出できない場合は `null`。`status` の判定には使わない** |
| `auto_fix.applied` | bool | `--auto-fix` が1つ以上指定されたか |
| `auto_fix.summary` | string | 実行した auto-fix コマンドを検出順に `" → "` 区切りで連結したもの |

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
- 各コマンドの生の stdout/stderr（`--- <gate>: <cmd> ---` 区切り）は **stderr に転記**する。件数抽出で丸められる詳細（lintエラー箇所・型エラー内容・失敗テストのスタックトレース等）を、失敗時に呼び出し側が原因分析するために使う
- 終了コード: `result` が `pass` なら 0、`fail` なら 1。jq 不在は 2、CLI引数不正（未知フラグ・値欠落・`--lint`/`--typecheck`/`--test` の重複指定）は 1（個別メッセージは stderr）。**exit 2（jq不在）の場合は stdout にJSONが出力されない**ため、呼び出し側は exit code を先に確認してから stdout をJSONとしてパースすること
- `--lint`/`--typecheck`/`--test` はそれぞれ1回のみ指定可（`--auto-fix` は0回以上）。重複指定は無言の上書きを避けるため exit 1 のエラーとする
- bash 3.2（macOS既定）の `set -u` 下での空配列展開の互換性に配慮した実装になっている（`${arr[@]+"${arr[@]}"}` イディオム）

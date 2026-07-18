# scripts/ 共通規約

`scripts/` 配下の gh 系（GitHub CLI を叩いて決定的な処理を行う）スクリプトが従う共通規約。最初の実例は `format-on-save.sh`（フック）と `extract-acceptance-criteria.sh`（gh 系スクリプト第1号）。後続スクリプトは本規約に従うこと。`check-e2e-traceability.sh` は `extract-acceptance-criteria.sh` の出力とテストケース設計のトレーサビリティ表JSONを突合する後続スクリプトの実例（gh を呼ばず jq のみで完結する純粋処理）。

プラグイン内ファイル参照（Bash実行・Read・サブエージェント受け渡し等）のパス解決規約は `docs/plugin-path-conventions.md` を参照。本ファイルは scripts/ 配下の実装規約のみを扱う。

## 前提

- bash + jq を前提とする
- jq 不在時のフォールバック方針は `format-on-save.sh` の防御的スタイルを踏襲する
  - フックのように「機能をスキップしても実害が小さい」処理は、jq 無しでも簡易パース（`sed` 等）で動かしてよい
  - `extract-acceptance-criteria.sh` のように JSON 構築そのものが本質のスクリプトは jq 必須とし、**jq 不在時は明示的なエラー JSON を stderr に併記した上で exit 非0**（無言でクラッシュしない・スタックトレースを吐かない）

## 出力規約

- **stdout には JSON を1個だけ出力する**。人間向けメッセージ（進捗・エラー詳細）は stderr に出す
- 成否は **exit code** で表現する。加えて JSON 側にも機械可読なステータスフィールドを含め、呼び出し元が exit code とJSONの両方から判定できるようにする
- 「特定できなかった」「対象外だった」は暗黙の空配列・空文字ではなく、**明示的なステータスフィールド**で返す（例: `parse_status: "no_checklist_found"`）。呼び出し側の LLM がこれを見てフォールバック挙動（別手段での抽出など）を判断できるようにするため

## quality-check との整合

`skills/quality-check/SKILL.md` の機械可読 JSON（`{result, auto_fix, gates:{lint:{status,errors,...}, ...}}`）と同じ思想＝**機械可読ステータス（exit code / JSON フィールド）と人間向け詳細（stderr メッセージ）を分離する**、という設計を踏襲する。

## テスト

- gh API 等の外部呼び出しを行う処理と、入力（本文テキスト等）から出力（JSON）を組み立てる純粋なパース処理は**関数として分離**する
- パース関数はスクリプトを `source` して直接呼び出すことで、外部コマンドを叩かずに単体テストできる作りにする
- テストは `scripts/tests/` 配下に bash スクリプトとして置き、`bash scripts/tests/xxx.sh` で実行できるようにする。失敗時は非0 exit で終了し、要約を出力する
- スクリプトを `source` するテストファイルは、スクリプト側が定義するグローバル変数（例: `SCRIPT_DIR`）と名前が衝突しないよう注意する。衝突すると `source` 時にテスト側の変数が上書きされる。スクリプト側は極力スクリプト固有の変数名（例: `PR_MERGE_PREFLIGHT_DIR`）を使う
- 外部呼び出し関数をテストからスタブ関数で上書きする場合、`command_substitution="$(fn)"` 経由の呼び出しはサブシェルで実行されるため、スタブ内でのプレーンな変数インクリメントは呼び出し元へ伝搬しない（戻り値/stdout は伝搬する）。呼び出し回数などをテストで検証したい場合は一時ファイル等サブシェルを跨げる手段を使う

## 設定ファイル

- 特定スクリプトが参照する設定の正本（例: sensitive パスパターン）は `scripts/config/` 配下に置く
  - `scripts/config/sensitive-paths.txt`: `pr-merge-preflight.sh` の risk 判定（`touches_sensitive`）が参照する glob パターン一覧。1行1パターン、`#` はコメント行。ファイルが無い場合はスクリプト内蔵のデフォルトにフォールバックする

## pr-merge-preflight.sh の出力仕様（正本）

`scripts/pr-merge-preflight.sh <PR番号> [ポーリング上限秒]` の stdout JSON。呼び出し側スキル（`/pr-merge`）はこの仕様を参照し、フィールド定義を複製しない。

| フィールド | 型 / 値 | 意味 |
|---|---|---|
| `gate` | `"production"` \| `"integration"` | base = 既定ブランチなら production（人間承認必須）、それ以外は integration（自律マージ可） |
| `base` / `default_branch` | string | PR の base とリポジトリ既定ブランチ。ブランチ構成由来のため再実行でも不変 |
| `ci` | `{status: "pass"\|"fail"\|"pending"\|"none", checks: [...]}` | CI チェックの集約。`cancel` 系は fail 扱い |
| `mergeable` | `"MERGEABLE"` \| `"CONFLICTING"` \| `"UNKNOWN"` | GitHub の mergeable 判定 |
| `reviews` | `[{author, state}]` | レビュー一覧（ポーリング待機後の最新状態） |
| `commented_bodies` | `[string]` | `COMMENTED` レビューの本文一覧。**重大性の意味判断はスクリプトでは行わない**（呼び出し側 LLM の責務） |
| `blocking` | bool | 下記 `block_reasons` が1つでもあれば true |
| `block_reasons` | 配列 | `changes_requested`（reviewDecision ベース。stale な過去レビューでは立たない）/ `ci_failed` / `conflicting` / `merge_blocked`（branch protection の必須条件未達）の部分集合 |
| `risk` | `{files_changed, insertions, deletions, touches_sensitive}` | 変更規模と sensitive パス接触。パターン正本は `scripts/config/sensitive-paths.txt` |

挙動の要点:

- 外部レビュー未投稿時は既定 60 秒間隔・最大約10分のポーリングを**スクリプト内で**待機する（第2引数で上書き可）
- ポーリング完了後に checks / mergeable / files を**再取得**してから判定する（ポーリング前のスナップショットで判定しない）
- 致命的エラー（jq 不在・PR 不存在等）は stderr にメッセージを出し exit 非0（出力規約どおり）
- **取得しないもの**: PR の title / body / 会話タブのコメント。これらは意味判断の材料であり、呼び出し側スキルが必要なフェーズで取得する

## quality-check-runner.sh の出力仕様（正本）

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
| `gates.lint.errors` / `.warnings`、`gates.typecheck.errors`、`gates.test.passed`/`.failed`/`.skipped` | 数値 \| `null` | ツール出力からの best-effort 抽出（ESLintの`X problems (Y errors, Z warnings)`、tscの`Found N errors.`、Jest/Vitest/pytestの`N passed`/`N failed`/`N skipped`等のパターンに対応）。**抽出できない場合は `null`。`status` の判定には使わない** |
| `auto_fix.applied` | bool | `--auto-fix` が1つ以上指定されたか |
| `auto_fix.summary` | string | 実行した auto-fix コマンドを検出順に `" → "` 区切りで連結したもの |

挙動の要点:

- auto-fix → lint → 型チェック → テストの順に実行する。**前段の失敗で後段をスキップしない**（全ゲートの結果を返す）
- auto-fix コマンドが失敗（非0 exit）しても致命的エラーとはせず、警告を stderr に出して次のコマンドへ進む（機械的に直せる範囲を適用する手続きであり、型エラー・テスト失敗の修正は対象外のため）
- 各コマンドの生の stdout/stderr（`--- <gate>: <cmd> ---` 区切り）は **stderr に転記**する。件数抽出で丸められる詳細（lintエラー箇所・型エラー内容・失敗テストのスタックトレース等）を、失敗時に呼び出し側が原因分析するために使う
- 終了コード: `result` が `pass` なら 0、`fail` なら 1。jq 不在は 2、CLI引数不正（未知フラグ・値欠落・`--lint`/`--typecheck`/`--test` の重複指定）は 1（個別メッセージは stderr）。**exit 2（jq不在）の場合は stdout にJSONが出力されない**ため、呼び出し側は exit code を先に確認してから stdout をJSONとしてパースすること
- `--lint`/`--typecheck`/`--test` はそれぞれ1回のみ指定可（`--auto-fix` は0回以上）。重複指定は無言の上書きを避けるため exit 1 のエラーとする
- bash 3.2（macOS既定）の `set -u` 下での空配列展開の互換性に配慮した実装になっている（`${arr[@]+"${arr[@]}"}` イディオム）
## extract-acceptance-criteria.sh / check-e2e-traceability.sh の入出力仕様（正本）

`skills/create-e2e/SKILL.md`（Step 1-1, Step 1-3）はこの仕様を参照し、フィールド定義を複製しない。

### extract-acceptance-criteria.sh

`scripts/extract-acceptance-criteria.sh <issue番号>` または `scripts/extract-acceptance-criteria.sh --stdin` の stdout JSON。

| フィールド | 型 / 値 | 意味 |
|---|---|---|
| `issue` | number \| null | Issue番号。`--stdin` 呼び出し時は null |
| `criteria` | `[{id, text, checked}]` | 抽出したチェックリスト項目。`id` は `AC-1` 形式の通しID、`checked` は bool |
| `parse_status` | `"ok"` \| `"no_checklist_found"` | チェックリストを1件でも抽出できたか |

挙動の要点:

- 使い方は2通り。`<issue番号>` 指定時は `gh issue view <issue番号> --json body` で本文を取得してパースする。`--stdin` 指定時は stdin から本文テキストを読み込んでパースする（gh を呼ばない。`issue` は null）
- 抽出対象は Issue本文の「## 受入基準」または「## 完了条件」セクション配下の `- [ ]` / `- [x]` チェックリスト行（インデント付きのネスト行は対象外）
- 両セクションが同一本文に存在する場合は連番で通しIDを振る
- チェックリストが1件も見つからない場合は `parse_status: "no_checklist_found"` を返す（exit 0、エラー終了しない）
- gh 呼び出し自体の失敗・jq 不在など真の異常系は stderr にメッセージを出し exit 非0 で終了する

### check-e2e-traceability.sh

`scripts/check-e2e-traceability.sh <criteria_json_file|-> <trace_json_file|->` の stdout JSON。第1引数は `extract-acceptance-criteria.sh` の出力JSON、第2引数はテストケース設計のトレーサビリティ表JSON（`{"cases": [{"name": "...", "class": "正常系", "criteria": ["AC-1", "AC-2"]}]}`）。いずれもファイルパスまたは `-` でstdin指定できるが、両方同時に `-` は不可。

| フィールド | 型 / 値 | 意味 |
|---|---|---|
| `uncovered` | `[{id, text}]` | criteria側にあり、どのテストケースにも紐づいていない完了条件 |
| `unknown_ids` | `[string]` | テストケース側が参照しているが criteria側に存在しないID（幻覚ID） |
| `status` | `"ok"` \| `"issues_found"` \| `"no_criteria"` | 突合結果の要約 |

`status` の意味:

- `no_criteria`: criteria側の `parse_status` が `no_checklist_found`、または `criteria` 配列が空（「未カバー」概念自体が成立しない）。`uncovered`/`unknown_ids` は空配列
- `ok`: `uncovered`・`unknown_ids` ともに空
- `issues_found`: いずれかが非空

挙動の要点:

- exit code は「チェックが正常に実行できたか」を表す。`issues_found` は検知の正常動作なので exit 0
- 真の異常系（jq不在、入力ファイル不存在、不正JSON、必須キー欠如、両方stdin指定等）は stderr にメッセージを出し exit 非0

# scripts/ 共通規約

`scripts/` 配下の gh 系（GitHub CLI を叩いて決定的な処理を行う）スクリプトが従う共通規約。最初の実例は `format-on-save.sh`（フック）と `extract-acceptance-criteria.sh`（gh 系スクリプト第1号）。後続スクリプトは本規約に従うこと。`check-e2e-traceability.sh` は `extract-acceptance-criteria.sh` の出力とテストケース設計のトレーサビリティ表JSONを突合する後続スクリプトの実例（gh を呼ばず jq のみで完結する純粋処理）。`collect-review-diff.sh` / `extract-hunk.sh` は、`/self-review`（`skills/self-review/SKILL.md`）が LLM 判断を要さない決定的な git/テキスト処理をレビューの各ラウンドで直接呼び出す実例（Issue #44・#107）。`spec-lint.sh` は同様のパターンで `/define-feature`（`skills/define-feature/SKILL.md` Step 6.5-1）が Bash ツールから直接呼び出す、gh非依存の決定的チェックスクリプトの実例（Issue #51で新設、#111 で Dynamic Workflow・git-ops エージェント経由の委譲を廃止し呼び出し元自身の直接実行に一本化した）。`mutation-run.sh` は `/explain-e2e`（`skills/explain-e2e/SKILL.md` Phase 2）が、呼び出し元自身の Bash ツールから直接呼び出す、gh非依存の決定的な git/テスト実行スクリプトの実例（Issue #47・#114）。`fetch-pr-comments.sh` / `reply-and-resolve.sh` は `/pr-review-respond`（`skills/pr-review-respond/SKILL.md`）が、PRレビューコメントの取得（Step 2）・返信・Resolved化（Step 12）のタイミングで Bash ツールから直接呼び出す実例（Issue #48。Issue #108 で Dynamic Workflow・git-ops エージェント経由の委譲を廃止し、呼び出し元自身の直接実行に一本化した）。`ci-wait.sh` / `worktree-setup.sh` / `worktree-cleanup.sh` は para-impl の star型並列実装が呼び出す、CI待ち・worktree作成・worktree削除を担う実例（Issue #45・#105。`ci-wait.sh` は `ticket-worker` が、`worktree-setup.sh`/`worktree-cleanup.sh` はリード側スキルが呼ぶ。gh系スクリプトだが LLM 判断を挟まない決定的処理としてスキルフローから直接実行される）。

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
- git操作そのものを検証する必要があるスクリプト（`collect-review-diff.sh` 等）は、gh呼び出しのみ引数明示でスキップし、git操作は `mktemp -d` で作った一時gitリポジトリ上で実際に実行して検証する（モックでは merge-base 算出やintent-to-addの実効果を検証できないため）。テスト終了時は `trap cleanup EXIT` で一時ディレクトリを確実に削除する

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

## collect-review-diff.sh / extract-hunk.sh の出力仕様（正本）

`/self-review`（`skills/self-review/SKILL.md`）が、レビューの各ラウンド開始時にこの2スクリプトを Bash ツールで直接呼び出す（LLM 判断を要さない決定的な git/テキスト処理のため。Issue #107 で Dynamic Workflow・git-ops エージェント経由の委譲を廃止し、呼び出し元自身の直接実行に一本化した）。

### `scripts/collect-review-diff.sh [BASE]`

| フィールド | 型 | 意味 |
|---|---|---|
| `base` | string | 解決されたBASEブランチ名。引数省略時は `gh pr view --json baseRefName` → `gh repo view --json defaultBranchRef` の順にフォールバック解決される |
| `merge_base` | string | `git merge-base origin/<base> HEAD`（またはローカル `<base>`）で算出したコミットSHA |
| `commits` | `[string]` | `merge_base..HEAD` の `git log --oneline` 相当 |
| `files` | `[string]` | `merge_base` から**作業ツリー込み**で変更されたファイル一覧（未追跡の新規ファイルを含む） |
| `diff_file` | string | `merge_base` から作業ツリー込みのunified diff本文を書き出した一時ファイルの絶対パス |

挙動の要点:

- レビュー対象diffの基準は「merge-base → 作業ツリー」に統一されている（Issue #44 クリティカル設計決定）。修正エージェントはコミットしない設計のため、毎周本スクリプトを呼び直すことで行番号のズレに追従する
- 未追跡ファイルは `git diff` のデフォルト挙動では検出されないため、diff採取前に `git add --intent-to-add -A` を実行し、新規ファイルもdiffに含める（内容はワーキングツリー側に残ったまま、追跡対象フラグのみが立つ）
- gh呼び出しの失敗・jq不在・git操作の失敗は stderr にメッセージを出し exit 非0

### `scripts/extract-hunk.sh <diff_file> <file> <line> [context_lines=3]`

| フィールド | 型 | 意味 |
|---|---|---|
| `file` / `line` | string / integer | 入力の値をそのまま返す |
| `found` | bool | 指定行を含むhunkが見つかったか |
| `snippet` | string | 該当hunk（＋前後 `context_lines` 行）。`found: false` の場合は最も近いhunk（無ければ空文字） |

gh/gitを呼ばない純粋なテキスト処理のみで完結する（diff_fileの中身だけを見る）。呼び出し元（`finding-verifier`）には Read/Grep を残しており、本スクリプトの一次スライスで不十分な場合は懐疑者自身がファイルを読みに行く設計を前提とする。

## spec-lint.sh の出力仕様（正本）

`/define-feature`（`skills/define-feature/SKILL.md` Step 6.5-1）が、Lint フェーズで Bash ツールから直接このスクリプトを呼び出す（Issue #51で新設、#111 で Dynamic Workflow・git-ops エージェント経由の委譲を廃止し呼び出し元自身の直接実行に一本化した）。機能仕様ドキュメント（`docs/features/{slug}.md`）に対する4つの決定的チェックの候補列挙のみを行い、**severity（blocker/minor/needs_user_input）の判定は行わない**（severity判定は呼び出し元の批評エージェント `agents/spec-critic.md` の責務）。gh呼び出しは一切行わない（gh非依存）。

### `scripts/spec-lint.sh <spec-file-path>`

stdout JSON:
```json
{
  "spec_file": "<入力パス>",
  "ambiguous_words": [{"line": 1, "word": "適切に", "text": "..."}],
  "template_placeholders": [{"line": 1, "text": "{採用案}"}],
  "broken_references": [{"line": 1, "path": "docs/foo.md", "exists": false}],
  "checklist_format_issues": [{"line": 1, "section": "機能要件", "text": "..."}]
}
```

| フィールド | 型 | 意味 |
|---|---|---|
| `spec_file` | string | 入力パスそのまま |
| `ambiguous_words` | `[{line, word, text}]` | スクリプト内蔵の単一定義の曖昧語辞書（「適切に」「必要に応じて」「など」「等」「柔軟に」等）でのマッチ候補。1行に複数語がマッチした場合は複数エントリを返す |
| `template_placeholders` | `[{line, text}]` | `{...}`（中身が空でない）形式のテンプレートプレースホルダ残骸の候補 |
| `broken_references` | `[{line, path, exists}]` | 本文中のバッククォート囲み（`` `path/to/file` `` 形式）のパス参照のうち、`/` を含み `{` `}` を含まないものを対象に、spec ファイルの位置から `git rev-parse --show-toplevel` で解決したリポジトリルート起点で存在確認した結果。**存在しないパスのみ**を返す（`exists` は常に `false`）。**URIスキーム付き文字列**（`https:` `http:` `mailto:` 等。`^[A-Za-z][A-Za-z0-9+.-]*:` にマッチするもの）と**`/` で始まる絶対パス**は対象外として存在確認前に除外する（誤検出防止） |
| `checklist_format_issues` | `[{line, section, text}]` | 「## 機能要件」「## 受入基準」セクション（次の `## ` 見出しまで）配下のリスト項目（`- ` 始まり）のうち、`- [ ] ` / `- [x] ` / `- [X] ` 形式になっていない行 |

挙動の要点:

- 4検査それぞれが `detect_ambiguous_words` / `detect_template_placeholders` / `detect_broken_references` / `detect_checklist_format_issues` として関数分離されており、スクリプトを `source` すれば直接テストできる（`extract-acceptance-criteria.sh` のパターンを踏襲）
- `broken_references` のリポジトリルート解決（`resolve_repo_root`）は、spec ファイルの位置から `git rev-parse --show-toplevel` を試み、失敗した場合（gitが使えない・リポジトリ外）は spec ファイルのディレクトリにフォールバックする（エラーにはしない）
- jq不在時は stderr にエラーメッセージ + エラーJSONを出し exit 非0（本ファイル冒頭の出力規約に従う）
- 入力ファイルが存在しない場合も stderr にメッセージを出し exit 非0

## mutation-run.sh の出力仕様（正本）

`/explain-e2e`（`skills/explain-e2e/SKILL.md` Phase 2）の Mutation 段階から、呼び出し元自身（Bash ツール）が直接このスクリプトを呼び出す（Issue #47・#114。#114 で Dynamic Workflow・git-ops エージェント経由の委譲を廃止し、呼び出し元自身の直接実行に一本化した）。「意味のある不具合を注入する」判断のみを変異エージェント（`agents/e2e-mutation-injector.md`）に残し、それ以外の全手順（テスト実行・失敗判定・`git checkout --` による復元・復元確認・再実行パス確認）を決定的に行う。

### `scripts/mutation-run.sh <test_command> <mutated_file_1> [<mutated_file_2> ...]`

stdout JSON:
```json
{"testFailed": true, "failureKind": "assertion", "restored": true, "rePassed": true}
```

| フィールド | 型 | 意味 |
|---|---|---|
| `testFailed` | bool | `test_command`（`bash -c` で実行）の終了コードが非0だったか |
| `failureKind` | `"assertion"` \| `"other"` \| `"none"` | `testFailed: false` なら `"none"`。`true` の場合、テスト出力からアサーション起因の失敗らしいかをbest-effortでテキスト判定する（`AssertionError` / `expect(` / `Expected...Received` 等のパターンにマッチすれば `"assertion"`、しなければ `"other"`） |
| `restored` | bool | `git checkout -- <mutated_file_*>` 実行後、`git status --porcelain -- <mutated_file_*>` が空になったか |
| `rePassed` | bool | `restored: true` の場合のみ `test_command` を再実行し、終了コードが0だったか（`restored: false` の場合は再実行そのものをスキップし常に `false`） |

挙動の要点:

- **手順0（クリーン確認）**: `git status --porcelain`（リポジトリ全体）の変更が `mutated_file_*` の範囲内に完全に収まっているかを検証する。範囲外の未コミット変更が1件でもあれば、`git checkout -- <files>` では作業ツリーを完全にクリーンへ戻せない前提が崩れるため、**テスト実行に進まず**真の異常系として stderr にメッセージを出し exit 非0（stdoutにJSONは出さない）。`mutated_file_*` のいずれにも変更が無い場合（注入が実際には行われていない）も同様に異常系として扱う
- **`mutated_file_*` の形式**: 絶対パス・リポジトリルート相対パスのいずれで渡してもよい（呼び出し契約上、変異エージェントは常に絶対パスを返す。`agents/e2e-mutation-injector.md`）。`git status --porcelain`（引数無し）が返すパスは常にリポジトリルート相対のため、手順0の比較専用にリポジトリルート相対へ正規化してから照合する（`normalize_to_repo_relative`）。加えて、渡されたパスがシンボリックリンク経由（例: macOS の `/tmp` → `/private/tmp`、`/var` → `/private/var`。`mktemp -d` の返り値が該当しうる）の場合に備え、比較前に `cd "$(dirname ...)" && pwd -P` で実体パスへ解決してから正規化する（`canonicalize_path`）。`git checkout --`/`git status --porcelain -- <file>` 自体は元の引数（絶対パスのまま）で実行する（git はパススペックとして絶対パスをそのまま受け付けるため変換不要）
- **手順1〜4**は上記チェックを通過した後にのみ実行する（テスト実行＋失敗判定 → 復元 → 復元確認 → 復元できた場合のみ再実行してパス確認）
- 終了コード: `0`（`restored && rePassed`。復元・再パスとも確認できた「安全な」状態）／ `1`（`restored`/`rePassed` のいずれかが `false`。前段の真の異常系＝クリーン確認失敗・引数不正・非gitリポジトリ等も同じ `1` だが、その場合は stdout にJSONを出さない点で区別できる）／ `2`（jq不在）。呼び出し側（`/explain-e2e` の SKILL.md Phase 2）は、この終了コードと JSON の `restored`/`rePassed` 自己申告を突き合わせることで、誤報告を検出できる
- gh は呼ばない（gh非依存）。`test_command` は呼び出し側が特定済みの文字列をそのまま `bash -c` で実行するだけで、コマンドの意味は解釈しない（`quality-check-runner.sh` の `run_command` と同じ設計）
- テスト容易性のため、外部コマンド（git/`test_command`）を起動する処理と、外部コマンドを起動しない純粋なテキスト処理（`porcelain_path` / `classify_failure_kind` / `check_dirty_scope` / `normalize_to_repo_relative`）を関数として分離している（`source` して直接テスト可能）。`canonicalize_path`（実ファイルシステムを参照する `cd`/`pwd -P`）はこの分離の対象外（副作用ありの外部コマンド実行側に置く）

## collect-promotion-context.sh / check-subtask-completion.sh の出力仕様（正本）

`/promote-verify`（`skills/promote-verify/SKILL.md`）が、Step 3（コンテキスト収集）でこの2スクリプトを Bash ツールから直接呼び出す（Issue #52。Issue #110 で Dynamic Workflow・git-ops エージェント経由の委譲を廃止し、呼び出し元自身の直接実行に一本化した）。`skills/promote-verify/SKILL.md` はこの仕様を参照し、フィールド定義を複製しない。

### `scripts/collect-promotion-context.sh <base_branch> <integration_branch>`

`collect-review-diff.sh` と同じ設計思想（gh非依存・純粋な git 操作・関数分離によるテスト容易性・diff本文は一時ファイル書き出し）で、base ブランチと統合ブランチの間の three-dot diff コンテキストを取得する。

stdout JSON:
```json
{
  "base": "main",
  "integration": "feat/issue-52-promotion-verify",
  "merge_base": "<sha>",
  "diff_stat": "path/a.js | +12 -3\n...",
  "name_status": [{"status": "M", "path": "path/a.js"}],
  "diff_file": "/path/to/tmpfile"
}
```

| フィールド | 型 | 意味 |
|---|---|---|
| `base` / `integration` | string | 引数にそのまま渡した値（解決前のブランチ名） |
| `merge_base` | string | `git merge-base <base_ref> <integration_ref>` で算出したコミットSHA |
| `diff_stat` | string | `git diff --stat <base_ref>...<integration_ref>`（three-dot）の出力 |
| `name_status` | `[{status, path, oldPath?}]` | `git diff --name-status <base_ref>...<integration_ref>` をJSON配列へパースしたもの。rename等の3カラム行は `oldPath` を伴う |
| `diff_file` | string | `git diff <base_ref>...<integration_ref>` の出力全体を書き出した一時ファイルの絶対パス |

挙動の要点:

- ref解決（`resolve_ref`）は `collect-review-diff.sh` の `resolve_base_ref` と同じフォールバック方式（`origin/<name>` が解決できなければ `<name>`（ローカルブランチ）にフォールバック）を、base/integration 両方の引数に使い回せるよう汎用化したもの
- `git fetch origin` は `fetch_origin` 関数に分離され、`main()` からのみ呼ばれる。best-effort（失敗しても stderr に警告を出すのみで処理を継続する）
- jq不在・git操作の失敗は stderr にメッセージを出し exit 非0

### `scripts/check-subtask-completion.sh <parent_issue_number>`

親Issueの全子Issueがマージ済みかを機械的に判定する。

stdout JSON:
```json
{
  "parent": 52,
  "source": "sub_issues_api",
  "status": "ok",
  "children": [{"number": 60, "title": "...", "state": "CLOSED", "mergedPr": 61}],
  "allMerged": true
}
```

| フィールド | 型 | 意味 |
|---|---|---|
| `source` | `"sub_issues_api"` \| `"parent_label_fallback"` | 子Issue一覧の取得経路。GitHub Sub-issues API を優先し、失敗（404等）または空配列の場合は本文 `Parent: #<parent>` 検索にフォールバックする |
| `status` | `"ok"` \| `"no_children_found"` | 子Issueが1件も見つからなかった場合は `no_children_found`。この場合 `children` は空配列、`allMerged` は暗黙にtrueにせず常に `false`（空集合に対する論理的な真=trueの罠を避ける安全側の設計） |
| `children[].mergedPr` | integer \| null | その子Issueをcloseした merged PR の番号（`gh search prs --state merged` で検索した最初の1件）。見つからなければ `null` |
| `allMerged` | bool | `children` が非空、かつ全要素が `state == "CLOSED"` かつ `mergedPr` が非nullの場合のみ `true` |

挙動の要点:

- gh を呼ぶ関数（`resolve_repo`/`fetch_sub_issues_json`/`fetch_fallback_issues_json`/`fetch_merged_pr_number`）と、生JSONから出力を組み立てる純粋関数（`normalize_sub_issues_json`/`normalize_fallback_issues_json`/`build_child_entry`/`compute_all_merged`）を分離している。テストから gh 呼び出し関数をスタブ関数で上書きして main() 全体の分岐を検証できる（`fetch-pr-comments.sh`/`reply-and-resolve.sh` と同じテスト方針）
- gh呼び出し自体の失敗（owner/repo解決失敗等）・jq不在は stderr にメッセージを出し exit 非0（sub_issues_api/フォールバック双方の「結果が空」はエラーではなく `no_children_found` として正常終了する点に注意）

## fetch-pr-comments.sh / reply-and-resolve.sh の出力仕様（正本）

`/pr-review-respond`（`skills/pr-review-respond/SKILL.md`）が、Step 2（取得）・Step 12（返信・Resolved化）でこの2スクリプトを Bash ツールから直接呼び出す（Issue #48。Issue #108 で Dynamic Workflow・git-ops エージェント経由の委譲を廃止し、呼び出し元自身の直接実行に一本化した）。`skills/pr-review-respond/SKILL.md` はこの仕様を参照し、フィールド定義を複製しない。

## ci-wait.sh の出力仕様（正本）

para-impl の star型並列実装で、`ticket-worker` が Phase 9（CI確認）でこのスクリプトを呼び出す（Issue #45 で新設、#105 で呼び出し元を Dynamic Workflow から ticket-worker へ変更）。`gh pr checks` を上限付きでポーリングし、失敗時は `gh run view --log-failed` から失敗ジョブのログ末尾を抽出する。gh を呼ぶ処理と、スナップショットの分類・ポーリング継続可否判定（`classify_checks`/`ci_wait_decision`）等の純粋関数を分離している。

### `scripts/ci-wait.sh <PR番号 or ブランチ名> [timeout秒（既定900。0でsingle-shot）] [poll間隔秒（既定30）]`

stdout JSON:
```json
{
  "ci": "green" | "red" | "timeout" | "none",
  "failed_checks": [{"name": "...", "workflow": "...", "link": "..."}],
  "failure_log_excerpt": "...",
  "pr_url": "...",
  "pr_number": 123,
  "pr_exists": true
}
```

| フィールド | 型 / 値 | 意味 |
|---|---|---|
| `pr_exists` | bool | `gh pr view <selector>` でPRが解決できたか。`false` の場合は他フィールドは空/nullで即終了する（ポーリングしない）。ticket-worker の attempt≥2 冪等分岐（PR未作成なら `gh pr create`、既存ならpushのみ）の判定材料 |
| `ci` | `"green"` \| `"red"` \| `"timeout"` \| `"none"` | `pass`（全checks成功）/ `fail・cancel検出`（他がpendingでも待たずに確定） / `pending のまま時間切れ` / `checksが1件も無い`。checks未設定リポジトリでの永久ブロックを避けるため、呼び出し側は `none` を green相当（ブロックしない）として扱ってよい |
| `failed_checks` | `[{name, workflow, link}]` | `ci: "red"` の場合のみ非空。fail/cancel状態のcheckのみ |
| `failure_log_excerpt` | string | `ci: "red"` の場合のみ、失敗checkのlinkから抽出したrun_idごとに `gh run view --log-failed` を実行し、末尾100行ずつ連結後、全体で約4000文字に切り詰めたもの |
| `pr_url` / `pr_number` | string / integer\|null | `gh pr view` で解決したPRのURL・番号。`pr_exists: false` の場合は `""` / `null` |

挙動の要点:

- `ci: "none"` の確定は「チェックが1件も無い」スナップショットを連続2回観測してから行う（ポーリング開始直後の一時的な空とCI未設定を区別するため）。ポーリングが時間切れになった時点でまだ空だった場合も、`pending` ではなかったため `timeout` ではなく `none` として確定する
- `timeout_seconds` に `0` を指定すると、sleepせず1回だけスナップショットを取得して確定する（single-shotモード）。PR作成有無だけを素早く確認したい呼び出し（attempt≥2の冪等分岐判定）に使う
- gh呼び出しの失敗・jq不在は stderr にメッセージを出し exit 非0（PR自体が存在しない場合は真の異常系ではなく `pr_exists: false` の正常終了として扱う点に注意）

## worktree-setup.sh / worktree-cleanup.sh の出力仕様（正本）

`skills/para-impl/SKILL.md` Phase 3（複数Issue時のworktree・作業ブランチ作成）とPhase 11（クリーンアップ）を切り出した決定的スクリプト（Issue #45）。resume時のキャッシュ安定性（固定スクリプト呼び出し）と、worktree作成・削除の冪等性をコードで保証する。gh は呼ばない（gh非依存）。

### `scripts/worktree-setup.sh <issue番号> <branch名> <base> [worktree_root]`

stdout JSON:
```json
{
  "issue": 45,
  "branch": "feature/issue-45-xxx",
  "base": "main",
  "worktree_path": "/path/to/xxx-worktrees/issue-45",
  "created": true,
  "reused": false,
  "branch_existed": false
}
```

| フィールド | 型 | 意味 |
|---|---|---|
| `branch` | string | `{type}/issue-{issue番号}-{ケバブケース説明}` 形式（type: feature/fix/refactor/docs/hotfix）でなければ拒否する。type・説明の意味的な決定は呼び出し側（LLM）の責務で、本スクリプトはパターン検証のみ行う |
| `worktree_path` | string | `worktree_root`省略時は `<リポジトリの1つ上の階層>/<リポジトリ名>-worktrees/issue-{issue番号}`。symlink経由のTMPDIR（macOSの `/tmp`→`/private/tmp`等）でも `git worktree list` の記録と一致するよう実体パスへ正規化してから使う |
| `created` | bool | このスクリプト呼び出しで新規に `git worktree add` を実行したか |
| `reused` | bool | `worktree_path` が既に**同一ブランチ**の登録済みworktreeだったため、新規作成せず再利用したか（resume時の冪等性） |
| `branch_existed` | bool | 指定ブランチがローカル/リモートに既に存在していたか（前回の途中失敗でブランチだけ作成済み等）。存在する場合は `-b` せず既存ブランチをそのままcheckoutする |

挙動の要点:

- `worktree_path` が**別ブランチ**の登録済みworktree、または**git worktreeに未登録の任意のディレクトリ**（stale等）の場合は、自動解決せず致命的エラーとして exit 非0（無条件の上書きはしない）
- base の存在確認は `git ls-remote --exit-code --heads origin <base>` のみで行う（gh非依存）。存在しなければ exit 非0
- gh呼び出しは一切行わない。git操作の失敗・jq不在は stderr にメッセージを出し exit 非0
- **worktreeロック（CodeRabbit指摘対応。Issue #45）**: `git fetch`/`git worktree add` を含む共有 `.git` への書き込み区間を、mkdirのatomic性を使った簡易ロック（`<git-common-dir>/claude-harness-worktree-ops.lock`）で保護する。`scripts/worktree-cleanup.sh` の `git worktree remove` も同じロックディレクトリを取り合うため、両スクリプトが理論上同時に実行されても直列化される。既定で最大60秒待機し（`WORKTREE_LOCK_WAIT_SECONDS`）、120秒（`WORKTREE_LOCK_STALE_SECONDS`）を超えて保持されたロックはプロセスクラッシュ等による解放漏れとみなし奪取する。**一次的な保証は呼び出し側（リード）が各Issueについて逐次実行する運用規律**（`skills/para-impl/references/star-parallel.md`）であり、本ロックはその規律が守られなかった場合の防御第二層

### `scripts/worktree-cleanup.sh <worktree_path> [--force|--skip-if-dirty]`

stdout JSON:
```json
{"worktree_path": "...", "removed": true, "skipped": false, "dirty": false, "reason": null}
```

| フィールド | 型 | 意味 |
|---|---|---|
| `removed` | bool | `git worktree remove` を実行し削除できたか |
| `skipped` | bool | `--skip-if-dirty` 指定時に dirty のため削除をスキップしたか |
| `dirty` | bool | `git status --short` が非空（未コミット差分あり）だったか |
| `reason` | string \| null | スキップ理由（`"dirty_worktree_skipped"`）。それ以外は `null` |

挙動の要点:

- **既定（フラグ省略）は保護優先**: dirty な worktree の削除は拒否し exit 非0（failure worktree の保護は呼び出し側の判断に委ねる設計。無条件削除をデフォルトにしない）
- `--force`: dirty かどうかに関わらず `git worktree remove --force` で強制削除する
- `--skip-if-dirty`: dirty なら削除せず `skipped: true` で正常終了（exit 0）。クリーンなら通常どおり削除する。複数worktreeを一括処理するループから、dirtyな1件だけを安全にスキップしたい場合に使う
- gh は呼ばない。worktree_path が存在しない・`git worktree remove` 失敗・jq不在は stderr にメッセージを出し exit 非0
- **worktreeロック**: `git worktree remove` の実行区間は `worktree-setup.sh` と**同一のロックディレクトリ**（上記参照）で保護される（`--skip-if-dirty` によるスキップ判定等、git writeを伴わない箇所はロック不要のため対象外）

### `scripts/fetch-pr-comments.sh <PR番号>`

PRのレビューコメントを3経路（レビュー本体/会話タブ/インライン）+ GraphQL reviewThreads + 変更ファイル一覧から取得し、単一の正規化配列へ組み立てる。owner/repoは `gh repo view --json owner,name` で解決する。

stdout JSON:
```json
{
  "pr": 48,
  "diff_stat": "path/a.js | +12 -3\npath/b.js | +5 -0",
  "comments": [
    {
      "id": "123",
      "threadId": "PRRT_xxx",
      "source": "inline",
      "author": "login",
      "is_bot": false,
      "path": "a.js",
      "line": 10,
      "diff_hunk": "...",
      "body": "...",
      "is_resolved": false,
      "is_outdated": false
    }
  ]
}
```

| フィールド | 型 | 意味 |
|---|---|---|
| `diff_stat` | string | `gh pr view --json files` の additions/deletions から組み立てた `"path \| +N -M"` 形式の行を改行連結した文字列（`build_diff_stat`） |
| `comments[].id` | string | コメントのDB ID（またはgh/GraphQLが返す識別子）を文字列化したもの。review/conversation/inlineでID空間は別だが、この正規化配列内では一意識別子として扱う |
| `comments[].threadId` | string \| null | GraphQL reviewThread のnode id。**inlineコメントで対応するスレッドが見つかった場合のみ**値を持つ。review/conversationコメントは常に `null` |
| `comments[].source` | `"review"` \| `"conversation"` \| `"inline"` | `"review"`（PR全体へのレビュー本体コメント。空bodyのレビューは除外済み）/ `"conversation"`（PR会話タブ、行に紐付かない）/ `"inline"`（個別行コメント） |
| `comments[].is_bot` | bool | `is_bot_author()`（gh を呼ばない純粋関数）の判定結果。authorのloginが `[bot]` サフィックス、または既知のAIレビュアー名にマッチするか |
| `comments[].path` / `.line` / `.diff_hunk` | string\|null / integer\|null / string\|null | inlineコメントのみ値を持つ。他は `null` |
| `comments[].is_resolved` / `.is_outdated` | bool | inlineコメントで対応スレッドが見つかった場合のみそのスレッドの値。他は `false` |

挙動の要点:

- gh を呼ぶ取得系関数（`resolve_repo`/`fetch_reviews_json`/`fetch_conversation_json`/`fetch_inline_json`/`fetch_review_threads_json`/`fetch_pr_files_json`）と、取得済みJSON文字列から正規化配列を組み立てる純粋パース関数（`normalize_comments`/`build_diff_stat`/`is_bot_author`/`build_threads_lookup`）を分離している。パース関数はスクリプトを `source` してフィクスチャJSON（4経路の入力JSON文字列）から直接呼び出してテストできる（`extract-acceptance-criteria.sh` と同じテスト方針）
- gh呼び出しの失敗・jq不在は stderr にメッセージを出し exit 非0

### `scripts/reply-and-resolve.sh <PR番号> <items_json_file|->`

分類済みコメントへの返信投稿とスレッドのResolved化を、1件ずつ**逐次**行う（GitHub secondary rate limit対策のため並列fan-outしない）。

入力JSON（配列。ファイルまたは `-` でstdin指定）:
```json
[{"commentId": "123", "threadId": "PRRT_xxx", "reply_body": "...", "resolve": true}]
```

stdout JSON:
```json
{"pr": 48, "results": [{"commentId": "123", "replied": true, "resolved": true, "error": null}], "succeeded": 1, "failed": 0}
```

| フィールド | 型 | 意味 |
|---|---|---|
| `results[].replied` | bool | 返信投稿（新規 or 冪等性スキップにより既に完了済み）が成立したか |
| `results[].resolved` | bool \| `"skipped_not_applicable"` | `true`/`false`＝実際にResolved化mutationを試行した結果（`resolve:false`、または返信自体が成立しなかった場合は試行せず `false`）。`"skipped_not_applicable"`＝threadIdがnullのため対象外。冪等性チェックで「既に返信済み」と判定された項目（`replied: true`）についても、`resolve:true` であれば mutation は実際に実行する（GitHubの `resolveReviewThread` はidempotentなため再実行しても安全であり、前回実行時のresolve失敗を見逃さないための設計） |
| `results[].error` | string \| null | 返信投稿またはResolved化のいずれかで失敗した場合の理由。両方成功、またはスキップのみの場合は `null` |
| `failed` | integer | `results` 内で `error` が非nullの項目数 |

挙動の要点:

- **冪等性（返信済みスキップ）**: 投稿する返信本文の末尾に隠しマーカー `<!-- pr-review-respond:{commentId} -->` を付与する（`build_marker`/`build_reply_body_with_marker`）。処理開始時に一度、既存コメント一覧（threadIdが非nullの項目向けは `gh api .../pulls/{pr}/comments`、threadIdがnullの項目向けは `gh pr view {pr} --json comments`）を取得し、このマーカーを含む既存コメントがあれば新規投稿をスキップする（`body_list_contains_marker`）
- 返信は threadId の有無で投稿先を切り替える: 非null（インラインコメント）は `gh api -X POST .../pulls/{pr}/comments -F in_reply_to={commentId}` への返信、null（会話タブ/レビュー本体コメント）は `gh pr comment {pr}` での新規投稿
- Resolved化は、返信が成立している（`replied: true`。冪等性スキップ含む）、かつ `resolve:true`、かつ threadId が非nullの場合に GraphQL `resolveReviewThread` mutation（`build_resolve_mutation_query`）を実行する。冪等性スキップの項目でも呼び出し自体は省略しない（前回実行のresolveが失敗していた場合を検知できるようにするため）
- `failed > 0` なら exit 1、それ以外は exit 0（本ファイル冒頭の出力規約: exit code と JSON の両方で成否を表現する）
- gh を呼ぶ関数（`resolve_repo`/`fetch_existing_inline_bodies`/`fetch_existing_conversation_bodies`/`post_inline_reply`/`post_conversation_reply`/`resolve_thread`）は、テストからスタブ関数で上書きして `main()` 全体の分岐（返信/Resolved化/冪等性スキップ/エラー集計）を検証する。`main()` はテスト容易性のため `exit` を直接呼ばず、常に `return` で終了コード相当の値を返す（直接実行時のみ、末尾の呼び出しが戻り値で実際に `exit` する）

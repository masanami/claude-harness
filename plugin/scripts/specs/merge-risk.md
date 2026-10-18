# merge-risk.sh の入出力仕様（正本）

`scripts/merge-risk.sh [--ai-review done|none] [--rules <file>]` は、PR のマージのリスク区分（`自動マージ可`／`人間判断`）と根拠を決定的に判定する。**判定するだけで、マージはしない**（マージするかは呼び出し側の承認ルールが決める）。

## 入力

- **stdin**: `scripts/pr-merge-preflight.sh` の出力 JSON（`base`・`ci.status`・`reviews`・`blocking`・`block_reasons`・`risk.files_changed`・`risk.touches_sensitive`・`files` を使う）
- `--ai-review done|none`（既定 `none`）: 呼び出し側が AI レビューを実施したか
- `--rules <file>`: 上書き規則のファイル（テスト・手元の確認用）。省略時は cwd のリポジトリで **`origin/<base>` の `.claude/merge-risk-rules.txt`** を読み、無ければ既定規則だけで判定する。作業ツリーの版は読まない（PR のブランチを checkout しているとき、PR が自分を判定する規則を書き換えられるため）

## 規則

1 行 = `<区分> <glob>`。空行と `#` 始まりの行は無視し、行末の CR は取り除く。glob は bash の `[[ "$path" == $glob ]]` で照合する（`*` は `/` も含めて任意の文字列に一致する）。

| 区分 | 意味 |
|---|---|
| `human` | 人間判断 |
| `auto` | 自動マージ可 |
| `test` | 自動マージ可。ただしそのファイルの削除行が 1 行以上なら人間判断（既存のテストを弱めうるため） |

- 照合順は**リポジトリの規則 → 既定規則**で、各ファイルについて最初に一致した規則を採る。リポジトリの規則は既定規則より優先されるので、既定を緩める（例: `auto src/ui/*`）ことも締める（例: `human docs/adr/*`）こともできる
- どの規則にも一致しないパス（プロダクションコード等）と、制御文字（タブ・改行等）を含むパスは人間判断（`path_unmatched`）
- リネーム（`previous_path` が在る）は、リネーム前のパスも `auto` の規則に一致しなければ人間判断（`test` に一致するテストの移動も含む）
- 次の 2 つは規則では外せない人間判断: 規則ファイル `.claude/merge-risk-rules.txt` 自体の変更、preflight の `risk.touches_sensitive`（`scripts/config/sensitive-paths.txt` に一致するパスの変更）
- 既定規則の正本はスクリプト内の `merge_risk_default_rules` だけ。スクリプト・権限定義（`.claude/*`）・スキル／エージェント定義とプロンプト・CI・契約ファイル・DB スキーマ・インフラ・シークレットは `human`、テストは `test`、ドキュメントは `auto`
- 規則ファイルの書式誤り（未知の区分・1 行に glob が 2 つ以上）は exit 2（読めない規則を黙って捨てない）

## 判定

`自動マージ可` になるのは次のすべてを満たすときだけ。1 つでも欠ければ `人間判断` で、欠けた条件ごとに `reasons` へ理由を積む。

1. 変更ファイルの一覧を取得できていて（`files` が null でない）、1 件以上あり、取り切れていて（`files` の件数 ≧ `risk.files_changed`）、すべてのファイルが `auto` 判定で、`risk.touches_sensitive` が false
2. 品質ゲートの通過: `ci.status` が `pass`（`none`〔CI が無い〕・`pending`・`fail` は満たさない）
3. AI レビューの実施: PR のレビューが 1 件以上、または `--ai-review done`（レビューゼロではマージしない）
4. `blocking` が false

## 出力（stdout に JSON 1 個）

| フィールド | 型 / 値 | 意味 |
|---|---|---|
| `status` | `"ok"` | 判定できた |
| `classification` | `"auto_merge_ok"` \| `"human_judgment"` | リスク区分 |
| `label` | `"自動マージ可"` \| `"人間判断"` | 区分の表示名 |
| `reasons` | `[{code, detail, path?, previous_path?, rule?, source?}]` | 人間判断の理由（自動マージ可なら空配列）。コードは下表 |
| `conditions` | `{paths, quality_gate, review, blocking}` | 判定の 4 条件それぞれの `ok` と材料（`ci_status`・`pr_reviews`・`ai_review`・`block_reasons`・`files_changed`・`files_classified`） |
| `files` | `[{path, previous_path, status, deletions, verdict, class, rule, source, code}]` \| null | ファイルごとの判定。`class`・`rule`・`source`（`repo` \| `default`）は `path` が一致した規則（無ければ null）。`code` は人間判断にした理由（auto なら null） |
| `rules.repo_file` | string \| null | 使ったリポジトリの規則（`origin/<base>:.claude/merge-risk-rules.txt` か `--rules` のパス） |
| `comment_markdown` | string | PR に残すコメントの本文（区分・4 条件・理由の全件、自動マージ可なら全ファイルの規則）。呼び出し側は書き直さずそのまま投稿する |

理由コード:

| コード | 意味 |
|---|---|
| `files_unavailable` | 変更ファイルの一覧を取得できなかった（preflight の `files` が null） |
| `no_files` | 変更ファイルが無い（判定の材料が無い） |
| `files_truncated` | 変更ファイルを取り切れていない |
| `rules_file_changed` | 規則ファイル自体を変更している |
| `path_human` | `human` の規則に一致したパスがある |
| `path_unmatched` | どの規則にも一致しないパスがある |
| `test_lines_deleted` | `test` の規則に一致したファイルで既存行を消している |
| `previous_path_not_auto` | リネーム前のパスが `auto` の規則に一致しない |
| `touches_sensitive` | preflight が sensitive パスへの変更を検出した |
| `quality_gate_not_passed` | 品質ゲート（CI）が pass ではない |
| `no_review` | レビューが 1 件も無い |
| `blocking` | preflight が blocking |

## 終了コード

| exit | 意味 |
|---|---|
| 0 | 自動マージ可 |
| 1 | 人間判断（stdout に JSON を出す。エラーではない） |
| 2 | 実行前提の欠落（jq 不在・引数不正・stdin が preflight の出力でない・`base` が無い・`origin/<base>` を解決できない・規則ファイルが読めない／書式誤り・判定の途中で失敗した）。stderr にメッセージ |

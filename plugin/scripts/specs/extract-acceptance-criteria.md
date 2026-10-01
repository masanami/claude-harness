# extract-acceptance-criteria.sh / check-e2e-traceability.sh の入出力仕様（正本）

`skills/create-e2e/SKILL.md`（Step 1-1, Step 1-3）はこの仕様を参照し、フィールド定義を複製しない。

## extract-acceptance-criteria.sh

`scripts/extract-acceptance-criteria.sh <issue番号>` または `scripts/extract-acceptance-criteria.sh --stdin` の stdout JSON。

| フィールド | 型 / 値 | 意味 |
|---|---|---|
| `issue` | number \| null | Issue番号。`--stdin` 呼び出し時は null |
| `criteria` | `[{id, text, checked}]` | 抽出したチェックリスト項目。`id` は `AC-1` 形式の通しID、`checked` は bool |
| `parse_status` | `"ok"` \| `"no_checklist_found"` | チェックリストを1件でも抽出できたか |
| `excluded_headings` | `[string]` | 括弧付きのため抽出対象外とした見出し行（`## 受入基準（S2）`・`## 完了条件 (旧)` 等。全角・半角の括弧とも）。本文の出現順・行そのまま。無ければ空配列 |

挙動の要点:

- 使い方は2通り。`<issue番号>` 指定時は `gh issue view <issue番号> --json body` で本文を取得してパースする。`--stdin` 指定時は stdin から本文テキストを読み込んでパースする（gh を呼ばない。`issue` は null）
- 抽出対象は Issue本文の「## 受入基準」または「## 完了条件」セクション配下の `- [ ]` / `- [x]` チェックリスト行（インデント付きのネスト行は対象外）
- 見出しは**完全一致**（`## 受入基準` / `## 完了条件` の後ろは空白のみ）だけを抽出対象にする。括弧付きの見出し（`## 受入基準（S2）` 等）は受理しない。スライスを重ねた本文では、当該スライスの受入基準を括弧なしの `## 受入基準` に置く（`/create-ticket` の要件モードが同じ規約を持つ）。括弧付きの見出しは `excluded_headings` に控え、`parse_status: "no_checklist_found"` で止まった呼び出し側が「括弧付きの受入基準見出しが N 件あるが対象外」と報告できるようにする（#273）
- 両セクションが同一本文に存在する場合は連番で通しIDを振る
- チェックリストが1件も見つからない場合は `parse_status: "no_checklist_found"` を返す（exit 0、エラー終了しない）
- gh 呼び出し自体の失敗・jq 不在など真の異常系は stderr にメッセージを出し exit 非0 で終了する

## check-e2e-traceability.sh

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

# group-acceptance-criteria.sh の入出力仕様（正本）

`/promote-verify`（`skills/promote-verify/SKILL.md`）が、Step 3-5 でこのスクリプトを呼び、受入基準を「1 体のエージェントが受け持つまとまり」へ分ける（Issue #423）。`skills/promote-verify/SKILL.md` はこの仕様を参照し、まとまりの作り方の規則と出力の項目の定義を複製しない。

まとまりの作り方をスクリプトに置く理由は、判定式を `promotion-decision.sh` に置いているのと同じである。散文の手順には試験が効かず、手がかりの優先・上限での分割・重なりの寄せ先の誤りを検出できない。

## 使い方

```text
scripts/group-acceptance-criteria.sh --max-per-group <N> [--input <file>]
```

- `--max-per-group <N>`: 1 つのまとまりに入れる基準の件数の上限（1 以上の整数）。**必須で、スクリプトは既定値を持たない**。上限の正本は `skills/promote-verify/SKILL.md` の 1 か所であり、スクリプトにも既定値を置くと 2 か所になって食い違う。
- 材料の JSON は stdin から読む。`--input <file>` を付けるとファイルから読む。

## 材料（入力の JSON）

```json
{
  "criteria": [
    { "id": "AC-1", "text": "…", "checked": false, "section": "受入基準", "subheading": "ログイン" }
  ],
  "children": [
    { "number": 60, "criteria": ["AC-1", "AC-3"] }
  ]
}
```

| 項目 | 型 | 意味 |
|---|---|---|
| `criteria` | `[{id, section?, subheading?}]`（必須） | 基準の一覧。**配列の順が「並び順」**（親の Issue に書かれた順）。`extract-acceptance-criteria.sh` の出力の `criteria` をそのまま渡せる（`text`・`checked` など、ほかの項目は読まずに無視する）。`id` は空でない文字列で、一覧の中で重複しないこと |
| `criteria[].section` | string \| null | 基準のある節の名前。無い・`null`・空文字は「節なし」として 1 つの節に扱う |
| `criteria[].subheading` | string \| null | 基準の小見出し。無い・`null`・空文字は「小見出し無し」 |
| `children` | `[{number, criteria}]`（省略可。省略は空の配列と同じ） | 子の Issue ごとの受け持ち。`number` は子の Issue の番号（1 以上の整数。重複しないこと）、`criteria` はその子の `対応する受入基準:` の行に書かれた ID の配列（文字列の配列。行が `なし` の子は空の配列） |

## 出力（stdout の JSON）

```json
{
  "status": "ok",
  "maxPerGroup": 10,
  "groups": [
    { "index": 1, "cue": "child_issue", "childIssue": 60, "section": "受入基準", "subheading": null, "part": 1, "parts": 2, "criteria": ["AC-1", "AC-3"] }
  ],
  "overlaps": [{ "id": "AC-3", "assignedTo": 60, "alsoIn": [61] }],
  "ignoredIds": [{ "id": "AC-99", "childIssue": 61 }],
  "summary": { "criteria": 12, "groups": 3, "byCue": { "child_issue": 2, "subheading": 1, "order": 0 } }
}
```

| 項目 | 型 / 値 | 意味 |
|---|---|---|
| `status` | `"ok"` \| `"no_criteria"` | `no_criteria` は `criteria` が空の配列（`groups` は空の配列。exit 0） |
| `maxPerGroup` | integer | 渡された上限 |
| `groups` | 配列 | まとまりの一覧。**どの基準も、ちょうど 1 つのまとまりに入る**（出力の前にスクリプトが確かめる）。空のまとまり・上限を超えるまとまりは出さない |
| `groups[].index` | integer | 1 からの通し番号 |
| `groups[].cue` | `"child_issue"` \| `"subheading"` \| `"order"` | まとまりを作った手がかり（下の「まとまりの作り方」の 1・2・3） |
| `groups[].childIssue` | integer \| null | `cue` が `child_issue` のときの子の Issue の番号。ほかは `null` |
| `groups[].section` | string \| null | まとまりの基準がある節の名前（節なしは `null`） |
| `groups[].subheading` | string \| null | `cue` が `subheading` のときの小見出し（「小見出し無し」のまとまりは `null`）。ほかの `cue` では常に `null`（子のまとまりは小見出しをまたぐ） |
| `groups[].part` / `groups[].parts` | integer | 上限で割ったときの「何番目 / いくつに割ったか」。割っていなければ `1` / `1` |
| `groups[].criteria` | `[string]` | まとまりに入る基準の `id`。並び順（`criteria` の配列の順）のまま |
| `overlaps` | `[{id, assignedTo, alsoIn}]` | 複数の子が挙げた基準。`assignedTo` はまとまりに入れた子（番号のいちばん小さい子）、`alsoIn` はほかに挙げた子の番号（小さい順）。無ければ空の配列 |
| `ignoredIds` | `[{id, childIssue}]` | 子が挙げたが `criteria` に無い ID と、それを挙げた子の番号。まとまりには入れない。無ければ空の配列 |
| `summary` | `{criteria, groups, byCue}` | 基準の件数・まとまりの数・手がかりごとのまとまりの数（`byCue` のキーは `child_issue`・`subheading`・`order`） |

## まとまりの作り方

手がかりは、確かな順に使う。

1. **子の Issue の受け持ち（`child_issue`）**: 子の `criteria` に挙がった基準を、子ごとにまとめる。
   - 子は番号の小さい順に処理する。**1 つの基準を複数の子が挙げているときは、番号のいちばん小さい子のまとまりに 1 回だけ入れ**、`overlaps` に残す。
   - `criteria` に無い ID は無視して `ignoredIds` に残す。
   - 同じ子の中に同じ ID が 2 回あるときは 1 回に数える（`overlaps` にはしない）。
   - 受け持ちが空の子（行が `なし`）、挙げた ID がすべて無視・ほかの子へ寄せられた子は、まとまりを作らない。
   - **まとまりの中の並びは、親の Issue の並び順**（`criteria` の配列の順）。子の行に書かれた順は使わない。
2. **小見出し（`subheading`）**: どの子の受け持ちにも無い基準を、節と小見出しごとにまとめる。同じ節の中で小見出しの文が同じ基準は、離れていても同じまとまりにする。小見出しの無い基準は、節ごとに「小見出し無し」の 1 まとまりにする。
3. **並び順（`order`）**: 渡された `criteria` に小見出しが 1 つも無いときは、どの子の受け持ちにも無い基準を、節ごとに並び順のまままとめる。

手がかり 2 と 3 は、渡された `criteria` の全体に小見出しが 1 つでもあるかで切り替える（残りの基準がたまたま小見出しの前のものだけでも、全体に小見出しがあれば手がかり 2 の「小見出し無し」のまとまりになる）。

どの手がかりにも共通の規則:

- **節が違う基準を同じまとまりにしない**。手がかり 1 でも、1 つの子が複数の節の基準を持つときは節ごとに分ける。
- **上限を超えたまとまりは、並び順のまま上限ごとに割る**（手がかり 1 のまとまりも、小見出しで割り直さない）。割った結果は `part`・`parts` に出る。
- **小さいまとまりを、ほかのまとまりと混ぜない**（割った端数も、次のまとまりへ足さない）。体数は少し増えるが、関係の薄い基準が 1 体に混ざると、見るファイルが増えて読み込みが浅くなる。
- `groups` の順は、手がかり 1 のまとまり（子の番号の小さい順）、続いて残りのまとまり（節・小見出しの初出順）。

## 終了コード

| exit | 意味 |
|---|---|
| `0` | まとまりを作れた（`status: "no_criteria"` を含む） |
| `2` | 実行前提の欠落: jq 不在・引数の誤り（`--max-per-group` が無い・1 以上の整数でない・知らない引数）・入力が読めない・空・JSON でない・JSON の値が 1 つでない・材料の形が違う（上の表に反する）。**stdout には何も出さず**、stderr にメッセージと `{"status":"error","error":"…"}` を出す |

呼び出し側は、exit 2 のときに自分でまとまりを作って埋め合わせない（作れなかったものを作れたことに見せない）。

## 試験

`scripts/tests/test-group-acceptance-criteria.sh` が、手がかりの優先・上限での分割・重なり・親に無い ID の扱い・節をまたがないこと・全件がちょうど 1 回ずつ入ることを固定する。同じ試験が、`skills/promote-verify/SKILL.md` と 2 つのエージェント定義（`agents/doc-verifier.md`・`agents/finding-verifier.md`）の本文が、まとまり単位の手順と食い違っていないことも固定する。

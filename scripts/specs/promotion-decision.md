# promotion-decision.sh の出力仕様（正本）

`/promote-verify` の2つの判定式を決定的に評価する。gh 呼び出しは一切行わない（gh 非依存）。

| mode | 評価する判定式 | 呼び出し箇所 |
|---|---|---|
| `all-consistent` | `guaranteeCheck.allConsistent`（保証整合チェックの4項） | Step 5.5-7 |
| `ready-for-promotion` | `readyForPromotion`（昇格可否の6項） | Step 7 |

**判定式の正本は本スクリプトの実装**であり、スキルの散文には「いつ呼ぶか」「結果をどう読むか」だけを置く。散文に論理式を書くと型検査もテストも効かず、次の2種の穴が検出できないまま残る（Issue #158 の実装で実際に発生した）:

- **要人間判定が算出式に接続されていない**（記録されるだけで合否に反映されない）
- **対象リストが空のとき全称条件が空虚に真になり、判定が true になりうる**

本スクリプトはこの2点を実装として強制する。**`null`（未確定・未検査）と空配列（検査した結果の0件）を区別し、`null` を空虚な真にしない**（検査不能≠0件）。空配列の扱いは mode で異なり、**どちらも意図した意味論**である:

| mode | 対象リスト | `null` | 空配列 |
|---|---|---|---|
| `all-consistent` | `targets` / `guarantees` | **判定を `false` にする**（検証対象を確定できていない） | **全称条件は真**（親Issueの保証節が「なし」と明示した＝検査した結果の0件。安全性は (b) 索引整合と (d) 要人間判定の不在が担保する） |
| `ready-for-promotion` | `criteria` | **判定を `false` にする**（`criteria_unknown`） | **判定を `false` にする**（`criteria_empty`。受入基準ゼロ件で昇格可能と誤判定する罠を塞ぐ。`/promote-verify` は Step 3-1 でそもそも中断するが、その防御が外れても落ちる二重防御） |

**この差は「0件が正常でありうるか」の違い**である。保証は「なし」が正常な状態になりうる（内部実装だけの変更）が、**受入基準が0件の親Issue は昇格判断の材料として成立しない**。

## `scripts/promotion-decision.sh <mode> [--input <file>]`

- 判定の材料は **stdin の JSON を1個**受け取る（`--input <file>` を渡した場合はそのファイルから読む）。
- **入力は「ちょうど1つの JSON オブジェクト」でなければならない**。判定式へ掛ける前に値の個数と型を検証し、2個以上・0個・オブジェクト以外は exit 2 にする（jq は入力ストリーム中の JSON 値ごとにプログラムを評価するため、値が複数あると出力も複数になり「stdout に判定結果 JSON を1個」という契約が壊れる。後段の真偽比較が `true` の連結を見て**判定を false と誤報告**する）。
- stdout に判定結果 JSON を1個出力する。人間向けの要約は stderr。

exit code:

| code | 意味 |
|---|---|
| 0 | 判定が `true`（stdout に JSON を出す） |
| 1 | 判定が `false`（stdout に JSON を出す。落ちた理由は `blockers`） |
| 2 | 実行前提の欠落（jq 不在・未知の mode・引数不正・入力が JSON でない・**入力が1つの JSON オブジェクトでない**・**必須キーの欠落**）。**stdout は空**で、stderr にエラー JSON とメッセージを出す |

**必須キーの欠落を `false` にしない**（exit 2 にする）。「判定できなかった」と「判定した結果の否」は別状態であり、材料を渡し忘れた呼び出しを「安全側に倒れたので問題なし」と読ませないため。

## mode: `all-consistent`

入力（**4キーすべてが必須**。値が `null` になりうるキーは下表のとおり）:

```json
{
  "targets": ["G-158-1", "G-158-2"],
  "guarantees": [{ "guarantee_id": "G-158-1", "verdict": "consistent" }],
  "index": { "status": "pass", "error": null },
  "humanReview": []
}
```

| キー | 型 | `null` の意味 |
|---|---|---|
| `targets` | `[string]` \| `null` | 検証対象を確定できていない（未検査） |
| `guarantees` | `[{guarantee_id, verdict}]` \| `null` | 判定一覧を組み立てられていない（未検査） |
| `index` | object \| `null` | 索引整合チェックを実行していない（未検査） |
| `humanReview` | `[{kind, detail}]` | （`null` 不可。要人間判定が無いときは `[]`） |

出力:

```json
{
  "mode": "all-consistent",
  "allConsistent": false,
  "terms": { "targetsCovered": true, "indexPass": false, "allVerdictsConsistent": true, "noHumanReview": true },
  "blockers": ["index_not_pass"]
}
```

`allConsistent` は次の4項の AND（**この表が項の正本**。項を増減するときは本表とスクリプト実装、および `skills/promote-verify/references/guarantee-consistency.md` の算出式を同時に更新する）:

| 項 | `terms` のキー | 真になる条件 |
|---|---|---|
| (a) | `targetsCovered` | `targets` と `guarantees` がいずれも非 `null` で、**両者の識別子がすべて妥当な保証 ID**（非空文字列かつ `G-{数字}-{枝番}` 書式）で、`targets` に重複が無く、`guarantees` の `guarantee_id` 集合が `targets` と1件ずつ対応する |
| (b) | `indexPass` | `index` が非 `null` で、**`error` キーが無いか値が `null`** であり、かつ `index.status === "pass"` |
| (c) | `allVerdictsConsistent` | `guarantees` が非 `null` で、全要素の `verdict` が `"consistent"` |
| (d) | `noHumanReview` | `humanReview` が空配列 |

- **(d) は「要人間判定が記録されたら必ず判定が落ちる」ための項**であり、理由コードごとに項を足す方式は採らない（`kind` を追加したときに判定式へ接続し忘れる事故を防ぐため、非空そのものを項にしている）。
- `targets` が空配列（親Issueの保証節が「なし」と明示していた＝**検査した結果の0件**）のとき、(a)(c) は0件について真になる。この経路の安全性は (b) と (d) が担保する。
- `targets` が `null`（**検査できなかった**）のときは (a)(c) を真にしない。空配列との区別を実装で強制している。
- **識別子の妥当性を「キーの存在」で代用しない**: `targets: [null]` と `guarantees: [{"guarantee_id": null, ...}]` は、`has("guarantee_id")` を満たし集合比較も一致するため、**実在の保証を1件も特定していないのに全件カバー済みと判定されうる**（`null` 以外に空文字・数値・オブジェクト・配列・ID 書式でない文字列も同様）。(a) は比較の前に両者の識別子を1件ずつ検証する。
- **保証 ID の書式の正本は `scripts/lib/common.sh` の `GUARANTEE_ID_PATTERN`**（`guarantee-index-check.sh` の台帳パースと本スクリプトの材料検査が同じ定義を参照する。同じ文法を2箇所で持たない）。
- **`index.error` の判定に `//` を使わない**: jq の `//` は `false` も「空」として扱うため、`error: false` が「エラー無し」に読み替えられる。キーの有無と `null` かどうかを明示的に見る。

`blockers` の語彙（複数該当する場合はソートして列挙）:

| コード | 意味 |
|---|---|
| `targets_unknown` | `targets` が `null`（検証対象が未確定） |
| `targets_invalid` | `targets` が配列でない |
| `targets_duplicated` | `targets` に同じ ID が複数ある（「1件ずつ」の対応が定義できない） |
| `guarantees_unknown` | `guarantees` が `null`（判定一覧が未確定） |
| `guarantees_invalid` | `guarantees` が配列でない |
| `target_id_invalid` | `targets` に妥当な保証 ID でない要素がある（`null` / 空文字 / 非文字列 / `G-{数字}-{枝番}` 書式でない） |
| `guarantee_id_missing` | `guarantees` の要素に `guarantee_id` が無い |
| `guarantee_id_invalid` | `guarantees` の `guarantee_id` に妥当な保証 ID でないものがある（同上） |
| `targets_not_covered` | `targets` と `guarantees` の ID が1件ずつ対応していない |
| `index_missing` | `index` が `null`（索引整合チェックを実行していない） |
| `index_invalid` | `index` がオブジェクトでない |
| `index_error` | `index.error` が非 `null`（結果を採用できない） |
| `index_not_pass` | `index.status` が `"pass"` でない |
| `verdict_missing` | `guarantees` の要素に `verdict` が無い |
| `verdict_not_consistent` | `consistent` 以外の `verdict` がある |
| `human_review_invalid` | `humanReview` が配列でない |
| `human_review_present` | `humanReview` に1件以上ある |

## mode: `ready-for-promotion`

入力（**5キーすべてが必須**）:

```json
{
  "allMerged": true,
  "criteria": [{ "id": "AC-1", "status": "consistent", "needsHumanReview": false }],
  "qualityCheck": { "skipped": false, "result": "pass" },
  "e2e": { "skipped": true, "reason": "..." },
  "guaranteeCheck": { "skipped": false, "allConsistent": true }
}
```

出力:

```json
{
  "mode": "ready-for-promotion",
  "readyForPromotion": false,
  "terms": {
    "allMerged": true, "criteriaConsistent": true, "criteriaNoHumanReview": true,
    "qualityOk": true, "e2eOk": true, "guaranteeOk": false
  },
  "blockers": ["guarantee_not_consistent"]
}
```

`readyForPromotion` は次の6項の AND（**この表が項の正本**）:

| 項 | `terms` のキー | 真になる条件 |
|---|---|---|
| 1 | `allMerged` | `allMerged === true` |
| 2 | `criteriaConsistent` | `criteria` が**1件以上**あり、全要素が `id` を**非空文字列で持ち**、全要素の `status` が `"consistent"` |
| 3 | `criteriaNoHumanReview` | `criteria` が**1件以上**あり、全要素が `needsHumanReview` を**boolean で持ち**、`true` の要素が無い |
| 4 | `qualityOk` | `qualityCheck.skipped === true` **または** `qualityCheck.result === "pass"` |
| 5 | `e2eOk` | `e2e.skipped === true` **または** `e2e.passed === true` |
| 6 | `guaranteeOk` | `guaranteeCheck.skipped === true` **または** `guaranteeCheck.allConsistent === true` |

- **`criteria` が空配列・`null` のときは項2・3を真にしない**（受入基準ゼロ件で昇格可能と誤判定する罠を実装で塞ぐ。`/promote-verify` は Step 3-1 でそもそも中断するが、その防御が外れても本スクリプトで落ちる二重防御）。
- 項4〜6 の「スキップは OK 扱い」は**意図した意味論**であり変更しないこと。ただし `skipped` が `true` でないのに判定フィールド（`result` / `passed` / `allConsistent`）が無い入力は、真にせず `*_result_missing` を積む（フィールドの不在を「問題なし」に読み替えない）。
- **項2・3 も同じ規律**である: `criteria` の要素に `id` / `status` / `needsHumanReview` が無い、`id` が非空文字列でない、または `needsHumanReview` が boolean でない入力は真にしない。**`needsHumanReview` の不在を「要人間判定なし」に読み替えると、要人間判定の付いた基準を渡し忘れた呼び出しがそのまま `readyForPromotion: true` になる**（項3が判定へ接続されていないのと同じ状態になる）。
- `guaranteeCheck.skipped` を `true` にしてよいのは SDD期として確定した場合だけ、という規律は呼び出し側（`/promote-verify` の Step 5.5）の責務であり、本スクリプトは判定しない。

`blockers` の語彙:

| コード | 意味 |
|---|---|
| `not_all_merged` | `allMerged` が `true` でない |
| `criteria_unknown` | `criteria` が `null` |
| `criteria_invalid` | `criteria` が配列でない |
| `criteria_empty` | `criteria` が空配列（受入基準ゼロ件） |
| `criteria_id_missing` | `criteria` の要素に `id` が無い |
| `criteria_id_invalid` | `criteria` の `id` が非空文字列でない |
| `criteria_status_missing` | `criteria` の要素に `status` が無い |
| `criteria_review_missing` | `criteria` の要素に `needsHumanReview` が無い（**不在を「要人間判定なし」に読み替えない**） |
| `criteria_review_invalid` | `needsHumanReview` が boolean でない（`null` / 文字列など。真偽の判定ができない値を `false` に丸めない） |
| `criteria_not_consistent` | `consistent` 以外の `status` がある |
| `criteria_needs_human_review` | `needsHumanReview === true` の基準がある |
| `quality_check_missing` / `quality_check_invalid` | `qualityCheck` が `null` / オブジェクトでない |
| `quality_result_missing` | スキップでないのに `result` が無い |
| `quality_not_pass` | `result` が `"pass"` でない |
| `e2e_missing` / `e2e_invalid` | `e2e` が `null` / オブジェクトでない |
| `e2e_result_missing` | スキップでないのに `passed` が無い |
| `e2e_not_passed` | `passed` が `true` でない |
| `guarantee_check_missing` / `guarantee_check_invalid` | `guaranteeCheck` が `null` / オブジェクトでない |
| `guarantee_result_missing` | スキップでないのに `allConsistent` が無い |
| `guarantee_not_consistent` | `allConsistent` が `true` でない |

## 挙動の要点

- 判定式は jq プログラム（`PROMOTION_DECISION_JQ_ALL_CONSISTENT` / `PROMOTION_DECISION_JQ_READY`）として分離されており、スクリプトを `source` すれば jq へ直接掛けて真理値表をテストできる（テストは `scripts/tests/test-promotion-decision.sh`）
- jq 不在時は stderr にエラーメッセージ + エラー JSON を出し exit 2（`scripts/README.md`「出力規約」に従う）
- 判定の材料そのもの（各項の値）を作るのは呼び出し側（LLM）の責務であり、本スクリプトは**与えられた材料から総合判定を導くところだけ**を担う（意味判断はしない）

### 値の妥当性検査の方針（「キーが在る」を「値が妥当」と読み替えない）

**存在検査（`has()`）だけで通し、値そのものを見ない項目を作らないこと**。不正な値が「問題なし」として読まれる経路になる。各フィールドの扱いは次のとおり（`scripts/tests/test-promotion-decision.sh` が全フィールドの不正値を実行して固定する）:

| フィールド | 不正値の扱い | 方式 |
|---|---|---|
| `targets[]` / `guarantees[].guarantee_id` | `target_id_invalid` / `guarantee_id_invalid` | **値を検証**（非空文字列 + ID 書式）。存在検査だけでは集合比較が一致してしまうため |
| `criteria[].id` | `criteria_id_missing` / `criteria_id_invalid` | **値を検証**（非空文字列）。判定式では読まないが契約フィールドであり、材料まるごとの取り違えを検出する |
| `criteria[].needsHumanReview` | `criteria_review_missing` / `criteria_review_invalid` | **値を検証**（boolean）。不在・非 boolean を「要人間判定なし」に読み替えないため |
| `index.error` | `index_error` | **キーの有無と `null` を明示的に判定**（`//` は `false` を空として扱うため使わない） |
| `guarantees[].verdict` / `criteria[].status` / `index.status` / `qualityCheck.result` / `e2e.passed` / `guaranteeCheck.allConsistent` / `allMerged` / `*.skipped` | 既定で **fail-closed**（`=== 期待値` の等値比較のため、`null`・型違い・想定外の値はすべて偽側へ落ちる） | 追加の型検査は置かない。**「不正値が真になる経路が無い」ことをテストで固定**する |

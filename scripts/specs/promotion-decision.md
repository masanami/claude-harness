# promotion-decision.sh の出力仕様（正本）

`/promote-verify` の2つの判定式を決定的に評価する。gh 呼び出しは一切行わない（gh 非依存）。

| mode | 評価する判定式 | 呼び出し箇所 |
|---|---|---|
| `all-consistent` | `guaranteeCheck.allConsistent`（保証整合チェックの4項） | Step 5.5-7 |
| `ready-for-promotion` | `readyForPromotion`（昇格可否の6項） | Step 7 |

**判定式の正本は本スクリプトの実装**であり、スキルの散文には「いつ呼ぶか」「結果をどう読むか」だけを置く。散文に論理式を書くと型検査もテストも効かず、次の2種の穴が検出できないまま残る（Issue #158 の実装で実際に発生した）:

- **要人間判定が算出式に接続されていない**（記録されるだけで合否に反映されない）
- **対象リストが空のとき全称条件が空虚に真になり、判定が true になりうる**

本スクリプトはこの2点を実装として強制する。**対象リストが `null`（未確定・未検査）と空配列（受入基準ゼロ件）は、全称条件を空虚に真にせず判定を `false` にする**（検査不能≠0件）。

## `scripts/promotion-decision.sh <mode> [--input <file>]`

- 判定の材料は **stdin の JSON を1個**受け取る（`--input <file>` を渡した場合はそのファイルから読む）。
- stdout に判定結果 JSON を1個出力する。人間向けの要約は stderr。

exit code:

| code | 意味 |
|---|---|
| 0 | 判定が `true`（stdout に JSON を出す） |
| 1 | 判定が `false`（stdout に JSON を出す。落ちた理由は `blockers`） |
| 2 | 実行前提の欠落（jq 不在・未知の mode・引数不正・入力が JSON でない・**必須キーの欠落**）。**stdout は空**で、stderr にエラー JSON とメッセージを出す |

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
| (a) | `targetsCovered` | `targets` と `guarantees` がいずれも非 `null` で、`targets` に重複が無く、`guarantees` の `guarantee_id` 集合が `targets` と1件ずつ対応する |
| (b) | `indexPass` | `index` が非 `null` で、`index.error` が `null` かつ `index.status === "pass"` |
| (c) | `allVerdictsConsistent` | `guarantees` が非 `null` で、全要素の `verdict` が `"consistent"` |
| (d) | `noHumanReview` | `humanReview` が空配列 |

- **(d) は「要人間判定が記録されたら必ず判定が落ちる」ための項**であり、理由コードごとに項を足す方式は採らない（`kind` を追加したときに判定式へ接続し忘れる事故を防ぐため、非空そのものを項にしている）。
- `targets` が空配列（親Issueの保証節が「なし」と明示していた＝**検査した結果の0件**）のとき、(a)(c) は0件について真になる。この経路の安全性は (b) と (d) が担保する。
- `targets` が `null`（**検査できなかった**）のときは (a)(c) を真にしない。空配列との区別を実装で強制している。

`blockers` の語彙（複数該当する場合はソートして列挙）:

| コード | 意味 |
|---|---|
| `targets_unknown` | `targets` が `null`（検証対象が未確定） |
| `targets_invalid` | `targets` が配列でない |
| `targets_duplicated` | `targets` に同じ ID が複数ある（「1件ずつ」の対応が定義できない） |
| `guarantees_unknown` | `guarantees` が `null`（判定一覧が未確定） |
| `guarantees_invalid` | `guarantees` が配列でない |
| `guarantee_id_missing` | `guarantees` の要素に `guarantee_id` が無い |
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
| 2 | `criteriaConsistent` | `criteria` が**1件以上**あり、全要素の `status` が `"consistent"` |
| 3 | `criteriaNoHumanReview` | `criteria` が**1件以上**あり、`needsHumanReview === true` の要素が無い |
| 4 | `qualityOk` | `qualityCheck.skipped === true` **または** `qualityCheck.result === "pass"` |
| 5 | `e2eOk` | `e2e.skipped === true` **または** `e2e.passed === true` |
| 6 | `guaranteeOk` | `guaranteeCheck.skipped === true` **または** `guaranteeCheck.allConsistent === true` |

- **`criteria` が空配列・`null` のときは項2・3を真にしない**（受入基準ゼロ件で昇格可能と誤判定する罠を実装で塞ぐ。`/promote-verify` は Step 3-1 でそもそも中断するが、その防御が外れても本スクリプトで落ちる二重防御）。
- 項4〜6 の「スキップは OK 扱い」は**意図した意味論**であり変更しないこと。ただし `skipped` が `true` でないのに判定フィールド（`result` / `passed` / `allConsistent`）が無い入力は、真にせず `*_result_missing` を積む（フィールドの不在を「問題なし」に読み替えない）。
- `guaranteeCheck.skipped` を `true` にしてよいのは SDD期として確定した場合だけ、という規律は呼び出し側（`/promote-verify` の Step 5.5）の責務であり、本スクリプトは判定しない。

`blockers` の語彙:

| コード | 意味 |
|---|---|
| `not_all_merged` | `allMerged` が `true` でない |
| `criteria_unknown` | `criteria` が `null` |
| `criteria_invalid` | `criteria` が配列でない |
| `criteria_empty` | `criteria` が空配列（受入基準ゼロ件） |
| `criteria_status_missing` | `criteria` の要素に `status` が無い |
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

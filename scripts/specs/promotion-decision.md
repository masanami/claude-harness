# promotion-decision.sh の出力仕様（正本）

`/promote-verify` の判定式を決定的に評価する。gh 呼び出しは一切行わない（gh 非依存）。

| mode | 評価する判定式 | 呼び出し箇所 |
|---|---|---|
| `ready-for-promotion` | `readyForPromotion`（昇格可否の5項） | Step 7 |

**判定式の正本は本スクリプトの実装**であり、スキルの散文には「いつ呼ぶか」「結果をどう読むか」だけを置く。散文に論理式を書くと型検査もテストも効かず、次の2種の穴が検出できないまま残る（Issue #158 の実装で実際に発生した）:

- **要人間判定が算出式に接続されていない**（記録されるだけで合否に反映されない）
- **対象リストが空のとき全称条件が空虚に真になり、判定が true になりうる**

本スクリプトはこの2点を実装として強制する。**`null`（未確定・未検査）と空配列（検査した結果の0件）を区別し、`null` を空虚な真にしない**（検査不能≠0件）。空配列を全称条件の空虚な真として通すかは **mode ごとに定める**:

| mode | 対象リスト | `null` | 空配列 |
|---|---|---|---|
| `ready-for-promotion` | `criteria` | **判定を `false` にする**（`criteria_unknown`） | **判定を `false` にする**（`criteria_empty`。受入基準ゼロ件で昇格可能と誤判定する罠を塞ぐ。`/promote-verify` は Step 3-1 でそもそも中断するが、その防御が外れても落ちる二重防御） |

**判断の軸は「0件が正常でありうるか」**である。`ready-for-promotion` は**受入基準が0件の親Issue が昇格判断の材料として成立しない**ため、空配列も `false` へ倒す（`null` との区別は `blockers` の語彙〔`criteria_unknown` / `criteria_empty`〕で保つ）。mode を追加するときは、その対象リストについて同じ軸で判断し本表へ行を足す。

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

## mode: `ready-for-promotion`

入力（**5キーすべてが必須**）:

```json
{
  "allMerged": true,
  "criteria": [{ "id": "AC-1", "status": "consistent", "needsHumanReview": false }],
  "qualityCheck": { "skipped": false, "result": "pass" },
  "e2e": { "skipped": true, "reason": "..." },
}
```

出力:

```json
{
  "mode": "ready-for-promotion",
  "readyForPromotion": false,
  "terms": {
    "allMerged": true, "criteriaConsistent": true, "criteriaNoHumanReview": true,
    "qualityOk": true, "e2eOk": false
  },
  "blockers": ["e2e_not_passed"]
}
```

`readyForPromotion` は次の5項の AND（**この表が項の正本**）:

| 項 | `terms` のキー | 真になる条件 |
|---|---|---|
| 1 | `allMerged` | `allMerged === true` |
| 2 | `criteriaConsistent` | `criteria` が**1件以上**あり、全要素が `id` を**非空文字列で持ち**、全要素の `status` が `"consistent"` |
| 3 | `criteriaNoHumanReview` | `criteria` が**1件以上**あり、全要素が `needsHumanReview` を**boolean で持ち**、`true` の要素が無い |
| 4 | `qualityOk` | `qualityCheck.result === "pass"`（**`skipped` は許可条件にしない** → 後述「ゲート未実行は常にブロックする」） |
| 5 | `e2eOk` | `e2e.skipped === true` **または** `e2e.passed === true` |

- **`criteria` が空配列・`null` のときは項2・3を真にしない**（受入基準ゼロ件で昇格可能と誤判定する罠を実装で塞ぐ。`/promote-verify` は Step 3-1 でそもそも中断するが、その防御が外れても本スクリプトで落ちる二重防御）。
- **項5（E2E）の「スキップは OK 扱い」は意図した意味論**であり変更しないこと（E2E が無いプロジェクトは珍しくない）。ただし `skipped` が `true` でないのに判定フィールド（`passed`）が無い入力は、真にせず `e2e_result_missing` を積む（フィールドの不在を「問題なし」に読み替えない）。
- **項4（品質）はスキップを OK 扱いにしない**（下記）。E2E と扱いが違うのは意図的であり、「対称にする」方向へ戻さないこと。
- **項2・3 も同じ規律**である: `criteria` の要素に `id` / `status` / `needsHumanReview` が無い、`id` が非空文字列でない、または `needsHumanReview` が boolean でない入力は真にしない。**`needsHumanReview` の不在を「要人間判定なし」に読み替えると、要人間判定の付いた基準を渡し忘れた呼び出しがそのまま `readyForPromotion: true` になる**（項3が判定へ接続されていないのと同じ状態になる）。

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
| `quality_result_missing` | `result` が無い（`skipped` の有無に関わらず） |
| `quality_not_verified` | **ゲートが1つも実行されていない**（`skipped === true` または `result === "skip"`）。「検査して落ちた」とは別状態 |
| `quality_not_pass` | ゲートは実行されたが `result` が `"pass"` でない（`"fail"` 等） |
| `e2e_missing` / `e2e_invalid` | `e2e` が `null` / オブジェクトでない |
| `e2e_result_missing` | スキップでないのに `passed` が無い |
| `e2e_not_passed` | `passed` が `true` でない |

## ゲート未実行は常にブロックする（品質のスキップを許可条件にしない）

**`qualityCheck` について `skipped: true` を昇格可の材料にしない。** 実行されたゲートが1つも無い場合は、理由が何であれ `quality_not_verified` を積んで `readyForPromotion` を `false` にする。

**なぜ**: 以前は `qualityCheck.skipped === true` を許可条件に置いており、`/promote-verify` の側も「lint/typecheck/test のいずれも特定できなかった場合、または CLI フラグ列が空になる場合は `skipped: true` にする」と指示していた。この組み合わせでは、**検査コマンドを特定できなかっただけで、何も検証していない変更が `readyForPromotion: true` になる**（実測: `{"skipped":true,"reason":"検出できず"}` で `blockers: []`）。しかもこの経路は `quality-check-runner` を**呼ばない**ため、Issue #192 で入れた `result: "skip"` / exit 3 の安全網が**構造的に届かない**——一段上の層に同じ欠陥（検査していないものを pass に見せる）を作っていた。

**「コマンドが存在しない」と「特定できなかった」を区別しない**（人間決定 2026-08-23）。区別しようとすると、判定が「LLM が特定に成功したか」に依存する。lint もテストも1つも無いプロジェクトは稀であり、**`readyForPromotion` は最終ゲートではなくその先に人間承認がある**ため、ブロックしても人間が状況を見て承認できる。fail-closed の方が安い。

- **`reason` は入力に残してよい**（呼び出し側の報告に使う）。**記録を残すために許可条件へ倒さない**——理由の記録と合否判定は別のことである。
- **`quality_not_verified` と `quality_not_pass` を分ける**のは、`quality-check-runner` が `skip` と `fail` を分けているのと同じ理由（「検査していない」と「検査して落ちた」は呼び出し側の対応が違う）。
- **一部のゲートだけが未実行の場合は対象外**。`quality-check-runner` は「1つも実行していない」ときだけ `result: "skip"` を返し、型チェックの無いプロジェクトのように一部を省略した実行は `result: "pass"` を返す（`scripts/specs/quality-check-runner.md`）。本項がブロックするのはその `"skip"`（と `skipped: true`）だけである。
- **E2E（項5）はこの決定の対象外**。`e2e.skipped === true` は許可条件のままとする。

## 挙動の要点

- 判定式は jq プログラム（`PROMOTION_DECISION_JQ_READY`）として分離されており、スクリプトを `source` すれば jq へ直接掛けて真理値表をテストできる（テストは `scripts/tests/test-promotion-decision.sh`）
- jq 不在時は stderr にエラーメッセージ + エラー JSON を出し exit 2（`scripts/README.md`「出力規約」に従う）
- 判定の材料そのもの（各項の値）を作るのは呼び出し側（LLM）の責務であり、本スクリプトは**与えられた材料から総合判定を導くところだけ**を担う（意味判断はしない）

### 値の妥当性検査の方針（「キーが在る」を「値が妥当」と読み替えない）

**存在検査（`has()`）だけで通し、値そのものを見ない項目を作らないこと**。不正な値が「問題なし」として読まれる経路になる。各フィールドの扱いは次のとおり（`scripts/tests/test-promotion-decision.sh` が全フィールドの不正値を実行して固定する）:

| フィールド | 不正値の扱い | 方式 |
|---|---|---|
| `criteria[].id` | `criteria_id_missing` / `criteria_id_invalid` | **値を検証**（非空文字列）。判定式では読まないが契約フィールドであり、材料まるごとの取り違えを検出する |
| `criteria[].needsHumanReview` | `criteria_review_missing` / `criteria_review_invalid` | **値を検証**（boolean）。不在・非 boolean を「要人間判定なし」に読み替えないため |
| `index.error` | `index_error` | **キーの有無と `null` を明示的に判定**（`//` は `false` を空として扱うため使わない） |
| `criteria[].status` / `qualityCheck.result` / `e2e.passed` / `allMerged` / `*.skipped` | 既定で **fail-closed**（`=== 期待値` の等値比較のため、`null`・型違い・想定外の値はすべて偽側へ落ちる） | 追加の型検査は置かない。**「不正値が真になる経路が無い」ことをテストで固定**する |

# guarantee-index-check.sh の出力仕様（正本）

保証台帳（`docs/guarantees.md`）の**テスト対応索引**を決定的に検査する。gh 呼び出しは一切行わない（gh 非依存）。

検査するのは「索引ドリフト」（テストの改名・削除・移動により台帳の参照が実在しなくなること）・「ID の重複」・「書式の破れ（保証 ID / GAP ID / テスト参照 / 宣言元）」であり、**意味ドリフト**（約束の文言とテストの実際の検証内容の乖離）は検査しない。意味整合は `/guarantee-audit drift` の LLM fan-out の責務。台帳の書式・運用の正本は `docs/ai-driven-development-strategy.md`「開発フェーズとドキュメントライフサイクル」の章。

**本スクリプトは台帳の読み取り規則の正本**である。呼び出し側（スキルの散文）は、台帳から保証 ID・約束文・テスト参照・宣言元を読み取る必要がある場合、**自分でファイルを読み直さず本スクリプトの `guarantees` 配列を使う**こと。散文が独自の規則で同じ台帳を読み直すと、スクリプトが無視する記述（フェンス内の記入例・節の外の見出し）を「登録済み」と解釈する食い違いが起き、**同じ台帳を2つの規則で読む**状態になる（索引チェックはフェンス内を見ないため `status` は `pass` のままで、食い違いが表に出ない）。

## `scripts/guarantee-index-check.sh [保証台帳のパス] [--base <dir>]`

- 台帳のパスを省略した場合は `docs/guarantees.md`（cwd 相対）を対象にする。
- `--base <dir>` はテスト参照のパスを解決する基準ディレクトリ。省略時は次の順で解決する:
  1. 台帳が置かれたディレクトリから `git rev-parse --show-toplevel` で解決したリポジトリルート
  2. 1 が解決できなければ cwd

stdout JSON:

```json
{
  "status": "fail",
  "ledger": "docs/guarantees.md",
  "base": "/path/to/repo",
  "counts": { "guarantees": 12, "refs": 15, "gaps": 3, "broken": 1 },
  "guarantees": [
    {
      "guarantee_id": "G-123-1",
      "statement": "POST /api/contact は JSON パース不能時に 400 を返す",
      "tests": ["tests/api/contact.test.ts::returns 400 for invalid json"],
      "provenance": { "kind": "issue", "issue": 123 }
    }
  ],
  "broken": [
    { "guarantee_id": "G-123-1", "ref": "tests/api/contact.test.ts::returns 400 for invalid json", "reason": "test_name_not_found" }
  ]
}
```

| フィールド | 型 | 意味 |
|---|---|---|
| `status` | `"pass"` \| `"fail"` | `broken` が空なら `pass` |
| `ledger` | string | 検査した台帳のパス（引数をそのまま反映） |
| `base` | string | テスト参照の解決に使った基準ディレクトリ（絶対パス） |
| `counts` | object | `guarantees`（保証節内の `###` 見出し数）/ `refs`（テスト参照数）/ `gaps`（GAP 行数）/ `broken`（問題件数） |
| `guarantees` | `[{guarantee_id, statement, tests, provenance}]` | 読み取った保証の一覧（後述） |
| `broken` | `[{guarantee_id, ref, reason}]` | 検出した問題。`ref` は参照を伴わない問題では `null` |

**呼び出し元が合否判定に使う契約フィールドは `status` と `broken` の2つ**（`/quality-check` の索引ゲートはこの2つだけを見る）。`ledger` / `base` / `counts` は報告用の付加情報。**`guarantees` は台帳の読み取り結果そのもの**であり、呼び出し側が台帳の中身（ID・約束文・テスト参照・宣言元）を必要とする場合に使う。

### `guarantees[]` の定義

| フィールド | 型 | 意味 |
|---|---|---|
| `guarantee_id` | string | 保証 ID（`G-{数字}-{枝番}`。書式を満たすものだけが並ぶ） |
| `statement` | string | 保証見出しの区切り（`:` / `：`）より後ろの約束文（前後の空白は除去） |
| `tests` | `[string]` | その保証見出し直下の `- テスト:` 行から読み取った参照（**台帳の記載どおり**。書式違反の参照も含み、その違反は `broken` に `malformed_test_ref` として別途出る） |
| `provenance` | `{kind, issue}` | 宣言元行の読み取り結果（下表） |

`provenance.kind` の語彙（この4状態で全体を覆う。呼び出し側は「行が無い」と「番号が入っていない」を区別できる）:

| `kind` | `issue` | 台帳の記載 | `broken` への計上 |
|---|---|---|---|
| `issue` | 数値 | `- 宣言元: #123` | しない |
| `pending` | `null` | `- 宣言元: 裁可待ち`（裁可前のドラフトの規約） | しない |
| `missing` | `null` | 保証見出し直下に宣言元行が無い | `missing_provenance` |
| `malformed` | `null` | 宣言元行はあるが `#<数字>` でも `裁可待ち` でもない | `malformed_provenance` |

- 同一の保証に宣言元行が2行以上ある場合は、**2行目以降を採用せず** `duplicate_provenance` を `broken` に積む（`provenance` には1行目の読み取り結果が入る）。どちらを出自とするか決められない状態を、先頭を黙って採ることで隠さないため。
- **`counts.guarantees` と `guarantees` の要素数は一致しない場合がある**: `counts.guarantees` は保証節内の `###` 見出しを ID 書式の可否によらず数えるのに対し、`guarantees` には ID 書式を満たす見出しだけが並ぶ。差分はちょうど `broken` の `malformed_guarantee_id` の件数になる（この不変条件は `scripts/tests/test-guarantee-index-check.sh` が固定する）。**`guarantees | length` を「保証節内の見出し総数」として使わないこと**。
- 「保証」節の外にある `### G-...` 見出しは `guarantees` に入らない（`broken` に `guarantee_outside_section` として出る）。

`broken[].reason` の語彙:

| `reason` | 意味 |
|---|---|
| `test_file_not_found` | 参照先のファイルが存在しない |
| `test_name_not_found` | ファイルは存在するが、テスト名の文字列がファイル内に出現しない |
| `malformed_test_ref` | テスト参照が `<パス>::<テスト名>` の形になっていない（区切りが無い・パスまたはテスト名が空） |
| `missing_test_ref` | 保証にテスト参照行が1つも無い（テストで裏付けられていない約束） |
| `malformed_guarantee_id` | 保証見出しの ID が `G-{数字}-{枝番}` 書式でない（裁可待ちの仮 ID `G-?-1` の残留を含む）。この場合 `guarantee_id` には見出しテキストがそのまま入る |
| `duplicate_guarantee_id` | 同一の保証 ID が台帳内に複数回出現する |
| `duplicate_gap_id` | 同一の GAP ID が台帳内に複数回出現する |
| `missing_provenance` | 保証見出し直下に `- 宣言元: ...` 行が1つも無い（出自の追跡ができない約束） |
| `malformed_provenance` | 宣言元行の値が `#<数字>` でも `裁可待ち` でもない |
| `duplicate_provenance` | 同一の保証に宣言元行が2行以上ある（どちらを出自とするか決められない） |
| `malformed_gap_id` | Gaps 節のチェックリスト行が `GAP-{数字}:` 書式でない（ID の書き忘れ・仮 ID の残留）。この場合 `guarantee_id` には行の内容がそのまま入る |
| `guarantee_outside_section` | `### G-...` 見出しが「保証」節の外にある（節の外の保証は索引検査の対象外になるため、黙って見逃さず報告する） |
| `duplicate_guarantee_section` | 「保証」節（`## 保証` で始まる H2）が2つ以上ある。`guarantee_id` には2つ目以降の見出しテキストが入る。**どちらの節を正とするか決められない状態を、黙って併合して pass にしない**（保証節の識別規則が「該当する見出しが2つ以上ある本文は解釈できないとして扱う」と定めており、台帳側でこれを実装するのが本スクリプトである） |

#### `reason` の分類（消費側が扱いを分けるための区分）

`guarantees` を消費する側は、**`status` の pass / fail だけで扱いを決めない**。`broken` の reason は次の2区分に分かれ、**区分 (I) は `guarantees` の完全性・一意性そのものを壊す**（しかもその大半は `counts.guarantees` と `guarantees` の**件数差分に現れない**）:

| 区分 | `reason` | `guarantees` への影響 | 件数差分に現れるか |
|---|---|---|---|
| **(I) 解釈・完全性を壊す** | `malformed_guarantee_id` | 当該見出しと**その配下のテスト参照**が `guarantees` に入らない | **現れる** |
| (I) | `guarantee_outside_section` | 同上（見出しも配下のテスト参照も入らない）。ただし `counts.guarantees` にも数えないため | **現れない** |
| (I) | `duplicate_guarantee_section` | 2つ以上の節を**黙って併合**した一覧になる（どちらを正とするか決められない） | **現れない** |
| (I) | `duplicate_guarantee_id` | 同一 ID の要素が複数並び、ID をキーにした突き合わせ・完全性 join が一意にならない | **現れない** |
| (I) | `malformed_test_ref` | `tests` に書式違反の文字列が入る。`<パス>::<テスト名>` として突き合わせる用途では**実質的に参照が欠落**する | **現れない** |
| **(II) 既存の索引ドリフト** | `test_file_not_found` / `test_name_not_found` | 参照は `tests` に正しく入っている（参照先の実体が無い／名前が一致しない） | 現れない（影響なし） |
| (II) | `missing_test_ref` | **その保証は `guarantees` に入る**（`tests` は空配列）。台帳側の欠陥であり一覧の欠落ではない | 現れない（影響なし） |
| (II) | `missing_provenance` / `malformed_provenance` / `duplicate_provenance` | `provenance` の読み取り結果に現れる（一覧の欠落ではない） | 現れない（影響なし） |
| (II) | `duplicate_gap_id` / `malformed_gap_id` | Gaps 節のみ。`guarantees` に影響しない | 現れない（影響なし） |

- **区分 (I) が1件でもあるとき、`guarantees` を「台帳に登録された保証の完全で一意な一覧」として扱わない**。消費側は用途に応じて中断するか、網羅性を主張しない形で扱う。
- **区分 (II) は `guarantees` の完全性を損なわない**。消費側は続行してよい（是正は台帳・テスト側の作業）。
- **件数差分（`counts.guarantees - (guarantees | length)`）だけを完全性の根拠にしないこと**。上表のとおり区分 (I) の大半は差分に現れず、差分 0 のまま一覧が不完全・非一意になる。
- この分類は**消費側が扱いを分けるための区分**であり、`status` の算出には影響しない（`broken` が非空なら区分によらず `fail`）。

#### 読んだ台帳の同一性（`ledger`）

`ledger` は**渡した引数をそのまま返す**（正規化・絶対パス化をしない。引数を省略した場合は既定値 `docs/guarantees.md` がそのまま入る）。消費側は **`ledger` が自分の渡したパスと一致することを確認できる**——複数の `docs/guarantees.md` を持つリポジトリで、引数の省略や cwd 違いによって**別の台帳を読んだ結果**を消費していないことの機械的な確認になる。

exit code:

| code | 意味 |
|---|---|
| 0 | `status: "pass"`（索引が健全） |
| 1 | `status: "fail"`（stdout には JSON を出す。人間向けの要約は stderr） |
| 2 | 実行前提の欠落（jq 不在・未知オプション・引数過多・台帳が読めない・`--base` が存在しない・**台帳に「保証」節が無い**）。**stdout は空**で、stderr にエラー JSON とメッセージを出す |

呼び出し側の規律:

- exit 2 を「検査対象なし」＝ pass に読み替えない。台帳の取り違え・節名の変更で全保証が未検査になった状態を pass として通すと、索引ゲートが素通りする。
- 保証が0件（節はあるが `###` 見出しが無い）の場合は `status: "pass"` ＋ stderr に警告を出す。**索引としては健全（壊れた参照が存在しない）だが台帳としては未整備**、という区別を呼び出し側が行えるよう、件数は `counts.guarantees` で判別する。
- **`provenance.kind` が `pending`（`- 宣言元: 裁可待ち`）の保証がある場合も stderr に警告を出す**（`status` は落とさない）。`裁可待ち` は**裁可前のドラフトの規約値**であり、正本台帳に残っているのは裁可経路の取りこぼしである。書式としては正当なため `broken` には積まないが、**`missing_provenance`（出自を追跡できない約束の検出）を回避する抜け道になりうる**ため、黙って通さず件数と ID を stderr に出す。呼び出し側は必要に応じてこの警告を報告へ転記する。
- 台帳の中身が必要な場合は `guarantees` を使い、**呼び出し側が台帳を読み直さない**（読み取り規則の二重化を作らない）。`guarantees` は `status` が `fail` の場合も読み取れた範囲で埋まるが、`status: "fail"` のまま「登録済み」の根拠に使わないこと（書式が壊れている保証が混じっている）。

### 後方互換（宣言元検査の追加時）

`missing_provenance` / `malformed_provenance` / `duplicate_provenance` / `duplicate_guarantee_section` の追加により、**これらに該当する既存台帳は `pass` から `fail` へ変わる**。宣言元は台帳書式の必須項目（`docs/ai-driven-development-strategy.md` 5.3）であり、`missing_test_ref`（テスト参照を1つも持たない保証）と同じ扱いに揃えたもの。既存の呼び出し元（`/quality-check` の索引ゲート・`/promote-verify` の 5.5-4・`/guarantee-audit drift`）は **JSON のフィールド追加では壊れず**、`status` / `broken` の解釈も変わらない（新しい `reason` が増えるだけ）。

**移行手順（宣言元行の一括補完）**: 宣言元は**保証 ID 自身が持っている**（`G-{宣言元番号}-{枝番}` の第1数値が宣言元 Issue / 裁可 PR の番号）。したがって補完は機械的に行える:

1. 索引チェックを実行し、`broken` から `missing_provenance` の `guarantee_id` を列挙する（`jq -r '[.broken[] | select(.reason == "missing_provenance") | .guarantee_id] | .[]'`）。
2. 各 ID について、台帳の該当保証見出し直下へ `- 宣言元: #<ID の第1数値>` を追加する（例: `G-123-1` なら `- 宣言元: #123`）。**ID から導けない宣言元は存在しない**（ID の一意性が宣言元スコープで担保されているため）。
3. `malformed_provenance` は値の書き直し（`- 宣言元: PR #163` → `- 宣言元: #163` など）、`duplicate_provenance` は2行目以降の削除、`duplicate_guarantee_section` は節の統合または見出しの改名で解消する。
4. 再実行して `status: "pass"` を確認する。

**猶予フラグ（検査を無効化するオプション）は設けない**。索引ゲートを部分的に無効化する手段は、それ自体が「検査していないものを pass に見せる」経路になり、本スクリプトが塞いでいる欠陥と同型になるため。上記のとおり補完は ID から機械的に導けるので、猶予期間を置く必要が無い。

## パースの規約

判定対象は台帳の固定書式（`docs/ai-driven-development-strategy.md` の正本と同一）:

```markdown
## 保証（Guarantees）

### G-123-1: POST /api/contact は JSON パース不能時に 400 を返す

- 種別: API契約
- テスト: `tests/api/contact.test.ts::returns 400 for invalid json`
- 宣言元: #123

## Gaps（テストのない公開面）

- [ ] GAP-001: GET /api/health のレスポンス形式（テスト未整備）
```

- **保証節**: `## 保証` で始まる見出し（`## 保証（Guarantees）` に一致）。次の `#` / `##` 見出しまでがこの節。
- **保証見出し**: 保証節内の `### <ID>: <約束文>`。ID は `G-{数字}-{枝番}` 固定。
- **テスト参照行**: 保証見出し直下のリスト項目 `- テスト: <参照>`。太字（`**`）の有無・半角/全角コロン（`:` / `：`）を許容する。1行に複数のバッククォート囲みがあればすべて参照として扱う。**バッククォート囲みが無くても `<パス>::<テスト名>` の形であれば参照として受け付ける**（装飾の欠落だけでは落とさない）。
- **宣言元行**: 保証見出し直下のリスト項目 `- 宣言元: #<番号>`。太字（`**`）の有無・半角/全角コロン（`:` / `：`）を許容する。裁可前のドラフトの規約値 `裁可待ち` を受け付ける。それ以外の値は `malformed_provenance`、行が無ければ `missing_provenance`、2行以上あれば `duplicate_provenance`。
- **Gaps 節**: `## Gaps` で始まる見出し。配下の `- [ ] GAP-NNN: ...`（`[x]` も可）を GAP として数える。**`GAP-NNN:` 書式に合致しないチェックリスト行は `malformed_gap_id` として `broken` に積む**（不正な ID を「GAP 行ではない」として黙って読み飛ばすと、件数にも問題一覧にも現れないまま台帳が pass するため）。チェックリスト形式でない行（節内の散文・注記）は対象外。
- `counts.gaps` に数えるのは**書式を満たす GAP 行のみ**。書式違反の行は `counts.broken` 側に現れる。
- **コードフェンス（``` / ~~~）の内側は検査対象外**。台帳が書式例を引用していても誤検出しない。閉じフェンスと認めるのは開始フェンスと同じ記号で・開始フェンス以上の長さで・情報文字列を伴わない行のみ（CommonMark と同じ規則）。
- CRLF 改行を許容する。
- **約束文・テスト参照・書式違反の見出しにタブが含まれていても、`guarantees` / `broken` は台帳の記載どおりの値を返す**（内部のタブ区切り受け渡しでエスケープし、JSON 組み立て時に復元する）。タブによって列がずれ、出力が空になる・別のフィールドを読む・値が切り詰められる、といったことは起きない。
- テスト参照のパスは `base` からの相対パスとして解決する（`/` で始まる場合は絶対パスとして扱う）。

## テスト名の一致判定の限界（既知）

テスト名の照合は**ファイル内の部分文字列の出現**で行う（テストフレームワーク非依存にするため、構文解析はしない）。このため次のケースは検出できない:

- テスト名を実行時に組み立てている場合（テンプレート文字列・パラメタライズドテストの動的生成）
- 同名のテストが複数ファイルに存在し、台帳の参照パスだけが古い場合（名前は別ファイルで一致してしまう… という誤検出ではなく、**参照パスのファイルに名前がある限り pass になる**という取りこぼし）
- コメント中にテスト名と同じ文字列が残っている場合（テストを消してもコメントが残っていれば pass になる）

これらは意味整合（`/guarantee-audit drift`）側で拾う前提の割り切りであり、索引チェックの役割は「明らかに壊れた参照を毎ループ潰す」ことに限定する。

## 挙動の要点

- 判定ロジックは `gic_scan`（台帳本文 → `GIC_REFS` / `GIC_ALL_REFS` / `GIC_GUARANTEES` / `GIC_ISSUES` / 各件数）、保証1件を閉じる際の検査（テスト参照ゼロ件・宣言元）は `gic_close_guarantee`、実ファイル検査は `gic_check_refs`、参照解決の基準ディレクトリの決定は `gic_resolve_base` として関数分離されており、スクリプトを `source` すれば直接テストできる（テストは `scripts/tests/test-guarantee-index-check.sh`）
- jq 不在時は stderr にエラーメッセージ + エラー JSON を出し exit 2（`scripts/README.md`「出力規約」に従う）
- 台帳を書き換える機能は持たない（監査と修正の分離。修正は通常の実装フローで行う）

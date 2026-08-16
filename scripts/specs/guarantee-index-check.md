# guarantee-index-check.sh の出力仕様（正本）

保証台帳（`docs/guarantees.md`）の**テスト対応索引**を決定的に検査する。gh 呼び出しは一切行わない（gh 非依存）。

検査するのは「索引ドリフト」（テストの改名・削除・移動により台帳の参照が実在しなくなること）と「ID の重複」のみで、**意味ドリフト**（約束の文言とテストの実際の検証内容の乖離）は検査しない。意味整合は `/guarantee-audit drift` の LLM fan-out の責務。台帳の書式・運用の正本は `docs/ai-driven-development-strategy.md`「開発フェーズとドキュメントライフサイクル」の章。

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
| `broken` | `[{guarantee_id, ref, reason}]` | 検出した問題。`ref` は参照を伴わない問題では `null` |

**呼び出し元が判定に使う契約フィールドは `status` と `broken` の2つ**（`/quality-check` の索引ゲートはこの2つだけを見る）。`ledger` / `base` / `counts` は報告用の付加情報。

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
| `guarantee_outside_section` | `### G-...` 見出しが「保証」節の外にある（節の外の保証は索引検査の対象外になるため、黙って見逃さず報告する） |

exit code:

| code | 意味 |
|---|---|
| 0 | `status: "pass"`（索引が健全） |
| 1 | `status: "fail"`（stdout には JSON を出す。人間向けの要約は stderr） |
| 2 | 実行前提の欠落（jq 不在・未知オプション・引数過多・台帳が読めない・`--base` が存在しない・**台帳に「保証」節が無い**）。**stdout は空**で、stderr にエラー JSON とメッセージを出す |

呼び出し側の規律:

- exit 2 を「検査対象なし」＝ pass に読み替えない。台帳の取り違え・節名の変更で全保証が未検査になった状態を pass として通すと、索引ゲートが素通りする。
- 保証が0件（節はあるが `###` 見出しが無い）の場合は `status: "pass"` ＋ stderr に警告を出す。**索引としては健全（壊れた参照が存在しない）だが台帳としては未整備**、という区別を呼び出し側が行えるよう、件数は `counts.guarantees` で判別する。

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
- **Gaps 節**: `## Gaps` で始まる見出し。配下の `- [ ] GAP-NNN: ...`（`[x]` も可）を GAP として数える。
- **コードフェンス（``` / ~~~）の内側は検査対象外**。台帳が書式例を引用していても誤検出しない。閉じフェンスと認めるのは開始フェンスと同じ記号で・開始フェンス以上の長さで・情報文字列を伴わない行のみ（CommonMark と同じ規則）。
- CRLF 改行を許容する。
- テスト参照のパスは `base` からの相対パスとして解決する（`/` で始まる場合は絶対パスとして扱う）。

## テスト名の一致判定の限界（既知）

テスト名の照合は**ファイル内の部分文字列の出現**で行う（テストフレームワーク非依存にするため、構文解析はしない）。このため次のケースは検出できない:

- テスト名を実行時に組み立てている場合（テンプレート文字列・パラメタライズドテストの動的生成）
- 同名のテストが複数ファイルに存在し、台帳の参照パスだけが古い場合（名前は別ファイルで一致してしまう… という誤検出ではなく、**参照パスのファイルに名前がある限り pass になる**という取りこぼし）
- コメント中にテスト名と同じ文字列が残っている場合（テストを消してもコメントが残っていれば pass になる）

これらは意味整合（`/guarantee-audit drift`）側で拾う前提の割り切りであり、索引チェックの役割は「明らかに壊れた参照を毎ループ潰す」ことに限定する。

## 挙動の要点

- 判定ロジックは `gic_scan`（台帳本文 → `GIC_REFS` / `GIC_ISSUES` / 各件数）、実ファイル検査は `gic_check_refs`、参照解決の基準ディレクトリの決定は `gic_resolve_base` として関数分離されており、スクリプトを `source` すれば直接テストできる（テストは `scripts/tests/test-guarantee-index-check.sh`）
- jq 不在時は stderr にエラーメッセージ + エラー JSON を出し exit 2（`scripts/README.md`「出力規約」に従う）
- 台帳を書き換える機能は持たない（監査と修正の分離。修正は通常の実装フローで行う）

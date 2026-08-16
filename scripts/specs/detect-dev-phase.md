# detect-dev-phase.sh の出力仕様（正本）

導入先プロジェクトの `CLAUDE.md` に宣言された**開発フェーズ**（SDD期 / GDD期）を決定的に判定する。gh 呼び出しは一切行わない（gh 非依存）。

フェーズ判定に依存するスキルは、**このスクリプトの出力のみを正とする**（各スキルが `CLAUDE.md` を独自に grep しない）。フェーズ宣言の書式・運用の正本は `docs/ai-driven-development-strategy.md`「開発フェーズとドキュメントライフサイクル」の章。

## `scripts/detect-dev-phase.sh [CLAUDE.md のパス]`

引数を省略した場合、判定対象は次の順で解決する:

1. cwd の `CLAUDE.md`
2. 1 が無ければ `git rev-parse --show-toplevel` で解決したリポジトリルートの `CLAUDE.md`（サブディレクトリ・worktree 内からの実行で宣言を見落とし、GDD期のプロジェクトを SDD期 と誤判定しないため）
3. どちらも無ければ「宣言なし」＝ SDD期（`reason: "no_claude_md"`）

引数でパスを明示した場合、そのファイルが読めなければ**フォールバックせず** exit 2（実行前提の欠落）とする。

stdout JSON:
```json
{
  "phase": "sdd",
  "reason": "declared_sdd",
  "source": "CLAUDE.md"
}
```

| フィールド | 型 | 意味 |
|---|---|---|
| `phase` | `"sdd"` \| `"gdd"` \| `"invalid"` | 判定結果。`invalid` は「宣言はあるが不正」＝**要人間判定**（SDD期 とみなしてはならない） |
| `reason` | string | 判定理由コード（下表の固定語彙） |
| `source` | string \| null | 判定に使った `CLAUDE.md` のパス。`CLAUDE.md` 自体が無い場合は `null` |

`reason` の語彙:

| `phase` | `reason` | 意味 |
|---|---|---|
| `sdd` | `no_claude_md` | `CLAUDE.md` が見つからない（宣言なし = 後方互換で SDD期） |
| `sdd` | `no_phase_section` | `## 開発フェーズ` 見出しが無い（宣言なし = 後方互換で SDD期） |
| `sdd` | `declared_sdd` | `SDD期` が宣言されている |
| `gdd` | `declared_gdd` | `GDD期` が宣言されている |
| `invalid` | `malformed_phase_heading` | `開発フェーズ` 見出しの階層が `## ` ではない（`### 開発フェーズ` 等） |
| `invalid` | `duplicate_phase_section` | `## 開発フェーズ` 見出しが複数ある |
| `invalid` | `missing_phase_field` | 見出しはあるが、セクション直下に `- **フェーズ**: ...` 行が無い |
| `invalid` | `duplicate_phase_field` | セクション内に `フェーズ` 行が複数ある |
| `invalid` | `unreplaced_placeholder` | 値が未置換のテンプレートプレースホルダ（`{DEV_PHASE}` 等、`{` `}` を含む） |
| `invalid` | `unknown_phase_value` | 値が許容値（`SDD期` / `GDD期`）以外 |

exit code:

| code | 意味 |
|---|---|
| 0 | `phase` が `sdd` / `gdd` として確定した |
| 1 | `phase` が `invalid`（stdout には JSON を出す。人間向けの理由は stderr） |
| 2 | 実行前提の欠落（jq 不在・未知オプション・引数過多・明示指定したパスが読めない）。**stdout は空**で、stderr にエラー JSON とメッセージを出す |

呼び出し側の規律（`docs/ai-driven-development-strategy.md` の共通文言と同一）:

- exit 1（`invalid`）・exit 2 のいずれも **`sdd` に読み替えない**。フェーズ依存の処理を停止し、要人間判定として報告する（不正宣言や実行不能によって GDD のゲート群が暗黙に無効化される事故を防ぐ）。
- GDD期のときだけ追加挙動を行い、SDD期・宣言なしのプロジェクトでは一切挙動を変えない。

## パースの規約

判定対象は次の書式に固定する（`docs/ai-driven-development-strategy.md` の正本と同一）:

```markdown
## 開発フェーズ

- **フェーズ**: GDD期
- 駆動文書: docs/guarantees.md
```

- **セクション**: `## 開発フェーズ`（見出しテキストが完全一致・階層は `##`）。次の見出し（階層を問わない）までがセクション。
- **フェーズ行**: セクション直下のリスト項目 `- **フェーズ**: <値>`。太字（`**`）の有無、半角/全角コロン（`:` / `：`）、値を囲むバッククォート・太字は許容し、値は前後空白を除去して比較する。値の許容は `SDD期` / `GDD期` の2値のみ。
- **`駆動文書` 行は判定に使わない**（人間向けの注記であり、欠落しても宣言を無効化しない）。
- **コードフェンス（``` / ~~~）の内側は判定対象外**。CLAUDE.md が宣言書式の例を引用していても誤判定しない。
- 宣言の有効性判定（不正なら `invalid` で停止）は上表の `reason` 語彙のとおり。

挙動の要点:

- 判定ロジックは `detect_dev_phase_scan`（本文テキスト → `DEV_PHASE_PHASE` / `DEV_PHASE_REASON` / `DEV_PHASE_DETAIL`）、値の正規化は `dev_phase_trim`、判定対象の解決は `dev_phase_resolve_source` として関数分離されており、スクリプトを `source` すれば直接テストできる（`spec-lint.sh` のパターンを踏襲。テストは `scripts/tests/test-detect-dev-phase.sh`）
- jq 不在時は stderr にエラーメッセージ + エラー JSON を出し exit 2（`scripts/README.md`「出力規約」に従う）
- `phase` を書き換える機能は持たない（フェーズを確定できるのは人間が `CLAUDE.md` に記載する宣言のみ。エージェントは読むのみで書き換えない）

# demo-e2e-out.sh の出力仕様（正本）

`/demo-e2e`（`skills/demo-e2e/SKILL.md` Step 2-2）が成果物パス（SAFE_CASE_ID・attempt番号）を求める際に呼び出す（Issue #147）。CASE_ID のサニタイズ・衝突防止ハッシュ・attempt採番という決定的処理を、実行のたびのLLMアドホック再実装から切り出したもの。gh は呼ばない（gh非依存）。

## `scripts/demo-e2e-out.sh <CASE_ID>`

stdout JSON（1行・compact）:
```json
{"safe_case_id": "CASE-101-3f2a1c9d", "out_dir": "demo-e2e-artifacts/CASE-101-3f2a1c9d/attempt-1", "attempt": 1, "gitignore_warning": false}
```

| フィールド | 型 | 意味 |
|---|---|---|
| `safe_case_id` | string | CASE_ID から導出したファイルシステム安全な識別子。`<サニタイズ済み可読部>-<hash8>` 形式（下記参照） |
| `out_dir` | string | 成果物の出力先。**projectRoot からの相対パス** `demo-e2e-artifacts/<safe_case_id>/attempt-<attempt>`（絶対パスにしない。`run-walkthrough.mjs` の `WALKTHROUGH_OUT` は projectRoot 基準の `path.resolve()` で解決される仕組みのため、相対パスのまま渡す前提と整合させる） |
| `attempt` | number | このケースの `demo-e2e-artifacts/<safe_case_id>/` 配下に存在する `attempt-<数字>` ディレクトリの最大番号+1。該当ディレクトリが無い、または `attempt-*` が1件も無ければ `1` |
| `gitignore_warning` | bool | projectRoot の `.gitignore`（git管理下）が `demo-e2e-artifacts` をカバーしていなければ `true` |

挙動の要点:

- **入力検証**: 引数が空、または空白のみ（trimして空）の場合は使用方法を stderr に出し非0 exit（stdout には何も出さない）
- **前後空白のtrim**: CASE_ID の前後空白（space/tab/newline）は識別子の一部とみなさない。空判定だけでなく `safe_case_id` の導出にも trim 後の値を使う（同じ論理ケースが前後空白の有無だけで別の `safe_case_id`／別の attempt 系列に分裂しないようにするため）
- **SAFE_CASE_ID のエンコード（一律・単射。PR #146 4ラウンド目レビューで確定した仕様）**: 条件付きハッシュ（置換が発生した場合のみハッシュを付ける）にはしない。trim後の非空 CASE_ID すべてに対して常に次の1つの規則を適用する:
  1. サニタイズ済み可読部: CASE_ID 中の `[A-Za-z0-9._-]` 以外の文字を `_` に置換したもの（改行を含む。ロケール依存の揺れ・不正バイト列によるクラッシュを避けるため `LC_ALL=C` でバイト単位に固定して置換する）
  2. 元の CASE_ID（サニタイズ前、trim後）の決定的な短いハッシュ（SHA-256 先頭8文字・16進数）を `-<hash8>` として**常に**付加する
  3. `safe_case_id = "<サニタイズ済み可読部>-<hash8>"`

  この規則により条件付き実装が不要になる: 例えば `A/B` → `A_B` + `-` + hash8("A/B")、`A_B` → `A_B` + `-` + hash8("A_B") となり、サニタイズ済み可読部が同じでもハッシュが異なるため衝突しない（単射性）。`.` や `..` も同一規則でハッシュが付くため自然に安全な文字列（`/` を含まず `.`/`..` 単体にもならない）になり、特別なフォールバック分岐は不要
  - ハッシュは `shasum -a 256`（macOS標準）と `sha256sum`（coreutils。Linux通常同梱）の両方を試す（どちらも同じダイジェスト値を返すためプラットフォーム間で結果が一致する）。どちらも無ければ stderr にエラーを出し非0 exit。ハッシュ対象文字列は `printf '%s'`（`echo` は使わない）で渡し、末尾改行の混入で結果がブレないようにする
- **プロジェクトroot解決**: `skills/demo/scripts/run-walkthrough.mjs` の `resolveProjectRoot` と同一規則。`WALKTHROUGH_PROJECT_ROOT` が設定されていればそれを使い、未設定なら `git rev-parse --show-toplevel`、それも失敗すれば cwd にフォールバックする。解決したパスが存在しないディレクトリの場合は非0 exit。相対パスで指定された `WALKTHROUGH_PROJECT_ROOT` にも対応するため、以降のスキャン・gitignore判定は解決したパスを起点にした絶対パスで行う
- **attempt 採番**: 上記で解決した projectRoot 配下の `demo-e2e-artifacts/<safe_case_id>/` をスキャンし、`attempt-<数字>` ディレクトリの最大番号+1を採用する（数値として比較する。`attempt-10` は `attempt-2` より大きい。ゼロ埋め表記の `attempt-08` 等が存在しても10進数として正しく扱う）
- **gitignore 警告**: 独自にgitignoreパターンをパースせず `git -C "<projectRoot>" check-ignore -q "demo-e2e-artifacts"` を使う。exit 0（ignore対象）なら `gitignore_warning: false`、exit 1（非対象）なら `true`。それ以外（非gitリポジトリ等の判定不能）は安全側に倒し `true`
- jq 不在時は stderr にエラーを出し非0 exit（`scripts/lib/common.sh` の `check_jq` を使用）
- **カタログ解決時の空/重複 CASE_ID 拒否**: 空文字列の拒否は本スクリプトが担う（上記入力検証）。重複 CASE_ID の拒否（同一カタログ内に同じ CASE_ID が複数存在する場合の実行前エラー）は本スクリプトの責務外（単一 CASE_ID を受け取る設計のため）。呼び出し元の `skills/demo-e2e/SKILL.md` Step 1-1（カタログ解決）側で扱う

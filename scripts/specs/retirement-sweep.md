# retirement-sweep.sh の出力仕様（正本）

退役（削除）した駆動文書への**被参照**がリポジトリに残っていないかを決定的に走査する。gh 呼び出しは一切行わない（gh 非依存）。

**駆動文書の削除は正本の引っ越しであり、被参照の付け替えまでが1セットである。** 退役手順が「ADR 昇格の要否判定」と「ドキュメントマップの更新」だけを定めていた時期に、削除済みファイルへの参照が **52箇所／28ファイル**残った（利用者向けドキュメントのリンクが 404 になり、実装コメントから設計根拠を辿れなくなった）。退役の目的（エージェントの Glob/Grep から汚染源を除く）に対して**辿れない参照を撒く**という逆の結果になる。本スクリプトはその掃引を機械化し、退役の完了条件「参照 0 件」を exit code で判定できるようにする。

手順側の正本は `docs/ai-driven-development-strategy.md`「開発フェーズとドキュメントライフサイクル」5.5 手順4（機能仕様の退役）。**付け替え先の判断基準（どの参照を保証 ID / ADR / Issue のどれへ向けるか）はそちらが正本**であり、本スクリプトは判断しない（候補を漏れなく出すところまでが責務）。

## `scripts/retirement-sweep.sh <退役したパス>... [--base <dir>] [--adr-dir <dir>]`

- `<退役したパス>` は**リポジトリルート相対**のパスを1個以上。複数指定できる（退役は複数ファイルをまとめて行うのが通常）。
- `--base <dir>` は走査するリポジトリの作業ツリー（既定: cwd から `git rev-parse --show-toplevel` で解決したルート）。
- `--adr-dir <dir>` は除外する ADR 置き場（既定: `docs/adr/`）。`docs/adr` / `./docs/adr/` のいずれの表記でも同じ前置きに正規化する。

走査対象は **git の追跡ファイル＋未追跡（非 ignore）ファイル**（`git grep --untracked`）。退役 PR の作業中——削除をコミットする前——に実行できるようにするため。

### 除外は「消してはいけない参照」の列挙であって、検査の無効化ではない

ADR の `宣言元は退役した <path>` は**正しい出所記録**であり、退役に伴って書き換えてはいけない（実測でこの形が10箇所あった）。そのため `--adr-dir` 配下は `status` の判定から外す。ただし:

- 除外したヒットは**捨てずに `excluded` として返し、`counts.excluded` に数え、stderr にも件数を出す**。黙って範囲を狭めると、掃引漏れと「除外して正しかった」が区別できなくなる。
- **汎用の `--exclude` は設けない。** 任意のパスを掃引対象から外せるフラグは、それ自体が「検査していないものを 0 件に見せる」経路になり、本スクリプトが塞いでいる欠陥と同型になる。除外してよい集合は上記1つだけであり、増やす場合は本仕様に理由つきで列挙する。
- `--adr-dir` に空文字は渡せない（exit 2）。除外を空にすると ADR の出所記録まで掃引対象になり、**消してはいけない参照を消す**方向の誤りを誘発する。

### 一致の取り方（パス形と弱一致）

一致は**リテラル一致**（`grep -F`）で行う。正規表現を受け付けると、退役パスに含まれる `.` が任意文字になり、無関係な行を参照として報告する。

| 種別 | 検索語 | `status` への影響 | 出力先 |
|---|---|---|---|
| `path` | 退役パスそのもの（`docs/features/daily-report.md`） | **落とす**（1件でもあれば `fail`） | `references` |
| `basename` | ファイル名だけ（`daily-report.md`） | **落とさない** | `weak_matches` |

- `basename` を `status` の根拠にしないのは、**同名別ファイルに当たりうる**ため。誤検出で退役を止めない。
- ただし黙って捨てない（`counts.weak` と stderr の警告に出す）。「検出したが `status` に出していない」ことと「検出していない」ことを区別できるようにするため。**弱一致の仕分けは手順側（退役 PR のレビュー）の責務**。
- `path` として拾った行（除外された行を含む）は `basename` でも当たるが、**二重には数えない**。二重計上すると `counts.weak` が「パス形では拾えなかった言及」を表さなくなり、仕分けの対象が読めなくなる。
- 退役パスにディレクトリが含まれない場合（`README.md` のようにルート直下）は `path` と `basename` が同一になるため、弱一致の走査は行わない。

### 検出できないもの（既知の限界）

リテラル一致であるため、次は検出できない。**手順側は本スクリプトの exit 0 を「参照が1つも無い」の証明として扱わず、「そのパス表記の参照が無い」として扱うこと**:

- パスを組み立てて参照している場合（変数連結・テンプレート）
- 別表記での言及（表示名だけのリンク・別名・URL 形式・`features/daily-report` のように拡張子を落とした形）
- ignore されているファイル・別リポジトリからの参照

## stdout JSON

```json
{
  "status": "fail",
  "base": "/path/to/repo",
  "targets": ["docs/features/daily-report.md"],
  "excluded_dirs": ["docs/adr/"],
  "counts": { "targets": 1, "references": 3, "files": 2, "excluded": 1, "weak": 1 },
  "references": [
    { "target": "docs/features/daily-report.md", "file": "src/report.ts", "line": 1, "text": "// 設計根拠: docs/features/daily-report.md の 3.2 節", "match": "path" }
  ],
  "excluded": [
    { "target": "docs/features/daily-report.md", "file": "docs/adr/0007-report.md", "line": 2, "text": "宣言元は退役した docs/features/daily-report.md", "match": "path" }
  ],
  "weak_matches": [
    { "target": "docs/features/daily-report.md", "file": "web/note.md", "line": 1, "text": "無関係な daily-report.md という言及だけの行", "match": "basename" }
  ]
}
```

| フィールド | 型 | 意味 |
|---|---|---|
| `status` | `"pass"` \| `"fail"` | `references` が空なら `pass` |
| `base` | string | 走査したリポジトリルート（絶対パス） |
| `targets` | `[string]` | 走査した退役パス（正規化後。先頭の `./` は除去） |
| `excluded_dirs` | `[string]` | 除外したディレクトリの前置き（末尾スラッシュ付き） |
| `counts` | object | `targets` / `references` / `files`（`references` のユニークファイル数）/ `excluded` / `weak` |
| `references` | `[{target, file, line, text, match}]` | 付け替えるべき参照。`file` はリポジトリルート相対、`line` は数値、`text` はヒット行の記載どおり |
| `excluded` | 同上 | 除外ディレクトリ内のヒット（**書き換えない**。件数の可視化のために返す） |
| `weak_matches` | 同上 | ファイル名だけの言及（`status` には影響しない。人間が仕分ける） |

- **合否判定に使う契約フィールドは `status` と `references` の2つ。** `excluded` / `weak_matches` / `counts` は仕分けと報告のための付加情報。
- `text` はヒット行を**そのまま**返す（タブを含む行でも列がずれず、切り詰めもしない）。内部のタブ区切り受け渡しでエスケープし、JSON 組み立て時に復元する。

## exit code

| code | 意味 |
|---|---|
| 0 | `status: "pass"`（`references` が0件。弱一致・除外の件数は stderr に出る） |
| 1 | `status: "fail"`（付け替えるべき参照が残っている。stdout には JSON を出す） |
| 2 | 実行前提の欠落（jq 不在・未知オプション・対象が0個・空のパス・`--base` が存在しない・git 作業ツリーでない・`--adr-dir` が空・**退役対象がまだ作業ツリーに存在する**・走査エラー）。**stdout は空**で、stderr にエラー JSON とメッセージを出す |

`error` の語彙（exit 2 のとき stderr の JSON に入る）: `jq not found` / `unknown option` / `--base requires a value` / `--adr-dir requires a value` / `no target given` / `empty target path` / `base directory not found` / `not a git work tree` / `empty adr dir` / `retired path still present` / `scan failed`。

呼び出し側の規律:

- **exit 2 を「参照なし」＝ pass に読み替えない。** とくに `retired path still present` は、**削除前に走らせた 0 件を「片付いた」と読ませない**ためのもの（削除前は当然そのファイル自身が残っており、掃引の前提が成立していない）。
- **`scan failed`（`git grep` の実行エラー）を「ヒット無し」として通さない。** `grep` の exit code は 0=マッチあり / 1=マッチなし / 2以上=実行エラーであり、2以上を握りつぶすと掃引漏れが `pass` に見える。
- exit 0 は「**指定したパス表記の参照が残っていない**」ことしか意味しない（上記「検出できないもの」）。退役 PR のレビューは、この結果に加えて `weak_matches` の仕分け結果を添えて行う。

## 挙動の要点

- 判定ロジックは `rs_scan_term`（検索語1つ分の走査）・`rs_add_hit`（除外判定とヒットの振り分け）・`rs_already_seen`（パス形と弱一致の二重計上防止）・`rs_normalize_dir_prefix`（除外ディレクトリの正規化）として関数分離されており、スクリプトを `source` すれば直接テストできる（テストは `scripts/tests/test-retirement-sweep.sh`）
- ファイル名一覧は `git grep -z` の NUL 区切りを**一時ファイル経由**で読む。コマンド置換（`$(...)`）は NUL バイトを捨てるため、変数へ入れると全ファイル名が1本に連結され、**1件も回らないまま「参照0件」**になる
- ヒット行の解析はファイルごとに `grep -n` を掛けて `行番号:本文` だけを見る（`git grep` の `ファイル:行:本文` を解析すると、コロンを含むファイル名で列がずれる）
- jq 不在時は stderr にエラーメッセージ + エラー JSON を出し exit 2（`scripts/README.md`「出力規約」に従う）
- 参照を書き換える機能は持たない（検出と修正の分離。付け替えは退役 PR の作業として人間・エージェントが行う）

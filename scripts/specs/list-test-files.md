# list-test-files.sh の出力仕様（正本）

リポジトリ内のテストファイルを**決定的に列挙**し、E2E / 結合 / 単体の区分を付けて返す。gh 呼び出しは一切行わない（gh 非依存）。

`/guarantee-audit bootstrap` が保証台帳ドラフトを起こす際の入力になる。「どのファイルがテストか」を LLM の判断に委ねるとチャンク分割のたびに対象が揺れるため、列挙と分類は本スクリプトが決定的に行い、**振る舞いの抽出と公開面／内部実装の判定だけを LLM が担う**（決定的処理と意味判断の分離）。

## `scripts/list-test-files.sh [オプション]`

| オプション | 意味 |
|---|---|
| `--root <dir>` | 列挙の起点（既定: cwd） |
| `--include <glob>` | テストファイルとして追加で扱う glob（繰り返し可） |
| `--exclude <glob>` | 列挙から除外する glob（繰り返し可）。**`--include` より優先する** |
| `--e2e <glob>` | E2E に分類する glob（繰り返し可・既定規則より優先） |
| `--integration <glob>` | 結合に分類する glob（繰り返し可・既定規則より優先） |

- glob は root からの相対パスに対して評価する（bash のパターンマッチのため `*` は `/` にもマッチする。例: `--e2e "tests/browser/*"`）。
- 位置引数は受け付けない（誤ってパスを渡した場合に黙って無視しないため exit 2）。

stdout JSON:

```json
{
  "status": "ok",
  "root": "/path/to/repo",
  "source": "git",
  "counts": { "e2e": 8, "integration": 4, "unit": 37, "total": 49, "skipped": 0 },
  "files": [
    { "path": "e2e/auth.spec.ts", "category": "e2e", "rule": "name:test-or-spec|dir:e2e" }
  ]
}
```

| フィールド | 型 | 意味 |
|---|---|---|
| `status` | `"ok"` \| `"no_test_files_found"` | テストファイルを1件でも列挙できたか |
| `root` | string | 列挙の起点（絶対パス） |
| `source` | `"git"` \| `"find"` | 列挙元。git リポジトリなら `git`、それ以外は `find` へフォールバック |
| `counts` | object | 区分ごとの件数と `total`。`skipped` はパスにタブ文字または改行文字を含み列挙対象から外した件数（通常 0。中間表現の区切り文字と衝突するため除外し、stderr に警告を出す） |
| `files` | `[{path, category, rule}]` | `path` は root 相対。`category` は `"e2e"` \| `"integration"` \| `"unit"`。`rule` は `<テスト判定規則>\|<分類規則>` |

`files` は **`LC_ALL=C` のパス昇順で固定**する（同じ入力からは常に同じ順序・同じ内容が返る。チャンク分割の再現性のため）。

exit code:

| code | 意味 |
|---|---|
| 0 | 列挙に成功した（**0件の場合も含む**。件数は `status` / `counts` で判別する） |
| 2 | 実行前提の欠落（jq 不在・未知オプション・位置引数・オプションの値欠落・`--root` が存在しない）。**stdout は空**で、stderr にエラー JSON とメッセージを出す |

呼び出し側の規律:

- `status: "no_test_files_found"` を「テストが無いので保証も無い」として先へ進めない。台帳ブートストラップの入力がゼロ件のまま続行すると、**空の台帳ドラフトが「公開面が無い」ことの証明のように見えてしまう**。列挙規則が実プロジェクトのレイアウトに合っていない可能性を疑い、`--include` / `--root` の指定を検討したうえで、解消しなければ人間に報告して停止する。

## 列挙元

1. **git**: `git ls-files --cached --others --exclude-standard`（追跡済み ＋ 未追跡かつ ignore されていないファイル）。まだコミットしていないテストを取りこぼさないため `--others` を含める。worktree から消えている追跡ファイルは除く。
2. **find**（非 git ディレクトリのみ）: 除外ディレクトリを prune した通常ファイル。

## テストファイルの判定規則

以下のいずれかに該当するものをテストファイルとする（`rule` の前半に記録される）:

| 規則 | 対象 | `rule` の値 |
|---|---|---|
| `--include` 指定 | 指定 glob にマッチ | `option:include(<glob>)` |
| ファイル名 | `*.test.*` / `*_test.*` / `*-test.*` / `*.spec.*` / `*_spec.*` / `test_*` / `spec_*`（`Test` / `Spec` の大文字始まりも可） | `name:test-or-spec` |
| クラス名 | 拡張子を除いた名前が `*Test` / `*Tests` / `*TestCase` / `*Spec`（Java・C# 等の規約） | `name:class-suffix` |
| 拡張子 | `.feature`（Gherkin） | `ext:feature` |
| ディレクトリ | `test` / `tests` / `__tests__` / `spec` / `specs` / `e2e` / `cypress` / `playwright` のいずれかを含むパスで、拡張子がコードファイル（`js jsx ts tsx mjs cjs py rb go java kt rs php cs swift scala sh feature`） | `dir:<ディレクトリ名>` |

**除外**（テスト判定より先に適用する）:

- ディレクトリ: `node_modules` `vendor` `dist` `build` `out` `target` `coverage` `.git` `.venv` `venv` `__pycache__` `__snapshots__` `__mocks__` `snapshots` `fixtures` `__fixtures__` `testdata`
- ファイル: `*.d.ts`、`jest.config.*` / `vitest.config.*` / `playwright.config.*` / `cypress.config.*` / `karma.conf.*`、`*.setup.ts` / `*.setup.js`
- `--exclude` 指定にマッチするもの

判定規則は**広めに取り、除外は「テスト本体ではないことが確実なもの」に限る**。テストの取りこぼしは台帳の公開面の取りこぼし（＝守っているつもりで守られていない約束）に直結する一方、ヘルパーファイルが混ざる害は「抽出エージェントが振る舞いを返さない」だけで済むため。

## E2E / 結合 / 単体 の分類規則

上から順に評価し、最初に一致した規則を採る（`rule` の後半に記録される）:

1. `--e2e` 指定にマッチ → `e2e`（`option:e2e(<glob>)`）
2. `--integration` 指定にマッチ → `integration`（`option:integration(<glob>)`）
3. パスに `e2e` / `E2E` / `cypress` / `playwright` / `acceptance` / `uitest` ディレクトリを含む → `e2e`（`dir:<名前>`）
4. ファイル名に `e2e` を区切り付きで含む（`login.e2e.test.ts` 等） → `e2e`（`name:e2e`）
5. 拡張子が `.feature` → `e2e`（`ext:feature`）
6. パスに `integration` 系ディレクトリ（`integration` `integrations` `integration-test(s)` `integration_test(s)`）を含む → `integration`（`dir:<名前>`）
7. ファイル名に `integration` / `int` を区切り付きで含む → `integration`（`name:integration`）
8. それ以外 → `unit`（`default:unit`）

- `it` のような短すぎるディレクトリ名は結合テストの手がかりにしない（無関係なディレクトリを誤検出するため）。
- **プロジェクト固有のレイアウト（例: E2E が `tests/browser/` にある）はオプションで上書きする**。スクリプトが `CLAUDE.md` を読んで推測することはしない（分類が実行のたびに揺れないようにするため）。呼び出し元のスキルが `CLAUDE.md` やテスト設定ファイルから読み取った規約をオプションへ翻訳する。

## 挙動の要点

- 判定ロジックは `ltf_is_test_file`（テスト判定・`LTF_TEST_RULE`）、`ltf_classify`（分類・`LTF_CATEGORY` / `LTF_CATEGORY_RULE`）、`ltf_is_excluded`（除外判定）として関数分離されており、スクリプトを `source` すれば直接テストできる（テストは `scripts/tests/test-list-test-files.sh`）
- これらの関数は結果を**グローバル変数**で返す（コマンド置換で受けるとサブシェルになり、判定規則を格納したグローバル変数が呼び出し元へ伝搬しないため。`scripts/README.md`「テスト」節の既知の落とし穴）
- jq 不在時は stderr にエラーメッセージ + エラー JSON を出し exit 2（`scripts/README.md`「出力規約」に従う）
- ファイルを書き換える機能は持たない（列挙のみ）

# eval/fixtures

harness スキルの評価シナリオを実行するためのテストリポジトリ テンプレートです。

## 含まれるファイル

| ファイル | 目的 |
|---------|------|
| `CLAUDE.md` | テストリポジトリのコーディング規約定義 |
| `package.json` | Node.js プロジェクト設定 |
| `.eslintrc.json` | ESLint 設定（CLAUDE.md の規約に対応） |
| `src/utils.js` | クリーンなコード（self-review TC-02、para-impl TDD用） |
| `src/auth.js` | 規約違反・セキュリティ問題を含むコード（self-review TC-01/TC-04用） |
| `src/legacy.js` | 技術負債を含むコード（reduce-debt用） |
| `tests/utils.test.js` | テストファイル |
| `setup.sh` | テストリポジトリ作成スクリプト |

## テストリポジトリの作成

harness リポジトリのルートから実行:

```bash
bash eval/fixtures/setup.sh [リポジトリ名]
# デフォルト名: harness-eval
```

スクリプトが実行すること:
1. 指定名のディレクトリを作成してフィクスチャをコピー
2. 評価シナリオ（`eval/scenarios/`）をコピー
3. `git init` して初期コミット
4. GitHub リポジトリ作成・評価用 Issue 作成（任意、`gh` コマンドが必要）

## 各ファイルの評価用途

### `src/auth.js` — 意図的な問題を含むファイル

| 問題 | 種別 | 対応TC |
|------|------|--------|
| APIキー・パスワードのハードコード | セキュリティ | self-review TC-01, TC-04 |
| `snake_case` の関数名・引数名 | 規約違反 | self-review TC-01 |
| タブインデント | 規約違反 | self-review TC-01 |

### `src/legacy.js` — 技術負債を含むファイル

| 問題 | 種別 | 対応TC |
|------|------|--------|
| `calculateTotal` と `sumPrices` の重複ロジック | 技術負債 | reduce-debt TC-01 |
| `applyDiscount` と `calcDiscountedPrice` の重複ロジック | 技術負債 | reduce-debt TC-01 |
| 未使用変数 `unusedConfig` | 技術負債 | reduce-debt TC-01 |
| マジックナンバー（`10000`, `5000`, `0.9`, `0.95`） | 技術負債 | reduce-debt TC-01 |

### GitHub Issues（setup.sh で自動作成）

| Issue | タイトル | 対応TC |
|-------|---------|--------|
| #1 | feat: add formatDate function | para-impl TC-01（単一 Issue 通常実装） |
| #2 | fix: README の誤字修正 | para-impl TC-02（複数 Issue 並列実装） |
| #3 | feat: add user authentication | para-impl（実装サンプル） |
| #4 | chore: legacy.js の技術負債調査と改善 | reduce-debt TC-01 |

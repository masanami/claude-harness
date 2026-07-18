# プラグイン内ファイル参照のパス規約

本プラグイン（`skills/` `agents/` `scripts/`）は配布先プロジェクトにインストールされて動く。プラグイン自身のファイル（スクリプト・テンプレート・参照ドキュメント）への参照は、**導入先プロジェクトのファイルと混同されない形**で解決しなければならない。cwd 起点の裸の相対パス（例: `scripts/foo.sh`）は、導入先プロジェクトに同名のディレクトリ・ファイルが存在する場合に誤読・実行不能を起こす。

本文書はパス参照メカニズムごとの規約を1箇所に集約する正本。`scripts/README.md` は scripts/ 配下の実装規約（jq前提・出力規約・テスト方針等）のみを扱い、プラグイン内ファイル参照のパス解決はここを参照する。

---

## (a) Bash 実行

スクリプトを Bash ツールで実行する場合、必ず絶対パスへ展開したうえで**引用符必須**で参照する。

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/xxx.sh" <引数>
```

- `${CLAUDE_PLUGIN_ROOT}` は Bash ツール上でのみ実行時にプラグインルートへ展開される
- cwd 起点の相対パス（`scripts/xxx.sh`）では呼び出さない（導入先プロジェクトの同名パスと衝突しうる／cwd がプラグインルートである保証がない）
- パスに空白を含む環境でも壊れないよう、引用符を省略しない

### 定型の所在注記（コピー用）

各 SKILL.md でスクリプトを初めて実行する箇所には、以下の定型文を配置する（スクリプト名・引数は該当箇所に合わせて置き換える）:

```text
> **スクリプトの所在（重要）**: 本スキルはプラグインとして配布されるため、スクリプトは**ユーザーのプロジェクトroot ではなく、プラグイン配下**にある。スクリプトを実行する際は必ず `bash "${CLAUDE_PLUGIN_ROOT}/scripts/xxx.sh" <引数>` の形式（`${CLAUDE_PLUGIN_ROOT}` は実行時にプラグインルートへ展開される）を用い、相対パス `scripts/xxx.sh` では呼び出さないこと。
<!-- 正本: docs/plugin-path-conventions.md -->
```

## (b) Workflow ツールの `scriptPath` / `args`

Workflow ツールに渡す `scriptPath` 等の引数は、Bash ツールと違い**環境変数展開が行われない**。プレースホルダ文字列 `${CLAUDE_PLUGIN_ROOT}` をそのまま渡しても展開されず、存在しないパスとしてエラーになる。

- Workflow ツールを呼ぶ**前**に、Bash で `echo "$CLAUDE_PLUGIN_ROOT"` 等を実行してプラグインルートの絶対パスを取得する
- 取得した絶対パスと相対部分（例: `/skills/xxx/scripts/yyy.js`）を連結した文字列を `scriptPath` に渡す
- resume 安定性のため、同一セッション内では常に同一の絶対パスをそのまま渡す（都度再計算して微妙に異なる文字列にしない）

## (c) Read ツールで参照する `references/` `templates/` `scripts/README.md`

Read ツールも Bash ツールと同様、パス文字列中の `${CLAUDE_PLUGIN_ROOT}` を展開しない。以下の優先順で解決する:

1. **スキル起動時にコンテキストへ与えられる「Base directory for this skill」を起点に絶対パスを組み立てる**（最も確実。例: `<base>/references/xxx.md`）。スキル自身の `references/` `templates/` はこの方式で解決できる
2. スキル外のファイル（例: `scripts/README.md`）は `<base>/../../scripts/README.md` のように相対階層で辿る
3. Base directory が得られない文脈では、(a) と同様に Bash で `echo "$CLAUDE_PLUGIN_ROOT"` を実行して絶対パスを組み立ててから Read する

### 定型の所在注記（コピー用）

```text
> **参照ファイルの所在（重要）**: 参照ファイルは導入先プロジェクトではなく**プラグイン配下**にある。Read する際は、スキル起動時にコンテキストへ与えられる「Base directory for this skill」を起点に絶対パスを解決する（例: `<base>/references/xxx.md`）。Base directory が得られない場合は Bash で `echo "$CLAUDE_PLUGIN_ROOT"` を実行して絶対パスを組み立てる（Read ツールは環境変数を展開しない）。
<!-- 正本: docs/plugin-path-conventions.md -->
```

## (d) サブエージェントへの受け渡し

エージェント定義（`agents/*.md`）に `${CLAUDE_PLUGIN_ROOT}` への依存を書かない。サブエージェントは呼び出し側（リード）とは別コンテキストで起動され、`${CLAUDE_PLUGIN_ROOT}` が展開される保証がない。呼び出し側が**解決済みの絶対パス**を spawn プロンプト・args に明示的に渡す（模範実装: `/self-review` の git-ops エージェント呼び出し）。

> **検証済み事実（2026-07-18 実機検証）**: Task ツールで spawn した汎用サブエージェント（general-purpose）の Bash 環境で `echo "${CLAUDE_PLUGIN_ROOT:-UNSET}"` を実行した結果は `UNSET` だった。**サブエージェントの Bash 環境で `${CLAUDE_PLUGIN_ROOT}` が設定されている保証は無い**ことが確認済み。このため、サブエージェントにプラグイン内ファイルへのアクセスをさせる場合は、呼び出し側が解決済みの絶対パスを渡すことが**必須**であり、サブエージェント側で `${CLAUDE_PLUGIN_ROOT}` を再展開しようとする実装は成立しない前提で設計すること。

## (e) スクリプト間の同梱参照

スクリプトが同梱の別ファイル（同一ディレクトリ内の別スクリプト等）を参照する場合は `${CLAUDE_PLUGIN_ROOT}` に依存せず、自スクリプトの位置から自己解決する:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
```

- 変数名はスクリプト固有にする（`scripts/tests/` で `source` する際に他スクリプトの同名グローバル変数と衝突させないため。詳細は `scripts/README.md`「テスト」節）

## (f) 実行時ファイルから docs/ 設計文書への参照禁止

`skills/` と `agents/`（実行時にモデルへロードされるファイル）から、`docs/` 配下の設計文書（ADR・戦略文書・経緯記録。本文書 `docs/plugin-path-conventions.md` 自身を含む）を参照しない。

- **規範（何をすべきか）は実行時ファイルに インラインで書き切る**。出典・経緯（なぜそうなのか）は書かない — ADR 等の経緯情報は実行時には不要で、参照が残るとモデルが読みに行きコンテキストを浪費する
- 参照の方向は **docs → skills の一方向のみ許可**（設計文書が実装を指すのは可、逆は不可）
- 複数スキルが共有すべき実行時コンテンツが生じた場合は、`docs/` ではなく `skills/` 内の共通配置（例: `skills/_shared/` や各 skill の `references/`）に置く
- 本文書（`docs/plugin-path-conventions.md`）を実行時ファイルから示す場合も、装飾的な出典として文中に埋め込まない。開発者向けの1行コメントとして **HTML コメントで残す**（実行時のモデルはコメントを読みに行かない）:

  ```text
  <!-- 正本: docs/plugin-path-conventions.md -->
  ```

  このコメントは「この定型文の正本がどこにあるか」を人間の開発者が追えるようにするための目印であり、規範そのものは常にコメントの直前に**インラインで書き切る**（コメントを読まないと規範が分からない状態にしない）。

---

## 再発防止テスト

`scripts/tests/test-path-conventions.sh` が `skills/` `agents/` に対して以下を grep ベースで検査する:

- 裸の `scripts/` 参照（`${CLAUDE_PLUGIN_ROOT}` も `<base>` も `SCRIPT_DIR` 自己解決も伴わない bash 実行）
- `docs/` 配下の設計文書への参照（HTML コメント内は除外）

既知の許容パターンはテストファイル内でホワイトリストとして管理する。

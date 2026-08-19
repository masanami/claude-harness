# プラグイン内ファイル参照のパス規約

本プラグイン（`skills/` `agents/` `scripts/`）は配布先プロジェクトにインストールされて動く。プラグイン自身のファイル（スクリプト・テンプレート・参照ドキュメント）への参照は、**導入先プロジェクトのファイルと混同されない形**で解決しなければならない。cwd 起点の裸の相対パス（例: `scripts/foo.sh`）は、導入先プロジェクトに同名のディレクトリ・ファイルが存在する場合に誤読・実行不能を起こす。

本文書はパス参照メカニズムごとの規約を1箇所に集約する正本。`scripts/README.md` は scripts/ 配下の実装規約（jq前提・出力規約・テスト方針等）のみを扱い、プラグイン内ファイル参照のパス解決はここを参照する。Bash 実行のランチャー（`claude-harness-run`）については、規約は本文書 (a)、**ランチャー自身の契約・セットアップ手順・permission マッチャの実測記録は `docs/script-launcher.md`** が正本。Dynamic Workflow は全廃済み（Issue #106）。Workflow ランタイムに関する実機検証記録は `docs/adr/archive-2026-08-01-dynamic-workflow-historical-record.md` に移設済み（Issue #126。ファイル名の `archive-` 接頭辞は、意思決定記録ではない記録を ADR の採番対象から外すための規約。正本は `docs/ai-driven-development-strategy.md` 4.3）。

## `${CLAUDE_PLUGIN_ROOT}` の位置づけ（重要）

`skills/` `agents/` の文中に現れる `${CLAUDE_PLUGIN_ROOT}` は**プラグインルートの絶対パスを表すプレースホルダ表記**であり、Bash の環境変数ではない。

> **検証済み事実（2026-07-18 実機検証）**: メインセッション・サブエージェントのいずれの Bash 環境でも `echo "$CLAUDE_PLUGIN_ROOT"`（およびデフォルト値付きの `echo "${CLAUDE_PLUGIN_ROOT:-UNSET}"`）は空／`UNSET` を返した。**`${CLAUDE_PLUGIN_ROOT}` を shell 変数として読み出す手順は成立しない。**

環境変数として実際に展開されるのは、`hooks/hooks.json` 等**ハーネスが置換する設定ファイル内の文脈のみ**（本文書が扱うパス参照規約の対象外。`hooks/hooks.json` の既存記述は変更不要）。skills/ agents/ 内で絶対パスが必要な場合は、Bash で値を読み出そうとせず、後述のとおり**スキル起動時にコンテキストへ与えられる「Base directory for this skill」から文字列操作で導出する**。

---

## (a) Bash 実行 — ランチャー `claude-harness-run` 経由

スクリプトを Bash ツールで実行する場合は、**PATH 上のランチャー経由**で、パスもバージョンも含まない形で呼び出す。**引用符を避けるのはコマンドの先頭トークン（`claude-harness-run`）と target だけ**であり、引数として渡す値（パス等）は従来どおり引用してよい。

```bash
claude-harness-run xxx <引数>                              # scripts/xxx.sh
claude-harness-run skills/<skill>/scripts/yyy.sh <引数>    # スキル同梱スクリプト
claude-harness-run --env KEY=VALUE xxx <引数>              # 環境変数を渡す場合
```

- **理由**: Claude Code の Bash permission マッチャはワイルドカードがトークン境界でしか効かず、パス中間（バージョン部分）の `*` を解釈しない。かつルールとコマンドは `:` より手前が引用符まで含めて完全一致する必要がある。従来形（絶対パス＋引用符）は **allowlist で書けるパターンが実質存在せず**、headless 委譲で permission 拒否になっていた（Issue #154）。ランチャー経由なら利用側は `Bash(claude-harness-run:*)` の1行で許可でき、プラグイン更新でも外れない。実測記録・セットアップ手順・allow パターンの正本は `docs/script-launcher.md`
- **先頭トークンを変えない**: `bash claude-harness-run …`・パス付き呼び出し・`FOO=bar claude-harness-run …`（環境変数の前置）はいずれもマッチしない（実測で拒否を確認）。環境変数は `--env` フラグで渡す
- **引数側の引用符は従来どおり**でよい（`--lint "npm run lint"`・`claude-harness-run create-debt-issues "<manifestパス>"` 等）。`:*` が受ける末尾引数側は引用符を含んでもマッチする（実測で確認）。空白を含みうる値（ファイルパス・worktree パス等）は**引用する**
- 同じ理由で、複合コマンドの前段（`cd "<worktreeパス>" && claude-harness-run …`）も**引数側は引用する**（`Bash(cd:*)` の前方一致はコマンド名までのため影響しない）
- cwd 起点の相対パス（`bash scripts/xxx.sh`）では呼び出さない（導入先プロジェクトの同名パスと衝突しうる／cwd がプラグインルートである保証がない）
- 値を Bash で読み出す（`echo "$CLAUDE_PLUGIN_ROOT"` 等）手順は前掲のとおり成立しないため行わない

### フォールバック（ランチャー未導入環境）

`claude-harness-run: command not found` になった場合に**限り**、従来形にフォールバックする:

```bash
bash "<解決済みプラグインルート>/scripts/xxx.sh" <引数>
```

- プラグインルートは「Base directory for this skill」から導出した絶対パスに置換する
- **パスは引用符で囲む**。空白やシェルメタ文字を含むプラグインルート（ローカル checkout・`CLAUDE_HARNESS_ROOT` 指定等）でも確実に実行するため
  - 引用符を付けると allowlist の前方一致ルールは書けなくなるが、**フォールバック経路はもともとバージョン固定の完全一致ルールでしか許可できず**（更新のたびに黙って外れる＝ Issue #154 が「使えない」と結論づけた形）、そこを守る価値より確実な実行を優先する。allowlist を効かせたい経路はランチャー形が担う
- フォールバックで実行した場合は、利用者にランチャー導入（`docs/script-launcher.md`）を案内する

### 定型の所在注記（コピー用）

各 SKILL.md でスクリプトを初めて実行する箇所には、以下の定型文を配置する（スクリプト名・引数は該当箇所に合わせて置き換える）:

```text
> **スクリプトの実行形（重要）**: 本スキルはプラグインとして配布されるため、スクリプトは**ユーザーのプロジェクトroot ではなく、プラグイン配下**にある。スクリプトは必ず PATH 上のランチャー経由で `claude-harness-run xxx <引数>` の形式（パス・バージョン・引用符を付けない。この形だけが `Bash(claude-harness-run:*)` の1行で allowlist できる）で実行し、相対パス `scripts/xxx.sh` では呼び出さないこと。`claude-harness-run: command not found` の場合のみ `bash "<プラグインルート>/scripts/xxx.sh" <引数>`（パスは引用符で囲む。プラグインルートはスキル起動時の「Base directory for this skill」から解決した絶対パス。`${CLAUDE_PLUGIN_ROOT}` は表記上のプレースホルダであり環境変数ではない）にフォールバックし、ユーザーにランチャー導入を案内すること。
<!-- 正本: docs/plugin-path-conventions.md / docs/script-launcher.md -->
```

## (c) Read ツールで参照する `references/` `templates/` `scripts/README.md` `scripts/specs/*.md`

Read ツールも Bash ツールと同様、パス文字列中の `${CLAUDE_PLUGIN_ROOT}` を展開しない。以下の手順で解決する:

1. **スキル起動時にコンテキストへ与えられる「Base directory for this skill」を起点に絶対パスを組み立てる**（例: `<base>/references/xxx.md`）。スキル自身の `references/` `templates/` はこの方式で解決できる
2. スキル外のファイル（例: `scripts/README.md`、各スクリプトの入出力仕様の正本である `scripts/specs/<name>.md`）は `<base>/../../scripts/README.md` や `<base>/../../scripts/specs/<name>.md` のように相対階層で辿る

Base directory はスキル起動時に必ずコンテキストへ与えられるため、これが唯一の解決手順であり、Bash による読み出しへのフォールバックは無い（前掲のとおり成立しないため）。

### 定型の所在注記（コピー用）

```text
> **参照ファイルの所在（重要）**: 参照ファイルは導入先プロジェクトではなく**プラグイン配下**にある。Read する際は、スキル起動時にコンテキストへ与えられる「Base directory for this skill」を起点に絶対パスを解決する（例: `<base>/references/xxx.md`）。
<!-- 正本: docs/plugin-path-conventions.md -->
```

## (d) サブエージェントへの受け渡し

エージェント定義（`agents/*.md`）に `${CLAUDE_PLUGIN_ROOT}` への依存を書かない。サブエージェントは呼び出し側（リード）とは別コンテキストで起動され、`${CLAUDE_PLUGIN_ROOT}` が展開される保証がない。

- **第一手はランチャー**: サブエージェントも PATH 上の `claude-harness-run` を呼べるため、スクリプト実行に絶対パスの受け渡しは不要になった（(a) 参照）
- **フォールバック用に絶対パスも渡す**: ランチャー未導入環境に備え、呼び出し側は**解決済みの絶対パス**も spawn プロンプト・args に渡しておく（模範実装: `ticket-worker` への `ci-wait.sh` 絶対パスの受け渡し。`agents/ticket-worker.md`）。サブエージェント側で `${CLAUDE_PLUGIN_ROOT}` を再展開しようとする実装は成立しない

> **検証済み事実（2026-07-18 実機検証）**: Task ツールで spawn した汎用サブエージェント（general-purpose）の Bash 環境で `echo "${CLAUDE_PLUGIN_ROOT:-UNSET}"` を実行した結果は `UNSET` だった。**メインセッションの Bash 環境で同様に検証した結果も `UNSET` だった**（前掲「`${CLAUDE_PLUGIN_ROOT}` の位置づけ」節参照）。**Bash 環境で `${CLAUDE_PLUGIN_ROOT}` が変数として設定されている保証はどのコンテキストにも無い**ことが確認済み。このため、サブエージェントにプラグイン内ファイルへのアクセスをさせる場合は、呼び出し側が解決済みの絶対パスを渡すことが**必須**であり、サブエージェント側で `${CLAUDE_PLUGIN_ROOT}` を再展開しようとする実装は成立しない前提で設計すること。

## (e) スクリプト間の同梱参照

スクリプトが同梱の別ファイル（同一ディレクトリ内の別スクリプト等）を参照する場合は `${CLAUDE_PLUGIN_ROOT}` に依存せず、自スクリプトの位置から自己解決する:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
```

- 変数名はスクリプト固有にする（`scripts/tests/` で `source` する際に他スクリプトの同名グローバル変数と衝突させないため。詳細は `scripts/README.md`「テスト」節）

## (g) `subagent_type` のプラグイン名前空間プレフィックス

サブエージェントを識別する文字列（Task ツールの `subagent_type`）は、**プラグイン名前空間プレフィックス付き**（`claude-harness:` + `agents/*.md` の `name:` フロントマター値。例: `claude-harness:feature-implementer`）で指定する。プレフィックス無しの裸の名前（例: `feature-implementer`）は名称解決エラーになる。

> **検証済み事実（Issue #41 実機プローブ）**: サブエージェントから Task ツールで別のサブエージェントを spawn する際、`subagent_type` にプレフィックス無しの `feature-implementer` を指定すると名称解決エラーになることを確認済み（`agents/ticket-worker.md` の委譲記述、コミット a1b5196 参照）。

- `agents/*.md` 本文中で自身の `subagent_type` 呼び出され方を自己記述する箇所（`description:` フロントマターや Step 記述）も、同じプレフィックス付き表記に揃える（実際の呼び出し表記と食い違うとドキュメントとして信頼できなくなるため）
- 新しいサブエージェントを追加する際も、この規約に従う

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
- 成立しない `echo "$CLAUDE_PLUGIN_ROOT"` 解決手順の再出現
- `skills/*.md` 内の呼び出し記述と `agents/*.md` 内の自己記述が `claude-harness:` プレフィックス付きであること（(g) の規約）
- 「実行時に（プラグインルートへ）展開される」等、`${CLAUDE_PLUGIN_ROOT}` が環境変数として自動展開されるかのような誤説明の再出現が無いこと（正: 表記上のプレースホルダであり、実行前に Base directory から解決した絶対パスへ置換する）
- allowlist できない実行形の再出現が無いこと（(a) の規約）: 実行位置の `${CLAUDE_PLUGIN_ROOT}`（引用符の有無を問わない）、実行位置へのマシン固有な絶対パス直書き、ランチャーへの実行系・パス・環境変数の前置（`bash claude-harness-run …` / `…/bin/claude-harness-run …` / `FOO=bar claude-harness-run …`。環境変数名は小文字を含む POSIX 形式も検出する）
  - フォールバック形 `bash "<プラグインルート>/scripts/xxx.sh"` は正当なため検出対象外（プレースホルダ表記であり、引数側の引用符は allowlist に影響しない）
  - **検出パターン自体の自己検査**を同テスト内に持つ（既知の違反形・正当形をパターンに直接掛ける）。grep は「マッチなし」と「パターンが壊れて検出できない」を区別しないため、検出器が機能していることを毎回確認する
- **ランチャー／フォールバックへ渡すパス引数の引用漏れ**（(a) の「空白を含みうる値は引用する」の再発防止）。先頭トークンと target（規約上引用符を付けない）は対象外とし、それ以降の引数のうちパス様のもの（パス区切り＋拡張子を持つトークン、`<...パス>` `<...file>` 等のプレースホルダ）が引用されていない場合に違反とする。ブランチ名（拡張子を持たない）・番号・リダイレクト先は誤検出しない。こちらも検出器の自己検査を持つ

`bin/claude-harness-run` 自体の契約は `scripts/tests/test-claude-harness-run.sh` が検証する（target 解決・引数／終了コード／cwd／stdin の透過・プラグインルートの解決順・不正入力の拒否）。

既知の許容パターンはテストファイル内でホワイトリストとして管理する。

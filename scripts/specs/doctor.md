# doctor.sh の出力仕様（正本）

導入先プロジェクトが **claude-harness の現行版を使うための前提**を満たしているかを決定的に診断する。gh 呼び出しは一切行わない（gh 非依存）。**何も書き換えない**（読み取り専用）。

`/init-project` は `CLAUDE.md` と `.claude/settings.json` を生成するが、生成物の**テンプレート追従（マイグレーション）**を持たない。そのため harness 側が要求する呼び出し形を変えても、先に scaffold された既存プロジェクトは追従できない。実害は allow 漏れで headless 委譲がブロックされる形で 4 回再発している（Issue #154 / #178）。本スクリプトはその追従漏れを**検出と提示**の側で塞ぐ。

## 自動適用しない（設計の中心）

**是正は行わない。** 検出した不足は「人間がそのまま実行できるコマンド」として `remediation` に出すところまでが責務である。理由:

- エージェントは `.claude/settings.json` を**原理的に書けない**（headless はパス保護、対話 auto mode は分類器がブロックする。いずれも実測済み）。書けない相手のために自動適用を設計しても、動くのは人間が手で走らせる経路だけになる。
- 読み取り専用であることは、**実行前後のバイト一致（`cmp`）で機械的に検算できる**。書き込みを持つと、非破壊性の担保が「削除範囲を比較対象から除外した検算」＝空虚に真になりうる形へ後退する（claude-flywheel PR #94 で実際に起きた欠陥）。
- allow の追加そのものは `skills/init-project/scripts/generate-settings.sh` の**冪等マージ**が既に持っている。本スクリプトはその再実行コマンドを提示するだけでよく、2 つ目のマージ実装を作らない。

## `scripts/doctor.sh [--project <dir>] [--target <path>] [--claude-md <path>] [--pm <pm>] [--test <fw>]... [--infra <infra>]... [--input <file|->]`

| 引数 | 内容 |
|---|---|
| `--project <dir>` | 診断対象のプロジェクトルート（既定: cwd）。`--target` / `--claude-md` の既定値の起点であり、ドキュメントマップの相対パスもここから解決する |
| `--target <path>` | 検査する settings ファイル（既定: `<project>/.claude/settings.json`） |
| `--claude-md <path>` | 検査する `CLAUDE.md`（既定: `<project>/CLAUDE.md`） |
| `--pm` / `--test` / `--infra` / `--input` | 期待 allow の条件付き部分を決める。**語彙・意味・複数指定の可否は `generate-settings.sh` と完全に同じ**（同じ関数へそのまま渡すため） |

`remediation` に出す再実行コマンドには、**診断に使った条件（`--pm` / `--test` / `--infra`）をすべて載せる**。落とすと、提示したコマンドを実行しても不足として報告した allow が入らない。

`--pm` 等を省略した場合、期待 allow は共通権限のみになる（pm 別・testFW 別・infra 別の追加分は「不足」と判定しない）。`/init-project` 実行時と同じ判定をさせたい場合は `analyze-project.sh` の出力を `--input` で渡す。

### 期待 allow は列挙せず、生成器から導出する

harness が要求する allow の**正本は `generate-settings.sh` の `gs_build_generated_settings_json`**（＝ `/init-project` が実際に書き込むもの）であり、本スクリプトはそれを `source` して呼び出した結果を期待値に使う。**期待 allow の一覧を本スクリプトや本仕様へ書き写さない。** 2 つのリストを同期させる散文規定は必ずずれ、しかもずれても誰も気付かない（生成器が新しい allow を足しても診断が要求しないため、追従漏れの検出という目的が静かに失われる）。

`gs_build_generated_settings_json` には deny の正本（`base-deny.json`）を渡さず空配列を渡し、`.permissions.allow` だけを読む。診断は allow しか見ないため、`base-deny.json` の欠損で**診断そのものが落ちて allow の検査まで巻き添えになる**のを避ける。

## 検査項目と severity（正本。実行時に判定しない）

severity は**この表で固定**であり、実行時の状況で変えない。実行時に決める形にすると「赤を避けたい」方向へ静かに漂う。`scripts/tests/test-doctor.sh` が本表とスクリプト内の表の**双方向一致**を検査する（片方だけ増減すると落ちる）。

| id | 検査内容 | severity |
|---|---|---|
| `launcher_on_path` | `claude-harness-run` が PATH 上に在る | blocking |
| `launcher_plugin_root` | ランチャーが解決するプラグインルートが、本スクリプト自身のプラグインルートと一致する | blocking |
| `settings_launcher_allow` | settings の allow に `Bash(claude-harness-run:*)` が在り、deny / ask に同一文字列が無い | blocking |
| `settings_base_allow` | 上記以外の期待 allow が settings に揃っている | advisory |
| `claude_md_sections` | `CLAUDE.md` にテンプレートの節（H2 見出し）が揃っている | advisory |
| `claude_md_placeholders` | `CLAUDE.md` にテンプレートのプレースホルダが未置換で残っていない | advisory |
| `claude_md_doc_map` | ドキュメントマップの行と実ファイルの存在が一致する | advisory |

**blocking と advisory を分ける理由**: blocking（ランチャー不在・ランチャー allow 欠落）は headless 委譲が**実際に完走できなくなる**。advisory（ドキュメントの欠落・節の追加）は動作を止めない。両者を同じ色にすると、整備していないドキュメントで恒久的に赤になり gate として死ぬ（`scripts/specs/retirement-sweep.md` が「削除した PR が自分で恒久的な `fail` の原因を作る」として戒めている型と同型）。

### 各検査の判定規則

#### `launcher_on_path` / `launcher_plugin_root`

- PATH 探索は `command -v claude-harness-run` による。見つからなければ finding とし、`remediation` に `docs/script-launcher.md` §2 の導入コマンド（本スクリプトから解決した実際のプラグインルート入り）を出す。
- `launcher_plugin_root` は `claude-harness-run --plugin-root` の出力と、本スクリプト自身の位置から解決したプラグインルートを**物理パス（symlink 解決後）で比較**する。不一致は「PATH 上のランチャーが別バージョンを解決している」状態であり、**旧版の SKILL.md ＋ 新版の参照ファイル**のような混成を生む。`launcher_on_path` が finding のときは `skipped`（理由つき）とする。

#### `settings_launcher_allow` / `settings_base_allow`

- 要件を満たす置き場は 3 つ: **プロジェクトの `.claude/settings.json`（git tracked。`--target` で差し替え可）**、**ユーザー設定 `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json`**、**プロジェクトの `.claude/settings.local.json`**（スクリプト内の `DOCTOR_ALLOW_SCOPES` = `project user local`）。いずれかにルールが在れば要件を満たし、3 つのどこにも無いときだけ finding にする。根拠は `docs/settings-governance.md` §2 の実測（2026-09-05 / Claude Code 2.1.261）: ユーザー設定の allow は worktree 内の headless 起動でも効き、`settings.local.json` は main checkout ルートのファイルが worktree からも読まれる（v2.1.211 以降）。並列実装の worker が動く worktree 隔離環境でも、この 3 層はいずれも効く。
- ユーザー設定と `settings.local.json` は**チームに共有されない**（オペレータ層）。この事実は blocking の理由にはしないが、隠さない: `checks[]` の当該項目が `ok` のとき **`satisfied_by`**（`"project"` / `"user"` / `"local"` の配列）にどの層で満たされたかを出す。finding の `items[].found_in` は同じ情報を `[{scope, path}]` で持つ（shadowing で finding になった場合に、allow 自体はどこに在ったかを示す）。
- `remediation` は**ユーザー設定への追記を第一候補**とし（「チーム共有が不要ならユーザー設定でよい」）、tracked の settings に揃える場合の `generate-settings.sh` 再実行コマンド（診断条件つき）を併記する。プロジェクト settings を deny 専用にする割当（`docs/settings-governance.md` §1）に従い、allow の不足を「tracked に足せ」だけで是正させない。
- **`DOCTOR_ALLOW_SCOPES` から外した層に在るルールは要件を満たさない**（例: `--settings` で渡す一時ファイル、managed settings）。検査対象の層を増やすときは、実測記録を `docs/settings-governance.md` に残してから表を変える。
- **shadowing は完全一致のみ検出する**（`deny` / `ask` に allow と同一の文字列が在る場合）。優先順は deny > ask > allow。**前置き一致どうしの打ち消し（例: `Bash(claude-harness-run:*)` に対する `Bash(claude-harness-run doctor)` 等）の意味論は本リポジトリに実測記録が無いため、検出対象外**とする（明示的な仮定。実測できた時点で拡張する）。
- **`Read(~/.claude/plugins/**)` は意図的に検査対象外**。生成設定へ加える案は「採らない」と決定済みである（理由 3 点は `docs/skill-note-inventory.md` 6 節の表: 権限拡大が広い／`CLAUDE_CONFIG_DIR` 利用環境・ローカルチェックアウトを 1 つの静的パターンで覆えない／既存の導入済みプロジェクトには効かない）。ランチャー不在時の正しい是正は**ランチャーを導入すること**（`docs/script-launcher.md` §2）であり、Read 許可の追加ではない。

#### `claude_md_sections` / `claude_md_placeholders`

- 期待値は `skills/init-project/templates/CLAUDE.md.template` から**実行時に抽出**する（節の一覧・プレースホルダの一覧を本仕様やスクリプトへ書き写さない）。
  - 節: テンプレートの `grep '^## '` にマッチする見出し行（行頭が `##` ＋半角空白）のうち、プレースホルダ（`{...}`）を含まないもの。プロジェクト側に**同一の見出し行**が在るかを `grep -Fx` で照合する。
  - プレースホルダ: テンプレートに現れる `{...}` トークンのうち、プロジェクトの `CLAUDE.md` に残っているもの。**テンプレート由来のトークンだけ**を対象にすることで、利用者が本文中に書いた `{...}`（コード例など）を誤検出しない。
- `CLAUDE.md` が存在しない場合、`claude_md_sections` は「ファイルが無い」ことを finding として出し、`claude_md_placeholders` と `claude_md_doc_map` は `skipped`（理由つき）とする。

#### `claude_md_doc_map`

正本は**導入先プロジェクト自身の `CLAUDE.md`** である。「9 軸で選定される雛形ドキュメントの欠落」を軸から判定する形は採らない — 軸とドキュメントの対応表はどこにも存在せず（`analyze-project.sh` の `build_axes_json` は軸名と `standing` しか返さない）、9 軸のうち 6 軸が `ask-user`（人間に聞かなければ立つか判定できない）ため、対応表を新設しない限り機械では評価できない。新設すればそれが同期の要る 2 つ目のリストになる。

- `## ドキュメントマップ` 節（見出しの次行から、次に `grep '^## '` がマッチする行の手前まで）の表行を読む。ヘッダ行・区切り行は除く。パスは 2 列目、状態は 3 列目。
- パスは前後の空白とバックティックを剥がす。空・`http` 始まり・`{` を含む行は対象外（未置換プレースホルダは `claude_md_placeholders` が扱う）。
- 判定は 2 種のみ:

| 種別 | 条件 | 意味 |
|---|---|---|
| `missing` | 状態が「作成予定」**以外**で、パスが実在しない | 「整備済み」と書いてあるのに実体が無い |
| `stale_pending` | 状態が「作成予定」で、パスが**実在する** | 整備したのに状態の更新漏れ |

- 「作成予定」かつ実在しないのは**宣言どおりの正常**であり指摘しない（未整備のドキュメントで恒久的に warn を出し続けないため）。
- 状態の語彙に依存するのは「作成予定」の 1 語のみ（`skills/init-project/SKILL.md` ステップ4 が書き込む語）。それ以外の状態は語彙を判定に使わず、**実在しなければ `missing`** とする（利用者が状態欄を書き換えていても検査が無効化されないようにするため）。

## 版マーカーは導入しない（Issue #178 提案3 への結論）

生成物に「どの版のテンプレートから生成したか」を埋める案は**採らない**。記録として残す:

1. 本スクリプトの検査はいずれも**削除も書き換えもしない**ため、「テンプレート由来か利用者の記述か」を区別する必要が発生しない。区別が要るのは自動書き換えを行う場合だけである。
2. その自動書き換えは、エージェントが `.claude/settings.json` を原理的に書けない以上、実装しても使われない（上記「自動適用しない」）。
3. 既存プロジェクトはマーカーを持たない世代であり、**診断はどのみちマーカー非依存で成立していなければならない**。マーカーを足しても、新規プロジェクトでしか使えない 2 つ目の判定経路が増えるだけになる。
4. **マーカーは嘘をつく**。生成後に人間が手で書き換えても版は古いまま残るため、実態と乖離しうる正本を 1 つ増やすことになる。

## stdout JSON

```json
{
  "status": "warn",
  "project": "/path/to/project",
  "settings": { "path": "/path/to/project/.claude/settings.json", "exists": true },
  "claudeMd": { "path": "/path/to/project/CLAUDE.md", "exists": true },
  "counts": { "checks": 7, "ok": 5, "finding": 1, "skipped": 1, "blocking": 0, "advisory": 1 },
  "checks": [
    { "id": "launcher_on_path", "severity": "blocking", "result": "ok" },
    { "id": "launcher_plugin_root", "severity": "blocking", "result": "ok" },
    { "id": "settings_launcher_allow", "severity": "blocking", "result": "ok", "satisfied_by": ["user"] },
    { "id": "settings_base_allow", "severity": "advisory", "result": "finding" },
    { "id": "claude_md_sections", "severity": "advisory", "result": "ok" },
    { "id": "claude_md_placeholders", "severity": "advisory", "result": "ok" },
    { "id": "claude_md_doc_map", "severity": "advisory", "result": "skipped", "reason": "CLAUDE.md にドキュメントマップ節が無い" }
  ],
  "findings": [
    {
      "check": "settings_base_allow",
      "severity": "advisory",
      "summary": "期待される allow のうち 1 件がプロジェクト settings・ユーザー設定・settings.local.json のいずれにも無い",
      "items": [ { "rule": "Bash(npm:*)", "found_in": [] } ],
      "remediation": "ユーザー設定 /Users/me/.claude/settings.json の permissions.allow に不足しているルールを追記する（チーム共有が不要ならユーザー設定でよい）。tracked の settings に揃える場合: claude-harness-run skills/init-project/scripts/generate-settings.sh --target \"/path/to/project/.claude/settings.json\""
    }
  ]
}
```

- `checks` は**全 7 件を必ず出す**。`skipped` を出さずに黙って落とすと「未検査」と「調べた結果の 0 件」が区別できなくなる。`skipped` には必ず `reason` を付ける。
- `findings` の各要素は `check` / `severity` / `summary` / `items` / `remediation` を持つ。`items` の形は検査ごとに異なる（allow 系は `{rule, found_in}`（ランチャーは加えて `shadowed_by`）、doc map は `{path, state, kind}`、節は `{section}` 等）。
- `checks[]` の `settings_launcher_allow` / `settings_base_allow` が `ok` のときは `satisfied_by`（層名の配列）を持つ。
- `status` は `findings` から決まる: blocking が 1 件以上あれば `fail`、findings があり blocking が 0 件なら `warn`、findings が 0 件なら `ok`。
- `skipped` が blocking の検査を隠すことはない。`launcher_plugin_root` が skipped になるのは `launcher_on_path` が finding のとき（＝既に `fail`）だけである。

## 終了コード

| exit | `status` | 条件 |
|---|---|---|
| 0 | `ok` | finding が 0 件 |
| 0 | `warn` | finding は在るが blocking が 0 件 |
| 1 | `fail` | blocking の finding が 1 件以上 |
| 2 | — | 実行前提の欠落（jq 不在・引数不正・`--project` がディレクトリでない・`--input` が不正・**`--target` が存在するが JSON として読めない**・`generate-settings.sh` / テンプレートが見つからない＝インストール破損）。**stdout には何も出さない** |

既存の settings が JSON として読めない場合を finding ではなく exit 2 にするのは、allow が「無い」のかファイルが壊れているのかを区別できないまま「この allow を足せ」と提示すると、**壊れたファイルへの追記**という誤った是正へ誘導するためである（`generate-settings.sh` も既存 target が不正 JSON なら書き込まずに落ちる。同じ規律）。

`scripts/README.md`「出力規約」に従い、exit code と JSON の `status` の両方から判定できる。exit 2 の場合のみ stdout が空になるため、呼び出し側は exit code を先に見る。

## 呼び出し側

`skills/init-project/SKILL.md` ステップ1。既存の `CLAUDE.md` が在るとき（＝再実行）に実行し、結果を提示したうえで上書き・マージ・中止を確認する。

ランチャーが未導入の環境では `claude-harness-run doctor` そのものが実行できないため、その場合に限り `bash "<プラグインルート>/scripts/doctor.sh"` で起動する（`docs/plugin-path-conventions.md` (a) のフォールバック）。この経路で起動されたとき `launcher_on_path` が finding になり、導入コマンドが `remediation` に出る。

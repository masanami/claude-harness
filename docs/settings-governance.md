# 許可設定の統治 — 3 層の役割分担と、プロジェクト settings が保証しない範囲

Claude Code の permission ルール（`allow` / `ask` / `deny`）は複数の settings ファイルに分かれて置ける。本文書は claude-harness が**どの層に何を置くか**、および**プロジェクトの `.claude/settings.json` が何を保証しないか**の正本である。`/init-project` の生成物（`skills/init-project/scripts/generate-settings.sh`）と `preflight`（`scripts/specs/preflight.md`）はこの割当に従う。

**結論を先に書く**:

- プロジェクトの `.claude/settings.json`（git tracked）は **制限専用**（`deny` と `ask` だけ。`allow` は 1 件も書かない）にする。これは「そのリポジトリで壊されたくないもの」＝**リポジトリの性質**を書く場所である。`deny` は取り返しのつかない操作、`ask` は「人間が意図してやることはあるが、自走セッションが単独でやってはいけない」リリース系に使う（§1.1）。
- 運用上の allow（ランチャー `Bash(claude-harness-run:*)`・パッケージマネージャ・テストランナー・infra）は**ユーザー設定** `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json` に置く。「誰が・どのマシンで・どの権限モードで動かすか」＝**オペレータの性質**を書く場所である。
- **「プロジェクト `.claude/settings.json` がエージェントを統治する」とは名乗らない。** 下記 §3 のとおり、allow は trust と権限モードに依存して効いたり効かなかったりし、deny はプロセスツリーに適用されない。tracked の settings に allow を並べても、それは「統治」ではなく「その allow を trust した人の環境で prompt が減る」以上のものではない。

---

## 1. 3 層の割当表

| 層 | ファイル | 誰の性質か | 共有範囲 | 置くもの（claude-harness の割当） |
|---|---|---|---|---|
| **ユーザー設定** | `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json` | オペレータ（自己責任） | その人・そのマシンの**すべてのプロジェクト**。チームには共有されない | 運用 allow: `Bash(claude-harness-run:*)`・`Bash(bash:*)`（フォールバック実行形を使う場合のみ）・PM（`Bash(npm:*)` 等）・テストランナー・infra（`Bash(docker compose:*)` 等）。**`/init-project` はこの層向けのスニペットを出力するだけで、書き込まない** |
| **プロジェクト settings** | `<repo>/.claude/settings.json`（git tracked） | リポジトリ（共有） | そのリポジトリを clone した**全員**（allow は各人が trust したあとだけ） | **制限専用（`deny` / `ask`）**。`/init-project` のベース deny（`base-deny.json`）・ベース ask（`base-ask.json`）と、リポジトリ固有の deny（`terraform destroy` 等）。将来は repo 固有の `Read(...)` deny 等もここ |
| **プロジェクト local** | `<repo>/.claude/settings.json` と同じディレクトリの `settings.local.json`（gitignored） | 個人・そのリポジトリ限定 | 自分だけ。clone 先や他のマシンには無い | 個人の例外（WebSearch 等）。**運用 allow の置き場としては当てにしない**（§2 の制約） |

3 層のほかに `--settings <file>`（そのセッション限定）と managed settings（組織）がある。claude-harness はどちらも前提にしない。

### 1.1 `deny` と `ask` の切り分け（2026-09-20 決定。Issue #238）

プロジェクト settings に書く制限は 2 種類ある。**どちらに置くかは「人間が意図してやることがあるか」で決める。**

| | 置くもの | 判断基準 | ベースの正本 |
|---|---|---|---|
| `deny` | 取り返しのつかない操作。`rm -rf` / `git push --force` / `git push --force-with-lease` / `git clean -f` / `gh repo delete` / `docker run` / `docker exec` | やり直しが効かず、**対話でも自動でも、そのリポジトリでは行わない**と言い切れる | `skills/init-project/scripts/base-deny.json` |
| `ask` | 本番へ反映されるリリース系。`git tag` / `git push --tags` / `git push --follow-tags` / `gh workflow` / `gh release` / `cdk deploy` / `cdk destroy` / `npm run cdk` / `npx cdk` | **人間が意図してやることはある**が、自走セッションが単独でやってはいけない | `skills/init-project/scripts/base-ask.json` |

`ask` を選ぶ理由は、**headless（`claude -p`）では `ask` が実質 deny として働き、対話セッションでは人間が判断できる**ことにある。自走委譲が単独で本番へ到達することを防ぎつつ、人間の手元での正規のリリース操作は止めない。「宣言（`v*` タグ付与と本番 dispatch は人間承認必須）と実装（何の制限も無い）の矛盾」を消すのが目的である（Issue #238 の報告）。

**`ask` は `.devcontainer/claude-settings.json` には入れない**（明示的な仮定）。`/init-devcontainer` は `base-deny.json` だけを読み、`base-ask.json` は読まない。コンテナ内のセッションには承認する人間がいないため、`ask` は静かに全拒否へ倒れ、その理由が設定ファイルの見た目からは読み取れなくなる。コンテナ内でリリース系を締めたいリポジトリは、その `deny` へ明示的に足す。

**`docker run` / `docker exec` を `deny` に置くと、コンテナ実行を常用するリポジトリでは邪魔になる**（明示的な仮定）。それでもベースに入れるのは、`docker run -v /:/host …` が 1 文字列でホスト FS 全域と `~/.aws` 等の認証情報へ到達する経路だからである。常用するリポジトリは、生成後に該当行を外す（生成器は既存の設定を削らないため、外した状態は再実行でも戻らない）。

### 決定: プロジェクト settings を緩める allow は生成しない

**`/init-project` は、プロジェクトの `.claude/settings.json` へ `allow` を 1 件も書かない。緩和はユーザー設定側で行う。**

- **実装**: `skills/init-project/scripts/generate-settings.sh` の `gs_project_allow_json()` は常に `[]` を返す。運用 allow は `user_settings_snippet` として stdout に提示するだけで、ファイルへは書かない。書き込むのは `deny`（`base-deny.json`）と `ask`（`base-ask.json`）だけである。
- **回帰テスト**: `scripts/tests/test-generate-settings.sh` が「生成するプロジェクト settings の allow は空（pm/test/infra を渡しても）」「マージ結果の allow は既存のまま（生成側は allow を足さない）」「汎用実行系・PM・テストランナー・infra の allow が生成物に現れない」を固定する。
- **再実行しても変わらない**: 冪等マージは既存の allow を削らず、新規に足す allow も無い（§5）。
- **理由**: allow はオペレータの性質であり（下記「割当の根拠」）、tracked に置いても trust 未承認のクローンと headless では効かない（§2・§3）。「効かない allow が並んでいる」状態は、誤った安心を生むという意味で無いより悪い。

この決定は生成物の**出所の規律**（`skills/init-project/SKILL.md` ステップ4「harness／プラグイン固有の語を書かない」）と対になっている。どちらも**オペレータの性質をリポジトリの成果物へ書き込まない**という同じ切り分けであり、片方だけを守っても「harness を前提にしたリポジトリ」が出来上がる。

### 割当の根拠

- **allow はオペレータの性質である**: 同じ allow でも、それを「prompt なしで走らせてよい」と判断できるのは、その環境を動かしている人だけである。tracked に置くと、clone した全員の環境で trust 承認と同時にまとめて有効になる（承認ダイアログに列挙はされるが、1 行ずつ吟味されるとは限らない）。
- **deny はリポジトリの性質である**: 「この repo で `git push --force` はしない」「`terraform destroy` は流さない」は、誰が動かしていても変わらない。deny は **trust 不要で即座に効き、どの権限モードでも効く**（§3）ため、共有して困ることがない唯一の層でもある。
- **allow と deny を同じファイルに並べると、deny の保証範囲を allow が黙って狭める**（`Bash(bash:*)` があれば deny は迂回可能。`docs/script-launcher.md` §6「残る限界」）。制限専用にすることで「このファイルにあるものはすべて制限である」と読める。この「allow が deny を黙って狭める」状態そのものは、`preflight` の `settings_allow_overreach` が advisory で可視化する（§3.1）。

---

## 2. 実測記録（2026-09-05 / Claude Code 2.1.261 / macOS）

以下は本文書の判断の根拠であり、いずれも **headless `claude -p` を worktree（`git worktree add` で作った `<parent>/<repo>-worktrees/<name>`）を cwd にして起動**したときの結果である。実行者のユーザー設定は書き換えていない（既存の `Bash(claude-harness-run:*)` をプローブに使った）。対象の一時リポジトリは trust 未承認。

| # | 権限モード | ルールの置き場 | プローブ | 結果 |
|---|---|---|---|---|
| 1 | `default` | ユーザー設定 `allow: ["Bash(claude-harness-run:*)"]` | `claude-harness-run --plugin-root` | **実行された**（ユーザー設定の allow は worktree 内の headless 起動でも効く） |
| 2 | `default` | tracked `.claude/settings.json` `allow: ["Bash(touch:*)"]` | `touch probe-project` | **拒否**。stderr に `Ignoring 1 permissions.allow entry from .claude/settings.json: this workspace has not been trusted` と、trust のキーが **main checkout のパス**（worktree のパスではない）で示された |
| 3 | `default` | main checkout の `.claude/settings.local.json` `allow: ["Bash(mkdir:*)"]`（worktree 側には存在しない） | `mkdir probe-local-dir` | **実行された**（worktree 内の起動でも main checkout ルートの local ファイルが読まれる。trust 未承認でも効いた） |
| 4 | `default` | どこにも無い | `cp README.md probe-copy` | **拒否**（対照） |
| 5 | `bypassPermissions` | tracked `.claude/settings.json` `deny: ["Bash(cp:*)"]` | `cp README.md probe-bypass-copy` | **拒否**（deny は bypassPermissions でも効く） |
| 6 | `bypassPermissions` | 上と同じファイルの `allow: ["Bash(touch:*)"]`（trust 未承認で無視される） | `touch probe-bypass-touch` | **実行された**（bypassPermissions では allow の有無に関係なく実行される） |

公式ドキュメント（同日取得）の記述とも一致する:

- 「User settings (`~/.claude/settings.json`): your personal settings for every project.」（settings）
- 「`permissions.allow` rules and `permissions.additionalDirectories` entries in a project's `.claude/settings.json` grant capability, so Claude Code applies them only after you accept the workspace trust dialog for that folder. … `deny` and `ask` rules aren't affected, since they only restrict.」「Claude Code shows the trust dialog in interactive sessions only. A `claude -p` run or an SDK session never shows it」（permissions）
- 「In a worktree, it uses the main checkout's root, as it does for saved rules.」（trust のキー。permissions）／「In a worktree, it uses the file at the main checkout's root.」（`settings.local.json` の読み出し位置。settings。**v2.1.211 以降**の挙動）
- 「Deny rules block in every mode, including `bypassPermissions`. … Allow rules have no effect in `bypassPermissions`.」（permission-modes）

### 実測から言えること・言えないこと

- **言える**: ユーザー設定の allow は worktree 隔離の worker（`/para-impl` の star 型）にも効く。したがって単独オペレータ構成では、運用 allow はユーザー設定に置けば足りる。
- **言える**: tracked の allow は、**clone ごとに人間が trust を承認しない限り headless では永久に効かない**（headless は trust ダイアログを出さない）。「tracked に allow を置けば worker が動く」は trust 承認を暗黙の前提にしている。
- **言える**: `.claude/settings.local.json` は worktree に「コピーされない」が、**main checkout ルートのファイルが worktree からも読まれる**（v2.1.211 以降）。過去に本リポジトリが前提にしていた「local は worktree に効かない」は現行版では成立しない。ただし個人・マシン限定であることは変わらず、版依存の挙動でもあるため、運用 allow の置き場としては引き続き当てにしない。
- **言えない**: 対話セッション（`claude` を REPL で起動）や `Agent` ツールのサブエージェントでの適用は測っていない。上の表はすべて headless `-p` である。

### 2.1 `.claude/rules/` の適用規則の実測記録（2026-09-20 / Claude Code 2.1.278 / macOS 26.6.2）

Issue #242 の判断材料として測った。`.claude/rules/` は `permissions` とは別の機構（CLAUDE.md と同じ「指示の読み込み」）なので、上の表の結論（trust と allow の関係）からは演繹せず、独立に測っている。導入可否の案と推奨は `docs/claude-rules-adoption.md` に置く。

**測り方**: いずれも **headless `claude -p`**（`--model haiku --tools Read --output-format json`。R14 だけ `--tools Read Agent`、R15 は `--tools ""`、R16 は `--tools Write --permission-mode acceptEdits`、R17 は `--tools Grep`）を、`mktemp -d "$HOME/.rules-probe.XXXXXX"` で作った repo 外の一時 git リポジトリを cwd にして起動した。読み込みの判定は次の **2 系統**で取り、両者が一致した行だけを表に載せている。

1. **モデルの回答**: 各 rules ファイルに固有の合言葉（`CW-…`）を書いておき、「文脈に見える `CW-` を全部挙げよ」と聞く。`num_turns` でツール呼び出し回数を確認し、モデルが `.claude/` を自分で読んだ交絡が無いことを確かめた（読み出しなしのプローブは `num_turns: 1`、1 ファイル読むプローブは `num_turns: 2`）。
2. **`InstructionsLoaded` フックのログ**: `--settings <一時ファイル>` でフックを渡し、ペイロード（`file_path` / `load_reason` / `trigger_file_path` / `globs`）を一時ファイルへ追記させた。ハーネス側の事実であり、モデルの自己申告に依存しない。

実行者のユーザー設定と `~/.claude.json` は書き換えていない。**一時リポジトリはすべて trust 未承認**（実測の前後とも `~/.claude.json` の `projects` に該当パスの項目が無く、親の `$HOME` の項目は `hasTrustDialogAccepted: false`）。一時リポジトリとログは測定後に削除した。

プローブ用リポジトリの配置（`CW-…` は各ファイルの合言葉。`paths` の無いものは frontmatter なし）:

```
CLAUDE.md                              CW-ROOT-CLAUDEMD
.claude/rules/always.md                CW-ALWAYS
.claude/rules/sub/deep.md              CW-SUBDIR
.claude/rules/notmd.txt                CW-TXT
.claude/rules/src-ts.md                CW-SRC-TS         paths: "src/**/*.ts"
.claude/rules/dotslash.md              CW-DOTSLASH       paths: "./src/**/*.ts"
.claude/rules/root-md.md               CW-ROOT-MD        paths: "*.md"
.claude/rules/any-md.md                CW-ANY-MD         paths: "**/*.md"
.claude/rules/lib-rel.md               CW-LIBREL         paths: "lib/*.ts"
pkg/.claude/rules/nested-always.md     CW-NESTED-ALWAYS
pkg/.claude/rules/nested-scoped.md     CW-NESTED-SCOPED  paths: "lib/*.ts"
src/a.ts  src/deep/b.ts  lib/x.ts  pkg/lib/y.ts  other/z.py  README.md  docs/x.md
```

「起動時 3 本」は `CLAUDE.md`・`.claude/rules/always.md`・`.claude/rules/sub/deep.md`（フックの `load_reason: session_start`）を指す。

| # | 権限モード | ルールの置き場 | プローブ | 結果 |
|---|---|---|---|---|
| R1 | `default` | 上の配置（cwd = リポジトリルート） | ファイルを読まずに合言葉を列挙 | **起動時 3 本だけが読まれた**。`paths` の無い rule はサブディレクトリ（`rules/sub/`）も含めて起動時に読まれる。`notmd.txt`・`paths` 付きの 5 本・`pkg/.claude/rules/` の 2 本は読まれない。**trust 未承認でも読まれる**（stderr に trust の警告なし） |
| R2 | `default` | 同上 | `other/z.py` を Read | 起動時 3 本のまま。**どの `paths` にも一致しないファイルでは何も足されない**（対照） |
| R3 | `default` | 同上 | `src/a.ts` を Read | `src-ts.md` が足された（フック: `load_reason: path_glob_match`, `trigger_file_path: …/src/a.ts`, `globs: ["src/**/*.ts"]`）。**`./src/**/*.ts` の `dotslash.md` は足されない** |
| R4 | `default` | 同上 | `src/deep/b.ts` を Read | R3 と同じ（`**` は 2 階層下にも一致。`./` 付きはここでも不一致） |
| R5 | `default` | 同上 | `README.md`（ルート直下）を Read | `root-md.md`（`*.md`）と `any-md.md`（`**/*.md`）の両方が足された |
| R6 | `default` | 同上 | `docs/x.md`（サブディレクトリ）を Read | **R5 と同じく `*.md` の `root-md.md` も足された**（フック: `trigger_file_path: …/docs/x.md`, `globs: ["*.md"]`）。スラッシュを含まないパターンは階層を問わず basename に一致した。公式ドキュメントの表（下記）とは食い違う |
| R7 | `default` | 同上 | `lib/x.ts` を Read | ルートの `lib-rel.md`（`lib/*.ts`）が足された。`pkg/` 側の rule は足されない |
| R8 | `default` | 同上 | `pkg/lib/y.ts` を Read | `pkg/.claude/rules/` の 2 本が足された（`nested-scoped.md` は `path_glob_match`、`nested-always.md` は `load_reason: nested_traversal`）。**ルートの `lib-rel.md`（同じ `lib/*.ts`）は足されない**。スラッシュを含むパターンの基準は「その `.claude/` を含むディレクトリ」で、末尾一致ではない |
| R9 | `default` | 同上（**cwd = `pkg/`**） | ファイルを読まずに合言葉を列挙 | 起動時 3 本 **＋ `pkg/.claude/rules/nested-always.md`** が `session_start` で読まれた。cwd から上位へ辿って親の `CLAUDE.md` と `.claude/rules/` も読む |
| R10 | `default` | 同上（cwd = `pkg/`） | cwd の外の `<root>/src/a.ts` と `pkg/lib/y.ts` を Read | `<root>/src/a.ts` の Read は**権限で拒否**（`permission_denials: 1`）され、`src-ts.md` は足されない。`pkg/lib/y.ts` で `nested-scoped.md` は足された。**「cwd の外にある一致ファイル」はこの形では測れていない**（R11 で条件を変えて取り直した） |
| R11 | `default` | 同上（cwd = `pkg/`、`--add-dir <root>` を追加） | `<root>/src/a.ts` を Read | 読めて、ルートの `src-ts.md` が `path_glob_match` で足された。cwd がサブディレクトリでも、上位の `.claude/rules/` の `paths` は**その rules の置き場を基準に**評価される。`--add-dir` を付けた点が R10 と条件が違う |
| R12 | `default` | 同上（`--setting-sources user` を追加） | `src/a.ts` を Read | 回答は `NONE`、フックログは空。**`project` を外すと `CLAUDE.md` も rules も（`paths` 付きも）一切読まれない** |
| R13 | `default` | 同上を `git worktree add` した worktree（cwd = worktree） | `src/a.ts` を Read | 起動時 3 本＋`src-ts.md`。フックの `file_path` は **worktree 側のパス**。追跡されている rules は worktree にチェックアウトされ、そのまま効く |
| R14 | `default` | 同上 | 親は何も読まず、`Agent` で general-purpose サブエージェントを 1 つ起動して `src/a.ts` を Read させ、親子それぞれに合言葉を列挙させる | **サブエージェントの回答**: 起動時 3 本＋`CW-SRC-TS`。**親の回答**: 起動時 3 本のみ。サブエージェントにも起動時の rule が入り、`paths` 付き rule は**読んだ側の文脈にだけ**入る（フックログには `path_glob_match` が 1 件。ペイロードに親子を区別する項目は無かった） |
| R15 | `default` | 別の一時リポジトリ。`CLAUDE.md` に「PRIORITY の問いには ALPHA」、`.claude/rules/a-first.md` に「BRAVO」、`.claude/rules/z-last.md` に「CHARLIE」（いずれも `paths` なし） | 「PRIORITY の問いに 1 語で答えよ」を haiku で 3 回・sonnet で 2 回 | haiku: `ALPHA` / `ALPHA` / `BRAVO`。sonnet: `CHARLIE` / `CHARLIE`。**矛盾させたときにどれが勝つかは一定しない**。sonnet に文脈内の並び順を申告させると `ALPHA` → `BRAVO` → `CHARLIE`（`CLAUDE.md` が先、rules はファイル名順）。並び順はモデルの自己申告 1 回だけで、確度は低い |
| R16 | `acceptEdits` | 別の一時リポジトリ。`.claude/rules/src-ts.md`（`paths: "src/**/*.ts"`）のみ | Read を使わず **Write だけ**で新規ファイル `src/new.ts` を作成 | ファイルは作成されたが、回答は `NONE`、フックログは空。**一致するパスへの Write（新規作成）では発火しない** |
| R17 | `default` | R16 と同じ | Read を使わず **Grep だけ**で `src/a.ts` にヒットさせる（`output_mode: content`） | 回答は `NONE`、フックログは空。**Grep のヒットでは発火しない** |

R16・R17 の陽性対照は同じ内容の rule を使った R3（Read で発火）である。リポジトリは別だが、rule ファイルの中身と `paths` は同一にした。

公式ドキュメント（同日取得。`https://code.claude.com/docs/en/memory`）の記述。**以下は読んだ内容であって測った内容ではない**:

- 「Rules without `paths` frontmatter are loaded at launch with the same priority as `.claude/CLAUDE.md`.」「All `.md` files are discovered recursively」— R1 と一致。
- 「Path-scoped rules trigger when Claude reads files matching the pattern, not on every tool use.」— R3・R16・R17 と一致。
- パターン例の表に「`*.md` — Markdown files in the project root」— **R6 と食い違う**（実測ではサブディレクトリの `docs/x.md` にも一致した）。`paths` の相対基準と `./` 接頭辞の扱いは、同ページに記述が無い。
- 「Project rules are skipped if you exclude `project` from `--setting-sources`. Before v2.1.211, rules that load on demand, including path-scoped rules and rules in nested `.claude/rules/` directories, loaded even when `project` was excluded.」— 現行版の挙動は R12 と一致。v2.1.211 より前の挙動は測っていない。
- 「User-level rules are loaded before project rules, giving project rules higher priority.」「if two rules contradict each other, Claude may pick one arbitrarily.」— 後者は R15 と整合する。前者（`~/.claude/rules/`）は測っていない。
- プロジェクトの `.claude/rules/` が workspace trust を要するかは、同ページに**記述が無い**。trust に触れているのは、外部 import の承認ダイアログと、作業ディレクトリ外を指す symlink の rules だけである。
- 「Use the `InstructionsLoaded` hook to log which `CLAUDE.md` and rules files are loaded, when they load, and why.」— 本節の計器の出所。

#### 実測から言えること・言えないこと

- **言える**: プロジェクトの `.claude/rules/` は **trust 未承認の clone でも、headless でも、worktree でも、サブエージェントでも読まれる**（R1・R13・R14）。tracked の `allow`（§2 の #2）と違い、「人間が clone ごとに trust を承認しないと効かない」という制約は無い。裏返せば、**他人が commit した rules は承認なしに文脈へ入る**（CLAUDE.md と同じ性質）。
- **言える**: `paths` の無い rule は **CLAUDE.md と同じく起動時に毎回読まれる**（R1）。CLAUDE.md から `paths` なしの rule へ移しても、毎セッションの固定費は減らない。減るのは `paths` を付けたときだけである。
- **言える**: `paths` 付き rule が発火するのは **Read のときだけ**で、新規ファイルの Write と Grep では発火しない（R16・R17）。「新しいファイルをどこに置くか」のように**まだ存在しないファイルに効かせたい規約**は、`paths` 付き rule に置いても、作成の時点では文脈に入らない。
- **言える**: スラッシュを含むパターンは「その `.claude/` を含むディレクトリ」からの相対で評価され（R7・R8・R11）、スラッシュを含まないパターンは階層を問わず basename に一致する（R6）。`./` で始まるパターンは一致しない（R3・R4）。**`./` 付きで書いた rule は、エラーも警告も出ずに永久に発火しない**。
- **言える**: 矛盾する指示を CLAUDE.md と rules に分けて置いても、決まった優先順では解決されない（R15）。rules は CLAUDE.md を「上書き」する層ではなく、同じ文脈に並ぶ追加の指示である。
- **言える**: `--setting-sources` から `project` を外す起動では、CLAUDE.md と同時に rules も全部落ちる（R12）。
- **言えない**: **未対応バージョンでの挙動（無視されるか・エラーか）は測っていない**。旧版を入れて起動すると、実行者の `~/.claude.json` と `~/.claude/` を旧版が書き換えうるため、「ユーザー設定を書き換えない」という本実測の制約の下では試さなかった。`.claude/rules/` がどの版から使えるかも、公式ドキュメントの同ページからは特定できなかった（v2.1.198 / v2.1.207 / v2.1.211 / v2.1.217 で挙動が変わった旨の記述があるだけ）。
- **言えない**: **対話セッション（REPL）では測っていない**。trust ダイアログを承認した後・拒否した後で rules の扱いが変わるかも測っていない（承認の書き込みを要するため）。上の表はすべて trust 未承認の headless `-p` である。
- **言えない**: ユーザーレベルの `~/.claude/rules/` とプロジェクト rules の関係、`claudeMdExcludes` による除外、symlink の rules、`paths` のブレース展開・`[` の扱い、Edit・Glob・Bash（`cat` 等）での発火、`/compact` 後の再読み込みは測っていない。
- **言えない**: R15 は 5 回の試行であり、「どのモデルでも一定しない」とまでは言えない。言えるのは「一定の優先順を前提にできる結果ではなかった」までである。
- **言えない**: 読み込みの判定にはモデル haiku を使った。読み込み自体はハーネス側の処理で、フックログがモデルに依らずそれを示しているが、**読み込まれた rule にモデルがどの程度従うか**（遵守率）は測っていない。
- **付記（実行環境の事実）**: 実行者のグローバル gitignore（`~/.config/git/ignore`）に `.claude/*` があり、プローブ用リポジトリでは `.claude/rules/*.md` が `git add` で無視された（`git add -f` で追跡させた）。この環境に限った事情だが、同じ設定の利用者のもとでは、生成した rules が commit されず、worktree（R13）にも他の clone にも届かない。

---

## 3. プロジェクト settings が保証しない範囲（誤った安心を消す）

tracked の `.claude/settings.json` に書いたルールが**効かない**状況を列挙する。ここに無い保証を読み取らないこと。

| 書いたもの | 効かない状況 | 根拠 |
|---|---|---|
| `allow` | **trust 未承認のクローン**（headless `-p` ではダイアログが出ないため、人間が承認するまで常に未承認） | §2 実験 2・公式ドキュメント |
| `allow` | **`bypassPermissions` で起動したセッション**（allow は評価されず、すべて実行される） | §2 実験 6・公式ドキュメント |
| `deny` | **許可コマンドが起動する子プロセス**（`npm run` が `package.json` の指示で呼ぶもの、`make` のレシピ、`mutation-run` 自身が復元に使う `git`） | `docs/script-launcher.md` §6「`deny` がどこまで効くか」の表（正本。ここでは再掲しない） |
| `deny` | **別の層に汎用実行系の allow があるとき**（ユーザー設定に `Bash(bash:*)` があれば、その人の環境ではどのリポジトリの deny も `bash -c` で迂回できる） | `docs/script-launcher.md` §6「残る限界」 |
| `deny` | 一致しない書き方（`Bash(rm -rf:*)` は `rm -rf …` に一致するが `rm -r -f …` には一致しない。トークン内の `*` は解釈されない） | `docs/script-launcher.md` §1 の実測 |
| `ask` | **headless（`claude -p`）では人間に聞けないため実質 deny になる**。自走委譲で `ask` 対象へ到達すると、判断を仰ぐのではなく単に拒否される | **本リポジトリでの実測記録は無い**（§2 の実験は `allow` / `deny` のみ）。公式ドキュメントの「Claude Code shows the trust dialog in interactive sessions only. A `claude -p` run or an SDK session never shows it」から、headless が人間への問い合わせを出さないことを敷衍した**明示的な仮定**であり、§1.1 の `deny` / `ask` の切り分けはこの仮定に依存する |
| `deny` / `ask` とも | **同じ副作用へ別の文字列で到達する経路**（`git -C <path> push origin v1.2.3` / `gh api …/dispatches` / `npm run <別名>`） | §3.1（2026-09-20 / Claude Code 2.1.270 実測） |
| `allow` / `deny` とも | `Agent` ツールのサブエージェント・対話セッションでの適用範囲 | **未検証**（§2「言えないこと」） |

逆に **`deny` / `ask` だけが持つ性質**: trust 不要で即座に効き（制限だけを課すため trust ダイアログの承認を要しない）、`deny` は `bypassPermissions` を含む全モードで効き、共有しても他人の環境で何かを「自動で走らせる」ことがない。プロジェクト settings を制限専用にする理由はここにある。

**`Bash(claude-harness-run:*)` を allow することの意味**（どこに置くかによらない）は `docs/script-launcher.md` §6 が正本である。要点だけ書くと、ランチャーへ直接渡した 1 つの文字列で deny 対象へ到達できないことは保証するが、許可コマンドの子プロセスや `PATH` の完全性は保証しない。

### 3.1 保証の範囲（何を保証し、何を保証しないか）

**完全な封じ込めは達成できない。** ここで保証するのは次の 1 点だけである:

> **呼び出し側が書いた 1 つの文字列だけで、事前準備なしに `deny` / `ask` の対象へ到達できないこと。**

これを超える保証（「このリポジトリではエージェントが本番へ到達できない」等）を読み取らないこと。到達できない理由は permission ルールの性質そのものにある:

1. **`deny` / `ask` は前方一致であり、マッチャが見るのは呼び出し側が書いた文字列だけである。** 同じ副作用へ別の文字列で到達できれば一致しない。`Bash(git push --tags:*)` は `git -C <path> push origin v1.2.3` を取り逃がす（`git -C` 形の取り逃がしは Claude Code 2.1.270 で実測）。
2. **判定はランチャー／Bash ツールへの直接入力にしか効かない。** `npm run` / `make` / `cargo` が起動するプロジェクト定義の子プロセスは permission 判定を受けない（`docs/script-launcher.md` §6 が正本）。
3. **「実行するプログラムを引数で指名できる」コマンドの allow は、denylist を構造的に無効化する。** `uv run` / `bundle exec` / `npx` / `python3 -m` / `node --require` / `cargo run` / `go run` / `dotnet exec` のように、処理系ごとに際限なくある（claude-harness PR #224 で、先頭トークン列の一致だけでは `bundle exec rm -rf /` が通ることを実測）。同じ穴は環境変数側にもある（`PATH` / `NODE_PATH` / `PYTHONPATH` / `BASH_ENV` / `NODE_OPTIONS` / `LD_PRELOAD`）。**判定の基準は列挙ではなく「呼び出し側が、実行されるプログラムを引数で指名できるか」という形で持つ。**

したがって claude-harness の設計は「塞ぎ切る」ではなく **「直接経路を塞ぎ、残った範囲を可視化する」** である。可視化を担うのが `preflight` の `settings_allow_overreach`（汎用実行系 allow が deny / ask を無効化している状態を advisory で指摘する。`scripts/specs/preflight.md` が正本）であり、**この指摘は 0 件にすることを目的としない** —— ツールチェインの allow を外せば開発そのものが止まるためである。狭められない分は「`deny` / `ask` が実効的でない範囲」として受け入れ、不可逆操作の歯止めを permission 以外（人間承認・CI 側の保護ルール・環境分離）に置く。

#### Issue #238 が挙げた経路の現況

採用方針（`deny` 追加＋`ask` 追加＋スニペットの allow 縮小）の適用後、報告された各経路がどうなるか。**塞がれないものも明記する。**

| 経路 | 現況 | 理由 |
|---|---|---|
| `npm run cdk -- deploy <Stack>-prod` | **`ask`**（対話では人間が判断、headless では拒否） | `Bash(npm run cdk:*)` が前方一致する |
| `npm run deploy-prod`（別名のスクリプト） | **塞がれない** | script 名はリポジトリごとに任意。`Bash(npm:*)` の allow が残る以上、名前を列挙しても追随できない（`settings_allow_overreach` が「`npm run` が通る」ことを指摘する） |
| `git push origin v1.2.3` | **直接は塞がれない。タグ作成側で `ask`** | `Bash(git push --tags:*)` は `git push origin v1.2.3` に前方一致しない。ただしタグの作成（`git tag`）が `ask` のため、**新規タグの付与から push までの経路には承認が挟まる**。既存タグの push は素通りする |
| `git tag v1.2.3` | **`ask`** | `Bash(git tag:*)` |
| `gh workflow run deploy-prod.yml` | **`ask`** | `Bash(gh workflow:*)` |
| `gh api -X POST …/actions/workflows/…/dispatches` | **塞がれない** | `Bash(gh api:*)` は運用上必要（Issue / PR 操作の正規経路）。同じ副作用へ別の文字列で到達できる典型例（`settings_allow_overreach` が指摘する） |
| `docker run -v /:/host …` | **`deny`** | `Bash(docker run:*)`。加えてスニペットの `Bash(docker:*)` を `Bash(docker compose:*)` / `Bash(docker ps:*)` / `Bash(docker logs:*)` へ狭めた |
| `docker compose run <svc> <cmd>` | **塞がれない** | compose 定義が要る点で「事前準備なしの 1 文字列」ではないが、リポジトリに定義が在れば成立する（`settings_allow_overreach` が指摘する） |
| `git push --force-with-lease` | **`deny`** | `base-deny.json` へ追加し、同時にスニペットの allow からも外した（`--force` を deny しながら等価な経路を allow で開けている矛盾を解消） |
| `npm install <pkg>`（postinstall による任意コード実行） | **塞がれない** | `Bash(npm:*)` の allow が残る以上、成立する（`settings_allow_overreach` が指摘する） |

`Bash(npm:*)` を実在スクリプトの列挙へ置き換える案は**本変更のスコープ外**である（`analyze-project.sh` の出力に依存し、スクリプト名の変更へ追随できないため別課題）。

---

## 4. 構成別の使い分け

| 構成 | 運用 allow の置き場 | 補足 |
|---|---|---|
| **単独オペレータ**（1 人・1 マシン。claude-flywheel の自走委譲もこれ） | **ユーザー設定に 1 行**（`Bash(claude-harness-run:*)`）＋必要な PM・テストランナー | 全リポジトリ・全 worktree に効く。trust に依存しない。tracked には何も足さなくてよい |
| **チーム・複数マシン・CI** | **各人のユーザー設定**（tracked への手動追記は**非推奨**。下記） | 揃えたい内容は settings ではなく**導入手順**（README・オンボーディング）で配る。`/init-project` は tracked に allow を足さない |
| **deny による統治を効かせたい** | ユーザー設定に `Bash(bash:*)` 等の汎用実行系 allow を置かない。PM・infra の allow も、実行するプログラムが固定される形まで狭める（`Bash(docker:*)` ではなく `Bash(docker compose:*)`） | 汎用実行系の allow は「どの層にあっても」deny を無効化する。ランチャー未導入時のフォールバック実行形（`bash "<プラグインルート>/scripts/…"`）は対話セッションでの承認を前提にした縮退経路であり、allow で常時開けておくものではない。**狭めても塞ぎ切れるわけではない**（§3.1） |

> **tracked の `.claude/settings.json` へ運用 allow を手で追記するのは非推奨**（2026-09-10 決定。Issue #239）。理由は 2 つある。① **正本が 2 つになる**: deny 専用の割当（§1）と併存させると「運用 allow はどこに置くのが正か」が場所によって変わり、読み手は効いているかどうかを §3 の表を引かないと判定できない。② **効かない場面が広い**: tracked の allow は各人が各クローンで trust を承認するまで効かず、headless（`claude -p`）ではダイアログが出ないため**永久に効かない**（§2 実験 2）。チームで揃えたい場合は、リポジトリの README／オンボーディング手順で**各自のユーザー設定への追記を案内する**。
>
> 変わらないこと: **`/init-project` は tracked へ allow を決して書かない**（§1 の決定）。既に tracked に allow が在るリポジトリを一斉に是正することもしない（§5）。非推奨にしたのは「新たに手で足すこと」である。

`docs/getting-started.md` §2「許可設定をどこに置くか」は本表の要約である。

### ユーザー設定向けスニペット

`/init-project` は生成結果とあわせて次の形のスニペットを提示する（プロジェクトの PM・テストランナー・infra に応じて行が増減する）。**ファイルへの書き込みは人間が行う**（エージェントは `settings.json` を書き換えない。`scripts/specs/preflight.md`「自動適用しない」）。

```json
{
  "permissions": {
    "allow": [
      "Bash(claude-harness-run:*)",
      "Bash(npm:*)"
    ]
  }
}
```

既にユーザー設定がある場合は `permissions.allow` 配列へ要素を足す（配列ごと置き換えない）。

---

## 5. 移行方針

| 対象 | 方針 |
|---|---|
| **新規に `/init-project` を実行するプロジェクト** | 生成する `.claude/settings.json` の `allow` は運用 allow を含まない（deny 専用）。外した allow はユーザー設定向けスニペットとして完了報告に出す |
| **既に導入済みのプロジェクト**（`allow` に `Bash(bash:*)` 等が残っている） | **触らない。一斉是正しない。** 残っていても動作は変わらない（従来どおり trust 済みの環境で prompt が減るだけ）。deny 専用にしたければ、そのリポジトリの判断で手で外す。`generate-settings.sh` の冪等マージは**既存の allow を削らない** |
| **`preflight`** | `settings_launcher_allow` / `settings_base_allow` は、ルールがユーザー設定（オペレータ層）に在れば **blocking にしない**。tracked にも オペレータ層にも無いときだけ blocking。是正の提示は「チーム共有が不要ならユーザー設定でよい」を含む |
| **既に導入済みのプロジェクトへの `ask` の遡及適用** | **行わない（マイグレーションを持たない）。** 生成器を再実行すれば `ask` がマージされるが、一斉実行はしない。`preflight` の `settings_allow_overreach` は `ask` の有無に依存せず動く（deny だけでも働く） |
| **`/init-project` の再実行** | 既存の allow は保持される（削らない）。新規に足す allow は無い。**deny / ask の不足分だけ**がマージされる（生成器は `permissions.ask` も冪等にマージする） |
| **tracked に運用 allow を手で足しているリポジトリ** | **触らない。一斉是正しない。** 新たに足すのは非推奨（§4）だが、既に在るものを外すかはそのリポジトリの判断 |

### 変更の分割（Issue #227 / #222 / #226）

1. **設計（本文書）**: 割当表・保証しない範囲・移行方針を先に確定する。
2. **`preflight`（当時の名前は `doctor`）の判定変更（#222）**: ユーザー設定に在る allow を受理して blocking を落とす。生成物の変更より先に入れることで、「生成物から allow を外したら preflight が赤になる」順序の逆転を防ぐ。
3. **生成物の変更（#227・#226）**: `generate-settings.sh` の `allow` から運用 allow（`Bash(bash:*)` を含む）を外し、スニペット出力を足す。#226（既定 allow の `Bash(bash:*)`）はこの変更で完了条件を満たす。

---

## 6. 関連文書

- `docs/script-launcher.md` §6 — `Bash(claude-harness-run:*)` の保証範囲と、`deny` がプロセスツリーに効かないことの正本
- `skills/init-project/scripts/base-deny.json` / `base-ask.json` — 生成されるベース `deny` / `ask` の正本（§1.1）
- `skills/init-project/scripts/general-exec-allow.json` — 汎用実行系の呼び出し形の正本（`preflight` の `settings_allow_overreach` が読む。§3.1）
- `scripts/specs/preflight.md` — `preflight` の判定規則の正本（オペレータ層の扱いを含む）
- `skills/init-project/SKILL.md` ステップ6 — 生成物の契約とスニペットの提示（本文書 §1 の決定を参照する）
- `skills/init-project/SKILL.md` ステップ4 — 生成物へ harness／プラグイン固有の語を書かない規定（出所の規律。本文書 §1 の決定と対）
- `docs/getting-started.md` §2 — 導入手順と「許可設定をどこに置くか」
- `docs/claude-rules-adoption.md` — `.claude/rules/` の導入可否の案と推奨（§2.1 の実測を根拠にする。Issue #242）

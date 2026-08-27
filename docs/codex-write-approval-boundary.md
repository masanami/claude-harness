# Codex ticket worker の承認境界（`--sandbox workspace-write`）

Issue [#200](https://github.com/masanami/claude-harness/issues/200) の「最終決定（2026-08-23）」§6 が Phase 2（`codex exec --sandbox workspace-write` を使う ticket worker PoC）の着手条件として挙げた7項目を、**実際に強制できる単位**へ落とした設計。

**本文書はまだ決定ではない。** §8 に未決の設計判断を列挙してある。そこが埋まるまで Phase 2 へ進まない（#200 §6 の停止条件）。

**本文書のいちばんの価値は §5「強制できない項目」にある。** 7項目のうち何が OS とプロセス起動で機械的に止まり、何が止まらないのかを、推測ではなく実測で切り分けてある。強制できないものを「設計した」と書いてしまうのが、この種の境界設計でいちばん危険な失敗であり、それを避けるのが本文書の目的である。

---

## 1. 実測（codex-cli 0.145.0 / macOS 26.5 / 2026-08-27）

以下はすべて**この環境で実際に `codex exec` を起動して得た値**であり、ドキュメントからの引用や推測ではない。バージョンが上がれば再取得が要る（→ §7 の probe テスト）。

### 実測1: `--sandbox workspace-write` の既定 writable root

`codex exec --sandbox workspace-write -C <dir>` の起動バナーが実効設定を出す:

```text
approval: never
sandbox:  workspace-write [workdir, /tmp, $TMPDIR]
```

**既定で `/tmp` と `$TMPDIR` が書き込み可能**である。つまり「割り当て worktree 内に限定」は `-C` だけでは成立しない——worktree 自体が `/tmp` や `$TMPDIR` の配下にあると、**兄弟ディレクトリも親も書ける**。

同一プロンプトを2箇所で走らせた対照:

| worktree の位置 | `touch ./inside.txt` | `touch ../outside-sibling.txt` | `touch "$(git rev-parse --git-common-dir)/probe.txt"` |
|---|---|---|---|
| `/tmp/wtprobe/wt1` | 0 | **0（書けた）** | **0（書けた）** |
| `$HOME/wtprobe2/wt1` | 0 | 1 `Operation not permitted` | 1 `Operation not permitted` |

`/tmp` 側で「書けた」のは workdir の外だからではなく、**`/tmp` が既定 writable root だから**である。

### 実測2: git worktree の `.git` は worktree の外にある

`git worktree add` で作った作業ツリーの `.git` は**ファイル**であり、共有 git ディレクトリを指す:

```text
$ cat wt1/.git
gitdir: /Users/masami/wtprobe2/main/.git/worktrees/wt1
```

`git rev-parse --git-common-dir` は `<main>/.git` を返す。**コミットオブジェクトも ref も index.lock も、この worktree の外に書かれる。**

$HOME 配下（実測1 の下段）での書き込み可否:

| パス | 結果 |
|---|---|
| `<common>/objects/probe.txt` | 1 `Operation not permitted` |
| `<common>/refs/heads/probe-file.txt` | 1 `Operation not permitted` |
| `<common>/hooks/probe-hook.sh` | 1 `Operation not permitted` |
| `<common>/info/probe.txt` | 1 `Operation not permitted` |
| `<git-dir>`（= `<common>/worktrees/wt1/`）`/probe.txt` | 1 `Operation not permitted` |
| `<common>/config`（追記） | 1 `operation not permitted` |
| `<main>/probe-in-main-worktree.txt`（主 worktree の作業ツリー） | 1 `Operation not permitted` |

**サンドボックスは共有 `.git` を完全に閉じている。** `.git/hooks` も `.git/config` も書けない。これは良い知らせだが、同時に次を意味する——**サンドボックス内では `git commit` ができない**（→ 実測4）。

### 実測3: `~/.codex/rules/default.rules` が、対話セッションの履歴からサンドボックスの穴を作る

このマシンの `~/.codex/rules/default.rules`（10行）には、過去の対話 Codex セッションが書き足した恒久ルールが入っていた:

```text
prefix_rule(pattern=["git", "commit"], decision="allow")
prefix_rule(pattern=["gh", "issue"],   decision="allow")
prefix_rule(pattern=["gh", "api"],     decision="allow")
prefix_rule(pattern=["mkdir", "-p", "/Users/masami/dio-health/.worktrees/task-…"], decision="allow")
…
```

`codex exec` は既定でこれを読む（`--ignore-rules` の help: *"Do not load user or project execpolicy `.rules` files"*）。

### 実測4（決定的）: `.rules` の `decision="allow"` は**サンドボックスの外**でコマンドを実行させる

同一 worktree・同一サンドボックスモード・同一モデルで、`--ignore-rules` の有無だけを変えた対照実験:

| コマンド | 既定（`.rules` を読む） | `--ignore-rules` |
|---|---|---|
| `git commit --allow-empty -m probe` | **exit 0**。`<main>/.git` に ref とオブジェクトが実際に作られた | exit 128 `fatal: Unable to create '<main>/.git/worktrees/wt1/index.lock': Operation not permitted` |
| `gh api user --jq .login` | **exit 0**、`masanami` を返した（＝ネットワークも資格情報も通った） | exit 1 `error connecting to api.github.com` |
| `curl -s https://example.com`（`.rules` に無い） | exit 6（名前解決不可） | — |

同時刻のホスト側 `curl https://api.github.com/` は 200。**つまり `gh api` が通ったのはネットワークが空いていたからではなく、サンドボックスの外へ出たからである。**

この1点だけで #200 §6 の次の3項目が現状のまま破れる:

- 「local write / commit / push / Issue / PR / merge を**別権限**として扱う」——`git commit` と `gh api` が無差別に許可済み。`gh api` は API 経由の merge も delete も含む
- 「外部 write は runner 側の明示的な policy/approval を通す」——runner は何も通していない
- 「provider 切替によって権限が拡大しない」——この許可は**operator の過去の対話履歴**という、harness が管理していない可変状態に載っている

### 実測5: `codex exec` に人間承認の経路は無い

`codex exec --help`（0.145.0）に `--ask-for-approval` は**無い**。起動バナーは常に `approval: never`。バイナリ内の診断文字列にも `approval required by policy, but AskForApproval is set to Never` がある。

**「実行前に人間へ聞く」は `codex exec` の中には存在しない。** 承認は「起動する前に、能力を渡すかどうか」でしか表現できない。

### 実測6: worktree 内の `AGENTS.md` は次回起動時に必ずモデルへ届く

worktree 直下に `AGENTS.md` を置き、`codex debug prompt-input`（モデルに渡る input list を描画する。モデル呼び出しは発生しない）で確認:

```text
$ printf 'PROBE_MARKER_AGENTS_MD_LOADED\n' > AGENTS.md
$ codex debug prompt-input | grep -c PROBE_MARKER_AGENTS_MD_LOADED
1
```

worktree 内は書き込み可能なので、**エージェントは自分の次回起動時の指示を自分で書き換えられる**。

### 実測7: operator の `~/.codex/config.toml` が、サンドボックス外のツール経路を注入する

同じ `codex debug prompt-input` の出力（25,573 バイト）に、operator の user config 由来の skills / plugins / MCP が入っていた: `codex_apps` MCP、`browser:control-in-app-browser`（ブラウザ操作）、`documents` / `pdf` / `sites`、`mcp_servers.node_repl`（任意 JS 実行）。

`--sandbox` の help はスコープを明示している——*"Select the sandbox policy to use when executing **model-generated shell commands**"*。**MCP ツール呼び出しはシェルコマンドではない。** サンドボックスモードは MCP サーバのプロセスを縛らない。

現行の `scripts/codex-review-runner.sh` は `--ignore-user-config` を渡していないので、**read-only レビューカプセルにもこの経路は開いている**（本文書のスコープ外だが、同じ対策で塞がる）。

---

## 2. 権限モデル: 強制点は3層しかない

| 層 | 何が強制するか | runner が握れるか | 穴 |
|---|---|---|---|
| **L1 OS サンドボックス** | seatbelt（macOS）。`--sandbox` + `-C` + writable roots | 起動引数として握れる | **`.rules` の allow で個別コマンドが外へ出る**（実測4）／**MCP・plugin ツールは対象外**（実測7） |
| **L2 プロセス起動** | 起動引数・環境変数・cwd・worktree の中身 | **完全に握れる** | 無い（runner が唯一の起動経路である限り） |
| **L3 能力（資格情報）の不在** | 渡していない token・鍵・remote は使えない | **完全に握れる** | 無い（L1 が破れても効く） |

**設計の中心命題: 外部 write の禁止を L1 に賭けてはならない。** L1 の穴（`.rules`・MCP）は、どちらも harness の外——operator の過去の対話履歴と個人設定——に住んでいる。harness 側がリストで追いかけると、`docs/plugin-path-conventions.md` が「2つのリストを同期させる規定は必ずずれる」と書いたのと同じ形になる。

したがって:

> **禁止したい外部作用については、「やらせない規則」ではなく「やれる道具を渡さない」で成立させる。**

これは同期を要さない（許可リストが1つも増えない）。L1 が将来のバージョンで壊れても、資格情報が無ければ `gh` も `git push` も失敗する。

### 2.1 権限の分解表（どこで何が強制されるか）

#### 現行（対策前。実測に基づく素の `codex exec --sandbox workspace-write`）

| 権限 | 実行できるか | 強制点 | 根拠 |
|---|---|---|---|
| worktree 内の local write | ✅ できる | L1（意図どおり） | 実測1 |
| worktree 外の local write | ❌ できない（worktree が `/tmp`・`$TMPDIR` 配下でなければ） | L1 | 実測1 |
| `.git`（共有）への write | ❌ できない | L1 | 実測2 |
| **commit** | ⚠️ **`.rules` 次第で できる** | 無し | 実測4 |
| **push** | ⚠️ 未実測だが `git` prefix rule と資格情報の到達性次第 | 無し | 実測3・4 からの推論（→ §9 未検証） |
| **Issue / PR / merge（`gh`）** | ⚠️ **できる**（`gh api` が exit 0 で認証済み応答を返した） | 無し | 実測4 |
| 人間承認 | ❌ 経路が存在しない | — | 実測5 |

#### 本文書が提案する形（対策後）

| 権限 | 誰が実行するか | 強制点 | 強制の形 |
|---|---|---|---|
| worktree 内の local write | Codex | L1 + L2 | `--sandbox workspace-write -C <worktree>`。worktree は `/tmp`・`$TMPDIR` の配下に置かない |
| worktree 外の local write | 誰も | L1 | 同上（実測1 下段が示す既定挙動） |
| settings / 認証情報 / 権限設定の変更 | 誰も | L1 + L2 + **検出** | `~/.codex` は L1 が拒否（実測）。**worktree 内**の保護対象パス（`.claude/settings.json`・`scripts/*` 等）は L1 では止まらないので、runner が引き渡し前後のハッシュ差分で検出し fail-closed（→ §5-1） |
| **commit** | **runner**（Codex ではない） | L1 が構造的に拒否 + L2 | worktree 構成では sandbox 内 commit が原理的に不可能（実測2・4）。`--ignore-rules` で `.rules` の穴を塞げば「渡さなくても勝手にできない」状態になる |
| **push** | **runner** | L3 | worktree に到達可能な remote 資格情報を置かない（scrubbed env + 隔離 `HOME`） |
| **Issue / PR** | **runner** | L3 | `gh` の資格情報を渡さない（`GH_TOKEN`/`GITHUB_TOKEN` を落とし、`HOME` を隔離して `~/.config/gh/hosts.yml` を不可視にする） |
| **merge（既定ブランチへの昇格）** | **人間** | L3 + 運用ゲート | 上に同じ。加えて `CLAUDE.md` の昇格ゲート（可逆／不可逆の区別）が既存どおり効く |

**「別権限として扱う」の実体は、この表の「誰が実行するか」列がすべて違う値を取ること**である。権限名の列挙ではなく、**実行主体の分離**として表現する。

---

## 3. runner が固定すべき起動条件

L2 は runner が完全に握れる唯一の層なので、ここに全部を集約する。**正本は1箇所**（`sync-free-invariant`）——`codex exec` を直接呼ぶ経路を runner 以外に作らない。

| 項目 | 値 | 理由（実測） |
|---|---|---|
| `--sandbox` | `workspace-write` | — |
| `-C` | 割り当て worktree の絶対パス | 実測1 |
| `--ignore-rules` | **必須** | 実測4。これが無いと `git commit`・`gh api` がサンドボックス外へ出る |
| `--ignore-user-config` | **必須** | 実測7。MCP・plugin 経路を落とす。auth は `CODEX_HOME` から読まれるので Codex 自身の認証は壊れない |
| `CODEX_HOME` | runner 管理のディレクトリ（`auth.json` のみ） | `.rules` も `config.toml` も同居させない |
| `HOME` | 実行ごとの隔離ディレクトリ | `~/.config/gh/hosts.yml`・`~/.ssh`・`~/.gitconfig`（`credential.helper`）・`~/.netrc` を不可視にする（L3） |
| 環境変数 | `GH_TOKEN` / `GITHUB_TOKEN` / `GIT_ASKPASS` / `SSH_AUTH_SOCK` 等を除去 | L3 |
| worktree の位置 | `/tmp`・`$TMPDIR` の配下**ではない**こと | 実測1。既存 `scripts/worktree-setup.sh` の既定（`<repo>-worktrees`）はこれを満たす |
| worktree のパス形 | `<worktree_root>/issue-<N>` の**形**を正規表現で要求し、realpath で正規化して検査 | 前置一致検査は「そのディレクトリ自身」も受理してしまう。パス列挙ではなく形で塞ぐ（`scripts/read-plugin-doc.sh` の配送対象検査と同じ方式） |

### 3.1 「設定したつもり」を潰す起動時 self-check

上の表を**書いただけでは効かない**。runner は起動直後に**実効設定を読み戻して照合**する:

- `codex exec` の起動バナー（または `--json` イベント）から `sandbox:` 行と `approval:` 行を取る（実測1 でこの2行が出ることを確認済み）
- 期待値（`workspace-write [workdir]` を含む・`/tmp` や `$TMPDIR` が worktree の祖先でない・`approval: never`）と一致しなければ**即中断**

これは「flag を渡し忘れた」「codex のバージョンが上がって既定が変わった」を**機械で**検出できる唯一の手段である。

---

## 4. 現状（claude-harness）との差分

推測を混ぜないため、実在するファイルだけを挙げる。

| 現行の仕組み | 何を強制しているか | Codex worker に効くか |
|---|---|---|
| `skills/init-project/scripts/base-deny.json` | 利用側プロジェクトの `.claude/settings.json` に `rm -rf` / `git push --force` / `gh repo delete` 等 6 件の deny を合成 | **効かない**（Claude Code のツール層の設定であり、codex は読まない） |
| 同 `generate-settings.sh` の base allow（27 件） | `Bash(git commit:*)` `Bash(git push:*)` `Bash(gh issue:*)` `Bash(gh pr:*)` `Bash(gh api:*)` を**まとめて allow** | 同上。加えて**現行の Claude 側も commit / push / Issue / PR を別権限として分けていない**（#200 §6 の要件は Claude 側でも未達） |
| `agents/*.md` の `tools:` 宣言（例: `finding-verifier` は `Read, Glob, Grep`） | Claude Code のサブエージェントが持つツール集合 | **効かない**（codex は別のツール集合を持つ） |
| `scripts/config/sensitive-paths.txt` | 保護対象パスの**正本**（`.github/workflows/*`・`*secret*`・`*.pem`・`scripts/*`・`CLAUDE.md`・`.claude/settings*.json`） | **リストは再利用できる**が、現状の用途は `pr-merge-preflight.sh` の `touches_sensitive` **検出**であって強制ではない |
| `scripts/read-plugin-doc.sh` の配送対象検査（exit 77） | プラグイン配下の特定サブツリー外を拒否。絶対パス・`..` を拒否 | **方式が再利用できる**（形で塞ぐ・前置一致に頼らない） |
| `scripts/codex-review-runner.sh` | `--sandbox read-only` と `--output-schema`、`complete/partial/failed`、timeout、fail-closed な exit code | **土台としてそのまま使える**。ただし `--ignore-rules` / `--ignore-user-config` / 環境スクラブは**入っていない** |
| `CLAUDE.md`（運用側）の昇格ゲート | 既定ブランチへのマージは人間承認 | 散文の約束。強制ではない |

**このリポジトリ自身には `.claude/settings.json` が無い**（`generate-settings.sh` は利用側プロジェクト向けの生成器）。したがって「現行 harness の allow/ask/deny が Codex worker に対して何かを守っている」という前提は**成立しない**。

**保護対象ファイルのリストは増やさない。** 正本は `scripts/config/sensitive-paths.txt` のまま、runner の差分検査が**同じファイルを読む**。検出（PR 時）と強制（runner）が同じ正本を参照する形にして、2つのリストを同期させる設計にはしない。

---

## 5. 強制できない項目（できない理由と代替案）

#200 §6 の7項目を、強制できるもの／できないものへ仕分ける。

### 5-1. 「settings、認証情報、権限設定、保護対象ファイルの変更可否」——**worktree の外は強制できる。中は強制できない**

- **できる**: `~/.codex`・`~/.claude`・共有 `.git` への書き込みは L1 が拒否する（実測: `touch $HOME/.codex/probe-home.txt` → `Operation not permitted`、実測2 の表）
- **できない**: worktree の中にある `.claude/settings.json`・`scripts/*`・`.github/workflows/*` は、worktree 内である以上 L1 は止めない。「これらだけ書けない」を OS 権限で表現するには、実行ごとに chmod するか別マウントに逃がすしかなく、`git checkout` で戻る／プラグインとして配布できない
- **代替案（検出＋ fail-closed）**: 引き渡し**前**に `sensitive-paths.txt` にマッチする worktree 内ファイルのハッシュを取り、返却時に再取得して差分があれば**成果物を採用しない**。加えて `AGENTS.md`・`.codex/`・`.rules` を同じ扱いにする（実測6）
- **限界を明記する**: これは「変更させない」ではなく「変更されたら採用しない」である。Phase 2a（local implementation のみ、外部作用なし、失敗時は worktree ごと破棄）ではこの強度で釣り合うが、Phase 2b（commit / PR まで拡張）では釣り合わない

### 5-2. 「agent 自身が権限・approval policy を変更できない」——**ファイルシステム権限だけでは保証できない**

- `~/.codex/config.toml`・`~/.codex/rules/*.rules` は L1 が拒否する（実測）
- しかし **worktree 内の `AGENTS.md` は書けて、次回起動時に確実にモデルへ届く**（実測6）。「権限設定」そのものではないが、**指示層の自己改変**であり、プロンプト側の規律に依存した対策はすべてこれで無効化されうる
- `--ignore-rules` の help は "user or **project** execpolicy `.rules` files" と述べており、**project スコープの `.rules` が存在する**。その探索パスは 0.145.0 では未確認（→ §9）。worktree 内に置けるなら、これは指示層ではなく**権限層**の自己改変になる
- **代替案**: ① `--ignore-rules` を runner が常時付ける（project `.rules` の探索パスが何であれ、読まれない）② `AGENTS.md`・`.codex/` を 5-1 の差分検査対象に含める ③ **プロンプトに書いた規律を安全性の根拠にしない**（読ませて守らせる形は到達性が保証されない）
- **残る限界**: `--ignore-rules` を付け忘れた1回で穴が開く。だから §3.1 の起動時 self-check が要る（付け忘れを検出する）。ただし self-check はバナー出力に依存しており、**バナーは `.rules` の有無を表示しない**——`--ignore-rules` の有無は runner のコード側でしか検査できない（→ §7 のテストで固定する）

### 5-3. 「provider 切替によって権限が拡大しない」——**「等価にする」形では強制できない**

- Claude 側の権限は `.claude/settings.json` の allow/ask/deny とツール層、Codex 側は `.rules` + `config.toml` + seatbelt。**表現力も評価順序も違う**ので、2つを同値に保つ規定は必ずずれる
- しかも Codex 側の `.rules` は **operator の対話セッションが勝手に書き足す**（実測3。`git commit` も `gh api` も harness は一度も許可していない）
- **代替案**: 等価性ではなく**片側の包含**で成立させる。Codex 側は「許可リストを持たない・能力を渡さない」（§2 の L3）を採り、**構成上つねに Claude 側より狭い**ようにする。§2.1 の対策後の表はこれを満たす（commit すら渡さない）
- **限界を明記する**: これは「拡大しない」を**設計で保証**しているのであって、**照合で検証**しているのではない。Codex 側に何か1つでも許可リストを足した時点で、この保証は消える

### 5-4. 「外部 write は runner 側の明示的な policy/approval を通す」——**「通す」形は実現できない。「そもそも実行できない」形にする**

- `codex exec` に承認の経路が無い（実測5）。runner が「実行前に止める」ことはできない
- **代替案**: 外部作用の**能力そのもの**（`gh` の資格情報・push できる remote・network）を Codex に渡さず、外部 write は runner が worktree の外で実行する。承認は「runner が実行するかどうか」の判断へ移る
- **副次的な利点**: 承認点が runner の1関数に集約されるので、人間ゲート（既定ブランチへの昇格）を掛ける場所が1箇所になる

### 5-5. MCP / plugin 経路——**サンドボックスモードでは塞げない**

- `--sandbox` はモデル生成の**シェルコマンド**にしか掛からない（help の文言）。MCP サーバは別プロセスで、`browser` や `node_repl` のようなツールは任意の副作用を持ちうる（実測7）
- **代替案**: `--ignore-user-config` + 専用 `CODEX_HOME` で**経路自体を注入させない**。「危険な MCP を列挙して禁止する」形は採らない（列挙は operator 設定の変化に追随できない）

### 5-6. 強制できるもの（確認のため）

| 項目 | 強制できるか | 手段 |
|---|---|---|
| 書き込み範囲を worktree 内に限定 | ✅ | L1 + worktree を `/tmp`・`$TMPDIR` の外に置く（実測1） |
| commit / push / Issue / PR / merge を別権限にする | ✅ | 実行主体の分離（§2.1）。commit は L1 が構造的に拒否する（実測2・4） |
| approval 拒否・provider 失敗時の fail-closed | ✅ | §6 |

---

## 6. fail-closed の具体

**原則: 判定不能はすべて「権限を持たない側」「成果物を採用しない側」へ倒す。**

| 事象 | 何が起きるべきか | 状態 / exit |
|---|---|---|
| **provider 失敗**（`codex` が PATH に無い） | 起動しない | `codex_unavailable` / exit 69（既存 `codex-review-runner.sh` と同じ割り当て） |
| **provider 失敗**（`codex exec` が非0 / timeout） | 成果物（worktree の変更）を**採用しない**。worktree は破棄せず保全して調査可能にする | `result: failed` / exit 4 |
| **サンドボックス設定の取得失敗**（バナーを読めない・`sandbox:` 行が期待値と違う・`approval:` が `never` でない） | **起動を中断する**（読めない＝安全とは見なさない） | `sandbox_unverified` / exit 69 |
| **起動条件の不備**（`--ignore-rules` / `--ignore-user-config` の欠落、`CODEX_HOME` 準備失敗、環境スクラブ失敗） | 起動しない | `launch_precondition_failed` / exit 69 |
| **worktree パスの検査に失敗**（形が違う・`/tmp` や `$TMPDIR` の配下・realpath 解決不能） | 起動しない | `worktree_rejected` / exit 77（`read-plugin-doc.sh` の NOPERM と揃える） |
| **保護対象ファイルの差分を検出**（`sensitive-paths.txt` にマッチ、または `AGENTS.md` / `.codex/` / `.rules` が変化） | 成果物を採用しない。差分の一覧を報告に含める | `protected_path_modified` / exit 4 |
| **approval 拒否**（runner の policy 検査で外部作用が不許可） | 外部作用を実行しない。**local の成果物はそのまま残す**（判断を人間へ上げるため） | `approval_denied` / exit 3（partial） |
| **部分失敗**（worktree の一部だけ完了、quality gate 未通過） | `complete` と扱わない。何が未完かを構造化して返す | `result: partial` / exit 3 |

**「検査していないものを pass に見せない」**（#192・`quality-check-runner.sh` の exit 3）と同じ規律を、承認境界にも適用する。**空の差分・読めなかったバナー・取得できなかったハッシュを「問題なし」に変換しない。**

### 6.1 層を足したときに、上の層が下の層を迂回しないこと

本設計は L1（OS）の上に L2（起動条件）と runner の検査を足す。過去に「下層のゲートを上層が迂回する」欠陥を作った実例（PR #195 / `promote-verify` Step 6-1）があるため、迂回しないことを明示する:

- **runner は worktree 内で git を実行しない**——実行するなら、worktree 内の `.git` を信用しない形（`git -C` で共有 `.git` 側から操作する）にする。git worktree 構成では `.git` が共有側にあり Codex から書けない（実測2）ので、**この構成を維持している限り hook / config 経由の迂回は成立しない**
- **独立 clone に切り替えると、この保証は消える**（`.git/hooks`・`.git/config` が worktree 内＝Codex 書き込み可能になり、runner が `git status` を打った瞬間に `core.fsmonitor` / alias / `diff.external` 経由で unsandboxed 実行が起きうる）。§8 の質問③に直結する
- **runner の検査は Codex の成果物を読む前に走る**——`sensitive-paths.txt` の差分検査を「Codex の報告 JSON を信じて省略する」経路を作らない

---

## 7. 検証方法

### 7.1 テストで固定できるもの（bash テスト。`scripts/tests/*.sh` と同形）

| 検査対象 | 固定の仕方 |
|---|---|
| runner が渡す flag 列 | `codex` をスタブに差し替えて引数を記録し、`--sandbox workspace-write` / `--ignore-rules` / `--ignore-user-config` / `-C <worktree>` が**すべて**在ることを assert |
| 環境スクラブ | スタブが受け取った環境を書き出し、`GH_TOKEN` 等が**不在**であること・`HOME` と `CODEX_HOME` が runner 管理パスであることを assert |
| worktree パス検査 | `/tmp/x`・`$TMPDIR/x`・`<root>` 自身・`..` を含むパス・形が違うパスが**すべて拒否**されること（前置一致の落とし穴を直接突く負例を含める） |
| 起動時 self-check | バナーを偽装したスタブ（`sandbox: danger-full-access` / `approval: on-request` / バナー無し）で**中断**すること |
| 保護対象パスの差分検査 | `sensitive-paths.txt` の各パターンに当たるファイルを worktree 内で改変した状態を作り、`protected_path_modified` になること。`AGENTS.md` 新規作成も同様 |
| fail-closed の exit code | §6 の表の各行を1テストにする |
| 正本の単一性 | `codex exec` を直接呼ぶ箇所が runner 以外に無いこと（リポジトリ全体の grep） |

### 7.2 テストで固定できないもの（probe テスト＝実測の再取得）

seatbelt の挙動そのものは OS と codex のバージョンに依存し、スタブでは再現できない。**§1 の実測表を再取得するテスト**を別立てにする:

- `codex` が PATH に在り、かつ明示的に有効化されたときだけ走る（通常の品質ゲートを外部依存で不安定にしない）
- 使い捨ての git worktree を `$HOME` 配下に作り（`/tmp` は既定 writable なので測定にならない）、§1 の表と同じ probe を回して**表と一致するか**を判定する
- 一致しなければ「codex のサンドボックス挙動が変わった」として**設計の再検討を要求する**（テストを緩めない）

### 7.3 検証できないもの（正直に書く）

- **MCP / plugin 経路の網羅**——operator の `~/.codex/config.toml` 次第で増減する。列挙して検査する形は原理的に追いつかない。`--ignore-user-config` で経路自体を落とすこと**だけ**を検査する
- **`.rules` の allow が将来どのコマンドを覆うか**——過去の対話履歴が書き足す。`--ignore-rules` の有無**だけ**を検査する
- **「エージェントが規約を読んで守ったか」**——プロンプトへの規約配送は到達性が保証されない実測があるため、本設計は安全性をここに依存させていない。したがって検査項目にも置かない

---

## 8. 未決の設計判断（意思決定者の回答が要る）

**この3点が埋まるまで本文書は「決定」ではなく、Phase 2 へ進まない。**

### ① 境界を強制する層をどこに置くか

| 案 | 内容 | 評価 |
|---|---|---|
| A | codex の flag のみ（`--sandbox workspace-write --ignore-rules --ignore-user-config`） | 実測4 が示すとおり flag だけでも `.rules` の穴は塞がる。ただし `gh` の資格情報は環境と `HOME` に残ったままなので、**L1 が1度でも破れれば外部作用が通る** |
| **B（推奨）** | A + **環境スクラブと `HOME`/`CODEX_HOME` の隔離**（L3） | 外部作用を「規則」ではなく「能力の不在」で止める。許可リストを1つも増やさないので同期ずれが起きない |
| C | B + 専用 OS ユーザ / コンテナ | 最も強いが、claude-harness は**プラグイン**であり利用側マシンの構成に踏み込めない。配布形態と衝突する |

**推奨 B**。根拠: A では実測4 の `gh api user` が「サンドボックスが破れた瞬間に成功する」状態のまま残る。C は Phase 3 以降の選択肢として残し、今は採らない。

### ② 「強制できない項目」を許容して Phase 2 へ進むか

§5 の 5-1（worktree 内の保護対象ファイル）・5-2（`AGENTS.md` による自己改変）・5-5（MCP 経路の残存可能性）は、**検出＋ fail-closed** までしか作れない。

| 案 | 内容 |
|---|---|
| **A（推奨・条件つき）** | Phase 2a（local implementation のみ・外部作用なし・失敗時は worktree ごと破棄で回復可能）に限って許容し、**§3.1 の起動時 self-check と §5-1 の差分検査が実装されていること**を着手条件にする |
| B | すべて OS レベルで強制できるまで進まない | → 実質コンテナ化が前提になり、プラグインという配布形態と衝突する（①の C と同じ壁） |

**推奨 A**。根拠: Phase 2a の被害範囲は worktree 内に閉じ、外部作用の能力は渡していない（B 案の下では）。検出できれば成果物を捨てるだけで回復する。ただし **Phase 2b（commit / PR まで拡張）へ進むときは、この判断を必ず取り直す**——そこでは「採用しない」では回復しない。

### ③ Codex に許す git 操作の範囲

| 案 | 内容 | 評価 |
|---|---|---|
| **A（推奨）** | **working tree の変更のみ。commit は runner** | 実測2・4 のとおり worktree 構成では sandbox 内 commit が**構造的に不可能**なので、「許さない」を追加の仕掛けなしで満たせる。#200 本文の Phase 2a（「commit / push / PR は当面 runner または Claude lead に残す」）とも一致 |
| B | 独立 clone に切り替えて commit まで許す | `.git` が worktree 内に入るので commit できるようになるが、**同時に `.git/hooks` と `.git/config` が Codex 書き込み可能になる**。runner が後でその clone に対して git を打つと unsandboxed 実行が起きうる（§6.1）。「下層のゲートを上層が迂回する」形そのもの |
| C | push / PR 作成まで | Phase 2b。本設計のスコープ外。②で判断を取り直してから |

**推奨 A**。根拠: B は commit 1つのために、本文書がいちばん強く閉じられている境界（実測2 の `.git` 全面拒否）を自分から開ける。得るものと失うものが釣り合わない。

---

## 9. 置いた仮定・未検証事項

**仮定（軽微・可逆な範囲。本文書の構成に関する判断）**

- 本文書は `docs/` 側に置いた。実行時テキスト（`skills/` `agents/`）ではなく**設計判断の記録**であり、`docs/plugin-path-conventions.md` (h) の判定軸（「この文を削るとモデルの振る舞いが変わるか」）では docs 側になるため
- ADR ではなく設計ドキュメントにした。§8 が未決であり、**まだ決定ではない**ため。①②③ が確定したら ADR 昇格の要否を別途判定する
- 差分検査の対象は「`sensitive-paths.txt` にマッチするパス + `AGENTS.md` + `.codex/` + `.rules`」に限定した（worktree 全体のハッシュ検査は、Codex が作った正当な成果物との区別が付かないため）

**未検証**

- **push の実測**——`git push` が `.rules` の `["git","commit"]` prefix に**マッチしない**ことは形から明らかだが、`git` 全体を覆う rule が存在する環境での挙動は測っていない。§2.1 の現行表の push 行は実測4 からの**推論**である
- **project スコープ `.rules` の探索パス**——`--ignore-rules` の help が "user or project" と述べる一方、0.145.0 のバイナリからは探索パスを特定できなかった。worktree 内に置けるかどうかが 5-2 の深刻度を左右する
- **`--ignore-user-config` 適用後の prompt-input**——`codex debug prompt-input` は当該フラグを受け付けないため、`codex exec` 側で MCP が実際に消えることは未実測。実測7 は「user config 由来の MCP・plugin が既定で注入される」ことのみを示す
- **Linux（landlock）での挙動**——実測はすべて macOS 26.5 / seatbelt。writable root の既定（`/tmp`・`$TMPDIR`）が同じかは未確認
- **`--add-dir` の粒度**——共有 `.git` の一部だけを writable にできるかは試していない。仮にできても §6.1 の理由から採らない方針

---

## 参考

- Issue [#200](https://github.com/masanami/claude-harness/issues/200) — 「最終決定（2026-08-23）」§6（承認境界）・§7（実装順 5）
- [ADR 0001: Codex サポート](adr/0001-codex-support.md)
- [プラグイン内ファイル参照のパス規約](plugin-path-conventions.md) — (h) 実行時テキストと docs の書き分け
- `scripts/codex-review-runner.sh` / `scripts/specs/codex-review-runner.md` — read-only カプセルの先例（fail-closed・exit code の割り当て）
- `scripts/config/sensitive-paths.txt` — 保護対象パスの正本
- `scripts/read-plugin-doc.sh` — 「形で塞ぐ」パス検査の先例（exit 77）

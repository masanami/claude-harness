# Codex ticket worker の承認境界（`--sandbox workspace-write`）

Issue [#200](https://github.com/masanami/claude-harness/issues/200) の「最終決定（2026-08-23）」§6 が Phase 2（`codex exec --sandbox workspace-write` を使う ticket worker PoC）の着手条件として挙げた7項目を、**実際に強制できる単位**へ落とした設計。

**本文書は決定である**（→ §8。境界を強制する層・Phase 2 の可否・Codex に許す git 操作の範囲を 2026-08-27 に確定した）。**Phase 2a の着手条件**も §8 に置いてある。未決のまま残した項目は §8.4 に分離してある。

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

現行の `scripts/codex-review-runner.sh` は `--ignore-user-config` も `--ignore-rules` も渡していないので、**read-only レビューカプセルにもこの2経路は開いている**。本文書のスコープ外として [#211](https://github.com/masanami/claude-harness/issues/211) に分離した（守るべきものも対策の重心も違うため）。

### 実測8: 環境を「必要なものだけ通す」形に絞っても codex exec は動き、`gh` の資格情報は消える

`env -i` で環境を空にし、**次の6つだけを通して** `codex exec --sandbox workspace-write --ignore-rules --ignore-user-config` を起動した:

```text
PATH  HOME(隔離した空ディレクトリ)  CODEX_HOME  TMPDIR  LANG  TERM
```

結果:

| 検証 | 結果 |
|---|---|
| codex exec の起動・完走 | ✅ 正常に完走した（この6つで足りる） |
| `gh auth status` | **exit 1** `You are not logged into any GitHub hosts.` |

**`HOME` を隔離するだけで `gh` の資格情報（`~/.config/gh/hosts.yml`）が届かなくなる**ことを実測で確認した。`GH_TOKEN` 等を消す作業は、この形では「消す」ではなく「通さない」になる。

codex 自身が子プロセスへ `CODEX_CI=1` `NO_COLOR=1` `PAGER=cat` `LC_ALL` `LOGNAME` を追加し、PATH の先頭に自前のディレクトリを差し込むことも確認した（＝渡した環境がそのまま子に届くわけではない）。

**残る穴を明記する**: `PATH` は**通さざるを得ない**（ticket worker は `git` `node` 等を実行する）。実測に使った PATH には `~/bin` `~/.local/bin` `~/.pyenv/shims` など**operator の `$HOME` 配下**が多数含まれていた。`HOME` を隔離しても **PATH 経由で operator のホーム配下の実行ファイルは届く**。これは意図的に残す残余リスクであり、閉じるなら固定 PATH を渡すしかない（→ §8.4）。

### 実測9（決定的・runner 代行でも残る）: worktree の `.git` ファイルは書き換えられ、runner 側の git 実行を乗っ取れる

git worktree の `.git` は**作業ツリー内にある通常のファイル**（実測2）＝ **workspace-write で書き込み可能**である。これを攻撃者が用意した gitdir へ向けると、その gitdir の `config` が有効になる:

```text
$ printf 'gitdir: <worktree>/.evilgit/.git
' > <worktree>/.git
$ git --git-dir=<worktree>/.evilgit/.git config core.fsmonitor  <worktree 内のスクリプト>
$ git --git-dir=<worktree>/.evilgit/.git config core.hooksPath  <worktree 内のディレクトリ>
```

**runner（サンドボックスの外）が素の git を打つと実行される**:

| runner 側のコマンド | 経路 | 結果 |
|---|---|---|
| `git -C <worktree> status --porcelain` | `core.fsmonitor` | **実行された** |
| `git -C <worktree> commit` | `core.hooksPath` の `pre-commit` | **実行された** |

これは #200 §6 のどの項目でもなく、**「commit / push を runner が代行する」という設計そのものが持ち込む迂回路**である。L1 は共有 `.git` を完全に閉じている（実測2）のに、**runner が worktree 内の `.git` ファイルを信用した瞬間に、その閉じ方が無意味になる。**

対策も同じ環境で実測した:

| 対策 | `git status`（fsmonitor） | `git commit`（hook） | 形 |
|---|---|---|---|
| **M1: `GIT_DIR` / `GIT_WORK_TREE` を明示**（`.git` ファイルを一切参照させない） | 実行されず | — | **構造的**。列挙が要らない |
| M2: `-c core.fsmonitor= -c core.hooksPath=/dev/null` でコマンドライン上書き | 実行されず | 実行されず | **列挙が要る**（`diff.external` `core.pager` 等を数え上げ続けることになる） |

M1 では `git status` の出力に `.evilgit/` が untracked として現れ、**本物の gitdir が使われた**ことも確認できた。

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
| **commit** | **runner**（Codex ではない） | L1 が構造的に拒否 + L2 | worktree 構成では sandbox 内 commit が原理的に不可能（実測2・4）。`--ignore-rules` で `.rules` の穴を塞げば「渡さなくても勝手にできない」状態になる。**runner が代行するときは実測9 の M1 が必須** |
| **push** | **runner** | L3 | worktree に到達可能な remote 資格情報を置かない（環境の positive list + 隔離 `HOME`。実測8） |
| **Issue / PR** | **runner** | L3 | `gh` の資格情報を渡さない。**実測8 で `gh auth status` が exit 1 になることを確認済み** |
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
| 環境変数 | **`env -i` から始め、下の positive list だけを通す** | L3。実測8 |
| worktree の位置 | `/tmp`・`$TMPDIR` の配下**ではない**こと | 実測1。既存 `scripts/worktree-setup.sh` の既定（`<repo>-worktrees`）はこれを満たす |
| worktree のパス形 | `<worktree_root>/issue-<N>` の**形**を正規表現で要求し、realpath で正規化して検査 | 前置一致検査は「そのディレクトリ自身」も受理してしまう。パス列挙ではなく形で塞ぐ（`scripts/read-plugin-doc.sh` の配送対象検査と同じ方式） |

### 3.1 環境は「消す」ではなく「通す」（positive list）

**既知の危険な変数を列挙して消す形は採らない。** 消す側のリストは、新しい資格情報キャリア（新しい CLI の `*_TOKEN`、新しい認証ソケット）が増えるたびに追随が要り、追随を忘れた時点で黙って穴が開く——2つのリストを同期させる規定が必ずずれるのと同じ形である。

代わりに `env -i` を起点に、**動かすために必要だと実測できたものだけ**を通す:

| 変数 | なぜ通すか |
|---|---|
| `PATH` | ticket worker が `git` `node` 等を実行するため。**残余リスクあり**（下記） |
| `HOME` | **実行ごとの隔離ディレクトリを渡す**。operator の `$HOME` は渡さない（実測8: これだけで `gh auth status` が exit 1 になる） |
| `CODEX_HOME` | runner 管理のディレクトリ（`auth.json` のみ）。`--ignore-user-config` でも auth はここから読まれる |
| `TMPDIR` | 実行ごとの一時ディレクトリ。**worktree の祖先にしない**（実測1） |
| `LANG` | ロケール依存の出力差を避けるため |
| `TERM` | 端末制御文字の混入を避けるため |

この6つで `codex exec` が完走することを実測した（実測8）。**この表に無いものは通さない。** 新しい変数を足すときは、なぜ必要かを実測で示してこの表に1行足す——リストは1つのままで、増える方向にしか動かない。

**`PATH` は意図的に残す残余リスク**である。operator の PATH には `~/bin` `~/.local/bin` 等が含まれ、`HOME` を隔離しても**そこにある実行ファイルは届く**（実測8）。閉じるなら固定 PATH を渡すしかないが、利用側プロジェクトのツールチェーン（パッケージマネージャ・言語ランタイム）を runner が知り得ないため、現時点では採らない（→ §8.4）。

### 3.2 「設定したつもり」を潰す起動時 self-check

上の表を**書いただけでは効かない**。runner は起動直後に**実効設定を読み戻して照合**する:

- `codex exec` の起動バナー（または `--json` イベント）から `sandbox:` 行と `approval:` 行を取る（実測1 でこの2行が出ることを確認済み）
- 期待値（`workspace-write [workdir]` を含む・`/tmp` や `$TMPDIR` が worktree の祖先でない・`approval: never`）と一致しなければ**即中断**

これは「flag を渡し忘れた」「codex のバージョンが上がって既定が変わった」を**機械で**検出できる唯一の手段である。

**バナーは `--ignore-rules` / `--ignore-user-config` の有無を表示しない。** この2つは runner のコード側でしか検査できないので、§7.1 のテストで固定する。

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
- **代替案（検出＋ fail-closed）**: 引き渡し**前**に `sensitive-paths.txt` にマッチする worktree 内ファイルのハッシュを取り、返却時に再取得して差分があれば**成果物を採用しない**。加えて `AGENTS.md`・`.codex/`・`.rules`（実測6）と **worktree の `.git` ファイル**（実測9）を同じ扱いにする
- **限界を明記する**: これは「変更させない」ではなく「変更されたら採用しない」である。Phase 2a（local implementation のみ、外部作用なし、失敗時は worktree ごと破棄）ではこの強度で釣り合うが、Phase 2b（commit / PR まで拡張）では釣り合わない。**この差分検査は Phase 2a の着手条件である**（→ §8.2）

### 5-2. 「agent 自身が権限・approval policy を変更できない」——**ファイルシステム権限だけでは保証できない**

- `~/.codex/config.toml`・`~/.codex/rules/*.rules` は L1 が拒否する（実測）
- しかし **worktree 内の `AGENTS.md` は書けて、次回起動時に確実にモデルへ届く**（実測6）。「権限設定」そのものではないが、**指示層の自己改変**であり、プロンプト側の規律に依存した対策はすべてこれで無効化されうる
- `--ignore-rules` の help は "user or **project** execpolicy `.rules` files" と述べており、**project スコープの `.rules` が存在する**。その探索パスは 0.145.0 では未確認（→ §9）。worktree 内に置けるなら、これは指示層ではなく**権限層**の自己改変になる
- **代替案**: ① `--ignore-rules` を runner が常時付ける（project `.rules` の探索パスが何であれ、読まれない）② `AGENTS.md`・`.codex/` を 5-1 の差分検査対象に含める ③ **プロンプトに書いた規律を安全性の根拠にしない**（読ませて守らせる形は到達性が保証されない）
- **残る限界**: `--ignore-rules` を付け忘れた1回で穴が開く。§3.2 の起動時 self-check は**この付け忘れを検出できない**——バナーは `.rules` の有無を表示しないため。したがって `--ignore-rules` / `--ignore-user-config` の欠落は **runner のコード側でしか検査できず、§7.1 の negative test だけが歯止めになる**

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

本設計は L1（OS）の上に L2（起動条件）と runner の検査を足す。過去に「下層のゲートを上層が迂回する」欠陥を作った実例（PR #195 / `promote-verify` Step 6-1）があるため、迂回しないことを明示する。

**この節はいちばん注意が要る。commit / push / PR を runner が代行する設計（→ §8 ③）は、それ自体が迂回路を1本持ち込む。**

#### 迂回路: worktree の `.git` ファイル（実測9）

L1 は共有 `.git` を完全に閉じている（実測2）。ところが **worktree の `.git` は作業ツリー内の通常ファイルであり、Codex から書き換えられる**。攻撃者が用意した gitdir へ向け直せば、`core.fsmonitor` や `core.hooksPath` が有効になり、**runner が素の git を打った瞬間にサンドボックス外で実行される**（実測9 で `git status` と `git commit` の両方で再現した）。

つまり「Codex は共有 `.git` を触れないから安全」は**成り立たない**。触れるのは `.git` そのものではなく、**`.git` の行き先**である。

#### 迂回しない形（必須。実測9 の M1）

runner が worktree に対して git を実行するときは、**`.git` ファイルを一切参照させない**:

```sh
GIT_DIR="<main>/.git/worktrees/<name>" GIT_WORK_TREE="<worktree>" git <subcommand> …
```

- 設定の出所が **Codex から書けない共有 `.git/config`** に固定される
- **列挙が要らない**。`core.fsmonitor` `core.hooksPath` `diff.external` `core.pager` … を数え上げ続ける形（実測9 の M2）は、いずれ数え漏れる
- `.gitattributes` は worktree 内にあり Codex が書けるが、`filter` / `diff` ドライバの**定義**は config 側にあるため、M1 の下では実行に至らない
- **`git submodule` 系は打たない**。`.gitmodules` は worktree 内にあり、`ext::` 等の transport で任意コマンド実行に至りうる

**この形を runner の git 実行の唯一の経路にする**（`sync-free-invariant`。素の `git -C <worktree>` を書ける場所を残さない）。§7.1 でテストとして固定する。

#### その他の迂回禁止

- **独立 clone には切り替えない**（→ §8 ③ の決定）。`.git/hooks`・`.git/config` そのものが Codex 書き込み可能になり、M1 でも塞げなくなる
- **runner の検査は Codex の成果物を読む前に走る**——`sensitive-paths.txt` の差分検査を「Codex の報告 JSON を信じて省略する」経路を作らない
- **差分検査は `.git` ファイルの中身も対象にする**——実測9 の書き換えは、M1 で無害化したうえで**検出もする**（`protected_path_modified`）。無害化だけだと「攻撃が起きた事実」が報告に出ない

---

## 7. 検証方法

### 7.1 テストで固定できるもの（bash テスト。`scripts/tests/*.sh` と同形）

| 検査対象 | 固定の仕方 |
|---|---|
| runner が渡す flag 列 | `codex` をスタブに差し替えて引数を記録し、`--sandbox workspace-write` / `--ignore-rules` / `--ignore-user-config` / `-C <worktree>` が**すべて**在ることを assert |
| 環境の positive list | スタブが受け取った環境を書き出し、**§3.1 の表に無い変数が1つも無い**こと（不在検査ではなく完全一致）・`HOME` と `CODEX_HOME` が runner 管理パスであることを assert。危険変数の不在検査にしないのは、リストが育つ形になるため |
| worktree パス検査 | `/tmp/x`・`$TMPDIR/x`・`<root>` 自身・`..` を含むパス・形が違うパスが**すべて拒否**されること（前置一致の落とし穴を直接突く負例を含める） |
| 起動時 self-check | バナーを偽装したスタブ（`sandbox: danger-full-access` / `approval: on-request` / バナー無し）で**中断**すること |
| 保護対象パスの差分検査 | `sensitive-paths.txt` の各パターンに当たるファイルを worktree 内で改変した状態を作り、`protected_path_modified` になること。`AGENTS.md` 新規作成、**`.git` ファイルの書き換え**（実測9 の再現）も同様 |
| **runner の git 実行経路** | runner が打つ git がすべて `GIT_DIR` / `GIT_WORK_TREE` 明示であること（素の `git -C <worktree>` が1箇所も無いこと）。実測9 の細工を仕込んだ worktree を用意し、runner の代行 commit で**細工が実行されない**ことまで assert する |
| fail-closed の exit code | §6 の表の各行を1テストにする |
| 正本の単一性 | `codex exec` を直接呼ぶ箇所が runner 以外に無いこと（リポジトリ全体の grep） |
| flag の欠落 | `--ignore-rules` / `--ignore-user-config` はバナーに現れない（→ §3.2）ため、**コード側でしか検査できない**。この2つを外した場合にテストが落ちることを確認する（negative test） |

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

## 8. 決定（2026-08-27）

**この3点は人間が確定させた決定である。** 実装はこの決定に従う。

### 8.1 境界を強制する層 → **flag + 環境スクラブ + `HOME`/`CODEX_HOME` の隔離**

`--sandbox workspace-write --ignore-rules --ignore-user-config` に加えて、**環境を positive list に絞り**（→ §3.1）、`HOME` と `CODEX_HOME` を runner 管理の隔離ディレクトリにする。

- 環境の絞り込みは **「既知の危険な変数を消す」ではなく「必要な変数だけを通す」** 向きで書く。消す側のリストは新しい資格情報キャリアが増えるたびに追随が要り、忘れた時点で黙って穴が開く（`sync-free-invariant`）
- 実測8 のとおり、`HOME` を隔離するだけで `gh auth status` は exit 1 になる。**外部 write の禁止は、規則ではなく資格情報の不在で成立している**
- **専用 OS ユーザ／コンテナは採らない。** claude-harness はプラグインであり、利用側マシンの構成に踏み込めない＝配布形態と衝突するため。**Phase 3 以降の選択肢としては残す**（実測8 の PATH 残余リスクを閉じるにはこの方向しかない）

### 8.2 Phase 2 の可否 → **Phase 2a に限って許容する**

§5 の強制できない3項目（5-1 worktree 内の保護対象ファイル / 5-2 `AGENTS.md` による自己改変 / 5-5 MCP 経路）を、**Phase 2a に限って**許容する。範囲は「local implementation のみ・外部作用なし・失敗時は worktree ごと破棄で回復可能」。

**Phase 2a の着手条件（この2つが実装されるまで着手しない）:**

1. **起動時 self-check**（→ §3.2）——実効サンドボックスと approval をバナーから読み戻して照合し、不一致なら中断する
2. **保護対象パスの差分検査**（→ §5-1）——`scripts/config/sensitive-paths.txt` にマッチするパス、および `AGENTS.md` / `.codex/` / `.rules` / **worktree の `.git` ファイル**（実測9）の変更を引き渡し前後のハッシュで検出し、変化があれば成果物を採用しない

加えて、runner が worktree に対して git を実行する経路は §6.1 の M1（`GIT_DIR` / `GIT_WORK_TREE` 明示）に限る。これは Phase 2a で runner が commit を代行する以上、着手条件と同格である。

**Phase 2b（commit / PR まで拡張）へ進むときは、この判断を取り直す。** Phase 2a で許容が成り立つのは「検出したら成果物を捨てれば回復する」からであり、**Phase 2b では『採用しない』では回復しない**（外部作用は取り消せない）。

### 8.3 Codex に許す git 操作 → **working tree の変更のみ。commit / push / PR は runner が代行する**

人間の意向は「Claude の子に許しているのと同等（作業ブランチへの push・PR 作成まで）を Codex にも許してよい」だった。**成果の範囲はそのとおりにするが、実現方式は runner 代行にする。**

理由——**Claude の子と Codex では境界の正体が違う**:

| | 境界の正体 | エージェントが迂回しうるか |
|---|---|---|
| Claude の子 | **方針**（`.claude/settings.json` の allow/ask/deny ＋ 分類器） | 原理的にはしうる（方針は方針である） |
| Codex worker | **能力の不在**（サンドボックスの `.git` 全面拒否＝実測2） | できない（渡していないものは使えない） |

Codex 自身に commit / push を許すことは、**いちばん強く閉じている境界を policy ベースへ格下げする**ことを意味し、本設計の中心命題（§2）と正面から衝突する。しかも実測2・4 のとおり、worktree 構成での sandbox 内 commit は**そもそも原理的に不可能**なので、許すには構成を独立 clone に変える（＝`.git/hooks`・`.git/config` を Codex 書き込み可能にする）しかない。

**runner 代行なら成果は同等**である——実装は commit され、作業ブランチへ push され、PR まで出る。能力の不在は保たれたままになる。

> **「同じ権限を与える」ではなく「同じ成果を出す」で要件を満たす。**

**代行に伴って runner 側で無効化すべきもの**（実測9。詳細と実測値は §6.1）:

| 対象 | 措置 |
|---|---|
| worktree の `.git` ファイル | **参照させない**。`GIT_DIR` / `GIT_WORK_TREE` を明示して git を実行する（M1） |
| `core.fsmonitor` / `core.hooksPath` / `diff.external` / `core.pager` 等 | M1 の下では設定の出所が共有 `.git/config` に固定されるので、**個別の無効化は不要**（個別列挙＝M2 は採らない。数え漏れるため） |
| `.gitmodules` | `git submodule` 系のサブコマンドを打たない |
| `.gitattributes` | M1 の下ではドライバ定義が config 側にあるため実行に至らない。追加措置なし |

### 8.4 未決のまま残す項目

- **`PATH` の残余リスク**——`HOME` を隔離しても、PATH 経由で operator の `$HOME` 配下の実行ファイルは届く（実測8）。固定 PATH を渡す案は、利用側プロジェクトのツールチェーンを runner が知り得ないため今回は採らない。8.1 の「Phase 3 以降の選択肢」（隔離環境）と同じ枠で扱う
- **Phase 2b の可否**——8.2 のとおり、そこで判断を取り直す
- **Linux（landlock）での挙動**——実測はすべて macOS / seatbelt（→ §9）

## 9. 置いた仮定・未検証事項

**仮定（軽微・可逆な範囲。本文書の構成に関する判断）**

- 本文書は `docs/` 側に置いた。実行時テキスト（`skills/` `agents/`）ではなく**設計判断の記録**であり、`docs/plugin-path-conventions.md` (h) の判定軸（「この文を削るとモデルの振る舞いが変わるか」）では docs 側になるため
- ADR ではなく設計ドキュメントにした。§8 の3点は確定したが、実装（runner）がまだ無く、恒常的な設計決定として固まったとは言えないため。Phase 2a の実装が入った時点で `/create-adr` による ADR 昇格の要否を判定する
- 差分検査の対象は「`sensitive-paths.txt` にマッチするパス + `AGENTS.md` + `.codex/` + `.rules` + worktree の `.git` ファイル」に限定した（worktree 全体のハッシュ検査は、Codex が作った正当な成果物との区別が付かないため）

**未検証**

- **push の実測**——`git push` が `.rules` の `["git","commit"]` prefix に**マッチしない**ことは形から明らかだが、`git` 全体を覆う rule が存在する環境での挙動は測っていない。§2.1 の現行表の push 行は実測4 からの**推論**である
- **project スコープ `.rules` の探索パス**——`--ignore-rules` の help が "user or project" と述べる一方、0.145.0 のバイナリからは探索パスを特定できなかった。worktree 内に置けるかどうかが 5-2 の深刻度を左右する
- **`--ignore-user-config` 適用後に MCP が消えること**——`codex debug prompt-input` は当該フラグを受け付けないため未実測。`--ignore-user-config` 付きで `codex exec` が正常に完走することは実測8 で確認したが、MCP ツールの不在そのものは測っていない。実測7 は「user config 由来の MCP・plugin が既定で注入される」ことのみを示す
- **Linux（landlock）での挙動**——実測はすべて macOS 26.5 / seatbelt。writable root の既定（`/tmp`・`$TMPDIR`）が同じかは未確認
- **`PATH` 経由で届く実行ファイルの実害**——実測8 で PATH に operator の `$HOME` 配下が含まれることは確認したが、そこから資格情報付きの CLI に到達できるか（例: 別の認証済みツール）は個別に測っていない（→ §8.4）
- **`--add-dir` の粒度**——共有 `.git` の一部だけを writable にできるかは試していない。仮にできても §6.1 の理由から採らない方針

---

## 参考

- Issue [#200](https://github.com/masanami/claude-harness/issues/200) — 「最終決定（2026-08-23）」§6（承認境界）・§7（実装順 5）
- [ADR 0001: Codex サポート](adr/0001-codex-support.md)
- [プラグイン内ファイル参照のパス規約](plugin-path-conventions.md) — (h) 実行時テキストと docs の書き分け
- `scripts/codex-review-runner.sh` / `scripts/specs/codex-review-runner.md` — read-only カプセルの先例（fail-closed・exit code の割り当て）
- `scripts/config/sensitive-paths.txt` — 保護対象パスの正本
- `scripts/read-plugin-doc.sh` — 「形で塞ぐ」パス検査の先例（exit 77）

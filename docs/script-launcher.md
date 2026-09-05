# スクリプトランチャー `claude-harness-run`

プラグイン同梱スクリプトを、**パスもバージョンも含まない呼び出し形**で実行するためのランチャー。実体は `bin/claude-harness-run`。

これにより利用側は `Bash(claude-harness-run:*)` の**1行だけ**を allowlist に置けばよく、プラグイン更新のたびに許可が黙って外れることが無くなる。

---

## 1. なぜ必要か（実測した Bash permission マッチャの仕様）

従来のスキルは `bash "${CLAUDE_PLUGIN_ROOT}/scripts/xxx.sh"`（＝解決済み絶対パスを引用符で囲む形）でスクリプトを実行していた。この形は **allowlist で書けるパターンが実質存在しない**。headless 委譲（対話相手の人間がいない `claude -p`）では permission 拒否でスキルが完走できず、実運用で4回再発した（Issue #154）。

### 実測1: 絶対パス直接実行（2026-08-15 / headless 子セッション3本で独立実測）

| allow ルール | 実行コマンド | 結果 |
|---|---|---|
| `Bash(bash /Users/*/.claude/plugins/cache/masanami-harness/claude-harness/*/scripts/*.sh:*)` | 引用符あり | ✗ 拒否 |
| 同上 | 引用符なし | ✗ 拒否 |
| `Bash(bash /Users/…/claude-harness/9.9.9/scripts/hello.sh:*)`（完全パス・引用符なし） | 引用符あり | ✗ 拒否 |
| 同上 | 引用符なし | ✅ 実行 |
| `Bash(bash /Users/…/claude-harness/*/scripts/hello.sh:*)`（バージョン部分のみ `*`） | 引用符なし | ✗ 拒否 |

### 実測2: 本ランチャー経由（2026-08-15 / `--permission-mode default` の headless 子セッション。allow は `Bash(claude-harness-run:*)` の1行のみ）

| 実行コマンド | 結果 |
|---|---|
| `claude-harness-run --plugin-root` | ✅ 実行 |
| `claude-harness-run quality-check-runner --lint "printf hello"`（**引数に引用符あり**） | ✅ 実行 |
| `bash bin/claude-harness-run --plugin-root`（実行系を前置） | ✗ 拒否（`This command requires approval`） |

### 導かれる規則

1. **ワイルドカードはトークン境界でのみ効く**。1トークンであるパスの内部に `*` を置いても解釈されない（バージョン部分だけの `*` も不可）。`:*` は末尾引数側にのみ効く。
2. **`:` より手前はルール側とコマンド側で完全一致が要る**。引用符も1文字として一致が必要（片方だけ引用符付きは不一致）。
3. **`:*` が受ける末尾引数側は引用符を含んでよい**（実測2のB）。したがって `--lint "npm run lint"` のような引数の引用符は外さなくてよい。
4. **コマンドの先頭トークンが一致しないとマッチしない**（実測2のC）。実行系（`bash`）やパス、環境変数の前置はすべて先頭トークンを変えるため不可。

→ 「引用符を外す」だけでは不十分（バージョン固定が残り、更新のたびに黙って外れる）。**呼び出し形からパスとバージョンを消す**＝ランチャー経由が必要。

---

## 2. 一度きりのセットアップ（人間が実施）

PATH 上のディレクトリ（例: `~/.local/bin`）へランチャーを配置する。

```bash
# 1. インストール先を、ランチャー自身と同じ規則で解決する
#    （CLAUDE_HARNESS_ROOT 優先 → installed_plugins.json → cache 配下）
#    **候補を検証してからバージョン降順に最初の1件を採る**。最大バージョンを先に選ぶと、
#    その実体が消えている場合に有効な旧候補を飛ばして解決に失敗する（bin/claude-harness-run
#    の chr_resolve_from_installed_json も、この順で候補を絞ってから選んでいる）。
#    各所の `|| true` は set -e 下で落ちないため（未導入の環境では installed_plugins.json が
#    無く jq が非0で終わる＝まさにこの手順を実行する状況）。
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SRC="${CLAUDE_HARNESS_ROOT:-}"
if [ -z "$SRC" ]; then
  while IFS= read -r cand; do
    if [ -n "$cand" ] && [ -f "${cand%/}/bin/claude-harness-run" ]; then SRC="${cand%/}"; break; fi
  done <<EOF
$(jq -r '[ (.plugins // {}) | to_entries[]
    | select(.key | startswith("claude-harness@"))
    | (if (.value | type) == "array" then .value[] else .value end)
    | select(type == "object" and .installPath != null) ]
  | sort_by(.version // "0" | split(".") | map(tonumber? // 0)) | reverse
  | .[].installPath' "$CONFIG_DIR/plugins/installed_plugins.json" 2>/dev/null || true)
$(ls -d "$CONFIG_DIR"/plugins/cache/*/claude-harness/*/ 2>/dev/null | sort -t. -k1,1n -k2,2n -k3,3n -r || true)
EOF
fi

# 2. ランチャーを PATH 上へコピーする
mkdir -p ~/.local/bin
install -m 0755 "$SRC/bin/claude-harness-run" ~/.local/bin/claude-harness-run

# 3. 疎通確認（シェルからと、Claude Code の Bash ツールからの両方で実行する）
claude-harness-run --plugin-root   # プラグインルートの絶対パスが表示される
claude-harness-run --list          # 実行可能なスクリプト一覧が表示される
```

- **シンボリックリンクではなくコピーにする理由**: プラグインキャッシュのパスは `…/claude-harness/<version>/` を含むため、リンクはプラグイン更新で切れる。一方コピーしたランチャーは**実行のたびに現行版のプラグインルートを解決し直す**ので、プラグインを更新してもコピーを置き直す必要は無い（ランチャー自身の仕様が変わったときだけ再コピーする）。
- `~/.local/bin` が PATH に無い場合はシェルの設定（`~/.zshrc` 等）へ追加する。Claude Code の Bash ツールはユーザーのプロファイルから初期化されるため、プロファイルに書けばセッションからも見える。手順3の疎通確認は**必ず Claude Code の Bash ツール側でも**行うこと。
- **解決規則はランチャー本体（§4）と一致させてある**。`~/.claude` 決め打ち・`.value[0]` 固定にすると、`CLAUDE_CONFIG_DIR` を使う環境や `claude-harness@` エントリが複数ある環境で、導入失敗や旧版の固定化につながる。
- ローカルチェックアウトで開発している場合は、コピーせず `CLAUDE_HARNESS_ROOT=/path/to/claude-harness` を設定すればそのツリーが使われる（`claude --plugin-dir` で起動している場合も同様）。

### allowlist の設定

利用側プロジェクトの `.claude/settings.json`（またはユーザー設定）に次の1行を置く:

```json
{
  "permissions": {
    "allow": [
      "Bash(claude-harness-run:*)"
    ]
  }
}
```

`/init-project` が生成する設定にはこの行が最初から含まれる。

**先頭トークンを変える呼び方はマッチしない**（実測2のC）:

| 呼び方 | 可否 |
|---|---|
| `claude-harness-run quality-check-runner --lint "npm run lint"` | ✅ |
| `bash claude-harness-run …` / `bash ~/.local/bin/claude-harness-run …` | ✗ |
| `~/.local/bin/claude-harness-run …`（パス付き） | ✗ |
| `FOO=bar claude-harness-run …`（環境変数の前置） | ✗ → `claude-harness-run --env FOO=bar …` を使う |

---

## 3. スキルからの呼び出し規約

```bash
# scripts/ 直下のスクリプト（短縮名。'.sh' は省略可）
claude-harness-run quality-check-runner --lint "npm run lint" --test "npm test"
claude-harness-run collect-review-diff main

# スキル同梱スクリプト（プラグインルート相対パス）
claude-harness-run skills/demo/scripts/walkthrough-setup.sh
claude-harness-run skills/demo/scripts/run-walkthrough.mjs "/絶対パス/flow.mjs"

# 環境変数を渡す場合（前置形は allowlist にマッチしないため --env を使う）
claude-harness-run --env WALKTHROUGH_PROJECT_ROOT="/abs/project" demo-e2e-out 'CASE-101'
```

- **ランチャー名・target をパスで修飾しない／引用符で囲まない**（先頭トークンが変わる・完全一致が崩れるため）
- **引数側は引用してよい／すべき**（`:*` が受けるため allowlist に影響しない。実測2のB）。空白を含みうる値（ファイルパス・worktree パス等）は必ず引用する
- `cd` はしない。ランチャーは cwd を変更せず、呼び出し元の cwd のまま対象スクリプトを実行する

### 単独コマンドとして呼ぶ（allowlist 以前の関門）

permission チェックの手前に**シェル構文の静的解析**があり、解析できない形は allow ルールに到達する前に拒否される。ランチャー経由でもこの関門は変わらないため、**1回の Bash 呼び出しには単独のコマンドだけを書く**。

実測3（2026-08-15 / `--permission-mode default` の headless 子セッション。allow は `Bash(claude-harness-run:*)` の1行のみ）:

| 実行コマンド | 結果 |
|---|---|
| `claude-harness-run quality-check-runner --lint "printf hello" --test "printf world"` | ✅ 実行 |
| `RESULT=$(claude-harness-run quality-check-runner --lint "printf hello")`（代入のみ） | ✅ 実行 |
| `claude-harness-run --plugin-root; echo "$HOME"`（既知の環境変数を展開） | ✅ 実行 |
| `RESULT=$(claude-harness-run quality-check-runner --lint "printf hello"); echo "$RESULT"` | ✗ 拒否（`Contains shell syntax (string) that cannot be statically analyzed`） |
| 上と同じものを `\` 改行継続で複数行にした形 | ✗ 拒否（同上） |

→ **ローカルに代入した変数を後続コマンドで展開すると（`echo "$RESULT"` / `jq … <<<"$RESULT"`）、その Bash 呼び出し全体が解析不能として拒否される**。値は変数に取り込まず、**stdout と exit code を Bash ツールの実行結果からそのまま読む**。

（`>` によるワーキングディレクトリ外へのリダイレクトと、ワーキングディレクトリ外への `cd` も別途ブロックされる。これらは allow ルールの問題ではなく Claude Code のディレクトリ境界による。）

---

## 4. ランチャーの契約

```text
claude-harness-run [--env KEY=VALUE]... <target> [args...]
claude-harness-run --plugin-root | --list | --help
```

| 項目 | 内容 |
|---|---|
| `<target>`（`/` を含まない） | `scripts/<target>.sh` に解決（`.sh` は付けても付けなくてもよい） |
| `<target>`（`/` を含む） | プラグインルート相対パスとして解決（例: `skills/demo/scripts/run-walkthrough.mjs`） |
| 実行系 | `.sh` → `bash`、`.mjs` / `.js` → `node` |
| 拒否する target | 絶対パス、`..` を含むパス（プラグイン外への脱出防止） |
| `<target>` 以降の引数 | すべて対象スクリプトへそのまま渡す（引用・空白・stdin を保持） |
| 終了コード | 対象スクリプトの終了コードをそのまま透過 |
| cwd | 変更しない |

ランチャー自身のエラーは対象スクリプトの終了コードと衝突しないよう高い値を使い、stderr へ `claude-harness-run: …` 形式で理由を出す:

| コード | 意味 |
|---|---|
| 64 | 引数不正（未知フラグ・target 未指定・絶対パス／`..` を含む target・`--env` の形式不正・`--env` で禁止された変数名〈§6〉） |
| 66 | 対象スクリプトが見つからない |
| 69 | プラグインルートを解決できない／実行系（`bash`・`node`）が PATH に無い |

### プラグインルートの解決順

1. 環境変数 `CLAUDE_HARNESS_ROOT`（設定されていて不正な場合は**エラー終了**。黙って他へフォールバックしない）
2. **自身の配置位置**（`<自身のディレクトリ>/../.claude-plugin/plugin.json` が在ればその親）。`$0` のシンボリックリンクは意図的に解決しない — PATH 上のリンクを辿るとリンク先の固定バージョンに張り付くため、リンク経由の起動では 3 以降へ進ませる
3. `<config>/plugins/installed_plugins.json` の `installPath`（jq が在る場合。**現行版の正本**。複数該当時は最大バージョン）
4. `<config>/plugins/cache/*/claude-harness/*` の最大バージョン（3 が使えない場合の予備。`3.10.0 > 3.9.0` を正しく判定する数値比較）

`<config>` は `CLAUDE_CONFIG_DIR`、未設定なら `$HOME/.claude`。

> マーケットプレイスのチェックアウト（`~/.claude/plugins/marketplaces/<marketplace>/`）はバージョンレスで安定して見えるが、**インストール済み版と乖離しうる**ため解決先に採用していない。

---

## 5. ランチャー未導入時のフォールバック

ランチャーが PATH に無い環境では `claude-harness-run: command not found` になる。この場合に限り、スキルは従来形にフォールバックする:

```bash
bash "<解決済みプラグインルート>/scripts/xxx.sh" <引数>
```

- プラグインルートは、スキル起動時にコンテキストへ与えられる「Base directory for this skill」から導出した絶対パスに置換する（`${CLAUDE_PLUGIN_ROOT}` は Bash 環境変数ではない）
- **パスは引用符で囲む**。空白やシェルメタ文字を含むプラグインルート（ローカル checkout・`CLAUDE_HARNESS_ROOT` 指定・スペース入りのホームディレクトリ等）でも確実に実行するため
  - 引用符を付けると実測1のとおり前方一致の allow ルールは書けなくなる。ただし**フォールバック経路はもともと「引用符なし＋バージョン完全固定」でしか許可できず**、それはプラグイン更新のたびに黙って外れる形＝ Issue #154 が「使えない」と結論づけたものである。守る価値の薄い allowlist 可能性より、**空白を含むパスでも確実に動くこと**を優先する
  - allowlist を効かせたい経路はランチャー形（§3）が担う。フォールバックは対話セッションでの承認を前提とした縮退経路と位置づける
- フォールバックで実行した場合は、**利用者にランチャー導入（本ドキュメントの §2）を案内する**

---

## 6. このランチャーを allow することの意味

`Bash(claude-harness-run:*)` を allow に入れると、**その1行が settings.json の `deny` / `ask` より優先されるわけではない**が、permission マッチャが見るのは外側の `claude-harness-run …` だけである。つまり「ランチャーの向こう側で何が実行されるか」は permission の統治対象にならない。したがって**ランチャー配下のスクリプトが任意コマンドを実行できてはならない**。

以前はこれが成立していなかった（Issue #223）。`quality-check-runner` と `mutation-run` は受け取ったコマンド文字列を `bash -c` に渡していたため、`claude-harness-run quality-check-runner --lint "<任意のコマンド>"` で `Bash(rm -r:*)` / `Bash(git push --force:*)` / `Bash(sudo:*)` といった deny を素通りできた。`doctor` の `settings_launcher_allow` はこの allow を是正として提示するため、**doctor に従うほど deny が無効化される**状態だった。

### 現在の契約

- **コマンド文字列をシェルへ渡さない。** `--lint` / `--typecheck` / `--test` / `--auto-fix`（`quality-check-runner`）と `test_command`（`mutation-run`）は、空白で argv に分解して**直接実行**する。`;` `&&` `|` `>` `$(…)` `` ` `` クォート グロブ といったシェル構文は解釈されず、**含まれていればコマンドを1つも実行せずに exit 4 で拒否**する（黙って別物をリテラルとして実行しない）
- **実行してよいコマンドは同梱の閉じた一覧に限る。** argv の先頭トークン列が [`scripts/config/command-allowlist.txt`](../scripts/config/command-allowlist.txt) のエントリに前置一致しなければ拒否する。シェルを外すだけでは不十分で、`rm -rf …` を argv として実行できれば迂回は成立するため、**統制の主体はこの一覧**である
- **一覧の拡張路は同梱ファイルの編集だけ。** 環境変数・CLI フラグ・利用側リポジトリのファイルからは差し替えられない（差し替えられるなら、それが「任意文字列を通す別経路」になる）
- **一覧は「実行されるコマンド」を固定する。** エントリには2種類ある。`npm run` / `make` / `cargo test` のように**プロジェクト自身の設定ファイルが実行内容を決める**もの（呼び出し側が渡すのは名前であってプログラムのパスではない）と、`bundle exec` / `uv run` / `python3 -m` / `npx --no` のように**次のトークンが実行対象そのもの**になるものである。後者は「ラッパー」として扱い、**残りの argv もそれ自体が一覧に載っていること**を要求する（`bundle exec rspec` ✅ / `bundle exec rm -rf /` ❌）。この区別が無いと、前置一致だけでは `bundle exec rm -rf /` が通る
- **`--env` で実行系の解決を差し替えられない。** `--env` は **allowlist 方式**で、スキルが実際に使う変数（`WALKTHROUGH_*` / `BASE_URL`）以外はすべて拒否する（exit 64）。`PATH` / `NODE_PATH` / `PYTHONPATH` / `GEM_PATH` / `CLASSPATH` / `NODE_OPTIONS` / `LD_PRELOAD` / `CLAUDE_HARNESS_ROOT` のような「どのプログラムが実際に走るかを変える」変数は処理系ごとに際限なくあるため、**禁止列挙では取りこぼす**

### この allow が与える権限（正直な範囲）

**与える**: 対象プロジェクト自身の設定に書かれた品質手続きを起動する権限。`npm run lint` / `make test` / `cargo clippy` などが、**そのリポジトリの `package.json` / `Makefile` / `Cargo.toml` が定めるとおりに**動く。それらの中身が何をするかはリポジトリの内容が決めるものであり、呼び出し側が渡す文字列が決めるものではない。

**与えない**: **ランチャーへ直接渡したコマンドとして**、一覧に無いものを実行すること。`claude-harness-run quality-check-runner --lint "rm -rf …"` は exit 4 で拒否され、`rm` / `mv` / `chmod` / `curl` / `wget` / `ssh` / `git` / `sudo` / `bash` / `sh` / `env` / `xargs` はランチャー経由では起動できない。ネットワークからパッケージを取得して実行する形（素の `npx` / `bunx` / `uvx` / `pnpm dlx`）も同様である。

### `deny` がどこまで効くか（ここを取り違えないこと）

**`deny` が守るのは「ランチャーへの直接入力」だけである。** 保証の範囲を正確に書くと:

| 対象 | `deny` の効き方 |
|---|---|
| エージェントが Bash ツールに打つコマンド（`rm -rf …` を直接打つ） | **効く**（従来どおり permission マッチャが評価する） |
| ランチャーへ直接渡すコマンド（`--lint "rm -rf …"`） | **効く**（permission ではなくランナー側の allowlist が exit 4 で拒否する。結果として deny 対象へ到達できない） |
| 許可コマンドが起動する子プロセス（`npm run lint` が `package.json` の指示で `rm` を呼ぶ、`make` が Makefile のレシピを実行する、`cargo` がビルドスクリプトを走らせる） | **効かない**（permission 判定はプロセスツリーには適用されない） |
| ランナー自身が起動するコマンド（`mutation-run` の `git checkout --` / `git status`） | **効かない**（`Bash(git checkout:*)` を deny していても実行される。復元処理としてスクリプトが直接呼ぶため） |
| 許可名がどの実体へ解決されるか（`PATH` 上に置かれた `npm` / `jest`） | **効かない**（一覧が照合するのは名前。`PATH` へ書き込める主体は実体を差し替えられる。下記「残る限界」を参照） |

つまりこの allow が保証するのは「**呼び出し側の1つの文字列だけで、事前準備なしに deny 対象コマンドへ到達できないこと**」であって、「そのプロジェクトのツールチェインが deny を尊重すること」ではない。

### 残る限界（allow する前に知っておくこと）

- **プロジェクト自身の設定は信頼している。** `package.json` の `scripts.lint` や `Makefile` の中身は、書けば実行される。リポジトリへ書き込む権限（Edit / Write）とこの allow は別々に統治する必要がある
- **一覧が照合するのは「コマンド名」であり、名前から実体への写像は `PATH`（とシェルの探索順）が行う。** ランナーは検証時に `command -v` で解決した**絶対パス**を、そのまま起動時にも使う（起動時に `PATH` を引き直さない）。**ただしファイルの完全性までは保証しない**——検証後に**そのパスのファイル本体やシンボリックリンク先を置換できる**なら、起動されるのは別の実体になりうる。固定できるのは「どのパスを起動するか」であって「そのパスの中身が検証時と同じであること」ではない。
  - `PATH` に相対エントリ（`.` や cwd 相対のディレクトリ）がある場合の解決は**拒否**する（作業ツリーへ書き込めるだけで許可名を差し替えられてしまうため）。
  - **シェル関数へ解決される場合も拒否**する。bash の探索順は alias → keyword → function → builtin → `PATH` 上のファイルであり、**関数は `PATH` より先に一致する**。継承した `BASH_ENV` や `export -f` で許可名と同名の関数を注入されると、実行ファイルではなく関数本体が動く（実測で確認。かつ解決先が空のまま＝ `resolved:` の監査痕跡も残らなかった）。組み込み（`true` / `echo` / `printf`）は `PATH` 解決を経ないため従来どおり許可し、`PATH` 上に無いだけのコマンドも拒否しない（ツール未導入は当該ゲートの失敗として扱う契約）。
  - しかし**`PATH` そのものの汚染は防げない**——`PATH` 上のディレクトリへ実行ファイルを置ける主体は、`npm` や `jest` といった許可名を別のバイナリへ差し替えられる。
  - **信頼済み `PATH` の固定は採らなかった。** このランナーの目的は**開発者のツールチェインを起動すること**であり、`/usr/bin:/bin` のような固定 `PATH` では nvm / asdf / rbenv / venv / Homebrew / `node_modules/.bin` に置かれた実体を解決できず、機能そのものが成立しない。**利便性ではなく機能要件のためのトレードオフ**であり、その代わりに保証範囲をここに明記している
  - **`PATH` の汚染はこのランチャー固有のリスクではない。** `PATH` 上のディレクトリへ書き込める主体は、`Bash(npm run lint:*)` のように **allow に直接書かれたコマンド**も同じように差し替えられる。つまりランチャーの有無で状況は変わらない——`PATH` の完全性はこの統制の**前提**であって、この統制が守る対象ではない
  - どの実体が起動されたかは、実行時に stderr へ `--- <gate> resolved: <絶対パス> ---` として記録される（事後に追跡できるようにするため）
- **テストランナーは本質的にファイルパスを受け取る。** `pytest <path>` / `jest <path>` / `node --test <path>` / `zig test <path>` はいずれも、指定されたファイルを読み込んで**実行**する。これはテストを走らせるという機能そのものであり、一覧で塞げる性質のものではない。一覧が固定するのは「**どのプログラムが起動されるか**」であって「そのプログラムが何を読むか」ではない
- **許可したビルド／テストツールには一般に脱出口がある。** `make -f <別ファイル>` / `mvn exec:exec` / `gradle -b <別ファイル>` / `node --test --require <ファイル>` / `mocha --require <ファイル>` のように、**ツール自身の引数でコードの読み込み先を指定できる**ものがある。これらは対象ファイルが先に存在している必要があるため「事前準備なしの1手」ではないが、**リポジトリへ書き込める主体には塞げない**。一覧は「任意コマンド実行の一次経路」を閉じるものであり、ツールごとの脱出口まで塞ぐものではない
- **`Bash(bash:*)` など汎用実行系の allow が別途あると、この統治は成立しない。** その場合 deny は最初から迂回可能であり、ランチャーの有無とは無関係である。`/init-project` が生成する既定の allow には現在 `Bash(bash:*)` が含まれる（スクリプトのフォールバック実行形〈§5〉のため）。**deny による統治を効かせたいプロジェクトでは、この行を外すかスコープを絞ることを検討する**
- **`codex-review-runner` / `codex-task-runner` は別の性質を持つ。** これらは Codex エージェントを起動する経路であり、`chore` モードは対象リポジトリへの書き込みを伴う（ネットワークと書き込み範囲は起動引数で固定しているが、「決められた品質コマンドを起動するだけ」ではない）。ランチャーを allow するとこの経路も使える

---

## 7. トラブルシューティング

| 症状 | 原因と対処 |
|---|---|
| `claude-harness-run: command not found` | PATH 上に配置されていない。§2 の手順を実施する。シェルでは動くが Claude Code の Bash ツールでは動かない場合は、PATH の追加をプロファイル（`~/.zshrc` 等）に書く |
| `claude-harness-run: could not locate the claude-harness plugin.` | プラグイン未インストール、または `CLAUDE_CONFIG_DIR` が別の場所を指している。ローカルチェックアウトを使うなら `CLAUDE_HARNESS_ROOT` を設定する |
| 意図と違うバージョンが動いている | `claude-harness-run --plugin-root` で解決先を確認する。キャッシュには旧バージョンが残るため、`installed_plugins.json` が壊れていると予備の cache 走査（最大バージョン）に落ちる |
| `script not found: …` (exit 66) | target 名の綴り違い。`claude-harness-run --list` で一覧を確認する |
| permission 拒否が続く | 呼び出し形の先頭トークンが `claude-harness-run` になっているか確認する（`bash` やパスの前置・環境変数の前置はマッチしない。§2 の表を参照） |
| 導入先プロジェクトが現行版の前提を満たしているか確かめたい | `claude-harness-run doctor --project "<プロジェクトルート>"` を実行する。ランチャーの導入状況・解決先のバージョン・`.claude/settings.json` の allow 不足を診断し、是正コマンドを提示する（何も書き換えない。契約は `scripts/specs/doctor.md`） |

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
| 64 | 引数不正（未知フラグ・target 未指定・絶対パス／`..` を含む target・`--env` の形式不正） |
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

## 6. トラブルシューティング

| 症状 | 原因と対処 |
|---|---|
| `claude-harness-run: command not found` | PATH 上に配置されていない。§2 の手順を実施する。シェルでは動くが Claude Code の Bash ツールでは動かない場合は、PATH の追加をプロファイル（`~/.zshrc` 等）に書く |
| `claude-harness-run: could not locate the claude-harness plugin.` | プラグイン未インストール、または `CLAUDE_CONFIG_DIR` が別の場所を指している。ローカルチェックアウトを使うなら `CLAUDE_HARNESS_ROOT` を設定する |
| 意図と違うバージョンが動いている | `claude-harness-run --plugin-root` で解決先を確認する。キャッシュには旧バージョンが残るため、`installed_plugins.json` が壊れていると予備の cache 走査（最大バージョン）に落ちる |
| `script not found: …` (exit 66) | target 名の綴り違い。`claude-harness-run --list` で一覧を確認する |
| permission 拒否が続く | 呼び出し形の先頭トークンが `claude-harness-run` になっているか確認する（`bash` やパスの前置・環境変数の前置はマッチしない。§2 の表を参照） |
| 導入先プロジェクトが現行版の前提を満たしているか確かめたい | `claude-harness-run doctor --project "<プロジェクトルート>"` を実行する。ランチャーの導入状況・解決先のバージョン・`.claude/settings.json` の allow 不足を診断し、是正コマンドを提示する（何も書き換えない。契約は `scripts/specs/doctor.md`） |

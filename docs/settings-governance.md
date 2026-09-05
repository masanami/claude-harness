# 許可設定の統治 — 3 層の役割分担と、プロジェクト settings が保証しない範囲

Claude Code の permission ルール（`allow` / `ask` / `deny`）は複数の settings ファイルに分かれて置ける。本文書は claude-harness が**どの層に何を置くか**、および**プロジェクトの `.claude/settings.json` が何を保証しないか**の正本である。`/init-project` の生成物（`skills/init-project/scripts/generate-settings.sh`）と `doctor`（`scripts/specs/doctor.md`）はこの割当に従う。

**結論を先に書く**:

- プロジェクトの `.claude/settings.json`（git tracked）は **deny 専用**にする。これは「そのリポジトリで壊されたくないもの」＝**リポジトリの性質**を書く場所である。
- 運用上の allow（ランチャー `Bash(claude-harness-run:*)`・パッケージマネージャ・テストランナー・infra）は**ユーザー設定** `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json` に置く。「誰が・どのマシンで・どの権限モードで動かすか」＝**オペレータの性質**を書く場所である。
- **「プロジェクト `.claude/settings.json` がエージェントを統治する」とは名乗らない。** 下記 §3 のとおり、allow は trust と権限モードに依存して効いたり効かなかったりし、deny はプロセスツリーに適用されない。tracked の settings に allow を並べても、それは「統治」ではなく「その allow を trust した人の環境で prompt が減る」以上のものではない。

---

## 1. 3 層の割当表

| 層 | ファイル | 誰の性質か | 共有範囲 | 置くもの（claude-harness の割当） |
|---|---|---|---|---|
| **ユーザー設定** | `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json` | オペレータ（自己責任） | その人・そのマシンの**すべてのプロジェクト**。チームには共有されない | 運用 allow: `Bash(claude-harness-run:*)`・`Bash(bash:*)`（フォールバック実行形を使う場合のみ）・PM（`Bash(npm:*)` 等）・テストランナー・infra（`Bash(docker:*)` 等）。**`/init-project` はこの層向けのスニペットを出力するだけで、書き込まない** |
| **プロジェクト settings** | `<repo>/.claude/settings.json`（git tracked） | リポジトリ（共有） | そのリポジトリを clone した**全員**（allow は各人が trust したあとだけ） | **deny 専用**。`/init-project` のベース deny（`base-deny.json`）と、リポジトリ固有の deny（`terraform destroy` 等）。将来は repo 固有の `Read(...)` deny 等もここ |
| **プロジェクト local** | `<repo>/.claude/settings.json` と同じディレクトリの `settings.local.json`（gitignored） | 個人・そのリポジトリ限定 | 自分だけ。clone 先や他のマシンには無い | 個人の例外（WebSearch 等）。**運用 allow の置き場としては当てにしない**（§2 の制約） |

3 層のほかに `--settings <file>`（そのセッション限定）と managed settings（組織）がある。claude-harness はどちらも前提にしない。

### 割当の根拠

- **allow はオペレータの性質である**: 同じ allow でも、それを「prompt なしで走らせてよい」と判断できるのは、その環境を動かしている人だけである。tracked に置くと、clone した全員の環境で trust 承認と同時にまとめて有効になる（承認ダイアログに列挙はされるが、1 行ずつ吟味されるとは限らない）。
- **deny はリポジトリの性質である**: 「この repo で `git push --force` はしない」「`terraform destroy` は流さない」は、誰が動かしていても変わらない。deny は **trust 不要で即座に効き、どの権限モードでも効く**（§3）ため、共有して困ることがない唯一の層でもある。
- **allow と deny を同じファイルに並べると、deny の保証範囲を allow が黙って狭める**（`Bash(bash:*)` があれば deny は迂回可能。`docs/script-launcher.md` §6「残る限界」）。deny 専用にすることで「このファイルにあるものはすべて制限である」と読める。

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
| `allow` / `deny` とも | `Agent` ツールのサブエージェント・対話セッションでの適用範囲 | **未検証**（§2「言えないこと」） |

逆に **deny だけが持つ性質**: trust 不要で即座に効き、`bypassPermissions` を含む全モードで効き、共有しても他人の環境で何かを「自動で走らせる」ことがない。プロジェクト settings を deny 専用にする理由はここにある。

**`Bash(claude-harness-run:*)` を allow することの意味**（どこに置くかによらない）は `docs/script-launcher.md` §6 が正本である。要点だけ書くと、ランチャーへ直接渡した 1 つの文字列で deny 対象へ到達できないことは保証するが、許可コマンドの子プロセスや `PATH` の完全性は保証しない。

---

## 4. 構成別の使い分け

| 構成 | 運用 allow の置き場 | 補足 |
|---|---|---|
| **単独オペレータ**（1 人・1 マシン。claude-flywheel の自走委譲もこれ） | **ユーザー設定に 1 行**（`Bash(claude-harness-run:*)`）＋必要な PM・テストランナー | 全リポジトリ・全 worktree に効く。trust に依存しない。tracked には何も足さなくてよい |
| **チーム・複数マシン・CI** | 各人のユーザー設定、または **tracked の `.claude/settings.json` に手で追記** | tracked に置く場合は「各人が各クローンで trust を承認する」ことが前提になる（headless だけの環境では効かない）。`/init-project` は tracked に allow を足さないので、チームで揃えたい場合は明示的に追記する |
| **deny による統治を効かせたい** | ユーザー設定に `Bash(bash:*)` 等の汎用実行系 allow を置かない | 汎用実行系の allow は「どの層にあっても」deny を無効化する。ランチャー未導入時のフォールバック実行形（`bash "<プラグインルート>/scripts/…"`）は対話セッションでの承認を前提にした縮退経路であり、allow で常時開けておくものではない |

`docs/getting-started.md` §2「許可設定をどこに置くか」は本表の要約である。

### ユーザー設定向けスニペット

`/init-project` は生成結果とあわせて次の形のスニペットを提示する（プロジェクトの PM・テストランナー・infra に応じて行が増減する）。**ファイルへの書き込みは人間が行う**（エージェントは `settings.json` を書き換えない。`scripts/specs/doctor.md`「自動適用しない」）。

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
| **`doctor`** | `settings_launcher_allow` / `settings_base_allow` は、ルールがユーザー設定（オペレータ層）に在れば **blocking にしない**。tracked にも オペレータ層にも無いときだけ blocking。是正の提示は「チーム共有が不要ならユーザー設定でよい」を含む |
| **`/init-project` の再実行** | 既存の allow は保持される（削らない）。新規に足す allow は無い。deny の不足分だけがマージされる |

### 変更の分割（Issue #227 / #222 / #226）

1. **設計（本文書）**: 割当表・保証しない範囲・移行方針を先に確定する。
2. **`doctor` の判定変更（#222）**: ユーザー設定に在る allow を受理して blocking を落とす。生成物の変更より先に入れることで、「生成物から allow を外したら doctor が赤になる」順序の逆転を防ぐ。
3. **生成物の変更（#227・#226）**: `generate-settings.sh` の `allow` から運用 allow（`Bash(bash:*)` を含む）を外し、スニペット出力を足す。#226（既定 allow の `Bash(bash:*)`）はこの変更で完了条件を満たす。

---

## 6. 関連文書

- `docs/script-launcher.md` §6 — `Bash(claude-harness-run:*)` の保証範囲と、`deny` がプロセスツリーに効かないことの正本
- `scripts/specs/doctor.md` — `doctor` の判定規則の正本（オペレータ層の扱いを含む）
- `skills/init-project/SKILL.md` §6 — 生成物の契約とスニペットの提示
- `docs/getting-started.md` §2 — 導入手順と「許可設定をどこに置くか」

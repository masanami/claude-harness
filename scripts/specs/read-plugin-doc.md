# read-plugin-doc.sh の入出力仕様（正本）

プラグイン同梱の参照ドキュメントを、**ランチャー経由の allowlist 済み経路で** stdout へ配送する。gh 呼び出しは一切行わない（gh 非依存）。

## なぜこのスクリプトがあるか（到達性の問題）

プラグイン配下は導入先プロジェクトの作業ディレクトリの外にある。そのため `references/` `templates/` `scripts/specs/` への **Read ツールでの読み出しは、利用側に `Read` の allow 設定が無い限り拒否される**。

| 経路 | headless 委譲（`claude -p`）での可否 |
|---|---|
| `SKILL.md` 本体 | 届く（Skill ツールがコンテキストへ注入する） |
| `references/*.md`・`templates/*`・`scripts/specs/*.md`（Read ツール） | **既定では届かない**（作業ディレクトリ外の Read として拒否される） |
| 本スクリプト（`claude-harness-run read-plugin-doc <path>`） | 届く（`Bash(claude-harness-run:*)` の1行で allowlist 済み） |

対話セッションなら人間が都度許可できるが、headless 委譲には許可する相手がいないため拒否がそのまま確定する。さらに悪いことに **失敗が沈黙する**: モデルは本文を読めないまま手順を推測して完走でき、書式や停止条件だけが外れた成果物が「成功」に見える（実測: `/guarantee-audit bootstrap` が `references/bootstrap-mode.md` を読めないまま完走し、検証器の exit 2 で初めて発覚した）。

本スクリプトはその沈黙を潰す。**配送できたときだけ exit 0** であり、届かない場合は必ず非0 終了して stderr に停止指示を出す。

## `claude-harness-run read-plugin-doc <プラグインルート相対パス>`

引数はちょうど1個。プラグインルートからの相対パスで指定する（`<base>` からの相対でも絶対パスでもない）。

```bash
claude-harness-run read-plugin-doc skills/guarantee-audit/references/bootstrap-mode.md
claude-harness-run read-plugin-doc scripts/specs/list-test-files.md
```

プラグインルートは**本スクリプト自身の配置位置**（`<scriptのdir>/..`）から解決し、`.claude-plugin/plugin.json` の存在で検証する。`${CLAUDE_PLUGIN_ROOT}` は Bash 環境変数として存在しない（実機検証済み）ため参照しない。

### 出力

| 出力先 | 内容 |
|---|---|
| stdout | 対象ファイルの中身を**バイト単位でそのまま**。ヘッダ・フッタ等の付加は一切しない |
| stderr | 成功時は配送レシート `read-plugin-doc: delivered <path> (<n> bytes)`。失敗時はエラー内容と停止指示 |
| exit code | 下表 |

**`scripts/README.md` の「stdout には JSON を1個だけ出力する」規約には意図的に従わない。** 本スクリプトの成果物は機械可読なステータスではなく**モデルが読む本文そのもの**であり、JSON 文字列としてエスケープすると読み手にとって著しく劣化する。成否は exit code と stderr で表す（機械可読ステータスと人間／モデル向け内容を分離する、という規約の趣旨自体は満たしている）。

### 終了コード（sysexits 準拠。`bin/claude-harness-run` の割り当てと揃える）

| exit | 意味 | 発生条件 |
|---|---|---|
| 0 | 配送成功 | stdout に本文が出ている |
| 64 | 引数不正 | 引数の数が1個でない／空文字／絶対パス／`..` を含む |
| 66 | 対象なし | 指定パスが存在しない、または通常ファイルでない |
| 69 | プラグインルート解決不能 | 自身の位置から `.claude-plugin/plugin.json` を持つ親を見つけられない（インストール破損） |
| 77 | 配送対象外 | 下記の配送対象サブツリー外／シンボリックリンク／物理パスがプラグインルート外へ抜ける |

引数検証・配送対象判定・存在確認のいずれかで失敗した場合、**stdout は空**である（部分的な本文が「読めた」ように見えるのを防ぐ）。読み出し開始後の I/O エラーでのみ部分出力がありうるが、その場合も exit 66 で失敗が伝わる。

### 配送対象（fail-closed な allowlist）

これ以外のパスは exit 77 で拒否する:

| パターン | 用途 |
|---|---|
| `skills/<skill>/references/<name>.md` | スキルのモード別手順書 |
| `skills/<skill>/templates/<name>` | スキルが生成物の雛形として使うテンプレート |
| `scripts/specs/<name>.md` | スクリプトの入出力仕様 |
| `scripts/README.md` | scripts/ 共通規約 |

汎用の `cat` にはしない。プラグインルートがローカルチェックアウトの場合、配下には `.env` 等の非公開ファイルが存在しうるため、用途をドキュメント配送に限定し**任意ファイル読み出しの手段にしない**。同じ理由で、シンボリックリンクの配送と、親ディレクトリ側のリンクでプラグインルート外へ抜けるパスの配送も拒否する（サブツリー制限が抜け道で無効化されるのを防ぐ）。

## 呼び出し側の義務

**非0 終了は「読まなくてよかった」ではない。** 本文を得られていないまま手順を推測して続行しないこと。stderr のメッセージを添えてその場で停止し、ユーザーに報告する（`claude-harness-run: command not found` の場合のみ、Read ツールでの読み出しへフォールバックしてよい。詳細は `docs/plugin-path-conventions.md` (b)）。

## 非目標

- **セクション単位の切り出し（`--section`）は提供しない。** 大きい参照ファイル（20KB 超が4本ある）では部分配送に価値があるが、本 PR 時点で呼び出す側が存在しない。呼び出し元のない機能は実際の使われ方で検証されないまま腐るため、必要になった時点で追加する。
- **キャッシュ・整形・要約は行わない。** 配送経路の役割は「Read ツールで読めたはずのものを、同じ内容のまま届ける」ことに限る。

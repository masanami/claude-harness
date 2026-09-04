---
name: quality-check
description: "auto-fix→lint→型チェック→テストを順に実行し、必須ゲート通過を機械可読な結果で返す品質ゲートチェック。Triggers on: '/quality-check', '品質チェック', 'QCして', 'quality gate'"
model: sonnet
# effort: auto-fix は機械的範囲のみ（型/テスト失敗の修正は呼び出し元が担う）ため low。
effort: low
---

# 品質ゲートチェック

プロジェクトの **自動修正 → lint → 型チェック → テスト** を順に実行し、**必須ゲート**（Lint・型チェック・テストのパス）を通します。結果は人間向けサマリーと、呼び出し元が判定に使える機械可読な形式の両方で返します。

> 必須ゲートにはこのほか「セルフレビュー」「CI」も含まれますが、本スキルはそのうち自動実行できる Lint / 型チェック / テストを担います。

## 手順

> **スクリプトの実行形（重要・本スキルが実行する全スクリプト共通）**: 本スキルはプラグインとして配布されるため、実行するスクリプト（`quality-check-runner`）は**ユーザーのプロジェクトroot ではなく、プラグイン配下**にある。スクリプトを実行する際は必ず PATH 上のランチャー経由で `claude-harness-run <スクリプト名>` の形式（パス・バージョン・引用符を付けない。この形だけが `Bash(claude-harness-run:*)` の1行で allowlist できる）を用い、相対パス `scripts/<スクリプト名>.sh` では呼び出さないこと。`claude-harness-run: command not found` になった場合のみ `bash "<プラグインルート>/scripts/<スクリプト名>.sh"` にフォールバックする（パスは引用符で囲む。プラグインルートはスキル起動時の「Base directory for this skill」から解決した絶対パス。`${CLAUDE_PLUGIN_ROOT}` は表記上のプレースホルダであり環境変数ではない）。フォールバックした場合はユーザーにランチャー導入を案内すること。
<!-- 正本: docs/plugin-path-conventions.md -->

> **単独コマンドとして実行する（重要・全スクリプト共通）**: 各スクリプトは上記の形のまま、**シェル変数へ代入せず**（`RESULT=$(…)` としない）、**同じ Bash 呼び出しに後続コマンドを繋げない**（`; echo "$RESULT"` や `jq … <<<"$RESULT"` を続けない）こと。ローカル変数を展開する後続コマンドがあると、permission の静的解析が「解析不能」と判定して allowlist 到達前に拒否され、headless 実行が止まる（実測済み）。stdout の JSON と exit code は **Bash ツールの実行結果からそのまま読む**。

### 1. プロジェクト設定の確認（コマンド特定）

CLAUDE.md および `package.json` 等から、以下のコマンドを特定する（意味理解が必要なため LLM が行う）:

- **auto-fix 系コマンド**（0個以上）: lint --fix / format / organize-imports など、機械的に直せる範囲を直すコマンド
- リントコマンド（チェック用）
- 型チェックコマンド
- テストコマンド

**渡せるコマンドの形（重要）**: 手順2のスクリプトはコマンドを**シェルに渡さず直接実行する**（Issue #223。`Bash(claude-harness-run:*)` の allow が settings.json の deny を迂回する経路にならないようにするため）。したがって:

- **シェル構文を含めない**（`;` `&&` `||` `|` `>` `$(…)` `` ` `` クォート グロブ）。CLAUDE.md に `npm run lint && npm run lint:css` のように書かれていても**そのまま渡さない**。プロジェクト側の1コマンド（`package.json` の scripts / Makefile のターゲット）に該当するものがあればそれを渡し、無ければそのゲートは省略して**未実行として報告する**（繋げるために自分でシェル構文を組み立てない）
- **実行できるのは同梱 allowlist（`scripts/config/command-allowlist.txt`）に載っている実行系だけ**。`npm run …` / `pytest` / `cargo …` などは通り、`rm` / `curl` / `bash` などは通らない
- 環境変数が要る場合は `claude-harness-run --env KEY=VALUE …` で渡す（`KEY=V cmd` の前置形は使えない）

契約に反するコマンドを渡すと、手順2は**どのゲートも実行せずに exit 4** で拒否し、理由と書き直し方を stderr に出す。

該当するコマンドが存在しないものは省略する（手順2のスクリプトが「スキップ」として扱い、失敗とはしない）。**ただし lint / 型チェック / テストのいずれも特定できなかった場合**、手順2は `result: "skip"`（exit 3）を返す。`pass` に読み替えず、**未検証として報告する**（手順2・手順3）。

### 2. quality-check-runner.sh の実行

**自動修正の事前適用 → lint → 型チェック → テストの順序実行**、exit code に基づく `gates.*.status` 判定、機械可読 JSON の構築は、決定的な処理として `scripts/quality-check-runner.sh` に切り出されている。

```bash
claude-harness-run quality-check-runner \
  --auto-fix "<auto-fixコマンド1>" \
  --auto-fix "<auto-fixコマンド2>" \
  --lint "<リントコマンド>" \
  --typecheck "<型チェックコマンド>" \
  --test "<テストコマンド>"
```

- 手順1で特定できなかったコマンドは、対応する `--auto-fix`/`--lint`/`--typecheck`/`--test` フラグごと省略する（0個以上の `--auto-fix` を検出順に指定。`--lint`/`--typecheck`/`--test` は1回のみ指定可）
- 各コマンドの生出力（lintエラー箇所・型エラー内容・失敗テストの詳細）は stderr に転記される。**手順4の失敗分析はこの stderr 出力を使う**

**実行結果の解釈（品質結果と実行エラーを混同しない）**: 品質判定に使ってよいのは **stdout が妥当な JSON としてパースできた場合だけ**。次の順で判定する:

1. **stdout が空、または JSON としてパースできない** → **実行エラー**として扱う（品質 fail ではない）。stderr のメッセージをそのまま報告し、**手順3以降に進まず中断する**。原因は主に次の2系統:
   - **ランチャー段階の失敗**（`quality-check-runner` が起動される前に終了。exit `69` = プラグインルート／実行系を解決できない、`66` = target が見つからない、`64` = 引数不正、`command not found` = ランチャー未導入）。この場合は上記注記のフォールバック形を試し、ランチャー導入をユーザーに案内する
   - **runner 段階の失敗**（exit `2` = jq 不在、exit `1` + 空 stdout = CLI引数不正、exit `4` = **コマンドの形が契約に反する**〈シェル構文を含む／allowlist に無い実行系〉）
   - **exit `4` の場合は品質 fail ではない**。stderr の指示に従い、手順1へ戻って**そのプロジェクトの1コマンド**を特定し直して再実行する。書き直せない場合は**そのゲートを省略した実行**に切り替え、省略した事実を手順3で報告する（シェル構文を自分で組み立て直したり、`bash -c` 等の別経路で実行して回避したりしない——それは塞いだ迂回路を再び開くことになる）
2. **stdout が妥当な JSON** → 品質結果として解釈する。exit code は `result` が `pass` なら 0、`fail` なら 1、`skip` なら 3
   - JSON の `result` と exit code が食い違う場合は**実行エラー扱い**とし、暗黙に pass へ倒さない
   - **`result: "skip"`（exit 3）はゲートが1つも実行されなかった状態**。品質 fail ではないが、**`pass` にも読み替えない**。手順1でコマンドを取りこぼしていたなら特定し直して再実行し、それでも `skip` なら**未検証（⊘ SKIP）として手順3で報告する**（総合判定を `PASS` にしない）

出力 JSON の**フィールド定義と件数抽出の仕様の正本は、プラグイン配下の `scripts/specs/quality-check-runner.md`**（ここには複製しない）。**cwd 起点の相対パス `scripts/specs/quality-check-runner.md` では導入先プロジェクトの同名ファイルを誤って参照しうるため、Read する場合はスキル起動時の「Base directory for this skill」を起点に `<base>/../../scripts/specs/quality-check-runner.md` として解決すること。

### 3. 結果サマリー

手順2で得た stdout の JSON（`{result, auto_fix, gates}`）を、**機械可読な結果として最後にそのまま出力**する（呼び出し元のスキル/エージェントが判定に使う）。`result` が `"skip"` の場合も**そのまま出力し、`"pass"` に書き換えない**。

あわせて `gates.*` の内容から**人間向けサマリー**（✅ パス / ❌ 失敗 / ⊘ スキップ）を組み立てて提示する:

```text
## 品質ゲートチェック結果

### 自動修正 (適用された場合)
- {auto_fix.summary}

| チェック | 結果 | 詳細 |
|---------|------|------|
| リント | ✅/❌/⊘ | errors, warnings |
| 型チェック | ✅/❌/⊘ | errors |
| テスト | ✅/❌/⊘ | passed/failed/skipped |

### 総合判定: ✅ PASS / ❌ FAIL / ⊘ SKIP（ゲート未実行）
```

### 4. 失敗時の対応

`gates.*.status` が `fail` のゲートがある場合:
1. スクリプト実行時に stderr へ転記された生出力（`--- <gate>: <cmd> ---` 区切り）からエラー内容を分析
2. 修正方法を提案
3. ユーザーの指示に応じて修正を実施し、手順2から再実行

> 自律実行コンテキスト（feature-implementer などのサブエージェント呼び出し）では、呼び出し元が機械可読な結果を見て修正ループを管理する。

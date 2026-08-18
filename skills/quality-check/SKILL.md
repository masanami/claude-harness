---
name: quality-check
description: "auto-fix→lint→型チェック→テストを順に実行し、必須ゲート通過を機械可読な結果で返す品質ゲートチェック。GDD期のプロジェクトでは保証索引ゲートも検査する。Triggers on: '/quality-check', '品質チェック', 'QCして', 'quality gate'"
model: sonnet
# effort: auto-fix は機械的範囲のみ（型/テスト失敗の修正は呼び出し元が担う）ため low。
effort: low
---

# 品質ゲートチェック

プロジェクトの **自動修正 → lint → 型チェック → テスト** を順に実行し、**必須ゲート**（Lint・型チェック・テストのパス）を通します。**GDD期**のプロジェクト（開発フェーズの判定は手順2）では、これに**保証索引ゲート**（保証台帳のテスト対応索引の整合検査。手順4）が加わります。結果は人間向けサマリーと、呼び出し元が判定に使える機械可読な形式の両方で返します。

> 必須ゲートにはこのほか「セルフレビュー」「CI」も含まれますが、本スキルはそのうち自動実行できる Lint / 型チェック / テスト（GDD期はさらに保証索引）を担います。

## 手順

> **スクリプトの実行形（重要・本スキルが実行する全スクリプト共通）**: 本スキルはプラグインとして配布されるため、実行するスクリプト（`detect-dev-phase` / `quality-check-runner` / `guarantee-index-check`）は**ユーザーのプロジェクトroot ではなく、プラグイン配下**にある。スクリプトを実行する際は必ず PATH 上のランチャー経由で `claude-harness-run <スクリプト名>` の形式（パス・バージョン・引用符を付けない。この形だけが `Bash(claude-harness-run:*)` の1行で allowlist できる）を用い、相対パス `scripts/<スクリプト名>.sh` では呼び出さないこと。`claude-harness-run: command not found` になった場合のみ `bash "<プラグインルート>/scripts/<スクリプト名>.sh"` にフォールバックする（パスは引用符で囲む。プラグインルートはスキル起動時の「Base directory for this skill」から解決した絶対パス。`${CLAUDE_PLUGIN_ROOT}` は表記上のプレースホルダであり環境変数ではない）。フォールバックした場合はユーザーにランチャー導入を案内すること。
<!-- 正本: docs/plugin-path-conventions.md -->

> **単独コマンドとして実行する（重要・全スクリプト共通）**: 各スクリプトは上記の形のまま、**シェル変数へ代入せず**（`RESULT=$(…)` としない）、**同じ Bash 呼び出しに後続コマンドを繋げない**（`; echo "$RESULT"` や `jq … <<<"$RESULT"` を続けない）こと。ローカル変数を展開する後続コマンドがあると、permission の静的解析が「解析不能」と判定して allowlist 到達前に拒否され、headless 実行が止まる（実測済み）。stdout の JSON と exit code は **Bash ツールの実行結果からそのまま読む**。

### 1. プロジェクト設定の確認（コマンド特定）

CLAUDE.md および `package.json` 等から、以下のコマンドを特定する（意味理解が必要なため LLM が行う）:

- **auto-fix 系コマンド**（0個以上）: lint --fix / format / organize-imports など、機械的に直せる範囲を直すコマンド
- リントコマンド（チェック用）
- 型チェックコマンド
- テストコマンド

該当するコマンドが存在しないものは省略する（手順3のスクリプトが「スキップ」として扱い、失敗とはしない）。

### 2. 開発フェーズの判定（GDD 追加ゲートの発動判定）

開発フェーズ（SDD期 / GDD期）によって実行するゲートと最終出力の形が変わるため、先に判定する。判定は決定的スクリプトに切り出されており、フェーズは必ずこのスクリプトの出力だけで判定し、`CLAUDE.md` を自分で grep しないこと（判定規約の重複実装を防ぐため）:

```bash
claude-harness-run detect-dev-phase
```

stdout に `{"phase":"sdd"|"gdd"|"invalid","reason":"...","source":"..."|null}` が1個返る。

| 判定結果 | 扱い |
|---|---|
| `phase: "sdd"`（exit 0） | 従来どおり手順3→手順5へ進む。手順4は**実行しない**。SDD期・フェーズ宣言なしのプロジェクトでは本スキルの挙動・最終出力は従来と完全に同一 |
| `phase: "gdd"`（exit 0） | 手順3のあと手順4の保証索引ゲートを実行する |
| `phase: "invalid"`（exit 1）／スクリプト実行不能・stdout が JSON としてパース不能 | **実行エラー**として扱う（品質 fail ではない）。`sdd` に読み替えない。**手順3以降に進まず中断**し、`reason`・`source`・stderr のメッセージを添えて「要人間判定」として報告する（不正な宣言や実行失敗によって GDD のゲート群が暗黙に無効化される事故を防ぐ。宣言の修正は人間の責務であり、エージェントが `CLAUDE.md` を書き換えて解消しない） |

### 3. quality-check-runner.sh の実行

**自動修正の事前適用 → lint → 型チェック → テストの順序実行**、exit code に基づく `gates.*.status` 判定、機械可読 JSON の構築は、決定的な処理として `scripts/quality-check-runner.sh` に切り出されている。開発フェーズによらず常に実行する（このスクリプト自体はフェーズを判定・解釈しない）。

```bash
claude-harness-run quality-check-runner \
  --auto-fix "<auto-fixコマンド1>" \
  --auto-fix "<auto-fixコマンド2>" \
  --lint "<リントコマンド>" \
  --typecheck "<型チェックコマンド>" \
  --test "<テストコマンド>"
```

- 手順1で特定できなかったコマンドは、対応する `--auto-fix`/`--lint`/`--typecheck`/`--test` フラグごと省略する（0個以上の `--auto-fix` を検出順に指定。`--lint`/`--typecheck`/`--test` は1回のみ指定可）
- 各コマンドの生出力（lintエラー箇所・型エラー内容・失敗テストの詳細）は stderr に転記される。**手順6の失敗分析はこの stderr 出力を使う**

**実行結果の解釈（品質結果と実行エラーを混同しない）**: 品質判定に使ってよいのは **stdout が妥当な JSON としてパースできた場合だけ**。次の順で判定する:

1. **stdout が空、または JSON としてパースできない** → **実行エラー**として扱う（品質 fail ではない）。stderr のメッセージをそのまま報告し、**手順4以降に進まず中断する**。原因は主に次の2系統:
   - **ランチャー段階の失敗**（`quality-check-runner` が起動される前に終了。exit `69` = プラグインルート／実行系を解決できない、`66` = target が見つからない、`64` = 引数不正、`command not found` = ランチャー未導入）。この場合は上記注記のフォールバック形を試し、ランチャー導入をユーザーに案内する
   - **runner 段階の失敗**（exit `2` = jq 不在、exit `1` + 空 stdout = CLI引数不正）
2. **stdout が妥当な JSON** → 品質結果として解釈する。exit code は `result` が `pass` なら 0、`fail` なら 1
   - JSON の `result` と exit code が食い違う場合は**実行エラー扱い**とし、暗黙に pass へ倒さない

出力 JSON の**フィールド定義と件数抽出の仕様の正本は、プラグイン配下の `scripts/specs/quality-check-runner.md`**（ここには複製しない。手順4の `guarantee_index` は runner の出力には含まれず、この正本の対象外）。**cwd 起点の相対パス `scripts/specs/quality-check-runner.md` では導入先プロジェクトの同名ファイルを誤って参照しうるため、Read する場合はスキル起動時の「Base directory for this skill」を起点に `<base>/../../scripts/specs/quality-check-runner.md` として解決すること。

### 4. 保証索引ゲートの実行（GDD期のみ）

手順2の判定が `gdd` の場合のみ実行する（`sdd` では本手順を実行せず、手順5の最終出力に `guarantee_index` フィールド自体を出力に含めない）。保証台帳（既定: `docs/guarantees.md`）のテスト対応索引の整合を決定的スクリプトで検査する:

```bash
claude-harness-run guarantee-index-check
```

出力 JSON（`{status, ledger, base, counts, broken}`）のフィールド定義の正本はプラグイン配下の `scripts/specs/guarantee-index-check.md`（Read する場合は「Base directory for this skill」を起点に `<base>/../../scripts/specs/guarantee-index-check.md` として解決）。

実行結果は次のとおり `guarantee_index` フィールド（手順5で最終出力に格納する値）へ変換する:

- **exit 0 または 1 で、stdout が妥当な JSON**（`status` が `"pass"` / `"fail"`）→ その JSON を**そのまま** `guarantee_index` とする。JSON の `status` と exit code が食い違う場合（`status: "pass"` なのに exit 1 等）は次項の fail 扱いに倒し、暗黙に pass へ倒さない
- **exit 2（台帳が読めない・「保証」節が無い・jq 不在）／stdout が空または JSON としてパース不能／スクリプト実行不能** → `guarantee_index` を `{"status": "fail", "error": "<stderr のメッセージ>"}` とする。**スキップ（`skip`）や `pass` に変換しない**（検査不能は「問題0件」と同じではない。GDD期の宣言があるのに台帳が無い・読めない状態は、索引ゲートを素通りさせず fail として呼び出し元に見せる）

> 手順3の runner と異なり、本手順の実行不能は**中断ではなく fail 扱いで手順5へ進む**（runner の品質結果と索引ゲートの結果を1つの最終出力にまとめて呼び出し元へ返すため）。

### 5. 結果サマリー

最終出力の機械可読 JSON は開発フェーズ（手順2）で形が決まる。**機械可読な結果として最後にそのまま出力**する（呼び出し元のスキル/エージェントが判定に使う）:

- **SDD期**: 手順3で得た stdout の JSON（`{result, auto_fix, gates}`）を**そのまま**出力する（従来どおり。`guarantee_index` フィールド自体を出力に含めない。`null` や `skip` 値で足すこともしない）
- **GDD期**: `{result, auto_fix, gates, guarantee_index}`。`auto_fix`・`gates` は手順3の値、`guarantee_index` は手順4の値をそのまま格納する。**トップレベル `result` は「手順3の runner の `result` が `"pass"`」かつ「`guarantee_index.status` が `"pass"`」の場合のみ `"pass"`、それ以外は `"fail"`** とする（一部ゲートのみの成功を全体の成功として報告しない。**索引ゲートの失敗が `result: "pass"` に見える出力経路は存在させない**）

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
| 保証索引 (GDD期のみ) | ✅/❌ | guarantees, refs, broken の件数（実行不能時は error の内容） |

### 総合判定: ✅ PASS / ❌ FAIL
```

（保証索引の行は GDD期のみ表示する。SDD期は従来どおり3行の表とし、⊘ スキップ行としても表示しない）

### 6. 失敗時の対応

`gates.*.status` が `fail` のゲートがある場合:
1. スクリプト実行時に stderr へ転記された生出力（`--- <gate>: <cmd> ---` 区切り）からエラー内容を分析
2. 修正方法を提案
3. ユーザーの指示に応じて修正を実施し、手順3から再実行

`guarantee_index.status` が `fail` の場合（GDD期）:
1. `broken` の各 `{guarantee_id, ref, reason}` から、保証台帳のテスト参照とテスト側（ファイルパス・テスト名）のどちらを直すべきかを分析する。`broken` が無く `error` のみの場合は、stderr の内容から実行不能の原因（台帳の欠落・「保証」節の欠落等）を特定して報告する（台帳の新設・正本化は人間の裁可事項であり、本スキルでは行わない）
2. ユーザーの指示に応じて修正を実施し、手順3から再実行する（テスト側を修正した場合はテストゲートにも影響するため、索引チェックだけの再実行にしない）

> 自律実行コンテキスト（feature-implementer などのサブエージェント呼び出し）では、呼び出し元が機械可読な結果を見て修正ループを管理する。

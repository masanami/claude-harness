---
name: walkthrough
description: "AIがHeaded Playwrightでアプリを操作しながら動作確認を行い、ユーザーは画面を見て承認する。成功シナリオはE2Eテスト化できる。Triggers on: '/walkthrough', '動作確認して', 'デモして'"
argument-hint: "[Issue番号|PR番号|機能名]"
model: sonnet
# effort: ブラウザ操作主体で深い推論を要さないため、session 継承（無指定）とする。
---

# AI動作確認（ウォークスルー）

AI が **Headed Playwright**（可視ブラウザ）でアプリケーションを操作しながら、各ステップをナレーションします。ユーザーは画面を見て **OK / NG** を返すだけです。手動動作確認の負荷を肩代わりするためのスキルです。

---

## 入力パラメータ

対象機能: $ARGUMENTS（Issue番号 / PR番号 / 機能名。なければユーザーに確認）

## 前提

- Playwright がプロジェクトに導入されていること（無ければ導入を提案）
- dev server / アプリの起動方法が `CLAUDE.md` から判別できること

---

## 手順

### Phase 1: シナリオ設計

1. `CLAUDE.md`（テスト方針・起動コマンド・E2E設計書）を読む
2. 対象機能の**完了条件・シナリオ**を把握する（Issue/PR/設計書から）
3. 動作確認するシナリオ（正常系のハッピーパス中心）と、**完了条件とのトレーサビリティ**を提示する

```text
## 動作確認シナリオ

| # | シナリオ | 対応する完了条件 |
|---|---------|----------------|
| 1 | ... | ... |

この内容で動作確認を進めてよいですか？
```

### Phase 2: 環境準備

dev server とテストデータを整えたうえで、**同梱スクリプト**で Playwright(Headed) 環境を準備する。ブラウザ導入・OS依存・module 解決・runner はスクリプトが肩代わりするため、エージェントがアドホックに再実装しない。

> **スクリプトの所在（重要）**: 本スキルはプラグインとして配布されるため、スクリプトは**ユーザーのプロジェクトroot ではなく、プラグイン配下**にある。実行する際は必ず `${CLAUDE_PLUGIN_ROOT}/skills/walkthrough/scripts/` 配下のファイルを絶対パス（引用符必須）で参照し、相対パス `skills/walkthrough/scripts/...` では呼び出さないこと（`${CLAUDE_PLUGIN_ROOT}` は実行時にプラグインルートへ展開される）。`cd` はせず、**dev server を起動したプロジェクトを cwd にしたまま**スクリプトを実行する（runner は cwd の git root から `@playwright/test` を解決する）。
<!-- 正本: docs/plugin-path-conventions.md -->

1. **dev server / テストデータ**
   - dev server をバックグラウンドで起動し、起動を確認する（`BASE_URL` を控える。既定 `http://localhost:3000`）
   - 必要なテストデータを投入する

2. **セットアップスクリプトを実行**
   - `bash "${CLAUDE_PLUGIN_ROOT}/skills/walkthrough/scripts/walkthrough-setup.sh"` を実行する。
   - 内部で `playwright install chromium` を行い、**`uname` で OS 判定**して依存導入を分岐する（macOS は依存導入をスキップ／Linux は full chromium に対し `ldd` で不足を検出）。
   - 出力末尾の `WALKTHROUGH_SETUP_STATUS=<ready|deps-missing|error>` を確認する。
   - `error` の場合は再実行せず、まずセットアップログを確認して原因（Playwright 未導入など）を解消してから `2.` をやり直す。

3. **不足があれば案内コマンドで導入**
   - `deps-missing` の場合、スクリプトは **sudo を勝手に実行せず**、必要なコマンド（例: `sudo <playwright> install-deps chromium`）を表示して正常終了する。
   - 表示されたコマンドを**ユーザーに実行してもらう**よう促す（非対話環境ではエージェントは実行できない）。導入後に再度 `2.` を実行する。

4. **runner で起動**
   - `node "${CLAUDE_PLUGIN_ROOT}/skills/walkthrough/scripts/run-walkthrough.mjs" "/絶対パス/flow.mjs"` を**プロジェクトを cwd にしたまま**実行する。
     runner は `createRequire` で（cwd の git root 起点に）プロジェクトの `@playwright/test` を解決するため、**プラグイン配下の場所から実行しても壊れない**。
   - **headed + slowMo + trace** が既定 ON。ステップ実況ログ・スクショ・動画保存も runner が行う。
   - `BASE_URL` / `E2E_USERNAME` / `E2E_PASSWORD` は env で渡す（`E2E_*` は `/create-e2e` と共通の命名）。操作手順は `flow.mjs`（`export default async (ctx) => {...}`）に書き、`ctx.goto` / `ctx.step` / `ctx.shot` / `ctx.login` を使う。flow ファイルは**絶対パス**で渡すこと（cwd 相対で解決される）。
   - **表示不可環境**（Linux で `DISPLAY` 無し等）では runner が**自動的に headless + スクショへフォールバック**する。明示制御は `WALKTHROUGH_HEADED=false`（headless）/ `WALKTHROUGH_HEADED=true`（headed 強制）。WSL の Headed は WSLg（`DISPLAY`）前提。
   - 注意: trace は入力値も記録され得る（`sources` 有効）。認証情報を含む成果物の取り扱いに注意する。

### Phase 3: ウォークスルー実行

各シナリオについて、Headed Playwright でブラウザを操作しながら**ステップを実況**する:

1. 各操作の前に「これから何をするか」を一文で述べる（例:「ログイン画面を開きます」→「認証情報を入力します」→「ログイン成功を確認します」）
2. 操作を実行し、画面の結果を述べる
3. シナリオ完了後、ユーザーに確認を求める:

```text
## シナリオ {N}/{総数}: {名前}

{実行したステップの要約}
→ 期待結果: {...}（達成 / 未達成）

画面の動作を確認してください（OK / NG / 修正点）。
```

| ユーザー回答 | アクション |
|------------|---------|
| **OK** | 次のシナリオへ |
| **NG + 詳細** | 問題を報告。実装側の修正が必要な場合はその旨を伝える |
| **修正点** | シナリオを調整して再実行 |

### Phase 4: エビデンスと結果

- 各シナリオの trace / スクリーンショット / 動画の保存先を報告する
- 結果サマリー（確認済み / NG / スキップ）を提示する

### Phase 5: E2Eテスト化（任意）

ユーザーが希望する場合、OK となったシナリオを E2Eテストとして永続化する:

- `/create-e2e` を呼び出し、確認済みシナリオを正常系テストケースとして実装する（create-e2e は非対話・仕様ベース）
- 動作確認はこのウォークスルーで完了しているため、確認済みシナリオをそのままテストケース化する

---

## 注意事項

- 破壊的操作（データ削除・外部送信）を伴う場合は、実行前にユーザーへ確認する
- 操作対象が見つからない場合は `data-testid` 等のセレクタを確認し、必要なら実装側に追加を提案する
- メール送信等の外部副作用は、送信トリガーまでの確認に留める

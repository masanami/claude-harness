---
name: demo-e2e
description: "E2Eテストケースカタログ(CASE_ID付きCSV)と突き合わせながら、1テストケースごとに解説→実演→人間判定のサイクルでHeaded Playwrightのデモを行う。Triggers on: '/demo-e2e', 'テストケースごとにデモして', 'カタログと突き合わせてデモ', 'E2Eケースを1件ずつ確認して'"
argument-hint: "[カタログCSVパス|CASE_ID...|specファイル|画面名]"
model: sonnet
# effort: ブラウザ操作自体は/demoと同様に深い推論を要さないが、spec/シードデータからテスト設計意図を
# 言語化する解説フェーズがあるため medium とする。
effort: medium
---

# E2Eテストケース単位デモ（カタログ突き合わせ）

E2Eテストケースカタログ（CASE_ID付きCSV。例: `e2e/playwright-test-cases.csv`）を入力に、**1テストケース＝1サイクル**で「解説（実行前）→実演（Headed Playwright）→人間の判定（OK/NG/再実行）」を繰り返すスキルです。「テストケースカタログと突き合わせながらデモを見たい」「1ケースごとに何を確かめるテストか・どのシードデータを使うかまで解説してほしい」という要望に応えます。

> **本スキルは対話前提です**（`/explain-e2e` Phase 1・`/demo` と同様、メインセッションで人間とやり取りしながら進める）。サブエージェントへの委譲は行わない。

## `/demo`・`/explain-e2e` との違い

| スキル | 単位 | 画面を動かすか | カタログ・シードとの紐付け |
|-------|------|--------------|--------------------------|
| `/demo` | 機能シナリオ（正常系ハッピーパス中心） | ○（Headed Playwright） | なし |
| `/explain-e2e` | テストファイル | ×（文章解説＋独立検証のみ） | なし |
| `/demo-e2e`（本スキル） | **テストケース（CASE_ID）1件** | ○（Headed Playwright） | **あり**（カタログ行→specコード→シードデータの出自まで解説） |

---

## 入力パラメータ

対象指定: $ARGUMENTS

| 入力形式 | 解釈 |
|---------|------|
| カタログCSVパス＋CASE_ID群（例: `e2e/playwright-test-cases.csv CASE-101 CASE-102`） | 指定ケースのみを対象にする |
| specファイル（例: `e2e/tests/checkout.spec.ts`） | カタログから該当specに紐づく行を特定して対象にする |
| 画面名（例: `チェックアウト画面`） | カタログから該当画面の行を特定して対象にする |
| フィルタ指定（例: `passのみ`） | カタログの `status=pass` 行のみを対象にする |
| なし | Step 1-2 の提案フローに進む（カタログの pass ケースから提案し、人間の承認を得てから実行に入る） |

ペース調整（任意。固定のフラグ構文は無く、対話で人間が明示的に依頼した場合にのみ既定値を上書きする）:

| パラメータ | 既定値 | 意味 |
|-----------|-------|------|
| slowMo | **1500ms** | 操作間の待ち。`WALKTHROUGH_SLOWMO` として `run-walkthrough.mjs` に渡す |
| ステップ間静止秒数（`pauseMs`） | **5秒（5000ms）** | 1ステップ実行後に画面を静止させる秒数。`run-walkthrough.mjs` に `WALKTHROUGH_PAUSE_MS`（ms）として渡し、runner側で `ctx.step` / `ctx.goto` 完了直後に自動で静止させる（Issue #148。flow.mjs 側への手動挿入は不要） |

既定値は実運用で好評だった値（Issue #142）。人間が「もっと速く/遅く」と要望した場合は、その回のみ `WALKTHROUGH_SLOWMO` の値・`pauseMs` の値を具体的なミリ秒数で確認したうえで上書きする（例:「もっと速く」→「slowMo を800ms、静止を2秒にしますか？」と確認してから反映する。曖昧な指定のまま数値を推測で決め打ちしない）。

---

## 前提

- Playwright がプロジェクトに導入されていること
- dev server / アプリの起動方法・E2Eテスト実行コマンドが `CLAUDE.md` から判別できること
- 対象テストケースのカタログCSV（CASE_ID・spec参照・status（pass/fixme等）を持つ）が存在すること。無ければユーザーに所在を確認する

---

## Phase 0: セットアップ

dev server とテストデータを整えたうえで、**`/demo` と同梱の Playwright(Headed) セットアップスクリプトをそのまま流用**する（複製・再実装しない）。

> **スクリプトの所在（重要）**: 本スキルはプラグインとして配布されるため、スクリプトは**ユーザーのプロジェクトroot ではなく、プラグイン配下**にある。実行する際は必ず `${CLAUDE_PLUGIN_ROOT}/skills/demo/scripts/` 配下のファイルを絶対パス（引用符必須）で参照し、相対パス `skills/demo/scripts/...` では呼び出さないこと（`${CLAUDE_PLUGIN_ROOT}` は表記上のプレースホルダであり環境変数ではない。実行前に、スキル起動時の「Base directory for this skill」から解決したプラグインルートの絶対パスに置換して実行する）。`cd` はせず、**dev server を起動したプロジェクトを cwd にしたまま**スクリプトを実行する（runner は cwd の git root から `@playwright/test` を解決する）。
<!-- 正本: docs/plugin-path-conventions.md -->

**Step 0-1（dev server / テストデータ）**: dev server をバックグラウンドで起動して `BASE_URL` を控え、カタログが前提とするシードデータを投入する

**Step 0-2（セットアップスクリプトを実行）**: `bash "${CLAUDE_PLUGIN_ROOT}/skills/demo/scripts/walkthrough-setup.sh"` を実行し、`WALKTHROUGH_SETUP_STATUS=<ready|deps-missing|error>` を確認する（`deps-missing` の場合は表示された案内コマンドをユーザーに実行してもらう。`error` の場合は原因解消後に再実行する。詳細な分岐は `skills/demo/SKILL.md` Phase 2 と同一のため重複記載しない）

**Step 0-3（project root の明示・monorepo 注意）**: monorepoでPlaywrightがサブワークスペース配下にある場合、`walkthrough-setup.sh` / `run-walkthrough.mjs` は既定で git root を基準に `@playwright/test` を解決しようとするため、**Playwright が実際に入っているサブワークスペースを `WALKTHROUGH_PROJECT_ROOT` で明示しないと解決に失敗する**。`CLAUDE.md` のディレクトリ構成を確認し、必要なら `WALKTHROUGH_PROJECT_ROOT=<Playwrightプロジェクトの絶対パス>` を以降のスクリプト呼び出しに付与する。この値は `WALKTHROUGH_OUT`（成果物の出力先）の解決基準にもなる（Step 2-2 参照）。

---

## Phase 1: カタログ解決・対象ケースの確定

### Step 1-1: カタログとケースの特定

- 入力（$ARGUMENTS）で指定されたカタログCSVを読み、各行の CASE_ID・対象spec・screen（画面名）・status（pass/fixme等）を把握する
- specファイル・画面名・フィルタで指定された場合は、該当するカタログ行を絞り込む
- 各対象ケースについて、紐づく **specファイルの実コード**（該当 `test(...)` ブロックとその周辺コメント）を読む。Phase 2 の解説フェーズはこのspecコードとカタログ行を根拠にする

### Step 1-2: 無指定時の提案フロー（対話）

$ARGUMENTS が無指定の場合、カタログの `status=pass` の行から**デモ向きのケース**（正常系ハッピーパス・画面カバレッジが分かりやすいものを目安に）を提案する:

```text
## デモ対象ケースの提案

カタログから以下の pass ケースを提案します（{N}件）。

| CASE_ID | 画面 | spec | 概要 |
|---------|------|------|------|
| ... | ... | ... | ... |

この内容でよろしいですか？（そのまま進める／絞り込む／追加する）
```

人間の承認（または絞り込み後の確定）を得てから Phase 2 に進む。**承認前に実行に入らない**。

### Step 1-3: fixme / 実行不能ケースの扱い

対象に含めた行の status が `fixme` である、または spec 側に `test.skip` / `test.fixme` 等の無効化指示がある場合は、そのケースの**解説・実演をスキップ**する。スキップする際は必ずスキップ理由を提示する（例:「CASE-118 は既知バグ〈#123〉起因の fixme のためスキップします」）。理由が特定できない場合も「理由不明のため実行不能と判断してスキップ」と明示し、黙って読み飛ばさない。スキップ後は Phase 2 の次のケースへ進む。

---

## Phase 2: 1ケースサイクル（解説→実演→判定）

Phase 1 で確定した対象ケースを**1件ずつ**、次のサイクルで進める。**あるケースの判定（OK/NG/再実行）を人間から受け取るまで、次のケースへは進まない**。

### Step 2-1: 解説（実行前）

対象CASE_IDについて、`skills/explain-e2e/SKILL.md` Phase 1 の解説様式（対象フロー/前提/操作手順/検証内容/カバー範囲）を**1ケース粒度に流用**し、次を必ず含めて提示する:

```text
## テストケース解説: {CASE_ID}

- 対象フロー: {どのユーザーフロー・画面を検証するか}
- 前提: {ログイン状態・事前条件。spec の `beforeEach`/fixture/`test.use` 等が担っているセットアップがあれば、その内容も含める（Step 2-2 でこの前提を flow.mjs 側に再現する根拠になる）}
- 操作手順: {ステップバイステップの操作手順}
- 検証内容（アサーション）: {何を確かめるテストかの言語化。spec 内の expect が何を保証しているか}
- 使用シードデータの出自: {どのシードSQL/fixtureのどのレコードを使うか（ファイルパス・レコード識別子）。期待値がそのシードからどう導出されるか（例:「シード〈users.sql〉の id=42 ユーザーは残高10,000円のため、画面表示額もこの値と一致することを確認する」）}
- テスト設計上の意図: {spec コメントに眠っている判断の言語化。例: 「URLクエリ駆動にしている理由」「deferred同期のため検索ボタン押下が必要な理由」。spec にコメントが無い場合は「specコメントなし。コードから読み取れる意図: {推測内容}」と明示する}
- カバー範囲 / 非カバー範囲: {このケースが保証する範囲と、しない範囲}
```

この解説を提示し、次のステップ（実演）に進んでよいか軽く確認してよい（明確な異論が無ければそのまま Step 2-2 へ進めてよい。厳密な承認ゲートは Step 2-3 の判定フェーズに置く）。

### Step 2-2: flow生成・実演

1. **1ケース用の `flow.mjs` を生成する**（都度の使い捨て成果物。`run-walkthrough.mjs` 自体は変更しない）。Step 2-1 の操作手順を `ctx.goto` / `ctx.step` / `ctx.shot` / `ctx.login` で表現する。**ステップ間の静止は `run-walkthrough.mjs` が `WALKTHROUGH_PAUSE_MS` を見て `ctx.step` / `ctx.goto` 完了直後に自動で行う**（Issue #148。flow.mjs 側に `waitForTimeout` を手で挿入する必要はない。呼び出し方は次項2参照）。flow ファイルは絶対パス（例: スクラッチ領域配下）で保存する。

   - **前提の再現**: `run-walkthrough.mjs` は毎回新規にブラウザ・コンテキストを起動するため（ケース間でログインセッション等の状態は引き継がれない）、Step 2-1 で言語化した前提（ログイン状態・spec の `beforeEach`/fixture 相当のセットアップ）は、そのケース専用の `flow.mjs` の中で `ctx.login()` や事前の `ctx.goto` / 操作として明示的に再現する。認証情報が異なるケースでは `ctx.login({ username, password })` で明示上書きする。まずは Phase 0 Step 0-1 のシード投入・flow内での事前操作（`ctx.page` 経由のAPI呼び出しを含む）で再現を試み、それでもなお再現不能な前提が残る場合にのみ、Step 1-3 と同様に**実行不能と判断してスキップし、理由を提示する**（安易にスキップへ倒さない）

   ```js
   // 生成する flow.mjs のイメージ(デモ用に都度生成する使い捨てファイル)
   export default async (ctx) => {
     await ctx.login() // 前提: ログイン状態(spec の beforeEach 相当をここで再現)
     await ctx.goto('/checkout')
     await ctx.step('カートの商品を確認', async (page) => {
       await page.getByTestId('cart-item-1').waitFor()
     })
     // ...ケースの手順分だけ ctx.goto/ctx.step を繰り返す（ステップ間の静止は WALKTHROUGH_PAUSE_MS で runner が自動付与）
   }
   ```

2. **runner で実演を実行する**。dev server を起動したプロジェクトを cwd のまま実行する:

   ```bash
   WALKTHROUGH_SLOWMO=1500 \
   WALKTHROUGH_PAUSE_MS=5000 \
   WALKTHROUGH_OUT="demo-e2e-artifacts/<SAFE_CASE_ID>/attempt-<N>" \
   node "${CLAUDE_PLUGIN_ROOT}/skills/demo/scripts/run-walkthrough.mjs" "/絶対パス/flow.mjs"
   ```

   - `WALKTHROUGH_SLOWMO` は既定 1500ms（未上書き時）
   - `WALKTHROUGH_PAUSE_MS` は既定 5000ms（未上書き時）。runner が `ctx.step` / `ctx.goto` 完了直後に自動で指定ms静止させる（正の整数以外は無効化＝静止しない）
   - **CASE_ID のサニタイズ（パストラバーサル対策・衝突防止）**: CASE_ID はケースカタログ由来の外部入力であり、`WALKTHROUGH_OUT` は `run-walkthrough.mjs` 内で `path.resolve()` により絶対パスへ解決されるため、CASE_ID に `../` 等の区切り文字が含まれると成果物の保存先が projectRoot 外へ移動し得る。成果物パスを組み立てる前に CASE_ID から **`<SAFE_CASE_ID>`**（ファイルシステム安全な識別子）を導出する: `[A-Za-z0-9._-]` 以外の文字を `_` に置換する。**置換が1文字でも発生した場合は、異なる CASE_ID が同じ `<SAFE_CASE_ID>` に衝突するのを防ぐため、元の CASE_ID の短い安定ハッシュ（例: `shasum` で得た先頭8文字などの決定的な値）を `-<hash>` として末尾に付加する**（例: `A/B` → `A_B-3f2a1c9d`。置換が発生しない CASE_ID はファイルシステム上そのまま安全なため、可読性を保つ目的でハッシュを付加しない）。結果が `.` または `..` になる場合は採用せず、元の CASE_ID の短い安定ハッシュから導出した固定形式の識別子（例: `case-<hash>`）にフォールバックする（連番サフィックス等カタログ順・実行順に依存する識別子は、再実行のたびに別ディレクトリへ移動し既存の `attempt-*` を検出できなくなるほか、異なる特殊な CASE_ID 同士が同じ別名に衝突し得るため使用しない）。成果物ディレクトリと `attempt-*` の既存スキャンには常に `<SAFE_CASE_ID>` のみを使い、CASE_ID そのものはパス構成に使わない。画面への実況・解説・Step 2-3 の報告では元の CASE_ID をそのまま表示する
   - `WALKTHROUGH_OUT` は**ケースの`<SAFE_CASE_ID>`を含むサブディレクトリ**を毎回指定する（成果物をケースごとに区別するため。例: `demo-e2e-artifacts/CASE-101/attempt-1/`）。実行前に `demo-e2e-artifacts/<SAFE_CASE_ID>/` 配下の既存 `attempt-*` を確認し、**最大番号の次の番号**を `attempt-<N>` として使う（同一セッション内の初回はもちろん、別セッションでの再実行・過去の実行が残っている場合でも `attempt-1` から採番し直して上書きしない）。`run-walkthrough.mjs` は同一 `WALKTHROUGH_OUT` を毎回上書きするため、この連番を付けないと前回（NGだった回を含む）の trace/スクショ/動画が消える
   - `WALKTHROUGH_OUT` は `run-walkthrough.mjs` 内で `projectRoot`（Step 0-3 で `WALKTHROUGH_PROJECT_ROOT` を明示した場合はそのサブワークスペース、無指定なら git root）を基準に絶対パスへ解決される（cwd 基準ではない）。Phase 3 で成果物の場所を報告する際は、この解決規則を踏まえた**絶対パス**（またはプロジェクトrootからの相対パスであることを明示した表記）で報告し、単に `demo-e2e-artifacts/<SAFE_CASE_ID>/...` とだけ書いて曖昧にしない
   - `BASE_URL` / `E2E_USERNAME` / `E2E_PASSWORD` 等は `/demo` Phase 2 と同じ env 命名（`E2E_*`）で渡す
   - project root を Step 0-3 で明示した場合は `WALKTHROUGH_PROJECT_ROOT` も付与する
   - 表示不可環境（`DISPLAY` 無し等）では runner が自動的に headless + スクショへフォールバックする。挙動は `skills/demo/SKILL.md` Phase 2 と同一のため重複記載しない
   - **注意**: trace は入力値も記録され得る（`sources` 有効）。認証情報を含む成果物の取り扱いに注意する（詳細は本ファイル末尾の注意事項）

3. 実行中は各操作の前後で一文の実況を行う（例:「これからチェックアウトボタンを押します」→ 実行 →「注文確認画面に遷移しました」）。

### Step 2-3: 判定（人間ゲート）

実演完了後、Step 2-1 の解説内容が実際の挙動と一致していたかも含めてユーザーに確認を求める:

```text
## テストケース {N}/{総数}: {CASE_ID}（{画面名}）

{実行したステップの要約}
→ 検証内容: {Step 2-1 の検証内容}（達成 / 未達成）

画面の動作を確認してください（OK / NG / 再実行）。
```

| 人間の回答 | アクション |
|-----------|---------|
| **OK** | このケースを「確認済み」として記録し、次のケースの Step 2-1 へ進む |
| **NG + 詳細** | 問題を記録する。実装側の修正が必要な場合はその旨を伝える。人間の指示（次へ進む／このケースを打ち切る）を待つ |
| **再実行** | 同じケースの Step 2-2 を（必要ならペースやシナリオを調整して）再実行する。`WALKTHROUGH_OUT` の `attempt-<N>` を1つ進め、前回の成果物を上書きしない |

**この判定を受け取るまで次のケースには進まない**（自動で先へ進めない）。

---

## Phase 3: 成果物・サマリー

全対象ケース（またはユーザーが打ち切りを指示するまで）を終えたら、以下を報告する:

```text
## デモ結果サマリー

| CASE_ID | 画面 | 判定 | 成果物（絶対パス） |
|---------|------|------|-------------------|
| ... | ... | OK/NG/スキップ | 実演時: {実際に解決された `demo-e2e-artifacts/<SAFE_CASE_ID>/attempt-<N>/` の絶対パス}; スキップ: — |

- 確認済み: N件 / NG: N件 / スキップ（fixme・無効化・実行不能）: N件（理由一覧）
```

- 実演したケースの trace / スクリーンショット / 動画は `demo-e2e-artifacts/<SAFE_CASE_ID>/attempt-<N>/`（`WALKTHROUGH_OUT` で指定したパス。Step 2-2 の解決規則に従いプロジェクトroot基準で解決される）に保存されている（`run-walkthrough.mjs` の既存の保存機能をそのまま利用）。再実行したケースは複数の `attempt-<N>` が残るため、最終判定（OK/NG確定）に対応する回を明示する
- NG となったケースは、実装側の修正 Issue 化を提案してよい

---

## 注意事項

- 破壊的操作（データ削除・外部送信）を伴うケースは、実演前にユーザーへ確認する
- fixme / 実行不能ケースは黙ってスキップせず、必ずスキップ理由を提示する（Step 1-3）
- trace は入力値を記録し得る（`sources` 有効）。認証情報を含む成果物の取り扱いに注意する（`/demo` と同様の注意）。特に `demo-e2e-artifacts/`（`WALKTHROUGH_OUT` の出力先）はプロジェクト配下に生成される作業成果物であり、リポジトリの `.gitignore` に含まれているか確認し、含まれていなければコミット対象に含めないよう注意する（`git status` で意図せずステージされていないか確認してから `/commit` を行う）
- monorepo で Playwright がサブワークスペース配下にある場合は `WALKTHROUGH_PROJECT_ROOT` の明示が必須（Step 0-3）
- 操作対象が見つからない場合は `data-testid` 等のセレクタを確認し、必要なら実装側に追加を提案する
- 生成する `flow.mjs` は都度の使い捨て成果物であり、`skills/demo/scripts/run-walkthrough.mjs` / `walkthrough-setup.sh` 自体は変更しない

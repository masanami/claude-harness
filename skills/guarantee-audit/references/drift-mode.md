## drift モード（台帳と実態の乖離検出）

既存の台帳と実態の乖離を検出する。**検出するだけで修正しない。**

> **本ファイルの前提**: 起動引数の解釈と開発フェーズの確認（Step 1）は SKILL.md 側で完了している前提で読むこと。**サブエージェントへ渡すデータの分離（プロンプトインジェクション対策）とチャンク分割・完全性 join の規約は SKILL.md の「共通規約」が正本**であり、本ファイルには複製しない。fan-out を行う手順（Step D3・Step D4）では必ずそちらに従うこと。

### Step D1: 台帳の存在確認

`docs/guarantees.md` が存在しない場合:

- `phase` が `gdd` → **運用前提の破れ**として停止し、要人間判定で報告する（GDD期を宣言しているのに駆動文書が無い状態）。
- `phase` が `sdd` → 監査対象が無いため停止し、その旨を報告する。

### Step D2: 索引整合（決定的）

> **スクリプトの実行形（重要）**: 本スキルはプラグインとして配布されるため、スクリプトは**ユーザーのプロジェクトroot ではなく、プラグイン配下**にある。スクリプトは必ず PATH 上のランチャー経由で `claude-harness-run guarantee-index-check docs/guarantees.md` の形式（パス・バージョン・引用符を付けない。この形だけが `Bash(claude-harness-run:*)` の1行で allowlist できる）で実行し、相対パス `scripts/guarantee-index-check.sh` では呼び出さないこと。`claude-harness-run: command not found` の場合のみ `bash "<プラグインルート>/scripts/guarantee-index-check.sh" docs/guarantees.md`（パスは引用符で囲む。プラグインルートはスキル起動時の「Base directory for this skill」から解決した絶対パス。`${CLAUDE_PLUGIN_ROOT}` は表記上のプレースホルダであり環境変数ではない）にフォールバックし、ユーザーにランチャー導入を案内すること。
<!-- 正本: docs/plugin-path-conventions.md / docs/script-launcher.md -->

stdout の JSON（`{status, ledger, base, counts, broken}`）を `index` として保持する。フィールド定義・`reason` の語彙・exit code の意味の正本はプラグイン配下の `scripts/specs/guarantee-index-check.md`（ここには複製しない）。Read する場合はスキル起動時の「Base directory for this skill」を起点に `<base>/../../scripts/specs/guarantee-index-check.md` として解決すること。

- exit 0（`pass`）/ exit 1（`fail`）はいずれも正常な検査結果として続行する。この場合 `index.error` は `null` にする。
- **exit 2（実行前提の欠落）・stdout が JSON としてパースできない場合は、「検査対象なし」＝ pass に読み替えない**。索引整合を `{status: "fail", error: "..."}` として扱い、以降のステップを続けたうえで報告に明示する（台帳の取り違え・節名の変更で全保証が未検査になった状態を素通りさせないため）。このとき Step D5 では次の2つを**必ず**行う:
  - `index.error` に stderr のメッセージ（または JSON をパースできなかった旨）を入れる。**`broken` が空であることをもって「壊れた参照が無い」と読ませない**（実際には検査自体が走っていない）。
  - `human_review_required` に `kind: "index_error"` の項目を積む。
- **「台帳に実際の破損がある（`fail` かつ `broken` が非空）」と「検査を実行できなかった（`fail` かつ `error` が非 null）」は、機械可読結果の上で区別できなければならない**。前者は台帳・テストの修正、後者は実行環境や台帳パスの調査、と対処が全く異なるため。

**失敗の種別によって下流（Step D3・D4）の扱いが変わる**。exit 2 の場合は次のとおり分岐する:

| 失敗の種別 | 判定の根拠 | 下流の扱い |
|---|---|---|
| **台帳そのものが使えない**（台帳を読めない／`## 保証` 節が無く保証の一覧を取り出せない） | stderr のエラー JSON が `ledger not readable` / `guarantee section not found`、または **Step D3 で自分が台帳を読んでも保証の一覧を取り出せない** | **D3・D4 とも `not_analyzed`**。とくに **D4 は GAP 候補を生成しない** |
| **索引検査だけが実行できない**（`jq` 不在・ランチャー不在など。台帳自体は読める） | 上記以外の exit 2 で、かつ Step D3 で台帳を読めている | **D3・D4 は通常どおり実行する**。未解析なのは索引整合だけ |

- **台帳が使えない場合に D4 を走らせてはならない理由**: 参照集合が空または不完全なまま突き合わせると、**実際には台帳に登録されているテストまで「未登録」と判定され、実在しない GAP を人間に追わせる**ことになる。検出漏れより誤検出のほうが害が大きい場面であり、ここは「結果を出さない」を選ぶ。
- **どちらの種別か判別できない場合は「台帳そのものが使えない」側に倒す**（安全側）。

### Step D3: 意味整合（guarantee-auditor fan-out）

まず台帳を読み、保証の一覧（`guarantee_id` / 約束文 / テスト参照）を取り出す。ここで得られるテスト参照の集合が、Step D4 の突き合わせの基準にもなる。

**読み取りの成否で扱いを分ける**（「読めなかった」を「0件だった」と同一視しない）:

- **読み取りに失敗した場合**（ファイルを読めない・`## 保証` 節が無い・書式が崩れていて保証を1件も取り出せない）: 意味整合を `semantic.status: "not_analyzed"` として報告し、**fan-out を行わない**。`checked` は `null` とし、**`checked: 0`（＝0件を検証した）と書かない**。`human_review_required` に `kind: "ledger_unreadable"` / `step: "D3"` を積む。この場合 **Step D4 も `not_analyzed`** になる（Step D2 の分岐表）。
- **台帳の書式は正しく、保証が0件だった場合**: `semantic.status: "analyzed"` / `checked: 0` とする（「台帳に保証が1件も登録されていない」ことを**検査した結果**として報告する。未解析と区別する）。
- **保証を取り出せた場合**: 以下の fan-out に進む。

取り出せた保証を**10件ずつ**のチャンクに分けて `subagent_type: 'claude-harness:guarantee-auditor'` を並列 spawn する。

プロンプトに含めるもの:

- `mode: verify`
- `guarantees`: そのチャンクの `{guarantee_id, statement, test_refs}` 一覧（データブロックとして分離）
- 以下の形での返却を明記する（`guarantee_id` は入力の値をそのまま使わせること）:

```text
{verifications: [{guarantee_id, verdict: "consistent"|"drifted"|"uncertain", evidence}]}
```

**完全性 join**: 入力した全 `guarantee_id` について結果が返ったかを突き合わせる。返却が無い・`guarantee_id` が一致しない・構造化形式に従っていない担当分は、以下として `failed` に積む（**`consistent` にも `uncertain` にも変換しない**）:

```text
{ guarantee_id, verdict: "verification_failed", evidence: "guarantee-auditor agent failed" }
```

索引が壊れている保証（Step D2 の `broken` に `test_file_not_found` / `test_name_not_found` で挙がっているもの）も**意味検証の対象から外さない**（参照が複数あり一部だけ壊れている場合があるため）。ただし `evidence` に索引側の問題も併記する。

### Step D4: 逆方向チェック（台帳に無い公開面テストの検出）

台帳側から実装を見る Step D3 とは逆に、**テスト側から台帳を見て、台帳に載っていない公開面テスト**を洗い出す。

テストファイルの列挙には bootstrap モードと同じスクリプトを使う。

> **スクリプトの実行形（重要）**: 本スキルはプラグインとして配布されるため、スクリプトは**ユーザーのプロジェクトroot ではなく、プラグイン配下**にある。スクリプトは必ず PATH 上のランチャー経由で `claude-harness-run list-test-files <オプション>` の形式（パス・バージョン・引用符を付けない。この形だけが `Bash(claude-harness-run:*)` の1行で allowlist できる）で実行し、相対パス `scripts/list-test-files.sh` では呼び出さないこと。`claude-harness-run: command not found` の場合のみ `bash "<プラグインルート>/scripts/list-test-files.sh" <オプション>`（パスは引用符で囲む。プラグインルートはスキル起動時の「Base directory for this skill」から解決した絶対パス。`${CLAUDE_PLUGIN_ROOT}` は表記上のプレースホルダであり環境変数ではない）にフォールバックし、ユーザーにランチャー導入を案内すること。
<!-- 正本: docs/plugin-path-conventions.md / docs/script-launcher.md -->

プロジェクト固有のレイアウトに対するオプション補正（`--e2e` / `--integration` / `--include` / `--exclude`）は、**bootstrap モードの Step B2 と同じ方針**で行う（規約の正本はそちら。「Base directory for this skill」を起点に `<base>/references/bootstrap-mode.md` として解決する）。

**突き合わせはテスト参照（`<パス>::<テスト名>`）単位で行う。ファイル単位で絞り込まないこと。**

0. **上流の状態を確認する**: Step D3 が `not_analyzed`（台帳から参照集合を得られていない）の場合、**本ステップは実行せず** `reverse_check.status: "not_analyzed"` とし、`gap_candidates` は空のままにする。`human_review_required` に `kind: "not_analyzed"` / `step: "D4"` を積む（理由は Step D2 の分岐表。不完全な参照集合との突き合わせは実在しない GAP を作る）。
1. 対象テストファイルを決める。**外部コマンドはいずれも終了コードを確認し、空出力を「対象なし」と決めつけない**:
   - `--scope <base>..<head>` 指定時: `git diff --name-only <base>..<head>` を実行し、**終了コードを確認する**。不正な revision の場合、git は **exit 128 と空の stdout** を返すため、空出力を「差分なし」と解釈すると**検査していないのに「0件」と報告してしまう**。非0終了なら本ステップを `reverse_check.status: "not_analyzed"` とし、`human_review_required` に `kind: "scope_error"` / `step: "D4"` と git のエラーメッセージを積んで、**GAP 候補を生成せずに終える**。**exit 0 の場合のみ**、その結果と `claude-harness-run list-test-files` の列挙結果の**積集合**を対象にする（diff にはテスト以外のファイルも含まれるため、テスト判定は列挙側の規則に委ねる）。
   - 無指定時: 列挙結果の全件を対象にする。
   - `list-test-files` が**非0終了した場合、または stdout が JSON としてパースできない場合**も同様に `not_analyzed` とし、`human_review_required` に `kind: "enumeration_error"` / `step: "D4"` を積んで GAP 候補を生成しない。
   - `status` が `no_test_files_found` の場合は、列挙規則がプロジェクトのレイアウトに合っていない可能性を疑い、bootstrap モードの Step B2 と同じくオプション補正を検討する。補正しても0件なら、それは**正常に列挙した結果の0件**として扱ってよい。
   - **`--scope` は対象ファイルの絞り込みにだけ使う**。対象になったファイルの中では、どのテストを見るかを絞らない（全テストケースを突き合わせる）。
2. 対象ファイル**全件**について `guarantee-auditor`（`mode: extract`）を走らせ、各テストケースの `test_ref` を得る。**「台帳から1件も参照されていないファイル」だけに事前に絞り込まないこと**（**理由**: 同一ファイル内に登録済みのテストと未登録のテストが混在する場合、ファイル単位で絞ると未登録のテストを丸ごと取りこぼす。例えば `tests/foo.test.ts::test_a` が台帳にあり `tests/foo.test.ts::test_b` が無いとき、ファイル単位の絞り込みでは `test_b` の公開面が永久に検出されない。どのテストが未登録かはファイルの中身を見るまで分からないため、対象ファイルは一律に抽出へ掛ける）。
   - プロンプトの構成（`mode: extract` / `testFiles` / 返却形式）と抽出結果の仕分けは **bootstrap モードの Step B3 と同一**であり、チャンク分割・完全性 join は SKILL.md の「共通規約」に従う。
   - **抽出に失敗したファイル**（完全性 join で `extraction_failed` になったもの・`unreadable` として返されたもの）は、**そのファイルのテストを1件も突き合わせていない**。`reverse_check.extraction_failed` に積み、`human_review_required` に `kind: "extraction_failed"` / `step: "D4"` として登録する（「GAP 候補0件」に紛れ込ませない。未登録の公開面が残っている可能性がある）。
   - 全件抽出になるため fan-out のコストは対象ファイル数に比例する。範囲を絞りたい場合は `--scope` を使う（drift は定期実行・昇格前を想定した低頻度の監査であり、取りこぼしの回避をコストより優先する）。
3. Step D3 で台帳から読み取ったテスト参照の全件を参照集合とし、手順2で得た `test_ref` を**1件ずつ**突き合わせる。参照集合に無い `test_ref` を「**未登録テスト**」とし、`surface` で仕分ける:
   - `public` → **GAP 候補**として報告する
   - `internal` → 件数のみ報告する
   - `uncertain` → 要人間判定へ回す
4. **台帳への追記は行わない**。GAP は人間の台帳 PR でのみ採番・追記される。

**突き合わせの限界（既知）**: 照合は `<パス>::<テスト名>` の文字列一致で行う（前後の空白のみ除去し、それ以外の正規化はしない）。このため、テスト名が実行時に組み立てられている場合（テンプレート文字列・パラメタライズドテストの動的生成）は、**台帳に登録済みであっても未登録として現れうる**。`guarantee-auditor` が `rationale` に「動的生成のため参照が不安定」と記したものは、GAP 候補ではなく**要人間判定**へ回すこと（存在しない不足を人間に追わせないため）。この限界は索引整合チェック側と同じ性質のもので、正本はプラグイン配下の `scripts/specs/guarantee-index-check.md`「テスト名の一致判定の限界（既知）」（Read する場合は「Base directory for this skill」を起点に `<base>/../../scripts/specs/guarantee-index-check.md` として解決する）。

対象が0件だった場合は、**それが「正常に列挙・突き合わせを行った結果の0件」であるときに限り**「検査した結果0件」と報告する（`reverse_check.status: "analyzed"` / `files_checked: 0`）。上流の未解析・`--scope` の git エラー・列挙エラーによって0件になった場合は `not_analyzed` であり、**「0件」と報告してはならない**（検査していないことと、検査して問題が無かったことは別物）。

### Step D5: 報告（drift）

機械可読 JSON と人間向けサマリーの両方を出力する。

機械可読部（呼び出し元が定期実行の結果として消費できるようにする）:

```json
{
  "mode": "drift",
  "scope": "<base>..<head> または null",
  "phase": "gdd",
  "phase_reason": "declared_gdd",
  "index": {
    "status": "pass|fail",
    "error": null,
    "ledger": "docs/guarantees.md",
    "base": "/abs/path/to/repo",
    "counts": { "guarantees": 12, "refs": 15, "gaps": 3, "broken": 0 },
    "broken": []
  },
  "semantic": { "status": "analyzed|not_analyzed", "checked": 12, "drifted": [], "uncertain": [], "failed": [] },
  "reverse_check": { "status": "analyzed|not_analyzed", "files_checked": 40, "extraction_failed": [] },
  "gap_candidates": [{ "test_ref": "...", "behavior_ja": "...", "rationale": "..." }],
  "human_review_required": [{ "kind": "...", "step": "D2|D3|D4", "detail": "..." }]
}
```

**`index` は Step D2 で受け取ったスクリプトの stdout JSON をそのまま格納し、`error` だけを本スキルが足す**（フィールド定義の正本は `scripts/specs/guarantee-index-check.md`。Read する場合は「Base directory for this skill」を起点に `<base>/../../scripts/specs/guarantee-index-check.md` として解決する）:

| フィールド | 意味 |
|---|---|
| `status` | `guarantee-index-check` の判定（`pass` / `fail`）。**検査を実行できなかった場合も `fail`**（`pass` に読み替えない） |
| `error` | 検査を**実行できなかった**場合のみ理由の文字列。正常に検査できた場合（exit 0 / exit 1）は `null` |
| `ledger` / `base` / `counts` | スクリプトの出力をそのまま。**exit 2 では stdout が空のため取得できない。その場合は `null` にする**（`counts` を 0 で埋めない） |
| `broken` | 検出した壊れた索引の一覧。**`error` が非 null のときの空配列は「問題なし」を意味しない**（検査自体が走っていない） |

各ステップの `status` と、それが `not_analyzed` になる条件:

| フィールド | `not_analyzed` になる条件 | そのとき満たすこと |
|---|---|---|
| `index.error`（非 null） | 索引検査を実行できない（Step D2） | `human_review_required` に `kind: "index_error"` |
| `semantic.status` | 台帳を読めない・保証を取り出せない（Step D3） | `checked` は `null`（`0` にしない）。`kind: "ledger_unreadable"` |
| `reverse_check.status` | 上流が未解析／`--scope` の git エラー／列挙エラー（Step D4） | `gap_candidates` は空のまま。`kind` は `not_analyzed` / `scope_error` / `enumeration_error` のいずれか |

上の骨格で空配列として示した各要素の形（人間向けサマリーの表がそのまま参照する）:

| 配列 | 要素の形 | 定義の所在 |
|---|---|---|
| `index.broken` | `{guarantee_id, ref, reason}` | `guarantee-index-check` の出力仕様（Step D2 に記載の spec） |
| `semantic.drifted` / `uncertain` / `failed` | `{guarantee_id, verdict, evidence}` | Step D3 の返却形式 |
| `reverse_check.extraction_failed` | `{path, reason}` | Step D4 の完全性 join |
| `gap_candidates` | `{test_ref, behavior_ja, rationale}` | 上の骨格に記載 |

- `gap_candidates` は **`reverse_check.status` が `analyzed` のときだけ意味を持つ**。`not_analyzed` のときの空配列を「GAP 候補なし」と読ませない。
- `human_review_required[].kind` の語彙: `index_error` / `ledger_unreadable` / `scope_error` / `enumeration_error` / `extraction_failed` / `not_analyzed` / `uncertain`。`step` にはどのステップで生じたか（`D2` / `D3` / `D4`）を入れる。
- **`index.counts.gaps`（台帳に登録済みの GAP 行数）と `gap_candidates` の件数（D4 が新たに検出した候補）は別物**であり、報告でも別の名前で示す。

人間向けサマリー:

```text
## 保証台帳ドリフト監査結果

- 開発フェーズ: {phase}（{phase_reason}）
- 対象範囲: {scope の値 / 「全量」}
- 台帳: `{index.ledger}`（{index.counts ? `保証 ${index.counts.guarantees} 件 / 登録済み GAP ${index.counts.gaps} 件` : "件数は取得できませんでした（索引検査が実行できないため）"}）

### 索引整合（機械チェック）

{index.error ? `⚠️ 未解析（検査を実行できませんでした）: ${index.error}（下表が空でも「問題なし」ではありません。要人間対応）` : (index.status === 'pass' ? '✅ pass' : '❌ fail')}

| 保証ID | 参照 | 問題 |
|---|---|---|
| {guarantee_id} | {ref} | {reason} |

### 意味整合

{semantic.status === 'not_analyzed' ? '⚠️ 未解析（台帳から保証の一覧を取り出せませんでした。要人間対応）' : `${semantic.checked} 件を検証`}

| 保証ID | 判定 | 根拠 |
|---|---|---|
| {guarantee_id} | drifted / uncertain / verification_failed | {evidence} |

（`consistent` は件数のみ記載する）

### GAP 候補（台帳に無い公開面テスト）

{reverse_check.status === 'not_analyzed' ? '⚠️ 未解析（逆方向チェックを実行できませんでした。要人間対応）' : `対象 ${reverse_check.files_checked} ファイルを突き合わせ`}

| テスト参照 | 振る舞い |
|---|---|

### 要人間判定

| 種別 | ステップ | 内容 |
|---|---|---|
| {kind} | {step} | {detail} |

### 総合

- 索引ドリフト: {index.error ? "未解析" : `${index.broken の件数} 件`}
- 意味ドリフト: {semantic.status === 'not_analyzed' ? "未解析" : `${drifted の件数} 件`}
- 検証失敗: {semantic.status === 'not_analyzed' ? "未解析" : `${failed の件数} 件`}（**握りつぶしていません。上表を参照してください**）
- GAP 候補: {reverse_check.status === 'not_analyzed' ? "未解析" : `${gap_candidates の件数} 件`}
- 抽出できなかったファイル: {reverse_check.extraction_failed の件数} 件（この分は突き合わせていません）

**本監査は検出のみです。修正は行っていません。** 検出された項目は Issue を起こし、通常の実装フロー（保証の変更を伴う場合は宣言元 Issue の保証節の更新と再裁可）で対応してください。
```

`drifted` / `uncertain` / `verification_failed` が1件でもあれば、サマリー冒頭に**要対応**である旨を明示する。

**「0件」と「未解析」を書き分けること**（本モード全体で守る規律）: 検査を実施して問題が無かった項目は「0件」、実施できなかった項目は「未解析」と書く。**未解析の項目を 0件・pass・空表として出さない**。`human_review_required` が非空の場合は、サマリー冒頭にも**未解析の項目がある**旨を明示し、この監査結果が網羅的でないことを読み手に分かるようにする。

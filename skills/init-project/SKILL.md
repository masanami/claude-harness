---
name: init-project
description: "プロジェクトを分析してCLAUDE.mdと.claude/settings.jsonを自動生成する。観点ベース（規模/ドメイン/データ/運用/規制 等9軸）で整備すべきドキュメントを選定し、ブランチ戦略も決定する。Triggers on: '/init-project', 'プロジェクト初期設定', 'CLAUDE.mdを作成'"
model: sonnet
# effort: 初期設定の分析・選定が中心のため medium。
effort: medium
---

# プロジェクト初期設定

プロジェクトを自動分析し、`CLAUDE.md` と `.claude/settings.json` を生成します。

---

## 手順

### 1. 既存CLAUDE.mdの確認と健康診断

プロジェクトルートに `CLAUDE.md` が既に存在するか確認する。

- **存在しない場合**: そのまま続行
- **存在する場合**: 既に初期設定済み（＝本スキルの再実行）とみなし、**先に健康診断を実行して結果を提示したうえで**、上書き・マージ・中止を確認する

生成物は harness の更新に自動追従しない。とくに `.claude/settings.json` の allow が現行版の呼び出し形に追従できていないと、**headless 委譲でスクリプト実行が拒否されてスキルが完走できない**。診断はその不足を検出して是正コマンドを提示する。

> **スクリプトの実行形**: `doctor.sh` はプラグイン配下（`scripts/`）にある。実行は PATH 上のランチャー経由で `claude-harness-run doctor --project "<プロジェクトルート>"` を用いる。`claude-harness-run: command not found` になった場合のみ `bash "<プラグインルート>/scripts/doctor.sh" --project "<プロジェクトルート>"` にフォールバックする（パスは引用符で囲む。プラグインルートはスキル起動時の「Base directory for this skill」から解決した絶対パス。`${CLAUDE_PLUGIN_ROOT}` は表記上のプレースホルダであり環境変数ではない）。フォールバックした場合はユーザーにランチャー導入を案内すること。

- stdout に JSON が1個返る。`status` が `fail` のときは blocking の指摘（ランチャー未導入・`Bash(claude-harness-run:*)` の欠落・deny/ask による打ち消し）がある。**この状態のまま初期設定を続けても、以降のスキル実行は拒否され続ける**。`findings[].remediation` のコマンドをそのままユーザーに提示し、実行を促すこと
- `status` が `warn` のときは advisory の指摘のみ（`CLAUDE.md` の節・プレースホルダ・ドキュメントマップ・harness 固有語の混入）。**検出と提示にとどめ、適用はユーザーに委ねる**
- **エージェントは `.claude/settings.json` を書き換えない**（headless ではパス保護、対話 auto mode では分類器が書き込みを拒否する）。診断結果を代わりに適用しようとしないこと
- exit 2 の場合は診断が成立していない。stderr のメッセージを添えて報告し、診断なしで続行してよいかをユーザーに確認する（**指摘0件として扱わないこと**）

> **`claude-harness-run doctor` と `/doctor` は別物**（同名だが役割が違う。混同しないこと）。ここで実行するのは前者＝本プラグイン同梱の `scripts/doctor.sh` で、見るのは**このプラグインを使うための前提**（ランチャー・settings の allow/deny・生成物の追従）である。後者の `/doctor` は **Claude Code 本体のセッション内コマンド**（v2.1.206 以降）で、`CLAUDE.md` が長すぎる場合の **trim 提案**を持つ。**分量の棚卸しは `claude-harness-run doctor` の責務ではない**（行数を見ない）。生成した `CLAUDE.md` が育ってきたら、ユーザーにセッション内で `/doctor` を実行するよう案内する。CLI の `claude doctor` は設定ファイルの health check までで trim は提案しない。

### 2. プロジェクト自動分析

`analyze-project.sh [対象ディレクトリ]`（プラグイン配下。実行形は直後の注記を参照）を実行し、プロジェクト情報を検出する。検出規則（ロックファイル→PM対応、技術スタック判定、コマンド優先順位、除外ディレクトリ、設計ドキュメントglob、9軸の定義・判定ルール等）はすべてスクリプト側に実装されており、決定的に判定される。本セクションではスクリプトの入出力契約と、LLM側が担う補完のみを記す。

> **スクリプトの実行形（重要）**: 本スキルはプラグインとして配布されるため、スクリプトは**ユーザーのプロジェクトroot ではなく、プラグイン配下**にある。スクリプトを実行する際は必ず PATH 上のランチャー経由で `claude-harness-run analyze-project` の形式（パス・バージョン・引用符を付けない。この形だけが `Bash(claude-harness-run:*)` の1行で allowlist できる）を用い、相対パス `scripts/analyze-project.sh` では呼び出さないこと。分析対象ディレクトリ（引数）にはユーザープロジェクトの対象パスを渡す。`claude-harness-run: command not found` になった場合のみ `bash "<プラグインルート>/scripts/analyze-project.sh"` にフォールバックする（パスは引用符で囲む。プラグインルートはスキル起動時の「Base directory for this skill」から解決した絶対パス。`${CLAUDE_PLUGIN_ROOT}` は表記上のプレースホルダであり環境変数ではない）。フォールバックした場合はユーザーにランチャー導入を案内すること。
<!-- 正本: docs/plugin-path-conventions.md -->

- 実行例: `claude-harness-run analyze-project .`
- stdout に JSON が1個返る。トップレベルの `status` が `"ok"` であることを確認する
- `status: "error"`（jq不在・対象ディレクトリ不在等）の場合はエラー内容をユーザーに報告し、手動分析へフォールバックするかを確認する

**出力JSONの主なフィールド**:

| フィールド | 内容 |
|---|---|
| `pm` / `language` | パッケージマネージャ・言語（2a相当） |
| `name` / `nameSource` | プロジェクト名と検出元（2f相当） |
| `stack` | `frontend`/`backend`/`db`/`test`/`infra` の検出配列（2b相当） |
| `commands` | `test`/`lint`/`typecheck`/`format`/`build`/`dev` コマンド（2c相当） |
| `testPrereqs` | セットアップファイル・`pretest` の有無（2c-2相当） |
| `dirTree` | 除外・深さ制限付きディレクトリ構造（2d相当） |
| `docs` | `docsDir` と設計ドキュメント一覧、`adrDir`（設計判断記録の置き場 `docs/adr/` の有無。`*.md` が1件以上あるときのみ非 null。2e相当） |
| `testDirs` / `e2eDirs` | テスト/E2E配置（2e相当） |
| `colocatedTests` | `src/foo.test.ts` のようにテスト対象と同じディレクトリに置く co-located 配置の有無（真偽値、2e相当）。`testDirs` はディレクトリ名ベースの検出のため、co-located 配置はこのフィールドで別途表現する |
| `branchEvidence` | `branches`（`git branch -a`）、`recentMergeStyles`（直近コミットのsquash/merge集計）、`contributingPath` の**証拠のみ**（2g相当）。**戦略の推定・解釈（GitHub Flow既定の採用など）はスクリプトでは行わない。次項の手順で本スキル側が判断する** |
| `axes` | 観点9軸すべての仮判定（2h相当）。各要素は `{axis, name, standing: "auto-yes"\|"auto-no"\|"ask-user", evidence}` |

> 9軸の軸名・判定ルール（どの軸が自動判定/ask-user か）の正本は `scripts/analyze-project.sh` の `build_axes_json` / `fetch_axes` 実装。散文での再掲はしない。出力された各要素の `standing` を見れば `auto-yes`/`auto-no`（検出ベースの仮判定）か `ask-user`（要ユーザー確認）かが判別できる。

#### LLM側の補完

- スクリプトの検出結果が明らかに不足・誤検出している場合（未知フレームワークの誤分類、モノレポでの検出漏れ等）のみ、対象ファイルを直接 Read して補完する
- **スタック検出の補完**: `stack` の `frontend`/`backend`/`db` のいずれかが空、または `package.json` の `dependencies`/`devDependencies`（Node系の場合）に候補外の主要ライブラリが見える場合は、`package.json`（Node系以外は `go.mod`/`Cargo.toml`/`pyproject.toml`/`Gemfile` 等）を直接 Read し、リードの裁量でスタック判定を補う
- **ブランチ戦略の判断**: `branchEvidence` の証拠（`branches`, `recentMergeStyles`, `contributingPath`）から戦略を解釈する
  - `contributingPath` があれば内容を Read してブランチ/コミット規約を確認する
  - `recentMergeStyles` で `squash` が優勢なら squash マージ運用、`merge` が優勢なら merge commit 運用と推定する
  - `branches` から `{type}/{id}-{説明}` 等の命名傾向（プレフィックスの種類、区切り文字）を推定し、既存の慣習に沿った命名規則を採用する
  - 判断材料が乏しい（コミット数が少ない・新規リポジトリ等）場合は既定の **GitHub Flow**（命名 `{type}/{ticket-id}-{説明}`、squash マージ）を採用する
  - いずれの場合も、開発フローの**最小契約「1チケット = 1ブランチ → PR → 必須ゲート通過後にマージ」**を満たすこと
- **テスト前提の補完**: docker-compose 等でテスト環境（DB・外部サービスのモック等）を立てる構成は `testPrereqs` に現れないため、`docker-compose.yml`/`docker-compose.yaml`（`stack.infra` に `docker-compose` があれば存在する）があればサービス定義を Read し、テスト実行に必要な前提として補完する
- `axes` のうち `standing: "ask-user"` の軸は Step 3 でユーザーに問いかける（次項参照）。`auto-yes`/`auto-no` の軸はそのまま仮判定として提示する
- 既に存在が検出された（`docs.designDocs`）ドキュメントは「整備済み」扱いで候補化しない。立っている軸に対応するドキュメントが既存なら、新規作成候補には載せない

> 固定リストの内側に閉じず、軸が立てば**プロジェクト固有のドキュメント**（例: データフロー図、SLO定義、リリース手順）を候補に追加してよい。

### 3. 検出結果の提示と補完

検出結果をまとめてユーザーに提示し、以下を確認・補完する。提示テンプレートは `templates/detection-report.md` を Read し、プレースホルダー（`{detected_name}` 等）を検出結果・分析結果で埋めてユーザーに提示する。

> **参照ファイルの読み出し（重要）**: 参照ファイルは導入先プロジェクトではなく**プラグイン配下**にある。プラグイン配下は導入先プロジェクトの作業ディレクトリの外にあるため、Read ツールでの読み出しは利用側に allow 設定が無いと拒否される（headless 委譲では許可する相手がいないため、既定で読めない）。読み出しは allowlist 済みの配送経路`claude-harness-run read-plugin-doc "skills/init-project/templates/detection-report.md"`（プラグインルート相対パス）で行い、stdout に出た本文を使う。**非0 終了は「読まなくてよかった」ではない** — 本文を得られていないまま手順を推測して続行せず、stderr のメッセージを添えてその場で停止し報告すること（読めないまま完走すると、書式や停止条件だけが外れた成果物が「成功」に見える）。**exit 0 でも終端マーカー `=== read-plugin-doc END ... complete ===` が無ければ本文は完結していない** — `MORE` マーカーが出ていれば示された `--from-line` で続きを取得し、END も MORE も無ければ出力が切り詰められたとみなして同様に停止すること。**BEGIN マーカーの `root=` が「Base directory for this skill」の親ツリー（`<root>/skills/<スキル名>` が Base directory）と一致しなければ、別バージョンの本文が届いている** — ランチャーは同居する最大バージョンを選ぶため旧版 SKILL.md ＋ 新版参照ファイルの混成になりうるので、手順へ進まず同様に停止して報告すること。`=== read-plugin-doc ... ===` の行と `read-plugin-doc:` で始まる行は配送の制御情報であり本文ではない（テンプレートを埋めて書き出す際に成果物へ含めない）。`claude-harness-run: command not found` の場合のみ Read ツールへフォールバックし、スキル起動時にコンテキストへ与えられる「Base directory for this skill」を起点に `<base>/templates/detection-report.md` として解決する（Read も拒否された場合は同様に停止して報告し、ランチャー導入を案内すること）。
<!-- 正本: docs/plugin-path-conventions.md -->

> **ポイント**: 自動判定した軸（DB中心性・API外部公開度・テスト戦略の複雑度）はそのまま提示し、ユーザーは判定不能な軸（規模・複雑度、ドメイン、コード規約、データ、運用、規制）と修正点だけを答えればよい形にする。全項目の逐一確認は避ける。固定リストにない**プロジェクト固有のドキュメント**（例: SLO定義、データフロー図、リリース手順）もここで追加できる。

### 4. テンプレート読み込み & CLAUDE.md 生成

> **参照ファイルの読み出し（重要）**: 参照ファイルは導入先プロジェクトではなく**プラグイン配下**にある。プラグイン配下は導入先プロジェクトの作業ディレクトリの外にあるため、Read ツールでの読み出しは利用側に allow 設定が無いと拒否される（headless 委譲では許可する相手がいないため、既定で読めない）。読み出しは allowlist 済みの配送経路`claude-harness-run read-plugin-doc "skills/init-project/templates/CLAUDE.md.template"`（プラグインルート相対パス）で行い、stdout に出た本文を使う。**非0 終了は「読まなくてよかった」ではない** — 本文を得られていないまま手順を推測して続行せず、stderr のメッセージを添えてその場で停止し報告すること（読めないまま完走すると、書式や停止条件だけが外れた成果物が「成功」に見える）。**exit 0 でも終端マーカー `=== read-plugin-doc END ... complete ===` が無ければ本文は完結していない** — `MORE` マーカーが出ていれば示された `--from-line` で続きを取得し、END も MORE も無ければ出力が切り詰められたとみなして同様に停止すること。**BEGIN マーカーの `root=` が「Base directory for this skill」の親ツリー（`<root>/skills/<スキル名>` が Base directory）と一致しなければ、別バージョンの本文が届いている** — ランチャーは同居する最大バージョンを選ぶため旧版 SKILL.md ＋ 新版参照ファイルの混成になりうるので、手順へ進まず同様に停止して報告すること。`=== read-plugin-doc ... ===` の行と `read-plugin-doc:` で始まる行は配送の制御情報であり本文ではない（テンプレートを埋めて書き出す際に成果物へ含めない）。`claude-harness-run: command not found` の場合のみ Read ツールへフォールバックし、スキル起動時にコンテキストへ与えられる「Base directory for this skill」を起点に `<base>/templates/CLAUDE.md.template` として解決する（Read も拒否された場合は同様に停止して報告し、ランチャー導入を案内すること）。
<!-- 正本: docs/plugin-path-conventions.md -->

本スキルの `templates/CLAUDE.md.template`（上記の解決手順で絶対パスに変換して）を読み込み、検出結果とユーザー入力でプレースホルダーを埋めて `CLAUDE.md` を生成する。生成先の `CLAUDE.md` は**導入先プロジェクトのルート**に書き出す（テンプレートの所在と生成先を混同しないこと）。

#### 生成ルール（分量の規律）

**書くのは 2 種類だけである**: ①**コードベースから導けない判断**（Mock の対象/非対象、マージ戦略、新規ファイルの置き場）と、②**ツール既定と異なる規約**（Conventional Commits、PR 行数上限）。この 2 つに当てはまらないものは書かない。根拠は公式の memory ガイド — `CLAUDE.md` は長いほど**追従率が下がる**ため、`/doctor` の trim チェックは「pitfalls, rationale, conventions that differ from tool defaults」を残し、「content Claude can derive from the codebase, such as directory layouts, dependency lists, and architecture overviews」を削る。

- **次のものは書かない**（Claude がコードベースを読めば導ける。テンプレートにも節が無い）: プロジェクト概要・アーキテクチャ概要／技術スタック・依存一覧／ディレクトリ構成・ドキュメントの一覧／YAGNI・KISS・DRY のような**一般論の開発原則**（ツール既定と異なる規約ではなく、「過度な抽象化を避ける」の類は検証できない曖昧さの典型）。**テンプレートに無い節を足してこれらを書き戻さないこと。**
- **生成物全体で 200 行未満に収める**（公式ガイドの目標値）。超えるなら、まず上の「書かない」側に当たる記述を削る。
- **検証できる具体度で書く**（「コードを整形する」ではなく「インデントは半角スペース2つ」）。埋められない項目は、推測で埋めずに**その行を落とす**（節の見出しは残す）。判断が要る箇所だけコメント付きプレースホルダー（`<!-- TODO: ... -->`）を残す。
- **節どうしを矛盾させない**。同じ事柄（例: テストコマンド）を 2 つの節に別の形で書かない。矛盾があると、どちらが採用されるかは決まらない。
- **ブランチ戦略**: `{BRANCH_STRATEGY}`（既定 GitHub Flow）、`{BRANCH_FORMAT}`、`{MERGE_STRATEGY}`、`{SCOPES}` 等を `branchEvidence` の検出結果・ユーザー指定で埋める
- **`{NEW_FILE_PLACEMENT}`**: 既存構造からは読み取れない置き場の規約だけを 1〜3 行で書く（例:「新しい API ハンドラは `src/routes/` に 1 エンドポイント 1 ファイルで置く」）。既存構造を見れば自明なら `-` と書く。**命名スタイルの表（ファイル名 / 関数 / 定数 …）は書かない** — 既存コードから導ける。
- **`{QUALITY_POLICY}`**: **具体的なゲート**（実行するコマンドと閾値）だけを書く。「品質を保つ」「レビューを重視する」のような散文は書かない。
- **`{COMMON_COMMANDS}`**: 検出結果から、そのプロジェクトで実際に動くコマンドを書く。
- **`{TEST_APPROACH}` / `{MOCK_TARGETS}` / `{NO_MOCK_TARGETS}`**: 何をモックし何をしないかという**判断**を書く（テストの置き場や本数は書かない。導ける）。
- **末尾の `/doctor` 案内の 1 行はそのまま残す**（テンプレート最終行）。これは Claude Code 本体のセッションコマンドの案内であり、次項の「harness 固有語」には当たらない。

> ステップ3 でユーザーが選定した「作成予定」のドキュメントは、**`CLAUDE.md` には書かない**（未実在のパスが常時ロードされるため）。選定結果はステップ5（雛形を作るならファイルそのものが記録になる）とステップ7 の完了報告で伝える。

#### 生成ルール（出所の規律）— harness／プラグイン固有の語を書かない

生成物は**導入先リポジトリの性質**を書く場所である。本プラグインを使うかどうかは「誰が・どのツールで動かすか」＝**オペレータの性質**であり、許可設定を 3 層に割り当てるときと同じ切り分けになる（リポジトリの性質は共有物へ、オペレータの性質は各自の環境へ）。加えて生成物は harness の更新に自動追従しない（ステップ1）ため、混入すると**古いスキル名・古い呼び出し形がプロジェクト側に固定化**する。
<!-- 正本: docs/settings-governance.md -->

- **書かない対象**: ①**スキル名**（`/init-project` `/para-impl` `/quality-check` のようなスラッシュコマンド名） ②**ランチャー名**（`claude-harness-run`）とプラグイン名（`claude-harness` / `claude-flywheel`） ③**プラグイン配下のパス**（`.claude/plugins/...`、`skills/.../scripts/...`、`CLAUDE_PLUGIN_ROOT`） ④**harness のフロー名**（本スキルの手順名・Phase 番号など）。
- **混入経路は自由記述のプレースホルダ**（`{QUALITY_POLICY}` / `{COMMON_COMMANDS}` / `{TEST_APPROACH}` / `{NEW_FILE_PLACEMENT}`）である。品質ゲートやコマンドには、**プロジェクト自身のコマンド**（`npm test` 等）だけを書く。ハーネス経由でしか実行できないコマンドは書かない。
- **プロジェクトが日常的に harness のコマンドを使う場合でも、`CLAUDE.md` には書かない。** 置き場は各オペレータの環境（ユーザー設定・各自の手順書）か、リポジトリの `README`／オンボーディング文書である。`CLAUDE.md` に書くと、harness を使わない参加者にも常時ロードされる。
- **線引き — ステップ7 の完了報告はこの規定の対象外**。あれは**会話に出す案内であって生成物ではない**ため、`/define-feature` `/create-ticket` のようなスキル名を含んでよい。規定が縛るのはファイルに書き出す `CLAUDE.md` と `.claude/settings.json` である。
- 混入は `claude-harness-run doctor` の `claude_md_harness_terms`（advisory）が機械的に検出する。検出語の正本は `skills/init-project/scripts/harness-terms.json`（固定語）と `skills/` 配下のディレクトリ名（スキル名を実行時に導出）。

### 5. 選定ドキュメントの雛形作成（任意）

ユーザーが希望する場合のみ、ステップ3で「作成予定」としたドキュメントの雛形（見出しのみのスケルトン）を標準パスに作成する。

- 雛形作成の要否はユーザーに確認する
- **作成したファイルそのものが記録である。`CLAUDE.md` に一覧を作らない**（ドキュメントの所在は Glob で導ける。未実在パスを書けば、そのパスが常時ロードされ続ける）
- 作成しない場合は**ファイルを残さない**。選定結果はステップ7 の完了報告で伝え、必要なら課題管理（Issue 等）へ残すようユーザーに案内する

### 6. `.claude/settings.json` 生成とユーザー設定向けスニペットの提示

プロジェクトの `.claude/settings.json`（git tracked）は **deny 専用**である。ここに書くのは「そのリポジトリで壊されたくないもの」＝リポジトリの性質であり、誰が動かしても変わらない。deny は trust 承認なしで即座に効き、どの権限モードでも効く。

> **決定（変えない）**: 本スキルは**プロジェクト settings を緩める allow を 1 件も生成しない**（`generate-settings.sh` の `gs_project_allow_json()` は常に `[]` を返す）。緩和はユーザー設定側で行う。この決定は生成物の**出所の規律**（ステップ4 の「harness 固有語を書かない」）と対になっている — どちらも「オペレータの性質をリポジトリへ書き込まない」という同じ切り分けである。
<!-- 正本: docs/settings-governance.md -->

運用上の allow（ランチャー `Bash(claude-harness-run:*)`・git / gh・`cd`・パッケージマネージャ・テストランナー・infra）は**プロジェクト settings には書かない**。それは「誰が・どのマシンで・どの権限モードで動かすか」＝オペレータの性質であり、tracked に置いても trust 未承認のクローンや headless 実行（trust ダイアログが出ない）では評価されない。スクリプトはこれらを**ユーザー設定 `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json` 向けのスニペット**として stdout に出すので、ステップ7 の完了報告でそのまま提示する。ユーザー設定の allow は、そのオペレータのすべてのプロジェクトと worktree（並列実装の worker が動く隔離環境を含む）に効く。**エージェントはユーザー設定を書き換えない**（書き込みは人間が行う）。

権限の合成（deny の生成、スニペット＝共通権限 ＋ pm別/testFW別/infra別の条件付き権限）と、既存ファイルとの冪等マージは本スキルの `scripts/generate-settings.sh` が決定的に行う。本セクションはこのスクリプトの入出力契約と、deny の設計思想（規律文）のみを記す。

> **スクリプトの実行形**: `generate-settings.sh` はプラグイン配下（`skills/init-project/scripts/`）にある。実行は PATH 上のランチャー経由で `claude-harness-run skills/init-project/scripts/generate-settings.sh <引数>` を用いる。`claude-harness-run: command not found` になった場合のみ `bash "<プラグインルート>/skills/init-project/scripts/generate-settings.sh" <引数>` にフォールバックする（パスは引用符で囲む。プラグインルートはスキル起動時の「Base directory for this skill」から解決した絶対パス）。フォールバックした場合はユーザーにランチャー導入を案内すること。

**実行例**（Step 2 の `analyze-project.sh` 出力をそのまま入力にできる）:

```bash
claude-harness-run analyze-project . > /tmp/analyze-output.json
claude-harness-run skills/init-project/scripts/generate-settings.sh \
  --input "/tmp/analyze-output.json" --target ".claude/settings.json"
```

個別の検出結果を明示的に渡すことも可能（`--test` / `--infra` は複数回指定可）:

```bash
claude-harness-run skills/init-project/scripts/generate-settings.sh \
  --pm npm --test playwright --infra docker --target ".claude/settings.json"
```

**引数**:

| 引数 | 内容 |
|---|---|
| `--pm <pm>` | パッケージマネージャ（`analyze-project.sh` の `pm` 出力語彙: npm/yarn/pnpm/bun/cargo/go/pip/bundler。`python`/`ruby` も別名として可） |
| `--test <fw>` | テストフレームワーク（pytest/vitest/jest/playwright）。複数回指定可 |
| `--infra <infra>` | インフラ種別（`docker` を含む文字列。`analyze-project.sh` の `stack.infra` の値もそのまま渡せる）。複数回指定可 |
| `--input <file\|->` | `analyze-project.sh` の出力JSON（`-` で stdin）。`.pm` / `.stack.test[]` / `.stack.infra[]` を抽出し、`--pm`/`--test`/`--infra` と合成する |
| `--target <path>` | 出力先パス（既定: `./.claude/settings.json`） |

**出力**: 成功時のみ stdout に `{"status":"ok","target":"...","created":bool,"merged":bool,"allow_count":N,"deny_count":M,"user_settings_path":"...","user_settings_snippet":{"permissions":{"allow":[...]}}}` を1個出力する。`user_settings_snippet` がユーザー設定向けスニペット、`user_settings_path` はその書き込み先（実行環境の `CLAUDE_CONFIG_DIR` を反映した絶対パス）。失敗時（jq不在・入力JSON不正・既存 `.claude/settings.json` のスキーマ不正・書き込み失敗など）は stdout を空のまま exit 非0とし、エラー内容は stderr の `{"status":"error","error":"..."}` とメッセージで確認する（設定ファイル `base-deny.json` の欠損・スキーマ不正もこの経路に含まれ、その場合はインストール破損として報告する）。

**既存ファイルとの冪等マージ**: `--target` が既に存在する場合、既存の `permissions.allow`/`permissions.deny` を保持しつつ、生成した deny の非重複分のみ追加する（配列は重複排除され、同じ入力で再実行しても差分は出ない）。**既存の allow は削らない**——以前の生成物に運用 allow が残っていても、それを外すかどうかはそのリポジトリの判断に委ねる。存在しない場合は `.claude/` ディレクトリごと新規作成する。

**deny の設計思想**（スクリプトが合成するベース deny の方針。プロジェクトごとの追記判断に使う規律文のためインラインに残す）:

- **取り返しのつく操作はベースに含めない**。`git reset --hard`（reflogで復旧可）、`git branch -D`（reflog）、`gh pr close`（再オープン可）、`chmod` / `chown` などは deny しない。文脈的な危険判断はネイティブ auto-mode の分類器に委ねる。
- **インフラ・デプロイ系はベースに含めない**。`cdk` / `terraform` / `pulumi` / `serverless` / `kubectl` / `docker push` などはプロジェクト依存のため、必要なリポジトリで個別に追記する。
- **プロジェクト依存の削除系**（`gh issue delete`、`gh api -X DELETE`、`curl -X DELETE` など）も同様に、必要に応じて各リポジトリで追記する。

追記が必要な場合（インフラを扱うリポジトリの `terraform destroy` 等）は、スクリプト実行後に `.claude/settings.json` の `permissions.deny` へ手動で追記する。

#### `.gitignore` の確認

`.gitignore` に `.claude/settings.json` が含まれていないことを確認する。含まれている場合はユーザーに警告する（deny が clone 先・worktree に届かず、リポジトリの性質として共有できなくなるため）。

### 7. 完了報告

```
## プロジェクト初期設定 完了

- 生成ファイル: `CLAUDE.md`, `.claude/settings.json`（deny 専用）{生成した雛形ドキュメントがあれば列挙}
- ブランチ戦略: {採用した戦略}
- 整備を推奨したドキュメント: 雛形を作成 {N} 件 / 未作成 {M} 件（未作成分は `CLAUDE.md` には記録していません。必要なら Issue 等へ残してください）

### ユーザー設定に追記する allow（スクリプト出力の `user_settings_snippet` をそのまま載せる）

書き込み先: `{user_settings_path}`（既にファイルがある場合は `permissions.allow` 配列へ要素を足す。配列ごと置き換えない）

```json
{user_settings_snippet}
```

この allow が無いと、headless 実行（`claude -p`）でスキルのスクリプト起動が permission 拒否される。**チームで揃えたい場合も、tracked の `.claude/settings.json` へ手で追記するのは非推奨**——運用 allow の置き場の正本が 2 つになるうえ、tracked の allow は各人が各クローンで trust を承認するまで効かず、headless では永久に効かない。代わりに**リポジトリの README／オンボーディング手順で、各自のユーザー設定への追記を案内する**。
<!-- 正本: docs/settings-governance.md -->

次のステップ:
- 上のスニペットをユーザー設定に追記してください（エージェントは書き換えません）
- `CLAUDE.md` の内容を確認し、必要に応じて手動で調整してください（**追記するときも 200 行未満に保ち、コードベースから導ける内容は書かないでください**。育ってきたらセッション内で `/doctor` を実行すると trim 提案が得られます）
- `.claude/settings.json` の deny を確認し、リポジトリ固有の deny（`terraform destroy` 等）があれば追記してください
- 個人用の追加設定（WebSearch等）は `.claude/settings.local.json` に記載してください
- 「作成予定」のドキュメントは `/define-feature` 等で順次整備してください
- 機能定義を開始するには: /define-feature [テーマ]
- チケットを作成するには: /create-ticket
```

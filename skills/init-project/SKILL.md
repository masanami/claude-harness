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

### 1. 既存CLAUDE.mdの確認

プロジェクトルートに `CLAUDE.md` が既に存在するか確認する。

- **存在する場合**: ユーザーに上書き・マージ・中止を確認する
- **存在しない場合**: そのまま続行

### 2. プロジェクト自動分析

`${CLAUDE_PLUGIN_ROOT}/scripts/analyze-project.sh [対象ディレクトリ]`（所在は直後の注記を参照）を実行し、プロジェクト情報を検出する。検出規則（ロックファイル→PM対応、技術スタック判定、コマンド優先順位、除外ディレクトリ、設計ドキュメントglob、9軸の定義・判定ルール等）はすべてスクリプト側に実装されており、決定的に判定される。本セクションではスクリプトの入出力契約と、LLM側が担う補完のみを記す。

> **スクリプトの所在（重要）**: 本スキルはプラグインとして配布されるため、スクリプトは**ユーザーのプロジェクトroot ではなく、プラグイン配下**にある。スクリプトを実行する際は必ず `bash "${CLAUDE_PLUGIN_ROOT}/scripts/analyze-project.sh"` の形式（`${CLAUDE_PLUGIN_ROOT}` は実行時にプラグインルートへ展開される）を用い、相対パス `scripts/analyze-project.sh` では呼び出さないこと。分析対象ディレクトリ（引数）にはユーザープロジェクトの対象パスを渡す。
<!-- 正本: docs/plugin-path-conventions.md -->

- 実行例: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/analyze-project.sh" .`
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
| `docs` | `docsDir` と設計ドキュメント一覧（2e相当） |
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

> 参照ファイルは導入先プロジェクトではなく**プラグイン配下**にある。Read する際は、スキル起動時にコンテキストへ与えられる「Base directory for this skill」を起点に絶対パスを解決する（例: `<base>/templates/detection-report.md`）。Base directory が得られない場合は Bash で `echo "$CLAUDE_PLUGIN_ROOT"` を実行して絶対パスを組み立てる（Read ツールは環境変数を展開しない）。

> **ポイント**: 自動判定した軸（DB中心性・API外部公開度・テスト戦略の複雑度）はそのまま提示し、ユーザーは判定不能な軸（規模・複雑度、ドメイン、コード規約、データ、運用、規制）と修正点だけを答えればよい形にする。全項目の逐一確認は避ける。固定リストにない**プロジェクト固有のドキュメント**（例: SLO定義、データフロー図、リリース手順）もここで追加できる。

### 4. テンプレート読み込み & CLAUDE.md 生成

> **参照ファイルの所在（重要）**: 参照ファイルは導入先プロジェクトではなく**プラグイン配下**にある。Read する際は、スキル起動時にコンテキストへ与えられる「Base directory for this skill」を起点に絶対パスを解決する（例: `<base>/templates/CLAUDE.md.template`）。
<!-- 正本: docs/plugin-path-conventions.md -->

本スキルの `templates/CLAUDE.md.template`（上記の解決手順で絶対パスに変換して）を読み込み、検出結果とユーザー入力でプレースホルダーを埋めて `CLAUDE.md` を生成する。生成先の `CLAUDE.md` は**導入先プロジェクトのルート**に書き出す（テンプレートの所在と生成先を混同しないこと）。

生成ルール:
- 検出できなかったセクションは適切なデフォルト値またはコメント付きプレースホルダー（`<!-- TODO: ... -->`）を残す
- 該当しないレイヤー（例: フロントエンドのないバックエンドプロジェクト）は「-」と記入
- コマンドセクションは検出結果から具体的なコマンドを記入する
- 品質方針はプロジェクトのレビュー・テスト方針（重視する観点・E2E整備方針・クリティカル箇所）を記入する
- ディレクトリ構成は実際のスキャン結果を記入する
- **ブランチ戦略**: `{BRANCH_STRATEGY}`（既定 GitHub Flow）、`{BRANCH_FORMAT}`、`{MERGE_STRATEGY}`、`{SCOPES}` 等を `branchEvidence` の検出結果・ユーザー指定で埋める
- **ドキュメントマップ（`{DOCUMENT_MAP}`）**: 各行を `| カテゴリ | パス | 状態 |` で埋める
  - 既に存在するドキュメント（`docs.designDocs` 検出）: 状態「整備済み」
  - ユーザーが選定した作成対象（ステップ3）: 状態「作成予定」、パスは規約に沿った標準パス（例: `docs/coding-guidelines.md`）
  - 選定されなかった候補は記載しない

### 4c. 選定ドキュメントの雛形作成（任意）

ユーザーが希望する場合のみ、ステップ3で「作成予定」としたドキュメントの雛形（見出しのみのスケルトン）を標準パスに作成し、CLAUDE.md のドキュメントマップの状態を「整備済み」に更新する。

- 作成しない場合は「作成予定」として記録のみ（後で `/define-feature` 等で整備）
- 雛形作成の要否はユーザーに確認する

### 4b. `.claude/settings.json` 生成

並列実装（star 型）の各 worker はworktree隔離環境で動作するため、`.claude/settings.json`（git tracked）にBash権限を設定する必要がある。`.claude/settings.local.json`（gitignored）はworktreeにコピーされないため、ここに権限を記載してもworktree内のエージェントに適用されない。

権限の合成（共通権限 ＋ pm別/testFW別/infra別の条件付き権限）と、既存ファイルとの冪等マージは本スキルの `scripts/generate-settings.sh` が決定的に行う。本セクションはこのスクリプトの入出力契約と、deny の設計思想（規律文）のみを記す。

> **スクリプトの所在**: `${CLAUDE_PLUGIN_ROOT}/skills/init-project/scripts/generate-settings.sh` を参照すること。

**実行例**（Step 2 の `analyze-project.sh` 出力をそのまま入力にできる）:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analyze-project.sh" . > /tmp/analyze-output.json
bash "${CLAUDE_PLUGIN_ROOT}/skills/init-project/scripts/generate-settings.sh" \
  --input /tmp/analyze-output.json --target .claude/settings.json
```

個別の検出結果を明示的に渡すことも可能（`--test` / `--infra` は複数回指定可）:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/init-project/scripts/generate-settings.sh" \
  --pm npm --test playwright --infra docker --target .claude/settings.json
```

**引数**:

| 引数 | 内容 |
|---|---|
| `--pm <pm>` | パッケージマネージャ（`analyze-project.sh` の `pm` 出力語彙: npm/yarn/pnpm/bun/cargo/go/pip/bundler。`python`/`ruby` も別名として可） |
| `--test <fw>` | テストフレームワーク（pytest/vitest/jest/playwright）。複数回指定可 |
| `--infra <infra>` | インフラ種別（`docker` を含む文字列。`analyze-project.sh` の `stack.infra` の値もそのまま渡せる）。複数回指定可 |
| `--input <file\|->` | `analyze-project.sh` の出力JSON（`-` で stdin）。`.pm` / `.stack.test[]` / `.stack.infra[]` を抽出し、`--pm`/`--test`/`--infra` と合成する |
| `--target <path>` | 出力先パス（既定: `./.claude/settings.json`） |

**出力**: 成功時のみ stdout に `{"status":"ok","target":"...","created":bool,"merged":bool,"allow_count":N,"deny_count":M}` を1個出力する。失敗時（jq不在・入力JSON不正・既存 `.claude/settings.json` のスキーマ不正・書き込み失敗など）は stdout を空のまま exit 非0とし、エラー内容は stderr の `{"status":"error","error":"..."}` とメッセージで確認する。

**既存ファイルとの冪等マージ**: `--target` が既に存在する場合、既存の `permissions.allow`/`permissions.deny` を保持しつつ、生成した allow/deny の非重複分のみ追加する（配列は重複排除され、同じ入力で再実行しても差分は出ない）。存在しない場合は `.claude/` ディレクトリごと新規作成する。

**deny の設計思想**（スクリプトが合成するベース deny の方針。プロジェクトごとの追記判断に使う規律文のためインラインに残す）:

- **取り返しのつく操作はベースに含めない**。`git reset --hard`（reflogで復旧可）、`git branch -D`（reflog）、`gh pr close`（再オープン可）、`chmod` / `chown` などは deny しない。文脈的な危険判断はネイティブ auto-mode の分類器に委ねる。
- **インフラ・デプロイ系はベースに含めない**。`cdk` / `terraform` / `pulumi` / `serverless` / `kubectl` / `docker push` などはプロジェクト依存のため、必要なリポジトリで個別に追記する。
- **プロジェクト依存の削除系**（`gh issue delete`、`gh api -X DELETE`、`curl -X DELETE` など）も同様に、必要に応じて各リポジトリで追記する。

追記が必要な場合（インフラを扱うリポジトリの `terraform destroy` 等）は、スクリプト実行後に `.claude/settings.json` の `permissions.deny` へ手動で追記する。

#### `.gitignore` の確認

`.gitignore` に `.claude/settings.json` が含まれていないことを確認する。含まれている場合はユーザーに警告する（worktreeで権限が効かなくなるため）。

### 5. 完了報告

```
## プロジェクト初期設定 完了

- 生成ファイル: `CLAUDE.md`, `.claude/settings.json`{生成した雛形ドキュメントがあれば列挙}
- ブランチ戦略: {採用した戦略}
- ドキュメント: 整備済み {N} 件 / 作成予定 {M} 件

次のステップ:
- `CLAUDE.md` の内容を確認し、必要に応じて手動で調整してください
- `.claude/settings.json` の権限設定（allow/deny）を確認してください
- 個人用の追加設定（WebSearch等）は `.claude/settings.local.json` に記載してください
- 「作成予定」のドキュメントは `/define-feature` 等で順次整備してください
- 機能定義を開始するには: /define-feature [テーマ]
- チケットを作成するには: /create-ticket
```

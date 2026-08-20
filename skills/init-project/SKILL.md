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

`CLAUDE.md` が既に存在する場合は、続けて**現在の開発フェーズ宣言**を取得する（既存の宣言を Step 4 の生成で取りこぼさないため）。

> **開発フェーズの判定（重要）**: フェーズは必ず `claude-harness-run detect-dev-phase` の出力だけで判定し、`CLAUDE.md` を自分で grep しないこと（判定規約の重複実装を防ぐため）。stdout に `{"phase":"sdd"|"gdd"|"invalid","reason":"...","source":"..."}` が1個返る。フェーズ依存の追加挙動は **`phase` が `gdd` のときだけ**行い、`sdd`（宣言なしを含む）では一切挙動を変えない。**`phase` が `invalid`（exit 1）、またはスクリプトを実行できない・stdout が JSON としてパースできない（exit 2 等）場合は、`sdd` とみなさない**。フェーズ依存の処理を停止し、`reason` と `source`（および stderr のメッセージ）を添えて「要人間判定」としてユーザーに報告すること（不正な宣言や実行失敗によって GDD のゲート群が暗黙に無効化される事故を防ぐため）。`claude-harness-run: command not found` の場合のみ `bash "<プラグインルート>/scripts/detect-dev-phase.sh"` にフォールバックする（パスは引用符で囲む。プラグインルートはスキル起動時の「Base directory for this skill」から解決した絶対パス。`${CLAUDE_PLUGIN_ROOT}` は表記上のプレースホルダであり環境変数ではない）。
<!-- 正本: docs/ai-driven-development-strategy.md 5.2 / docs/plugin-path-conventions.md -->

本スキルでの使い方（`reason` で「宣言あり」と「宣言なし」を区別する）:

| `phase` / `reason` | 扱い |
|---|---|
| `gdd` / `declared_gdd`、`sdd` / `declared_sdd` | 既に人間が宣言している。**その値を維持する**（Step 3 では確定値として提示するだけで、変更を促さない） |
| `sdd` / `no_phase_section`（宣言なし） | 未宣言。Step 3 の確認対象（既定は SDD期） |
| `invalid`（exit 1） | 宣言が壊れている。**SDD期 とみなさず**、`reason` を添えてユーザーに修正を促し、フェーズ節の生成を進めない（他の生成物の作業を続けるかはユーザーの判断を仰ぐ） |
| 実行前提の欠落（exit 2）・スクリプトを実行できない・stdout が JSON としてパースできない | 同じく**SDD期 とみなさない**。ただし **exit 2 では stdout が空で `reason` / `source` が得られない**ため、代わりに次を控えて Step 3・Step 7 の報告に使う: (a) **stderr のエラーメッセージ**（jq 不在・引数不正・指定パスが読めない 等）、(b) **実際に判定を試みた対象**（引数を渡していなければ「cwd の `CLAUDE.md`、無ければリポジトリルートの `CLAUDE.md`」）、(c) **想定される修正手順**（jq の導入・`claude-harness-run` の導入／フォールバック実行・パスの指定）。「`reason` が無いので報告しない」としない |

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
| `docs` | `docsDir` と設計ドキュメント一覧、`guaranteesLedger`（保証台帳 `docs/guarantees.md` の有無）、`adrDir`（設計判断記録の置き場 `docs/adr/` の有無。`*.md` が1件以上あるときのみ非 null。2e相当） |
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

> 参照ファイルは導入先プロジェクトではなく**プラグイン配下**にある。Read する際は、スキル起動時にコンテキストへ与えられる「Base directory for this skill」を起点に絶対パスを解決する（例: `<base>/templates/detection-report.md`）。

> **ポイント**: 自動判定した軸（DB中心性・API外部公開度・テスト戦略の複雑度）はそのまま提示し、ユーザーは判定不能な軸（規模・複雑度、ドメイン、コード規約、データ、運用、規制）と修正点だけを答えればよい形にする。全項目の逐一確認は避ける。固定リストにない**プロジェクト固有のドキュメント**（例: SLO定義、データフロー図、リリース手順）もここで追加できる。

#### 開発フェーズの確定

CLAUDE.md に出力する「開発フェーズ」（`SDD期` / `GDD期` の2値）をここで確定する。**検出結果の提示には、フェーズの値だけでなく Step 1 で得た `reason` と `source` も必ず載せる**（ユーザーが「何を根拠にその値になったか」を見て訂正できるようにするため）。

| Step 1 の判定 | Step 3 での扱い |
|---|---|
| `declared_sdd` / `declared_gdd`（既存の宣言あり） | **その値を維持**する。確定値として提示するだけで、変更を促さない。**上書き生成・マージ・再実行のいずれでも、またユーザーから切り替えを要望された場合でも、本スキルはフェーズ値を書き換えない**（切り替えは宣言1行の編集ではなく駆動文書の移行手順一式のため。要望を受けたら「保証台帳の用意 → 裁可 → 機能仕様の退役 → ドキュメントマップ更新」を人間が別途行う運用であることを案内し、この実行では既存値を維持する） |
| 宣言なし（`no_phase_section` / `no_claude_md`）かつ `docs.guaranteesLedger` が null | **`SDD期`**（既定）。機能仕様 `docs/features/{slug}.md` を駆動文書とする従来の運用。提示に含めてユーザーが訂正できる形にすれば足り、逐一質問はしない（訂正が無ければ承認とみなす） |
| 宣言なしかつ `docs.guaranteesLedger` が非 null（保証台帳が既にある） | **`GDD期` を候補として提示し、ユーザーの明示的な同意を得る**。同意が得られない・回答が無い場合は `SDD期` とする |
| `invalid`（判定スクリプトの実行失敗・JSON パース不能を含む） | **既定値を選ばない**。`SDD期` として扱わず「要人間判定」として `reason` / `source` とともに提示し、フェーズ節の生成を保留する（Step 4 でフェーズ節を出力しない） |

- **`GDD期`（ゲートが増える方向）への確定だけは明示同意を必須**とし、現状維持（`SDD期`）には確認ゲートを増やさない
- **台帳ファイルの存在をフェーズの自動判定に使わない**。これはユーザーへ提示する推奨値の算出にのみ使う材料であり、フェーズを確定できるのは人間が CLAUDE.md に記載する宣言だけである（エージェントが勝手にフェーズを切り替えない）

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
- **開発フェーズ**: `{DEV_PHASE}` に Step 3 で確定した値（`SDD期` または `GDD期`）を、`{DRIVING_DOC}` に対応する駆動文書のパス（SDD期: `docs/features/`、GDD期: `docs/guarantees.md`。CLAUDE.md 側で別パスを採用する場合はそれ）を入れる
  - **プレースホルダのまま残さない**。`{DEV_PHASE}` が未置換だとフェーズ判定が `invalid`（`unreplaced_placeholder`）になり、以降のフェーズ依存処理が停止する
  - 既存 CLAUDE.md への上書き生成・マージの場合は、Step 1 で取得した既存の宣言をそのまま維持する（ユーザーの要望があっても本スキルではフェーズ値を書き換えない。Step 3 の表を参照）
  - **Step 3 で「要人間判定」になった場合（`invalid` 等）は、フェーズ節をテンプレートごと出力しない**（`SDD期` を書き込んで既存の不正宣言を上書き・隠蔽しない）。完了報告でフェーズが未確定である旨と修正手順を伝える
  - `GDD期` を書き込んでよいのは、既存宣言が `declared_gdd` の場合か、Step 3 でユーザーの明示的な同意を得た場合のみ
- **ドキュメントマップ（`{DOCUMENT_MAP}`）**: 各行を `| カテゴリ | パス | 状態 |` で埋める
  - 既に存在するドキュメント（`docs.designDocs` 検出）: 状態「整備済み」
  - ユーザーが選定した作成対象（ステップ3）: 状態「作成予定」、パスは規約に沿った標準パス（例: `docs/coding-guidelines.md`）
  - 選定されなかった候補は記載しない
  - **設計判断記録（ADR）**: `docs.adrDir` が非 null のときだけ `| 設計判断記録 | docs/adr/ | 整備済み |` の行を足す。**null のときは行を作らない**（「作成予定」にもしない）。ADR は恒常的な設計決定が発生したときに1件ずつ増えるオンデマンドの記録であり、初期設定で空の受け皿を用意してもエージェントの Glob/Grep に露出するだけで中身が無い。最初の1件が作られた時点で `/create-adr` がこの行を追加する

### 5. 選定ドキュメントの雛形作成（任意）

ユーザーが希望する場合のみ、ステップ3で「作成予定」としたドキュメントの雛形（見出しのみのスケルトン）を標準パスに作成し、CLAUDE.md のドキュメントマップの状態を「整備済み」に更新する。

- 作成しない場合は「作成予定」として記録のみ（後で `/define-feature` 等で整備）
- 雛形作成の要否はユーザーに確認する

### 6. `.claude/settings.json` 生成

並列実装（star 型）の各 worker はworktree隔離環境で動作するため、`.claude/settings.json`（git tracked）にBash権限を設定する必要がある。`.claude/settings.local.json`（gitignored）はworktreeにコピーされないため、ここに権限を記載してもworktree内のエージェントに適用されない。

権限の合成（共通権限 ＋ pm別/testFW別/infra別の条件付き権限）と、既存ファイルとの冪等マージは本スキルの `scripts/generate-settings.sh` が決定的に行う。本セクションはこのスクリプトの入出力契約と、deny の設計思想（規律文）のみを記す。

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

**出力**: 成功時のみ stdout に `{"status":"ok","target":"...","created":bool,"merged":bool,"allow_count":N,"deny_count":M}` を1個出力する。失敗時（jq不在・入力JSON不正・既存 `.claude/settings.json` のスキーマ不正・書き込み失敗など）は stdout を空のまま exit 非0とし、エラー内容は stderr の `{"status":"error","error":"..."}` とメッセージで確認する（設定ファイル `base-deny.json` の欠損・スキーマ不正もこの経路に含まれ、その場合はインストール破損として報告する）。

**既存ファイルとの冪等マージ**: `--target` が既に存在する場合、既存の `permissions.allow`/`permissions.deny` を保持しつつ、生成した allow/deny の非重複分のみ追加する（配列は重複排除され、同じ入力で再実行しても差分は出ない）。存在しない場合は `.claude/` ディレクトリごと新規作成する。

**deny の設計思想**（スクリプトが合成するベース deny の方針。プロジェクトごとの追記判断に使う規律文のためインラインに残す）:

- **取り返しのつく操作はベースに含めない**。`git reset --hard`（reflogで復旧可）、`git branch -D`（reflog）、`gh pr close`（再オープン可）、`chmod` / `chown` などは deny しない。文脈的な危険判断はネイティブ auto-mode の分類器に委ねる。
- **インフラ・デプロイ系はベースに含めない**。`cdk` / `terraform` / `pulumi` / `serverless` / `kubectl` / `docker push` などはプロジェクト依存のため、必要なリポジトリで個別に追記する。
- **プロジェクト依存の削除系**（`gh issue delete`、`gh api -X DELETE`、`curl -X DELETE` など）も同様に、必要に応じて各リポジトリで追記する。

追記が必要な場合（インフラを扱うリポジトリの `terraform destroy` 等）は、スクリプト実行後に `.claude/settings.json` の `permissions.deny` へ手動で追記する。

#### `.gitignore` の確認

`.gitignore` に `.claude/settings.json` が含まれていないことを確認する。含まれている場合はユーザーに警告する（worktreeで権限が効かなくなるため）。

### 7. 完了報告

```
## プロジェクト初期設定 完了

- 生成ファイル: `CLAUDE.md`, `.claude/settings.json`{生成した雛形ドキュメントがあれば列挙}
- ブランチ戦略: {採用した戦略}
- 開発フェーズ: {SDD期|GDD期|未確定（要人間判定）}
  {未確定の場合のみ: 判定結果が得られた場合（exit 1）は `reason` と `source`、判定自体が実行できなかった場合（exit 2・実行不能・JSON パース不能）は **stderr のエラーメッセージ・判定を試みた対象（引数指定パス、または cwd／リポジトリルートの `CLAUDE.md`）・修正手順**を必ず添える。フェーズ節は生成していない旨も明記する}
- ドキュメント: 整備済み {N} 件 / 作成予定 {M} 件

次のステップ:
- `CLAUDE.md` の内容を確認し、必要に応じて手動で調整してください
- `.claude/settings.json` の権限設定（allow/deny）を確認してください
- 個人用の追加設定（WebSearch等）は `.claude/settings.local.json` に記載してください
- 「作成予定」のドキュメントは `/define-feature` 等で順次整備してください
- 機能定義を開始するには: /define-feature [テーマ]
- チケットを作成するには: /create-ticket
```

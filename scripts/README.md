# scripts/ 共通規約

`scripts/` 配下の gh 系（GitHub CLI を叩いて決定的な処理を行う）スクリプトが従う共通規約。下表のスクリプトについては、入出力仕様（正本）を `scripts/specs/` 配下にスクリプト単位で分割してある。参照するスキルは該当specファイル1本だけをReadすればよく、本ファイル全文（旧450行）を読む必要はない。表に無いスクリプト（analyze-project.sh 等、スキルから参照されない補助スクリプト）は、従来どおり各スクリプト自身のヘッダコメントが仕様を兼ねる。1スクリプトを複数スキルが束ねて参照する場合や、密接に関連する複数スクリプト（例: 取得/更新のペア）は1つのspecファイルにまとめる。

| スクリプト | 仕様ファイル |
|---|---|
| pr-merge-preflight.sh | `scripts/specs/pr-merge-preflight.md` |
| quality-check-runner.sh | `scripts/specs/quality-check-runner.md` |
| extract-acceptance-criteria.sh / check-e2e-traceability.sh | `scripts/specs/extract-acceptance-criteria.md` |
| collect-review-diff.sh / extract-hunk.sh | `scripts/specs/collect-review-diff.md` |
| spec-lint.sh | `scripts/specs/spec-lint.md` |
| mutation-run.sh | `scripts/specs/mutation-run.md` |
| collect-promotion-context.sh / check-subtask-completion.sh | `scripts/specs/collect-promotion-context.md` |
| fetch-pr-comments.sh / reply-and-resolve.sh | `scripts/specs/fetch-pr-comments.md` |
| ci-wait.sh | `scripts/specs/ci-wait.md` |
| worktree-setup.sh / worktree-cleanup.sh | `scripts/specs/worktree-setup.md` |
| demo-e2e-out.sh | `scripts/specs/demo-e2e-out.md` |
| promotion-decision.sh | `scripts/specs/promotion-decision.md` |
| list-test-files.sh | `scripts/specs/list-test-files.md` |
| read-plugin-doc.sh | `scripts/specs/read-plugin-doc.md` |
| retirement-sweep.sh | `scripts/specs/retirement-sweep.md` |
| codex-review-runner.sh | `scripts/specs/codex-review-runner.md` |
| codex-task-runner.sh | `scripts/specs/codex-task-runner.md` |
| doctor.sh | `scripts/specs/doctor.md` |

プラグイン内ファイル参照（Bash実行・Read・サブエージェント受け渡し等）のパス解決規約は `docs/plugin-path-conventions.md` を参照。本ファイルは scripts/ 配下の実装規約のみを扱う。

スキルからのスクリプト実行は、`bin/claude-harness-run`（PATH 上へ導入するランチャー）経由で `claude-harness-run <スクリプト名> <引数>` の形で行う。ランチャー自身の契約・セットアップ手順・permission allowlist の実測記録は `docs/script-launcher.md` が正本。`scripts/` に新しいスクリプトを追加した場合、`scripts/` 直下の `*.sh` は追加設定なしでランチャーの target になる（`claude-harness-run <ファイル名から .sh を除いたもの>`）。

## 前提

- bash + jq を前提とする
- jq 不在時のフォールバック方針は `format-on-save.sh` の防御的スタイルを踏襲する
  - フックのように「機能をスキップしても実害が小さい」処理は、jq 無しでも簡易パース（`sed` 等）で動かしてよい
  - `extract-acceptance-criteria.sh` のように JSON 構築そのものが本質のスクリプトは jq 必須とし、**jq 不在時は明示的なエラー JSON を stderr に併記した上で exit 非0**（無言でクラッシュしない・スタックトレースを吐かない）

## 出力規約

- **stdout には JSON を1個だけ出力する**。人間向けメッセージ（進捗・エラー詳細）は stderr に出す
- 成否は **exit code** で表現する。加えて JSON 側にも機械可読なステータスフィールドを含め、呼び出し元が exit code とJSONの両方から判定できるようにする
- 「特定できなかった」「対象外だった」は暗黙の空配列・空文字ではなく、**明示的なステータスフィールド**で返す（例: `parse_status: "no_checklist_found"`）。呼び出し側の LLM がこれを見てフォールバック挙動（別手段での抽出など）を判断できるようにするため
- **例外**: 成果物が機械可読なステータスではなく**モデルが読む本文そのもの**であるスクリプト（`read-plugin-doc.sh`）は、stdout へ本文をそのまま出す。JSON 文字列としてエスケープすると読み手にとって著しく劣化するため。この場合も成否は exit code と stderr で表し、機械可読ステータスと内容を分離するという趣旨自体は満たす（`scripts/specs/read-plugin-doc.md`）

## quality-check との整合

`skills/quality-check/SKILL.md` の機械可読 JSON（`{result, auto_fix, gates:{lint:{status,errors,...}, ...}}`）と同じ思想＝**機械可読ステータス（exit code / JSON フィールド）と人間向け詳細（stderr メッセージ）を分離する**、という設計を踏襲する。

## テスト

- gh API 等の外部呼び出しを行う処理と、入力（本文テキスト等）から出力（JSON）を組み立てる純粋なパース処理は**関数として分離**する
- パース関数はスクリプトを `source` して直接呼び出すことで、外部コマンドを叩かずに単体テストできる作りにする
- テストは `scripts/tests/` 配下に bash スクリプトとして置き、`bash scripts/tests/xxx.sh` で実行できるようにする。失敗時は非0 exit で終了し、要約を出力する
- スクリプトを `source` するテストファイルは、スクリプト側が定義するグローバル変数（例: `SCRIPT_DIR`）と名前が衝突しないよう注意する。衝突すると `source` 時にテスト側の変数が上書きされる。スクリプト側は極力スクリプト固有の変数名（例: `PR_MERGE_PREFLIGHT_DIR`）を使う
- **macOS 標準の awk（BWK awk）は、非 ASCII 文字列の `==` / `!=` を誤って真にする**（実測: `awk 'BEGIN{print ("「あ」" == "「い」")}'` が `1` を返す。数値でない文字列どうしが数値比較に倒れる）。**日本語を含む文字列の一致判定に awk の `==` を使わないこと**——別物どうしが一致と判定され、テストが黙って通る。文字列一致は `grep -F` / `grep -Fx` / `cmp` / `diff`（いずれもバイト厳密）で行い、awk は行番号の算出・正規表現マッチ・`index()` に留める（`index()` と正規表現マッチは正しく動くことを実測済み）
- 外部呼び出し関数をテストからスタブ関数で上書きする場合、`command_substitution="$(fn)"` 経由の呼び出しはサブシェルで実行されるため、スタブ内でのプレーンな変数インクリメントは呼び出し元へ伝搬しない（戻り値/stdout は伝搬する）。呼び出し回数などをテストで検証したい場合は一時ファイル等サブシェルを跨げる手段を使う
- **手順書（`docs/`・`README.md`・`CHANGELOG.md`）に載せるシェルスニペットは、想定する実行環境の条件を有効にして実行し検証する。** 対話シェルで動いたことは、その手順が想定している環境で動くことの証明にならない——**対話シェルは errexit が無効**なため、`set -e` 前提の CI 向け手順に混ざった欠陥をそのまま通す。実測で2件見つかった: (a) `cmd` を裸で置いて次行で `$?` を読む形は、非0 終了の時点でシェルが終わり**分岐へ到達しない**（`|| status=$?` で受ける。受け先の初期化を忘れない）、(b) `VAR="$(cmd)"` の単純代入は**コマンド置換の失敗でそのまま中断する**（`$(cmd || true)` にする）。検証は**スニペットを文書から機械的に抜き出して**行う（書き写すと、直したのは手元のコピーだけで文書は古いまま、という取りこぼしが起きる）
- git操作そのものを検証する必要があるスクリプト（`collect-review-diff.sh` 等）は、gh呼び出しのみ引数明示でスキップし、git操作は `mktemp -d` で作った一時gitリポジトリ上で実際に実行して検証する（モックでは merge-base 算出やintent-to-addの実効果を検証できないため）。テスト終了時は `trap cleanup EXIT` で一時ディレクトリを確実に削除する

## 設定ファイル

- 特定スクリプトが参照する設定の正本（例: sensitive パスパターン）は `scripts/config/` 配下に置く
  - `scripts/config/sensitive-paths.txt`: `pr-merge-preflight.sh` の risk 判定（`touches_sensitive`）が参照する glob パターン一覧。1行1パターン、`#` はコメント行。欠損時の挙動は `scripts/specs/pr-merge-preflight.md` を参照

---
name: create-ticket
description: "機能仕様ドキュメントから要件チケットを作成、または親要件チケットを実装チケット群に分解する。入力で動作が切り替わる。Triggers on: '/create-ticket', 'チケットを作成', 'Issueを作って', 'create ticket', '実装チケットに分解'"
argument-hint: "<機能仕様ドキュメントパス | 親Issue番号> [--base <統合ブランチ>]"
model: sonnet
# effort: 仕様→チケット分解が中心のため medium。
effort: medium
---

# チケット作成

GitHub Issue を作成します。入力に応じて動作が切り替わります。

---

## 入力で動作切替

| 入力 | モード | 動作 | 出力 |
|---|---|---|---|
| **機能仕様ドキュメントパス**（例: `docs/features/auth.md`） | **要件モード** | 機能仕様を読み、親要件チケットを作成 | Issue 1件（`requirement` ラベル付与） |
| **親Issue番号**（例: `42`, `#42`） | **実装分解モード** | 親要件チケット本文を読み、実装タスクへ分解 | Issue N件（`Parent: #42` 付与、依存関係付き） |

`$ARGUMENTS` を上記ルールで判定する:

- まず `--base <統合ブランチ>` オプションがあれば切り出して保持し、残りを主引数として判定する
- パス区切り `/` を含む、または `.md` 拡張子で終わる → 要件モード
- 純粋な数値（先頭の `#` は除く）→ 実装分解モード
- いずれにも該当しない → エラー、ユーザーに入力の確認を求める

### `--base <統合ブランチ>`（統合ブランチ方式）

**実装分解モードでのみ有効**。指定すると、分解した各実装チケットに **base 統合ブランチ**（例 `feat/issue-42`）を記録する。後続の `/para-impl` はこの base を読み取り、サブタスク PR の宛先を統合ブランチにする（`main` を触らず自律実行）。

- ねらい: 親 Issue 単位の統合ブランチにサブタスクを集約し、既定ブランチ（通常 `main`）を常に本番安全に保つ。統合ブランチへのマージは本番影響がなく可逆のため自律実行でき、人間の承認は「統合 → 既定ブランチへの昇格」の一点に集約される。
- 未指定時は従来どおり base = リポジトリの既定ブランチ（通常 `main`）を前提とする（各チケットに base 記録は付けない）。
- **要件モードで指定された場合は無視**し、次の標準メッセージでユーザーに知らせる:
  > 注意: `--base` オプションは実装分解モードでのみ有効です。要件モードでは無視されます。

---

## モード別の参照ファイル

> **参照ファイルの読み出し（重要）**: 参照ファイルは導入先プロジェクトではなく**プラグイン配下**にある。プラグイン配下は導入先プロジェクトの作業ディレクトリの外にあるため、Read ツールでの読み出しは利用側に allow 設定が無いと拒否される（headless 委譲では許可する相手がいないため、既定で読めない）。読み出しは allowlist 済みの配送経路`claude-harness-run read-plugin-doc "skills/create-ticket/references/requirement-mode.md"`（プラグインルート相対パス）で行い、stdout に出た本文を使う。**非0 終了は「読まなくてよかった」ではない** — 本文を得られていないまま手順を推測して続行せず、stderr のメッセージを添えてその場で停止し報告すること（読めないまま完走すると、書式や停止条件だけが外れた成果物が「成功」に見える）。`claude-harness-run: command not found` の場合のみ Read ツールへフォールバックし、スキル起動時にコンテキストへ与えられる「Base directory for this skill」を起点に `<base>/references/requirement-mode.md` として解決する（Read も拒否された場合は同様に停止して報告し、ランチャー導入を案内すること）。
<!-- 正本: docs/plugin-path-conventions.md -->

モード判定後、該当する参照ファイルを Read し、その手順に従う:

| モード | 参照ファイル |
|---|---|
| 要件モード | `${CLAUDE_PLUGIN_ROOT}/skills/create-ticket/references/requirement-mode.md` |
| 実装分解モード | `${CLAUDE_PLUGIN_ROOT}/skills/create-ticket/references/decompose-mode.md` |

---

## 開発フェーズの判定（GDD期のみ追加挙動）

モード判定後、モード別参照ファイルを Read する前に、開発フェーズ（SDD期 / GDD期）を判定する。GDD期のプロジェクトでは Issue に保証節・裁可ラベル・保証参照行が加わるため、先に判定する。

> **開発フェーズの判定（重要）**: フェーズは必ず `claude-harness-run detect-dev-phase` の出力だけで判定し、`CLAUDE.md` を自分で grep しないこと（判定規約の重複実装を防ぐため）。stdout に `{"phase":"sdd"|"gdd"|"invalid","reason":"...","source":"..."}` が1個返る。フェーズ依存の追加挙動は **`phase` が `gdd` のときだけ**行い、`sdd`（宣言なしを含む）では一切挙動を変えない。**`phase` が `invalid`（exit 1）、またはスクリプトを実行できない・stdout が JSON としてパースできない（exit 2 等）場合は、`sdd` とみなさない**。フェーズ依存の処理を停止し、`reason` と `source`（および stderr のメッセージ）を添えて「要人間判定」としてユーザーに報告すること（不正な宣言や実行失敗によって GDD のゲート群が暗黙に無効化される事故を防ぐため）。`claude-harness-run: command not found` の場合のみ `bash "<プラグインルート>/scripts/detect-dev-phase.sh"` にフォールバックする（パスは引用符で囲む。プラグインルートはスキル起動時の「Base directory for this skill」から解決した絶対パス。`${CLAUDE_PLUGIN_ROOT}` は表記上のプレースホルダであり環境変数ではない）。
<!-- 正本: docs/ai-driven-development-strategy.md 5.2 / docs/plugin-path-conventions.md -->

判定結果ごとの扱い:

| `phase` | 扱い |
|---|---|
| `sdd`（exit 0） | GDD期の追加手順を**一切実行しない**（保証節・裁可ラベル・保証参照行のいずれも足さない）。モード別参照ファイルの手順だけを行い、**本スキルの挙動・作成される Issue・報告は従来と完全に同一** |
| `gdd`（exit 0） | モード別参照ファイルに加えて後述の GDD 参照ファイルを Read し、その手順を上乗せする |
| `invalid`（exit 1）／スクリプト実行不能・stdout が JSON としてパース不能 | **Issue を1件も作成せずに中断**し、`reason`・`source`・stderr のメッセージを添えて「要人間判定」として報告する。`sdd` に読み替えない（不正な宣言や実行失敗によって GDD のゲート群が暗黙に無効化される事故を防ぐ。宣言の修正は人間の責務であり、エージェントが `CLAUDE.md` を書き換えて解消しない） |

`gdd` の場合に Read する参照ファイル（モード別参照ファイルと**両方**読む。置き換えではない）:

| 対象 | 参照ファイル | 内容 |
|---|---|---|
| GDD期の保証節・裁可ラベル | `${CLAUDE_PLUGIN_ROOT}/skills/create-ticket/references/guarantee-section.md` | 前提の確認（満たさなければ Issue を作成しない）、台帳の読み取り規則、保証節の書式と組み立て、保証 ID の確定手順、裁可ラベルの運用、実装チケットへの保証参照 |

## 注意事項

- 機能仕様ドキュメントの作成は `/define-feature` の責務
- バグ修正やドキュメント更新など、親要件チケットを伴わない単独タスクの場合は、ユーザー指示に基づき要件モードに準じて単発 Issue を作成してよい

---
name: codex-task
description: "調査(read-only)または雑務(workspace-write)をCodexへ委譲し、境界の付いた小さなJSONサマリだけを受け取る。Triggers on: '/codex-task', 'Codexで調べて', 'Codexにやらせて', 'Codexへ委譲'"
argument-hint: "[investigate|chore] <タスクの1行要約>"
effort: medium
---

# Codex Task

1つの区切られたタスクをCodexへ委譲し、**結論だけ**を受け取る。目的は呼び出し元のコンテキスト消費を抑えることであり、そのために**入力はパスで渡し、出力は1個のJSONに限定する**。

このスキルはcommit・push・PR作成・PRコメント投稿を行わない。`chore`モードの成果は作業ツリーに残し、その先は呼び出し元が判断する。

## 入力

`$ARGUMENTS`: 先頭トークンが`investigate` / `chore`ならモード指定、残りがタスクの要約。モード省略時は`investigate`（read-only）。

## Step 0: 委譲すべきタスクかを判定する（省略しない）

Codexは**呼び出し元のCLAUDE.mdもこのセッションの文脈も引き継がない**。ブリーフに書いた分しか知らないため、委譲が節約になるのは**入力が大きく結論が小さい**タスクに限られる。ブリーフを書く費用が節約を上回るなら、委譲は損になる。

**委譲する**:

- ログ・差分・大量ファイルの掃引と、そこからの結論の抽出
- ある値・規則・関数の呼び出し元／消費者の追跡
- 依存・設定・命名の棚卸し
- 対象repository内で完結する定型のファイル生成・機械的な一括修正

**委譲しない**:

- 複数repositoryの整合を要する判断（判断材料が対象repository外にあり、ブリーフに書き切れない）
- 要件・仕様の詰め、設計分岐の選択（選択肢を意思決定者と詰めることが品質機構そのもの）
- ワークスペースの運用状態（課題台帳・ポジション・記憶）に依存する判断

委譲しないと判断した場合は、その理由を1行で述べて通常どおり自分で実行する。**判定を飛ばして機械的に委譲しない**。

## Step 1: ブリーフを書く

`mktemp`で一時ファイルを作り、次を書く。**promptへ直貼りせず、必ずファイルへ書いてパスで渡す**。

- タスク（何を答えるか／何をするか）を具体的に
- `investigate`なら**答えるべき問いを列挙**する（`answers`はこの問いに対応して返る）
- 完了条件と、触ってよい範囲・触ってはいけない範囲
- 前提知識（Codexは呼び出し元の文脈を持たない）
- 判断の所在: **軽微・可逆な判断は自分で決めて`assumptions`に記録し、重大・非自明な判断は決めずに`unverified`へ書いて返す**

参照させたいファイルがあれば`--input`でパスを渡す（本文をブリーフへ貼らない）。

## Step 2: runner実行

`chore`モードは対象repositoryの作業ツリーへ書き込む。**実行前に`git status --porcelain`で未コミットの変更が無いことを確認する**。残っている場合、実行前から汚れていたパスは変更申告との照合対象から外れるため、Codexの申告漏れを検出できない。変更の混在も避けるため、ユーザーへ確認してから進める。

> **スクリプトの実行形（重要）**: 本スキルはプラグインとして配布されるため、スクリプトは**ユーザーのプロジェクトroot ではなく、プラグイン配下**にある。スクリプトを実行する際は必ず PATH 上のランチャー経由で `claude-harness-run codex-task-runner --mode <investigate|chore> --brief-file "<brief_file>" [--repo "<repo_dir>"] [--input "<input_file>"]...` の形式（パス・バージョン・引用符を付けない。この形だけが `Bash(claude-harness-run:*)` の1行で allowlist できる）を用い、相対パス `scripts/codex-task-runner.sh` では呼び出さないこと。`claude-harness-run: command not found` になった場合のみ `bash "<プラグインルート>/scripts/codex-task-runner.sh" --mode <investigate|chore> --brief-file "<brief_file>" [--repo "<repo_dir>"] [--input "<input_file>"]...` にフォールバックする（パスは引用符で囲む。プラグインルートはスキル起動時の「Base directory for this skill」から解決した絶対パス。`${CLAUDE_PLUGIN_ROOT}` は表記上のプレースホルダであり環境変数ではない）。フォールバックした場合はユーザーにランチャー導入を案内すること。
<!-- 正本: docs/plugin-path-conventions.md -->

長時間になる見込みなら`--timeout`を伸ばす（既定900秒）。結果が大きくなる見込みなら`--max-output-bytes`を上げる（既定20000）。

## Step 3: 結果の扱い

runnerのstdout JSONを保持する。exit codeと`result`を次のように扱う。

- exit 0 / `complete`: 完全な結果
- exit 3 / `partial`: 部分結果は提示するが、**完了として扱わない**。`errors[]`を必ず報告に含める
- exit 4 / `failed`: `task`を利用せず、実行失敗として報告する
- exit 64/66/69: 入力・導入・依存関係の問題として報告する

`errors[]`に次が含まれる場合の意味:

| code | 意味と扱い |
|---|---|
| `changes_mismatch` | 申告した変更と実際の作業ツリーが食い違う。**申告を信じず`git status` / `git diff`を自分で確認する** |
| `commit_detected` | 契約に反してcommitされた。何がcommitされたかを確認し、必要なら呼び出し元の判断で戻す |
| `output_budget_exceeded` | 結果が予算超過。結果自体は使えるが、次回はブリーフで問いを絞る |
| `invalid_task_contract` | 出力が契約を満たさない。結果は使わない |
| `codex_timeout` / `codex_failed` | Codexが完走していない。結果は使わない |

## Step 4: 報告と後始末

次を報告する。

- `result`とmode
- `summary`（結論）
- `answers`（investigate）または`changes`（chore）
- `assumptions` / `unverified` / `followups`
- `errors[]`、`duration_seconds`、取得できた`usage`

**`unverified`を黙って落とさない**。Codexが決着させなかった点は、呼び出し元が引き取るかユーザーへ上げる。

`chore`の成果を採用する場合も、このスキルではcommitしない（必要なら`/commit`を別途呼ぶ）。

最後にブリーフの一時ファイルを削除する。失敗経路でも残さない。

`complete`かつ`answers`が空でない場合のみ「Codexの調査結果」として提示できる。`partial` / `failed`を完了した調査として合成しない。

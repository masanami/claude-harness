---
name: init-devcontainer
description: "devcontainer環境を構築する設定ファイルを生成する。Triggers on: '/init-devcontainer', 'devcontainerを設定', 'devcontainer環境を作って'"
model: sonnet
# effort: 初期設定生成が中心のため medium。
effort: medium
---

# devcontainer 環境構築

プロジェクトを分析し、Claude Code をサンドボックス環境で安全に実行するための devcontainer 設定ファイルを生成します。

---

## 手順

### 1. 既存設定の確認

`.devcontainer/` ディレクトリが既に存在する場合はユーザーに上書き・マージ・中止を確認する。

### 2. プロジェクト情報の検出

言語・パッケージマネージャを検出し、適切なベースイメージと features を決定する。

| 検出結果 | ベースイメージ | 追加 features |
|---------|-------------|--------------|
| Node.js | `mcr.microsoft.com/devcontainers/base` | `ghcr.io/devcontainers/features/node` |
| Python | `mcr.microsoft.com/devcontainers/python` | - |
| Go | `mcr.microsoft.com/devcontainers/go` | - |
| Rust | `mcr.microsoft.com/devcontainers/rust` | - |
| 不明 | `mcr.microsoft.com/devcontainers/base` | - |

さらに、以下を確認してプロジェクトのパッケージ管理外でインストールが必要なシステムツールを探索する。

- `README.md` のセットアップ手順
- `Makefile` / `scripts/` 内のセットアップ系スクリプト
- `.github/workflows/` のCI設定（`apt install`、`brew install`、`curl ... | sh` などのパターン）
- `docs/` 内のセットアップガイド

検出したツールは `postCreateCommand` でのインストールコマンドに含める。

### 3. 設定ファイルの生成

以下のファイルを生成する。

#### `.devcontainer/devcontainer.json`

以下の要件を満たす内容で生成する。最新の devcontainer 仕様に従い、実際のスキーマに合わせて適切なフォーマットで記述すること。

| 設定項目 | 内容 |
|---------|------|
| コンテナ名 | `{プロジェクト名} Sandbox` |
| ベースイメージ | 手順2で検出したイメージ |
| features | git、および言語に応じた feature |
| postCreateCommand | Claude Code のインストール + `/workspace/.devcontainer/claude-settings.json` を `~/.claude/settings.json` にコピー + 手順2で検出したシステムツールのインストール |
| マウント | ローカルワークスペースを `/workspace` にバインド |
| workspaceFolder | `/workspace` |
| 環境変数 | `ANTHROPIC_API_KEY` をローカル環境から引き継ぐ |

#### `.devcontainer/claude-settings.json`

コンテナ内の Claude Code に決定論的な安全ゲートとして `permissions.deny` を設定する。`/init-project` と同じ最小限のベース（ブラスト半径が広く取り返しのつかない操作）を含める。

ベース deny の正本は `${CLAUDE_PLUGIN_ROOT}/skills/init-project/scripts/base-deny.json`（JSON配列。init-project の `generate-settings.sh` が参照するものと同一ファイル。`${CLAUDE_PLUGIN_ROOT}` は本スキルがプラグインとして配布されるため、ユーザーのプロジェクトrootではなくプラグイン配下へ実行時に展開されるパス）。このファイルを読み込み、`{"permissions": {"deny": <配列の内容>}}` の形に埋め込んで `.devcontainer/claude-settings.json` を生成する（例: `jq -n --argjson deny "$(cat "${CLAUDE_PLUGIN_ROOT}/skills/init-project/scripts/base-deny.json")" '{permissions: {deny: $deny}}'`）。

> プロジェクト固有の破壊的操作は `permissions.deny` に追記してください（例: `Bash(terraform destroy:*)`）。コマンドの文脈的な安全判断は Claude Code ネイティブの auto-mode が担うため、独自のコマンドブロックスクリプトは設定しない。

### 4. ネットワーク制御の確認（オプション）

外部ネットワークを遮断したい場合は `.devcontainer/docker-compose.yml` も生成するか確認する。

```yaml
services:
  sandbox:
    image: {ベースイメージ}
    volumes:
      - ../:/workspace:cached
    networks:
      - sandbox-net

networks:
  sandbox-net:
    driver: bridge
    internal: true
```

> **注意**: `internal: true` は外部通信を全て遮断する。`postCreateCommand` でのパッケージインストールが失敗するため、必要なものは事前にイメージに含めること。

### 5. 完了報告

```text
## devcontainer 環境構築 完了

- 生成ファイル:
  - `.devcontainer/devcontainer.json`
  - `.devcontainer/claude-settings.json`

次のステップ:
- VS Code: "Reopen in Container" でコンテナを起動
- CLI: `devcontainer up --workspace-folder . && devcontainer exec --workspace-folder . claude`（セッション内で auto-mode を有効化）
- プロジェクト固有のdenyルールは `.devcontainer/claude-settings.json` の `permissions.deny` に追記してください
```

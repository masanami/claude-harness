# auto-mode の安全な利用ガイド

## 概要

auto-mode は Claude Code のセッション内で有効化できる自律実行モードです。ツール実行の都度表示される確認プロンプトをスキップし、長時間の自律実行が可能になりますが、危険なコマンドが意図せず実行されるリスクがあります。

本ガイドでは `block-dangerous.sh` と denyリストを組み合わせることで、このリスクを軽減しながら安全に auto-mode を活用する方法を説明します。

---

## リスクと対策

| リスク | 対策 |
|--------|------|
| 危険なコマンドの意図しない実行 | denyリスト (`denylist.conf`) でブロック |
| カスタマイズしにくいブロックルール | 外部ファイルでのdenyリスト管理 |
| 本番環境での意図しない操作 | devcontainer などのサンドボックス環境で実行 |

---

## セットアップ

> **Note**: `/init-project` を実行すると、以下のフック設定が `.claude/settings.json` に自動で追加されます。手動セットアップは不要です。

### 1. フックの設定

`.claude/settings.json` に以下を追加します。

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/claude-harness/scripts/block-dangerous.sh"
          }
        ]
      }
    ]
  }
}
```

### 2. denyリストの確認・カスタマイズ

デフォルトのdenyリストは `scripts/denylist.conf` に定義されています。

```conf
# 形式: PATTERN<TAB>MESSAGE  (区切り文字はタブ文字)
rm[[:space:]]+(-[a-zA-Z]*r[a-zA-Z]*f|...)[[:space:]]+/[[:space:]]*$<TAB>rm -rf / は実行できません
```

プロジェクト固有のルールを追加する場合は、`DENYLIST_PATH` 環境変数でカスタムファイルを指定します。

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "DENYLIST_PATH=/path/to/custom-denylist.conf /path/to/claude-harness/scripts/block-dangerous.sh"
          }
        ]
      }
    ]
  }
}
```

### 3. auto-mode を有効化

Claude Code セッション内で auto-mode を有効化します。

---

## denyリストのデフォルト設定

`scripts/denylist.conf` には以下のパターンが初期設定されています。

### ファイルシステム破壊系

| パターン | 説明 |
|----------|------|
| `rm -rf /` | ルートディレクトリ全体の削除 |
| `rm -rf /*` | ルート直下の全ファイル削除 |
| `rm -rf $HOME` / `rm -rf ~` | ホームディレクトリ全体の削除 |

### Gitリポジトリ破壊系

| パターン | 説明 |
|----------|------|
| `git push --force origin main/master` | main/masterへの強制プッシュ |
| `git push -f origin main/master` | main/masterへの強制プッシュ（短縮形） |
| `git reset --hard origin/main` | リモートの状態に強制リセット |

### データベース破壊系

| パターン | 説明 |
|----------|------|
| `DROP TABLE` | テーブルの削除 |
| `DROP DATABASE` | データベースの削除 |
| `TRUNCATE TABLE` | テーブルデータの全削除 |

### インフラ破壊系

| パターン | 説明 |
|----------|------|
| `terraform destroy` | Terraformによるインフラ全削除 |
| `cdk destroy` | AWS CDKによるスタック削除 |
| `cdktf destroy` | Terraform CDKによるスタック削除 |

### システム・権限系

| パターン | 説明 |
|----------|------|
| `chmod 777 /` | ルートディレクトリの権限変更 |
| `chown -R root /` | ルートディレクトリのオーナー変更 |

---

## カスタムdenyリストの書き方

```conf
# コメント行（# で始まる）
# 空行は無視される

# 形式: PATTERN<TAB>MESSAGE  (区切り文字はタブ文字)
# PATTERN: 拡張正規表現（grep -E で評価）、POSIX文字クラス [[:space:]] を使用
# MESSAGE: ブロック時に表示するメッセージ

# 大文字小文字を区別しない場合は [case-insensitive] プレフィックスを付ける
[case-insensitive]DROP[[:space:]]+(TABLE|DATABASE)<TAB>DROP TABLE/DATABASE は実行できません

# プロジェクト固有のルール例
kubectl[[:space:]]+delete[[:space:]]+namespace[[:space:]]+production<TAB>productionネームスペースの削除は実行できません
```

---

## 推奨設定例

### CI/CD 環境での利用

```bash
# GitHub Actions などで安全に自律実行する場合
export DENYLIST_PATH="/workspace/.github/claude-denylist.conf"
claude --dangerously-skip-permissions  # CI環境ではCLIフラグを使用
```

> **Note**: CI/CD 環境など非対話的な実行では、従来の `--dangerously-skip-permissions` フラグを使用します。対話的なセッションでは auto-mode を推奨します。

### devcontainer 環境での利用

devcontainer の設定ファイルを自動生成するには `/sandboxed-run` スキルを実行してください。

---

## hooks denyリスト と settings.json の deny の住み分け

危険なコマンドのブロックには2つの仕組みがあり、役割が異なります。

| | hooks denyリスト（`denylist.conf`） | `settings.json` の `permissions.deny` |
|--|----------------------------------|--------------------------------------|
| **動作レイヤー** | PreToolUse フック（シェルスクリプト） | Claude Code ネイティブの権限システム |
| **チェック対象** | Bash に渡されるコマンド文字列全体 | ツール呼び出しのプレフィックス |
| **記述形式** | 拡張正規表現（引数の組み合わせも表現可能） | `Bash(コマンド:*)` 形式の固定パターン |
| **得意なケース** | 引数や位置によって危険度が変わるコマンド（例: `git push --force origin main` のみブロックし、他ブランチへのforce pushは許可） | コマンド単位で一律ブロックしたい場合（例: `rm -rf` は引数を問わず常にブロック） |
| **カスタマイズ** | `denylist.conf` を編集、`DENYLIST_PATH` で切り替え可能 | `settings.json` を直接編集 |

### 使い分けの指針

- **`settings.json` deny**: コマンドプレフィックスで一律ブロックできるものに使う。シンプルで確実。
- **hooks denyリスト**: 引数や文脈によって危険かどうかが変わる複雑なパターンに使う。正規表現で柔軟に記述できる。

両者は独立して動作するため、**多層防御として組み合わせて使うことを推奨します**。

---

## 注意事項

- auto-mode は**信頼できる環境**でのみ使用してください
- denyリストはすべての危険なコマンドを網羅するものではありません。あくまで追加の安全策です
- 本番環境での直接実行は避け、devcontainerやステージング環境で実行することを推奨します
- denyリストのパターンは定期的に見直し、プロジェクトのニーズに合わせて更新してください

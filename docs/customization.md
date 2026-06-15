# カスタマイズ方法

harnessプラグインはプロジェクト固有の要件に合わせてカスタマイズできます。

---

## 1. CLAUDE.md連携

最も基本的なカスタマイズ方法です。プラグインのエージェント・スキルはプロジェクトの `CLAUDE.md` を参照して動作するため、CLAUDE.mdに適切な情報を記述することで挙動を制御できます。

### カスタマイズ可能な項目

| 項目 | CLAUDE.mdへの記述例 | 影響するコンポーネント |
|------|-------------------|---------------------|
| テストコマンド | `テスト実行: npm run test` | test, quality-check スキル |
| リントコマンド | `リント: npm run lint` | quality-check スキル、code-reviewer |
| 型チェックコマンド | `型チェック: npm run typecheck` | quality-check スキル |
| E2Eテストコマンド | `E2E: npm run e2e` | run-e2e スキル、create-e2e スキル |
| ディレクトリ構成 | `ソースコード: src/features/` | implement-feature, modify-feature |
| コーディング規約 | `命名規則: camelCase` | code-reviewer |
| ドキュメントパス | `設計書: docs/design/` | doc-verifier, implement-feature |
| 品質方針 | `品質方針: クリティカル箇所はコードレビュー必須` | para-impl, code-reviewer |

---

## 2. エージェントのオーバーライド

プロジェクトの `.claude/agents/` に同名のファイルを配置すると、プラグインのエージェントをオーバーライドできます。

### 例: code-reviewerをカスタマイズ

```bash
# プロジェクトのルートで
mkdir -p .claude/agents
```

`.claude/agents/code-reviewer.md` を作成:

```markdown
---
name: code-reviewer
description: プロジェクト固有のコードレビュー
tools: Read, Glob, Grep, Bash
model: inherit
---

# コードレビューエージェント（カスタム版）

## プロジェクト固有のチェック項目

- [ ] Server Actionsに `"use server"` ディレクティブがある
- [ ] RLSポリシーが適用されている
- [ ] 監査ログが記録されている

## 汎用チェック項目

（プラグインのcode-reviewer.mdの内容を必要に応じて含める）
```

### オーバーライド対象

| ファイル名 | 配置先 |
|-----------|--------|
| `code-reviewer.md` | `.claude/agents/code-reviewer.md` |
| `implement-feature.md` | `.claude/agents/implement-feature.md` |
| `modify-feature.md` | `.claude/agents/modify-feature.md` |
| `doc-verifier.md` | `.claude/agents/doc-verifier.md` |

---

## 3. スキルのオーバーライド

プロジェクトの `.claude/skills/{skill-name}/SKILL.md` に配置します。

### 例: commitスキルをカスタマイズ

`.claude/skills/commit/SKILL.md`:

```markdown
---
name: commit
description: "プロジェクト固有のコミットルール"
---

# コミット

## プロジェクト固有ルール

- scopeは以下のいずれか: `core`, `web`, `api`, `db`
- チケット番号を必ずfooterに含める

（以降はプラグインのcommit/SKILL.mdの内容をベースに）
```

---

## 4. フックの追加

プロジェクトの `.claude/settings.json` でプラグインのフックに追加のフックを重畳できます。

### 例: プロジェクト固有のフックを追加

`.claude/settings.json`:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          {
            "type": "command",
            "command": "./scripts/custom-lint-check.sh"
          }
        ]
      }
    ]
  }
}
```

プラグインのフック（自動フォーマット）とプロジェクトのフックは両方実行されます。

---

## 5. 新しいエージェント・スキルの追加

プラグインのオーバーライドに加え、完全に新しいエージェントやスキルを追加できます。

### 新しいエージェントの追加

`.claude/agents/my-custom-agent.md`:

```markdown
---
name: my-custom-agent
description: プロジェクト固有のカスタムエージェント
tools: Read, Glob, Grep, Edit, Write, Bash
model: inherit
---

# カスタムエージェント

（エージェントの説明と手順）
```

### 新しいスキルの追加

`.claude/skills/my-skill/SKILL.md`:

```markdown
---
name: my-skill
description: "カスタムスキルの説明"
argument-hint: "[引数]"
model: opus
---

# カスタムスキル

入力パラメータ: $ARGUMENTS

（スキルの手順）
```

---

## 6. カスタマイズの優先順位

1. **プロジェクトの `.claude/` 内のファイル**（最優先）
2. **プラグインのファイル**
3. **CLAUDE.mdの記述**（エージェント実行時に参照）

プロジェクト側のファイルが存在する場合、プラグインの同名ファイルは使用されません。

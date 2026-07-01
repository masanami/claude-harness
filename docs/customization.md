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
| E2Eテストコマンド | `E2E: npm run e2e` | create-e2e スキル、explain-e2e スキル |
| ディレクトリ構成 | `ソースコード: src/features/` | feature-implementer |
| コーディング規約 | `命名規則: camelCase` | code-reviewer |
| ドキュメントパス | `機能仕様: docs/features/` | doc-verifier, feature-implementer |
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
| `feature-implementer.md` | `.claude/agents/feature-implementer.md` |
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

---

## 7. reasoning effort（思考の深さ）の方針

各スキル・サブエージェントは frontmatter の `effort` で reasoning effort を指定できます（Opus 4.8/4.7・Fable 5 で `low` / `medium` / `high` / `xhigh`。`max` は session 専用のため frontmatter では使わない）。frontmatter の `effort` は実行時に session level を override します（環境変数は override しない）。effort は model-dependent（モデルごとに calibrate 済み）です。

### 割り当ての基本方針

「深い推論・正確性が重要」なものを高め、「機械的・定型」なものを低めにします。**過剰な effort 付与はコスト増**につながるため、**session 継承（無指定）で十分なものには付けない**のが原則です。

| 対象 | 種別 | effort | 理由 |
|------|------|--------|------|
| code-reviewer | agent | `xhigh` | バグ・正確性・設計の深い検討 |
| design-reviewer | agent | `xhigh` | 依存方向・境界の構造的判断 |
| feature-implementer | agent | `high` | 実装の中核ロジック |
| e2e-engineer | agent | `medium` | パターン踏襲が中心 |
| doc-verifier | agent | `medium` | 整合性チェック |
| define-feature | skill | `xhigh` | 要件・クリティカル設計の意思決定 |
| para-impl / tdd-impl / reduce-debt | skill | `high` | 設計〜実装・負債判断 |
| create-ticket / pr-review-respond / create-e2e / explain-e2e / init-project / init-devcontainer | skill | `medium` | 分解・実装・解説・初期設定 |
| commit / quality-check / pr-merge | skill | `low` | 定型・機械的処理 |
| self-review / walkthrough | skill | （無指定＝継承） | 下記参照 |

### スキル→サブエージェント委譲時の effort

スキルがサブエージェントに委譲する場合、**それぞれのコンテキストで各自の `effort` が効く**という理解で設計しています。

- 呼び出し元スキルの `effort` … スキル本体（委譲前の観点整理・委譲後の統合）を回すメインループに効く
- 委譲先エージェントの `effort` … サブエージェント内のコンテキストに効く

このため、深い検討が委譲先で行われるスキルは**スキル本体を継承のままにできます**。

- **self-review**: 深い検討は委譲先レビュー agent（`code-reviewer`/`design-reviewer` = `xhigh`）側で効くため、スキル本体は継承。
- **walkthrough**: ブラウザ操作主体で深い推論を要さないため継承。

> この委譲時の効き方は実機検証で最終確認する余地があります（#25 未決事項Cと関連）。

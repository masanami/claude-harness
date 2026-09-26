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

> エージェント定義・スキル本文は**実行時にモデルへ配送されるテキスト**であり、人間が読むドキュメントとは書き分ける。判定軸（「この文を削るとモデルの振る舞いが変わるか」）と、逐語コピーの規律との関係は [プラグイン内ファイル参照のパス規約](./plugin-path-conventions.md) (h) を参照。

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

各スキル・サブエージェントは frontmatter の `effort` で reasoning effort を指定できます（`low` / `medium` / `high` / `xhigh`。`max` は session 専用のため frontmatter では使わない）。frontmatter の `effort` は実行時に session level を override します（環境変数は override しない）。effort は model-dependent（モデルごとに calibrate 済み）です。

現在の値は **Opus 5.5 を前提に調整**しています（Issue #264）。Opus 5.5 では既定の effort が `high` から `medium` に変わったため、Opus 4.8/4.7・Fable 5 の頃に決めた値から、`model: opus` を指定したもの（と Opus 5.5 のセッションで動くことが多い `tdd-impl`）を**一段ずつ下げました**。`low` のもの、浅い推論では役割を果たせないもの、`model: sonnet` のものは据え置いています。

### 割り当ての基本方針

「深い推論・正確性が重要」なものを高め、「機械的・定型」なものを低めにします。**過剰な effort 付与はコスト増**につながるため、**session 継承（無指定）で十分なものには付けない**のが原則です。

| 対象 | 種別 | effort | 理由 |
|------|------|--------|------|
| code-reviewer | agent | `high` | バグ・正確性・設計の深い検討（旧値 `xhigh`） |
| design-reviewer | agent | `high` | 依存方向・境界の構造的判断（旧値 `xhigh`） |
| defect-sweeper | agent | `high` | 据え置き（下記） |
| feature-implementer | agent | `high` | 実装の中核ロジック（`model: sonnet` のため対象外） |
| ticket-worker | agent | `high` | 1チケットのフロー統括（CI失敗分析・差し戻し判断。`model: sonnet` のため対象外） |
| issue-conflict-predictor | agent | `low` | 1Issueあたりのファイル衝突予測に限定した軽量タスク |
| e2e-engineer | agent | `medium` | 据え置き（下記） |
| doc-verifier | agent | `medium` | 整合性チェック |
| surface-auditor | agent | `medium` | 指定ファイルの読解・分類（探索・設計判断を含まない） |
| surface-audit | skill | `high` | 列挙・fan-out・完全性 join の統括（抽出の実務は agent 側。`model: sonnet` のため対象外） |
| define-feature | skill | `high` | 要件・クリティカル設計の意思決定（旧値 `xhigh`） |
| impl / para-impl / tdd-impl | skill | `medium` | 設計〜実装の自走フロー。深い検討はレビュー agent 側で担保（旧値 `high`） |
| create-adr / promote-verify / reduce-debt | skill | `medium` | ADR の線引き・受入基準の整合判定の整形・負債の優先度判断（旧値 `high`） |
| create-e2e / pr-review-respond | skill | `medium` | 据え置き（下記） |
| create-ticket / explain-e2e / init-project / init-devcontainer | skill | `medium` | 分解・解説・初期設定 |
| commit / quality-check / pr-merge | skill | `low` | 定型・機械的処理 |
| self-review / demo | skill | （無指定＝継承） | 下記参照 |

上表は主なものです。表に無いスキル・エージェント（`model: sonnet` の検証・分類系など）の値と理由は各ファイルの frontmatter と直前の `# effort:` コメントが正本です。

#### Opus 5.5 への調整で据え置いたもの

| 対象 | 種別 | effort | 理由 |
|------|------|--------|------|
| defect-sweeper | agent | `high` | 中核が「好意的解釈をせず、文字どおりに従う実装を再現する」推論であり、浅い effort では書き手の意図を補って読む方向へ流れて掃引が成り立たないため |
| e2e-engineer | agent | `medium` | E2E テストのコードそのものを書く工程のため |
| create-e2e | skill | `medium` | 同上 |
| pr-review-respond | skill | `medium` | 指摘への対応の要否を判断して修正する工程で、`low` だと「対応不要」と判断する方向に振れる恐れがあるため |
| pr-merge | skill | `low` | `low` はそのままにする |

### スキル→サブエージェント委譲時の effort

スキルがサブエージェントに委譲する場合、**それぞれのコンテキストで各自の `effort` が効く**という理解で設計しています。

- 呼び出し元スキルの `effort` … スキル本体（委譲前の観点整理・委譲後の統合）を回すメインループに効く
- 委譲先エージェントの `effort` … サブエージェント内のコンテキストに効く

このため、深い検討が委譲先で行われるスキルは**スキル本体を継承のままにできます**。

- **self-review**: 深い検討は委譲先レビュー agent（`code-reviewer`/`design-reviewer` = `high`）側で効くため、スキル本体は継承。
- **demo**: ブラウザ操作主体で深い推論を要さないため継承。

> この委譲時の効き方は実機検証で最終確認する余地があります（#25 未決事項Cと関連）。

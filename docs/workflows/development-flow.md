# 開発フロー

## 1. 概要

本ドキュメントは、AI駆動開発における開発フローの概要を定義する。
品質保証・レビュー方針については [AI駆動開発戦略](../ai-driven-development-strategy.md) を参照。

### 関連ドキュメント

- [AI駆動開発戦略](../ai-driven-development-strategy.md) - 開発サイクル、品質保証・レビュー方針
- [ブランチ戦略](./branching-strategy.md) - GitHub Flow、PR規約
- [チケット記述ガイドライン](./ticket-writing.md) - チケットの書き方

---

## 2. 開発サイクル

### 2.1 全体フロー

```
要件定義 → 設計 → チケット作成 → 事前レビュー → 実装 → レビュー → マージ → デプロイ
```

### 2.2 詳細フロー

```mermaid
flowchart TD
    subgraph phase1["1. 要件定義・チケット作成"]
        p1[PdM/開発者: 機能要件を定義しチケットに分解]
    end

    subgraph phase2["2. 設計"]
        p2[開発者 ↔ AIエージェント: 要件確認・設計方針・実行計画]
    end

    subgraph phase3["3. 事前レビュー"]
        p3[PdM/PdO ↔ 開発者: 詳細設計・実行計画をチケット上でレビュー]
    end

    subgraph phase4["4. 実装（AI並列稼働)"]
        p4[AIエージェント: 実装 → テスト → セルフレビュー（レビューエージェント/必要に応じて人間） → PR作成]
    end

    subgraph phase5["5. レビュー"]
        p5[自動レビューツール（設定に応じて） + 担当開発者 + 他開発者]
    end

    subgraph phase6["6. マージ・デプロイ"]
        p6[CIパス確認 → マージ → 自動デプロイ]
    end

    phase1 --> phase2
    phase2 --> phase3
    phase3 -->|承認後| phase4
    phase4 --> phase5
    phase5 -->|Approve| phase6
    phase5 -.->|修正要| phase4
```

> レビューは変更のリスク・重要度に応じて範囲を判断して実施。詳細は [AI駆動開発戦略](../ai-driven-development-strategy.md) を参照。

---

## 3. チケット管理

### 3.1 チケット構造

```
親チケット（要件）
├── 子チケット: 設計
└── 子チケット: 実装（設計完了後にタスク分割）
    ├── 実装タスク 1
    ├── 実装タスク 2
    └── ...
```

### 3.2 チケット粒度

1つのチケットは、以下の条件を満たす粒度とする:

- 1人のAIエージェントが完結できる
- 明確な完了条件がある
- 他チケットとの依存が最小限

> 詳細（テンプレート、ライフサイクル、依存関係）は [チケット記述ガイドライン](./ticket-writing.md) を参照

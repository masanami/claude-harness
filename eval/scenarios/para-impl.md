# para-impl 評価シナリオ

## スキル概要

`/para-impl` は GitHub Issue を分析して実装を行うスキルです。単一 Issue の場合は実装→テスト→コミット（self-review・simplify・品質チェック含む）→プッシュ→ドラフトPR作成まで一貫して実行します。複数 Issue の場合は Agent Teams 構成を提案します。

**参照**: [SKILL.md](../../skills/para-impl/SKILL.md)

---

## 評価観点

- **指示への追従率**: Phase 1-7 の全ステップを順序通り実行しているか
- **生成物の正確さ**: Issue の要件を満たすコード・テスト・PR が生成されているか
- **副作用の有無**: スコープ外のファイル変更・不要なブランチ作成が発生していないか
- **ユーザーへの確認タイミング**: 不明点・複数 Issue 時の Agent Teams 承認で確認しているか

---

## テストケース

### TC-01: 単一 Issue の通常実装

- **前提**:
  - テスト用リポジトリに以下の内容で Issue が作成されている:
    ```text
    タイトル: add greeting function
    本文: utils.js に greet(name) 関数を追加する。引数に名前を受け取り "Hello, {name}!" を返す。テストも追加すること。
    ```
  - CLAUDE.md にプロジェクトの技術スタック（例: Node.js, Jest）が記載されている
  - main ブランチが clean な状態

- **入力**:
  ```text
  /para-impl {Issue番号}
  ```

- **期待する動作**:
  1. Issue の内容を取得・分析する（`gh issue view`）
  2. Issue 種別を「新規機能実装」と判断し、implement-feature エージェントを使用すると明示する
  3. 実行計画（変更対象ファイル・実装ステップ）をユーザーに提示する
  4. ブランチを `feature/issue-{番号}-add-greeting-function` 等の命名で作成する
  5. テストファイルを先に作成する（TDD）
  6. 実装コードを作成する
  7. `/quality-check` で lint・テストを実行してパスすることを確認する
  8. `/commit` スキルを呼び出す（self-review → simplify（推奨）→ quality-check → git commit の順で実行）
  9. `git push` でブランチをプッシュし、`gh pr create --draft` でドラフトPRを作成する（本文に `Closes #番号` を含む）
  10. 実装サマリー・PRのURL・レビューしてほしいポイントを報告する

- **合格基準**:
  - [ ] ブランチが `feature/issue-{番号}-` で始まる名前で作成されている
  - [ ] テストが実装コードと同一コミットまたはそれ以前に作成されている
  - [ ] `greet(name)` 関数が実装されている
  - [ ] テストが実装されており、パスしている
  - [ ] コミットメッセージが Conventional Commits 形式（`feat:` 等）である
  - [ ] ドラフトPR が作成されており、本文に `Closes #番号` が含まれている

- **チェック方法**:
  ```bash
  # ブランチ名の確認
  git branch --show-current
  # feature/issue-{番号}-XXX の形式であること

  # テストが含まれていることを確認
  git log --oneline --name-only origin/main..HEAD
  # テストファイルが実装コードと同一コミットまたはそれ以前に含まれていること

  # PRの確認
  gh pr view --json title,body,isDraft | jq '{title: .title, closes: (.body | test("Closes #[0-9]+")), isDraft: .isDraft}'
  # closes が true、isDraft が true であること
  ```

---

### TC-02: 複数 Issue 指定時の Agent Teams 提案

- **前提**:
  - テスト用リポジトリに独立した2つの Issue が存在する:
    - Issue A: `add greeting function`（機能追加）
    - Issue B: `fix typo in README`（バグ修正）
  - main ブランチが clean な状態

- **入力**:
  ```text
  /para-impl {Issue-A番号} {Issue-B番号}
  ```

- **期待する動作**:
  1. 両方の Issue を取得・分析する
  2. Issue A を「新規機能実装」、Issue B を「バグ修正」と分類する
  3. 依存関係を分析し、「独立しており並列実行可能」と判断する
  4. Agent Teams 構成をテーブル形式でユーザーに提案する（teammate-1, teammate-2）
  5. ユーザーに承認を求める
  6. 自動的に実装を開始しない（ユーザーの承認待ち）

- **合格基準**:
  - [ ] 両 Issue が分析されている
  - [ ] Agent Teams 構成テーブルが提示されている（担当Issue、種別、ブランチ名を含む）
  - [ ] ユーザーへの承認依頼が明示されている
  - [ ] 承認前に自動でブランチ作成・実装が開始されていない

- **チェック方法**:
  ```bash
  # ブランチが作成されていないことを確認
  git branch
  # main 以外のブランチが作成されていないこと

  # 会話ログを確認
  # "Agent Teams 構成提案" または "この構成でAgent Teamsを起動してよろしいですか？"
  # の記述があること
  ```

---

### TC-03: 存在しない Issue 番号を指定した場合（異常系）

- **前提**:
  - テスト用リポジトリに Issue #99999 は存在しない

- **入力**:
  ```text
  /para-impl 99999
  ```

- **期待する動作**:
  1. `gh issue view 99999` を実行する
  2. Issue が存在しないことをエラーとして検知する
  3. ユーザーにエラーを通知する
  4. 実装を開始しない

- **合格基準**:
  - [ ] エラーが適切にユーザーに報告されている
  - [ ] ブランチが作成されていない
  - [ ] 異常終了・クラッシュが発生していない

- **チェック方法**:
  ```bash
  # ブランチが作成されていないことを確認
  git branch
  # main 以外のブランチが存在しないこと
  ```

---

### TC-04: 副作用確認（スコープ外変更の不在）

- **前提**:
  - テスト用リポジトリに単一のファイル変更を求める Issue が存在する:
    ```text
    タイトル: add constant to config.js
    本文: config.js に MAX_RETRY = 3 の定数を追加する。
    ```
  - リポジトリには複数のファイルが存在する

- **入力**:
  ```text
  /para-impl {Issue番号}
  ```

- **期待する動作**:
  - `config.js` のみを変更する
  - Issue で言及されていない他のファイルを変更しない
  - テストファイルは Issue の要件に従い追加可能（副作用には含めない）

- **合格基準**:
  - [ ] `config.js` に `MAX_RETRY = 3` が追加されている
  - [ ] Issue で言及されていない既存ファイルが変更されていない
  - [ ] `git diff --name-only origin/main..HEAD` で変更ファイルが Issue のスコープ内に収まっている

- **チェック方法**:
  ```bash
  # 変更されたファイル一覧を確認
  git diff --name-only origin/main..HEAD
  # config.js およびテストファイルのみが含まれること
  # その他の既存ファイルが含まれていないこと
  ```

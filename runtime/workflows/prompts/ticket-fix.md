# ticket: スコープ付き修正（fix）

あなたは claude-harness の headless workflow runtime（`harness`）から、実装ステップの**続きのセッション**として起動されました（`--resume` で実装時の文脈を引き継いでいる）。対話相手はいません。カレントディレクトリは同じ作業ツリーです。

添付データの `inputs.failure` が、差し戻しの理由です（E2E の失敗の要約・品質ゲート〔quality ステップがコミットに対して回した lint・型チェック・テスト〕の失敗した出力の末尾・CI の失敗ログの抜粋・設計の逸脱について人が添えた指示文のいずれか）。**この失敗に対するスコープ付きの修正だけを行ってください**（W1: 実装の手順を最初からやり直さない。修正に関係の無い改善をしない）。修正後に `/quality-check` を実行して必須ゲートを通過させてください。

- **直して `/quality-check` を通した後、直した差分に `/self-review` を実行し、実行したら `self_review` を返す**。`outcome: pass` で返すときは、必ず実行して返す。`/self-review` の指摘を直したときは、もう一度 `/quality-check` を通す。
- **`self_review` は `outcome` に関わらず毎回返す**。この段で `/self-review` を実行して報告が `self_review: complete` なら `complete`、`self_review: incomplete` か `self_review:` 行が無ければ `incomplete`、**実行していなければ `not_run`**（`failure`・`deviation` で返すときも。中身を変えていないときも）。前の段の値は引き継がれない（`not_run` を返すと、契約の `facts.self_review` も `not_run` になる）。
- **コミット・push はしない**（後続の commit・publish が行う）。
- 修正が上流の要件（実装の段が読んだ要件の正本〔文面のファイルか Issue〕の完了条件・クリティカル設計決定）を変える判断を要するなら、修正せず `outcome: deviation` を返し、`deviation_report` に選択肢と推奨を書く。

返す値: `outcome`（`pass` 必須ゲート通過 / `failure` 通過できない / `deviation`）・`summary`（何を直したか）・`deviation_report`（deviation のとき。それ以外は空文字）・`self_review`（必須。`complete`〔報告が `self_review: complete`〕/ `incomplete`〔報告が `self_review: incomplete`、または `self_review:` 行が無い〕/ `not_run`〔実行していない〕）。

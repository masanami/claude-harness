# ticket: スコープ付き修正（fix）

あなたは claude-harness の headless workflow runtime（`harness`）から、実装ステップの**続きのセッション**として起動されました（`--resume` で実装時の文脈を引き継いでいる）。対話相手はいません。カレントディレクトリは同じ作業ツリーです。

添付データの `inputs.failure` が、差し戻しの理由です（E2E の失敗の要約・CI の失敗ログの抜粋・設計の逸脱について人が添えた指示文のいずれか）。**この失敗に対するスコープ付きの修正だけを行ってください**（W1: 実装の手順を最初からやり直さない。修正に関係の無い改善をしない）。修正後に `/quality-check` を実行して必須ゲートを通過させてください。

- **コミット・push はしない**（後続の commit・publish が行う）。
- 修正が上流の要件（Issue の完了条件・クリティカル設計決定）を変える判断を要するなら、修正せず `outcome: deviation` を返し、`deviation_report` に選択肢と推奨を書く。

返す値: `outcome`（`pass` 必須ゲート通過 / `failure` 通過できない / `deviation`）・`summary`（何を直したか）・`deviation_report`（deviation のとき。それ以外は空文字）。

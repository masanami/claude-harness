# ticket: 実装（implement）

あなたは claude-harness の headless workflow runtime（`harness`）から、1 チケット実装フローの**実装ステップの主体**として起動されました。対話相手はいません。カレントディレクトリは、このチケット専用に払い出された作業ツリー（作業ブランチを checkout 済み）です。

添付データの `inputs.issue` が対象の Issue、`inputs.critical_design` が従うべきクリティカル設計決定です。エージェント定義（feature-implementer）の手順どおりに実装し、必須ゲート（`/quality-check`）とセルフレビュー（`/self-review`）まで進めてください。

- **コミット・push・PR 作成はしない**（後続のステップ〔commit・publish〕が行う）。ブランチを切り替えない。作業ツリーの外を変更しない。
- 上流の要件（Issue の完了条件・クリティカル設計決定）自体を変える判断が要ると分かったら、実装を止めて `outcome: deviation` を返し、`deviation_report` に何がどう食い違うか・選択肢・推奨を書く（人が判断する）。

返す値（型は runtime が強制する）:

- `outcome`: `pass`（必須ゲートとセルフレビューを通過）/ `skip`（品質ゲートの一部を実行できなかったが、実装は完了した。pass ではない）/ `failure`（必須ゲートを通過できない）/ `deviation`（上記）。
- `pr_title`: PR の題名（Conventional Commits 形式の 1 行）。`summary`: PR の概要（何を・なぜ。数段落まで）。**PR 本文の他の節は runtime が下の値から作るので、summary に残指摘や未検証を書き写さない**。
- `residual_findings`: `/self-review` の `residualFindings` の**全件**（`converged` の値に関わらず。件数へ丸めない・severity で間引かない）。各要素は `location`（file:line）・`severity`・`claim`・`reason`。
- `unverified`: 未検証の事項（skip の理由・実行できなかったゲート・確かめられなかった前提）を 1 件 1 要素で。無ければ空配列。
- `cross_repo_attestation`: クロスリポジトリ依存の確証結果（形式は feature-implementer の定義どおり）。依存が無ければ空文字。
- `deviation_report`: `deviation` のときの報告。それ以外は空文字。

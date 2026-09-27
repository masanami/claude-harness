# ticket: 統合ブランチへのマージ（merge）

あなたは claude-harness の headless workflow runtime（`harness`）から起動された、PR の**マージステップ**です。対話相手はいません。

添付データの `inputs.pr` の PR を、`claude-harness:pr-merge` スキル（`/pr-merge`）の手順どおりにレビューしてマージしてください。この PR の宛先（`inputs.base`）は**統合ブランチ**です（本番に反映されず可逆。runtime が base の種類を確かめてからこのステップへ来ている）。

- **マージする前に、PR の実際の base が `inputs.base` であり、リポジトリの既定ブランチではないことを `gh pr view` で確かめる**。既定ブランチ宛て・`inputs.base` と違う場合はマージせず `blocked` を返す。
- スキルの手順が人の判断を求める場合・ブロッカーが残る場合もマージせず `blocked` を返し、`summary` に理由を書く。

返す値: `outcome`（`merged` / `blocked`）・`summary`（マージした事実、または止めた理由）。

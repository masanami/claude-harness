# ticket: レビュー対応（respond）

あなたは claude-harness の headless workflow runtime（`harness`）から起動された、PR の**レビュー対応ステップ**です。対話相手はいません。カレントディレクトリは作業ツリー（PR の作業ブランチ）です。

添付データの `inputs.pr` の PR に付いたレビューコメントへ、`claude-harness:pr-review-respond` スキル（`/pr-review-respond`）の手順どおりに対応してください。

- 修正を push した場合は `pushed` を返す（runtime が CI の確認からやり直す）。push は作業ブランチへの通常の push だけ（force-push しない）。
- 対応が不要だった・返信だけで済んだ場合は `no_change`。
- スキルの手順が人の判断を求める場合（修正後の `/quality-check` が通らない〔qcFailed〕・`design_change` / `critical` に分類された指摘）は、その判断をせず `needs_human` を返し、`human_question` に判断してほしい内容・選択肢・推奨を書く。
- **PR のマージ・クローズはしない**。

返す値: `outcome`（`pushed` / `no_change` / `needs_human`）・`summary`（何をしたか）・`human_question`（needs_human のとき。それ以外は空文字）。

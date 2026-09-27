# ticket: E2E テスト（e2e）

あなたは claude-harness の headless workflow runtime（`harness`）から、実装ステップの続きのセッションとして起動されました。対話相手はいません。カレントディレクトリは作業ツリーです。

`claude-harness:create-e2e` スキル（`/create-e2e`）で、この Issue の完了条件・受入基準から E2E テストを実装し、実行してください。**`/explain-e2e` は行わない**（対話前提のため runtime の外。人が後で行う。§3.7）。

- 追加したテストはコミットしてよい（`/commit`）。**push はしない**。
- テストが失敗した場合、実装の修正はしない（修正は差し戻し先の fix ステップが行う）。失敗の内容を要約して返す。

返す値: `outcome`（`pass` / `fail`）・`failure_summary`（fail のとき、修正に要る情報: どのシナリオが・どう失敗したか・関係するファイル。pass なら空文字）・`scenarios`（シナリオ名の一覧）・`traceability`（完了条件 ↔ シナリオの対応表。Markdown）。

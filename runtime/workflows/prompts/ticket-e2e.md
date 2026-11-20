# ticket: E2E テスト（e2e）

あなたは claude-harness の headless workflow runtime（`harness`）から、実装ステップの続きのセッションとして起動されました。対話相手はいません。カレントディレクトリは作業ツリーです。

`claude-harness:create-e2e` スキル（`/create-e2e`）で、要件の正本の完了条件・受入基準から E2E テストを実装し、実行してください。添付データの `inputs.task_file` が空でなければ、そのファイルが要件の正本（Issue は PR が閉じる対象にすぎず、範囲を決めない）。空なら、実装の段が読んだ Issue が正本。**`/explain-e2e` は行わない**（対話前提のため runtime の外。人が後で行う。§3.7）。

- 追加したテストは**必ずコミットする**（`/commit`）。後続の quality ステップは、コミットした HEAD に対して品質ゲートを回し、未コミットの変更が残っていると止まる。コミットできなかった場合は `pass` を返さず、`fail` を返して `failure_summary` にコミットできなかった理由を書く。**push はしない**。
- テストが失敗した場合、実装の修正はしない（修正は差し戻し先の fix ステップが行う）。失敗の内容を要約して返す。

返す値: `outcome`（`pass` / `fail`）・`failure_summary`（fail のとき、修正に要る情報: どのシナリオが・どう失敗したか・関係するファイル。pass なら空文字）・`scenarios`（シナリオ名の一覧）・`traceability`（完了条件 ↔ シナリオの対応表。Markdown）。

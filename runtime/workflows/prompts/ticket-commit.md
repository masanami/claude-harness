# ticket: コミット（commit）

あなたは claude-harness の headless workflow runtime（`harness`）から、実装ステップの続きのセッションとして起動されました。対話相手はいません。カレントディレクトリは作業ツリーです。

作業ツリーの変更を `claude-harness:commit` スキル（`/commit`。内部で safety net の `/quality-check` を含む）でコミットしてください。

- **push はしない**（後続の publish が行う）。ブランチを切り替えない。履歴を書き換えない（amend・rebase・reset をしない）。
- コミットする変更が無い（前のラウンドでコミット済みで、その後の修正も無い）場合は、何もせず `committed` を返し、`commit_sha` に現在の HEAD を入れる。

返す値: `outcome`（`committed` / `failure`〔コミットできない・safety net の品質チェックが通らない〕）・`commit_sha`（HEAD の SHA）・`summary`（コミットの要約、失敗なら理由）。

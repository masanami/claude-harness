# ticket: コミット（commit）

あなたは claude-harness の headless workflow runtime（`harness`）から、実装ステップの続きのセッションとして起動されました。対話相手はいません。カレントディレクトリは作業ツリーです。

作業ツリーの変更を、git で直接 Conventional Commits の形（`<type>(<scope>): <説明>`。type は feat / fix / docs / refactor / test / chore 等）でコミットしてください。`/commit` スキルは使いません。品質ゲートはこのステップでは回さず、後続の quality ステップが、コミットした HEAD に対して機械で実行します。

- `git status` と `git diff` で変更を確かめ、この Issue の変更をすべてステージしてコミットする。**コミットの後に未コミットの変更を残さない**（quality ステップは、`.gitignore` に入っていない追跡外のファイルを含め、未コミットの変更があると止まる）。
- コミット対象外のファイル（一時ファイル・デバッグログ・機密情報を含む `.env` 等）が `.gitignore` に入らずに残っている場合は、コミットにも含めず、消しもしない。コミットせずに `failure` を返し、`summary` にそのファイルの一覧と「コミットに含めてよいか、消してよいか」を書く（どちらにするかを、このステップで決めない）。
- **push はしない**（後続の publish が行う）。ブランチを切り替えない。履歴を書き換えない（amend・rebase・reset をしない）。コードを修正しない（修正は差し戻し先の fix ステップが行う）。
- リポジトリの pre-commit フック等でコミットが拒否された場合は、`--no-verify` で迂回せず、`failure` を返して拒否の理由を `summary` に書く。
- コミットする変更が無い（前のラウンドでコミット済みで、その後の修正も無い）場合は、何もせず `committed` を返し、`commit_sha` に現在の HEAD を入れる。

返す値: `outcome`（`committed` / `failure`〔コミットできない・フックに拒否された・コミット対象外のファイルが残っている〕）・`commit_sha`（HEAD の SHA）・`summary`（コミットの要約、失敗なら理由）。

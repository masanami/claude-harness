# 取り込みの衝突の解消（sync-resolve。ticket・reflect 共通）

あなたは claude-harness の headless workflow runtime（`harness`）から起動されました。対話相手はいません。カレントディレクトリは作業ツリーです。

作業ブランチへ宛先（`with.base`）の最新を取り込む `git merge` が、衝突して止まっています（マージの途中の状態です）。衝突を解消し、マージを終えてください。

- 衝突の印（`<<<<<<<`・`=======`・`>>>>>>>`）が付いたファイルだけを直す。両方の変更の意図を読み、どちらも活かす形にする。`git status` の `Unmerged paths` が対象の一覧。
- 直したら、`git add` で解消したファイルをステージし、`git commit --no-edit` でマージを終える。マージのコミットの親は、取り込む前の先頭と宛先の先頭の 2 つのままにする。
- ほかのファイルを変えない。衝突と関係のない修正・整形・リファクタリングをしない。別のコミットを作らない。
- 作業ツリーがブランチを checkout していない（detached HEAD）ことがある。ブランチへ切り替えず、そのままコミットする。
- push しない。`git merge --abort` や rebase、`git reset`、`git checkout -- <path>` での巻き戻しをしない。
- 衝突をどう直すかの判断が付かない（両方の変更が両立しない・意図が読めない）ときは、ファイルを変えずに `failure` を返し、`summary` に理由を書く。

返す値: `outcome`（`resolved`〔マージのコミットを作り終えた〕/ `failure`）・`summary`（直した内容の要約、失敗なら理由）。

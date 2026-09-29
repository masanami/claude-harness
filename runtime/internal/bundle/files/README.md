# 埋め込む定義とスクリプトの置き場（生成物）

このディレクトリの `workflows/`・`scripts/`・`agents/` は、リポジトリのルートで `make bundle` が作る写しである（docs/harness-runtime-design.md §6.5 の S1）。git には入れない（`.gitignore`）。

- `workflows/` ← `runtime/workflows/`
- `scripts/` ← `plugin/scripts/`（`tests/` を除く）
- `agents/` ← `plugin/agents/`（`harness validate` が `agent:` の参照先の実在を確かめるためだけに使う。子の `claude -p` はインストール済みのプラグインから解決する）

このファイルだけはコミットする（写しが無くても `go:embed` の対象が在り、ビルドが通るように）。写しの無いバイナリは定義を持たず、`--workflow-dir` / `--scripts-dir` を要求する。

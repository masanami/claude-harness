# prompts/

`llm` 種類が使うプロンプト（Markdown）の置き場。`ticket-*.md` は `ticket` ワークフロー（`../ticket.yaml`・PR-4）のもの。`conflict-predict.md` は `conflict-predict-issue` ワークフロー（`../conflict-predict-issue.yaml`・#288）のもの。
runtime はプロンプトの本文の後ろに、ステップの `with` の値と run の現在地（ラウンド・残予算・直前のゲートの入力）を JSON のデータブロックとして添えて `claude -p` の stdin へ渡す（本文へ文字列置換で埋め込まない。§3.3・§4.4）。
型付きの出力（`--json-schema`）の形は `../schemas/` にあり、プロンプトは「何を返すか」の意味だけを書く（形は runtime がスキーマで強制する）。
配置は `docs/harness-runtime-design.md` §6.1。

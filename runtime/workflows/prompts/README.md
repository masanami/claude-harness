# prompts/

`llm` 種類が使うプロンプト（Markdown）の置き場。`llm` 種類は PR-3 で入ったが、同梱のワークフロー（`ticket` 等）は PR-4 以降なので、まだ空。
runtime はプロンプトの本文の後ろに、ステップの `with` の値と run の現在地（ラウンド・残予算・直前のゲートの入力）を JSON のデータブロックとして添えて `claude -p` の stdin へ渡す（本文へ文字列置換で埋め込まない。§3.3・§4.4）。
配置は `docs/harness-runtime-design.md` §6.1。

# spec-lint.sh の出力仕様（正本）

`/define-feature`（`skills/define-feature/SKILL.md` Step 6.5-1）が、Lint フェーズで Bash ツールから直接このスクリプトを呼び出す（Issue #51で新設）。機能仕様ドキュメント（`docs/features/{slug}.md`）に対する4つの決定的チェックの候補列挙のみを行い、**severity（blocker/minor/needs_user_input）の判定は行わない**（severity判定は呼び出し元の批評エージェント `agents/spec-critic.md` の責務）。gh呼び出しは一切行わない（gh非依存）。

## `scripts/spec-lint.sh <spec-file-path>`

stdout JSON:
```json
{
  "spec_file": "<入力パス>",
  "ambiguous_words": [{"line": 1, "word": "適切に", "text": "..."}],
  "template_placeholders": [{"line": 1, "text": "{採用案}"}],
  "broken_references": [{"line": 1, "path": "docs/foo.md", "exists": false}],
  "checklist_format_issues": [{"line": 1, "section": "機能要件", "text": "..."}]
}
```

| フィールド | 型 | 意味 |
|---|---|---|
| `spec_file` | string | 入力パスそのまま |
| `ambiguous_words` | `[{line, word, text}]` | スクリプト内蔵の単一定義の曖昧語辞書（「適切に」「必要に応じて」「など」「等」「柔軟に」等）でのマッチ候補。1行に複数語がマッチした場合は複数エントリを返す |
| `template_placeholders` | `[{line, text}]` | `{...}`（中身が空でない）形式のテンプレートプレースホルダ残骸の候補 |
| `broken_references` | `[{line, path, exists}]` | 本文中のバッククォート囲み（`` `path/to/file` `` 形式）のパス参照のうち、`/` を含み `{` `}` を含まないものを対象に、spec ファイルの位置から `git rev-parse --show-toplevel` で解決したリポジトリルート起点で存在確認した結果。**存在しないパスのみ**を返す（`exists` は常に `false`）。**URIスキーム付き文字列**（`https:` `http:` `mailto:` 等。`^[A-Za-z][A-Za-z0-9+.-]*:` にマッチするもの）と**`/` で始まる絶対パス**は対象外として存在確認前に除外する（誤検出防止） |
| `checklist_format_issues` | `[{line, section, text}]` | 「## 機能要件」「## 受入基準」セクション（次の `## ` 見出しまで）配下のリスト項目（`- ` 始まり）のうち、`- [ ] ` / `- [x] ` / `- [X] ` 形式になっていない行 |

挙動の要点:

- 4検査それぞれが `detect_ambiguous_words` / `detect_template_placeholders` / `detect_broken_references` / `detect_checklist_format_issues` として関数分離されており、スクリプトを `source` すれば直接テストできる（`extract-acceptance-criteria.sh` のパターンを踏襲）
- `broken_references` のリポジトリルート解決（`resolve_repo_root`）は、spec ファイルの位置から `git rev-parse --show-toplevel` を試み、失敗した場合（gitが使えない・リポジトリ外）は spec ファイルのディレクトリにフォールバックする（エラーにはしない）
- jq不在時は stderr にエラーメッセージ + エラーJSONを出し exit 非0（`scripts/README.md`「出力規約」に従う）
- 入力ファイルが存在しない場合も stderr にメッセージを出し exit 非0

#!/bin/bash
# test-pr-merge-workflow.sh
# skills/pr-merge/scripts/merge-judge.js（Dynamic Workflow スクリプト）の
# 構文妥当性とロジックをテストする。
#
# 実行方法: bash scripts/tests/test-pr-merge-workflow.sh
#
# (a) `node --check` でスクリプトの構文妥当性を検証する
# (b) 静的ガード: merge-judge.js が node:fs/node:child_process への参照や
#     import/require を一切含まないことを検証する（Workflowランタイムはこれらに
#     アクセスできないサンドボックスで実行されるため。再発防止のためのガード）
# (c) 純粋関数（findingKey/isRiskGateTriggered/mapBlockerToFindingInput/isPanelVetoed/
#     buildXxxPrompt）と default export（mock した agent/parallel/pipeline 経由。
#     agent() が opts.agentType === 'claude-harness:git-ops' を見て diff収集・hunk抽出の
#     モック応答を返す）を scripts/tests/pr-merge-workflow-smoke.mjs で検証する
#
# node が不在の環境では、format-on-save.sh の防御的スタイル（機能をスキップしても
# 実害が小さい処理は無言でクラッシュさせず skip する）に倣い、このテスト全体を
# skip 扱いにする（非0 exitにしない。skip した旨を出力する）。
# merge-judge.js 自体は本テストが無くても shellcheck 等の対象外のまま動作するため、
# node 不在は「このテストを実行できない」だけであり、他ゲートの失敗を意味しない。

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW_JS="${SCRIPT_DIR}/../../skills/pr-merge/scripts/merge-judge.js"
SMOKE_MJS="${SCRIPT_DIR}/pr-merge-workflow-smoke.mjs"

main() {
  if ! command -v node &>/dev/null; then
    echo "SKIP: node not found in PATH. Skipping merge-judge.js syntax/logic checks." >&2
    echo "skip: node not found"
    exit 0
  fi

  if [ ! -f "$WORKFLOW_JS" ]; then
    echo "Error: workflow script not found at ${WORKFLOW_JS}" >&2
    exit 1
  fi

  echo "=== node --check (syntax) ==="
  if ! node --check "$WORKFLOW_JS"; then
    echo "NG - node --check failed for ${WORKFLOW_JS}"
    exit 1
  fi
  echo "ok - node --check passed"
  echo ""

  echo "=== runtime-restriction guard (no Node builtin imports) ==="
  # 空白付きimport（行頭以外のインデント含む）・require前の空白・dynamic import(...)も検出する。
  if grep -nE 'child_process|node:fs|require[[:space:]]*\(|(^|[[:space:]])import[[:space:]]*(\(|[[:space:]])' "$WORKFLOW_JS"; then
    echo "NG - merge-judge.js must not reference Node built-in modules or use import/require (Workflow runtime has no fs/child_process/module access)"
    exit 1
  fi
  echo "ok - no forbidden Node builtin references found"
  echo ""

  echo "=== smoke test (logic) ==="
  if ! node "$SMOKE_MJS"; then
    echo "NG - smoke test failed"
    exit 1
  fi

  exit 0
}

main "$@"

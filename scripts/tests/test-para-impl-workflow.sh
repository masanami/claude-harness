#!/bin/bash
# test-para-impl-workflow.sh
# skills/para-impl/scripts/para-impl-tickets.js（Dynamic Workflow スクリプト）の
# 構文妥当性とロジックをテストする。
#
# 実行方法: bash scripts/tests/test-para-impl-workflow.sh
#
# (a) `node --check` でスクリプトの構文妥当性を検証する
# (b) 静的ガード: para-impl-tickets.js が node:fs/node:child_process への参照や
#     import/require を一切含まないことを検証する（Workflowランタイムはこれらに
#     アクセスできないサンドボックスで実行されるため。再発防止のためのガード）
# (c) 純粋関数とdefault export（mock した agent/parallel/pipeline/workflow 経由）を
#     scripts/tests/para-impl-workflow-smoke.mjs で検証する
#
# node が不在の環境では、他の *-workflow smoke テストと同じ防御的スタイルに倣い、
# このテスト全体を skip 扱いにする（非0 exitにしない）。

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW_JS="${SCRIPT_DIR}/../../skills/para-impl/scripts/para-impl-tickets.js"
SMOKE_MJS="${SCRIPT_DIR}/para-impl-workflow-smoke.mjs"

main() {
  if ! command -v node &>/dev/null; then
    echo "SKIP: node not found in PATH. Skipping para-impl-tickets.js syntax/logic checks." >&2
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
  if grep -nE 'child_process|node:fs|require[[:space:]]*\(|(^|[[:space:]])import[[:space:]]*(\(|[[:space:]])' "$WORKFLOW_JS"; then
    echo "NG - para-impl-tickets.js must not reference Node built-in modules or use import/require (Workflow runtime has no fs/child_process/module access)"
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

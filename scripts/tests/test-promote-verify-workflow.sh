#!/bin/bash
# test-promote-verify-workflow.sh
# skills/promote-verify/scripts/promote-verify.js（Dynamic Workflow スクリプト）の
# 構文妥当性とロジックをテストする。
#
# 実行方法: bash scripts/tests/test-promote-verify-workflow.sh
#
# (a) `node --check` でスクリプトの構文妥当性を検証する
# (b) 静的ガード: promote-verify.js が node:fs/node:child_process への参照や
#     import/require を一切含まないことを検証する（Workflowランタイムはこれらに
#     アクセスできないサンドボックスで実行されるため。再発防止のためのガード）
# (c) 純粋関数（chunkArray/computeReadyForPromotion/buildXxxPrompt）と default export
#     （mock した agent/parallel/pipeline 経由。agent() が opts.agentType/opts.label を見て
#     応答を返す）を scripts/tests/promote-verify-workflow-smoke.mjs で検証する
#
# node が不在の環境では、format-on-save.sh の防御的スタイル（機能をスキップしても
# 実害が小さい処理は無言でクラッシュさせず skip する）に倣い、このテスト全体を
# skip 扱いにする（非0 exitにしない。skip した旨を出力する）。
# promote-verify.js 自体は本テストが無くても shellcheck 等の対象外のまま動作するため、
# node 不在は「このテストを実行できない」だけであり、他ゲートの失敗を意味しない。

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW_JS="${SCRIPT_DIR}/../../skills/promote-verify/scripts/promote-verify.js"
SMOKE_MJS="${SCRIPT_DIR}/promote-verify-workflow-smoke.mjs"

main() {
  if ! command -v node &>/dev/null; then
    echo "SKIP: node not found in PATH. Skipping promote-verify.js syntax/logic checks." >&2
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
    echo "NG - promote-verify.js must not reference Node built-in modules or use import/require (Workflow runtime has no fs/child_process/module access)"
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

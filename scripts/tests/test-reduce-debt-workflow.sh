#!/bin/bash
# test-reduce-debt-workflow.sh
# skills/reduce-debt/scripts/reduce-debt-scan.js（Dynamic Workflow スクリプト）の
# 構文妥当性とロジックをテストする。
#
# 実行方法: bash scripts/tests/test-reduce-debt-workflow.sh
#
# (a) `node --check` でスクリプトの構文妥当性を検証する
# (b) 純粋関数（classifyParentRelation/decideVerdict/planScanBuckets）と
#     default export（mock した agent/pipeline/parallel 経由）を
#     scripts/tests/reduce-debt-workflow-smoke.mjs で検証する
#
# node が不在の環境では、format-on-save.sh の防御的スタイル（機能をスキップしても
# 実害が小さい処理は無言でクラッシュさせず skip する）に倣い、このテスト全体を
# skip 扱いにする（非0 exitにしない。skip した旨を出力する）。
# reduce-debt-scan.js 自体は本テストが無くても shellcheck 等の対象外のまま動作するため、
# node 不在は「このテストを実行できない」だけであり、他ゲートの失敗を意味しない。

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW_JS="${SCRIPT_DIR}/../../skills/reduce-debt/scripts/reduce-debt-scan.js"
SMOKE_MJS="${SCRIPT_DIR}/reduce-debt-workflow-smoke.mjs"

main() {
  if ! command -v node &>/dev/null; then
    echo "SKIP: node not found in PATH. Skipping reduce-debt-scan.js syntax/logic checks." >&2
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

  echo "=== smoke test (logic) ==="
  if ! node "$SMOKE_MJS"; then
    echo "NG - smoke test failed"
    exit 1
  fi

  exit 0
}

main "$@"

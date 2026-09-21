# 品質ゲートの入口（docs/harness-runtime-design.md §6.3）。
# ルートは配布物（plugin/）の外にあるため、この Makefile は利用者の環境へ配布されない。
#
#   make check   bash テスト全件（plugin/scripts/tests/*.sh）を順に実行し、失敗したテスト名を
#                集計する。1 本でも落ちれば非 0 で終わる。
#
# 途中で落ちても残りを最後まで実行する（最初の失敗で止めると、失敗の全体像が 1 回で分からない）。
# テストが 1 本も見つからない場合も失敗にする（検査していないものを通過と報告しない）。

SHELL := /bin/bash
TESTS_DIR := plugin/scripts/tests

.PHONY: check check-bash

check: check-bash

check-bash:
	@total=0; failed=0; failed_names=""; \
	for t in $(TESTS_DIR)/*.sh; do \
	  [ -f "$${t}" ] || continue; \
	  total=$$((total + 1)); \
	  echo "=== $${t}"; \
	  if bash "$${t}"; then :; else \
	    failed=$$((failed + 1)); \
	    failed_names="$${failed_names} $${t}"; \
	  fi; \
	done; \
	echo ""; \
	echo "=== make check: bash tests total=$${total} passed=$$((total - failed)) failed=$${failed}"; \
	if [ "$${total}" -eq 0 ]; then \
	  echo "NG: no tests found under $(TESTS_DIR)"; exit 1; \
	fi; \
	if [ "$${failed}" -ne 0 ]; then \
	  for name in $${failed_names}; do echo "  FAILED: $${name}"; done; \
	  exit 1; \
	fi

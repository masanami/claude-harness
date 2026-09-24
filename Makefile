# 品質ゲートの入口（docs/harness-runtime-design.md §6.3）。
# ルートは配布物（plugin/）の外にあるため、この Makefile は利用者の環境へ配布されない。
#
#   make check           次の 3 つをすべて実行し、1 つでも落ちれば非 0 で終わる。
#   make check-bash      bash テスト全件（plugin/scripts/tests/*.sh）を順に実行し、失敗したテスト名を集計する。
#   make check-go        runtime/ の gofmt・go vet ./...・go test ./...
#   make check-validate  harness validate（runtime/workflows/*.yaml の静的検証）
#
# 途中で落ちても残りを最後まで実行する（最初の失敗で止めると、失敗の全体像が 1 回で分からない）。
# テストが 1 本も見つからない場合も失敗にする（検査していないものを通過と報告しない）。
# 同じ理由で、go が無い環境では Go のゲートを skip せず失敗にする（§6.3）。

SHELL := /bin/bash
TESTS_DIR := plugin/scripts/tests
RUNTIME_DIR := runtime

.PHONY: check check-bash check-go check-validate require-go

check:
	@failed=""; \
	$(MAKE) --no-print-directory check-bash || failed="$${failed} check-bash"; \
	$(MAKE) --no-print-directory check-go || failed="$${failed} check-go"; \
	$(MAKE) --no-print-directory check-validate || failed="$${failed} check-validate"; \
	echo ""; \
	if [ -n "$${failed}" ]; then \
	  echo "=== make check: FAILED:$${failed}"; exit 1; \
	fi; \
	echo "=== make check: all gates passed (check-bash check-go check-validate)"

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

require-go:
	@command -v go >/dev/null 2>&1 || { \
	  echo "NG: go not found in PATH; the Go gates (gofmt, go vet, go test, harness validate) cannot run."; \
	  echo "    Install Go (see $(RUNTIME_DIR)/go.mod for the version). A missing toolchain is a failure, not a skip."; \
	  exit 1; \
	}

check-go: require-go
	@echo "=== gofmt -l $(RUNTIME_DIR)"
	@files="$$(cd $(RUNTIME_DIR) && gofmt -l .)"; \
	if [ -n "$${files}" ]; then echo "NG: gofmt found unformatted files:"; echo "$${files}"; exit 1; fi
	@echo "=== go vet ./..."
	cd $(RUNTIME_DIR) && go vet ./...
	@echo "=== go test ./..."
	cd $(RUNTIME_DIR) && go test ./...

check-validate: require-go
	@echo "=== harness validate"
	cd $(RUNTIME_DIR) && go run ./cmd/harness validate --workflow-dir workflows --scripts-dir ../plugin/scripts

# 品質ゲートの入口（docs/harness-runtime-design.md §6.3）。
# ルートは配布物（plugin/）の外にあるため、この Makefile は利用者の環境へ配布されない。
#
#   make check           次の 3 つをすべて実行し、1 つでも落ちれば非 0 で終わる。
#   make check-bash      bash テスト全件（plugin/scripts/tests/*.sh）を順に実行し、失敗したテスト名を集計する。
#   make check-go        runtime/ の gofmt・go vet ./...・go test ./...・check-go-linux
#   make check-go-linux  Linux（amd64・arm64）向けの go vet ./... とテストバイナリのビルド（Linux 上での実行はしない）
#   make check-validate  harness validate（runtime/workflows/*.yaml の静的検証。作業ツリーの定義と、埋め込んだ定義の両方）
#   make bundle          埋め込む定義・スクリプトの写しを runtime/internal/bundle/files/ へ作る（§6.5 の S1。check-go・dist の前提）
#   make dist VERSION=X.Y.Z  リリースの成果物を $(DIST_DIR)/ へ作る（§6.4。タグ runtime/vX.Y.Z の push で GitHub Actions が呼ぶ）
#
# 途中で落ちても残りを最後まで実行する（最初の失敗で止めると、失敗の全体像が 1 回で分からない）。
# テストが 1 本も見つからない場合も失敗にする（検査していないものを通過と報告しない）。
# 同じ理由で、go が無い環境では Go のゲートを skip せず失敗にする（§6.3）。

SHELL := /bin/bash
TESTS_DIR := plugin/scripts/tests
RUNTIME_DIR := runtime
BUNDLE_DIR := $(RUNTIME_DIR)/internal/bundle/files
VERSION_PKG := github.com/masanami/claude-harness/runtime/internal/version
DIST_DIR ?= dist
PLATFORMS ?= darwin/arm64 darwin/amd64 linux/amd64 linux/arm64
LINUX_CHECK_ARCHS ?= amd64 arm64

.PHONY: check check-bash check-go check-go-linux check-validate require-go bundle dist

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

# plugin/scripts（tests/ を除く）・plugin/agents・runtime/workflows を写す。go:embed はモジュールの外を指せないため
# モジュールの中へ写す（写しは .gitignore。agents/ は validate が agent: の参照先を確かめるためだけに使う）。
# 一時ディレクトリに作って比べ、違うときだけ置き換える（同時に走る go test のビルドが消えかけの写しを読まないように）。
bundle:
	@echo "=== bundle -> $(BUNDLE_DIR)"
	@set -e; tmp="$$(mktemp -d "$${TMPDIR:-/tmp}/harness-bundle.XXXXXX")"; \
	trap 'rm -rf "$${tmp}"' EXIT; \
	cp -R $(RUNTIME_DIR)/workflows "$${tmp}/workflows"; \
	cp -R plugin/scripts "$${tmp}/scripts"; \
	rm -rf "$${tmp}/scripts/tests"; \
	cp -R plugin/agents "$${tmp}/agents"; \
	mkdir -p "$(BUNDLE_DIR)"; \
	for d in workflows scripts agents; do \
	  if [ -d "$(BUNDLE_DIR)/$${d}" ] && diff -r -q "$${tmp}/$${d}" "$(BUNDLE_DIR)/$${d}" >/dev/null; then continue; fi; \
	  rm -rf "$(BUNDLE_DIR)/$${d}"; mv "$${tmp}/$${d}" "$(BUNDLE_DIR)/$${d}"; echo "    updated $${d}/"; \
	done

check-go: require-go bundle
	@echo "=== gofmt -l $(RUNTIME_DIR)"
	@files="$$(cd $(RUNTIME_DIR) && gofmt -l .)"; \
	if [ -n "$${files}" ]; then echo "NG: gofmt found unformatted files:"; echo "$${files}"; exit 1; fi
	@echo "=== go vet ./..."
	cd $(RUNTIME_DIR) && go vet ./...
	@echo "=== go test ./..."
	cd $(RUNTIME_DIR) && go test ./...
	@$(MAKE) --no-print-directory check-go-linux

# 手元の OS（macOS）だけで通すと、Linux に無い API（syscall.Getsid 等）を使ったテストが、Linux でビルドできないまま
# 通過してしまう（PR #348）。Linux の各アーキテクチャ向けに vet とテストのビルドだけを行う（Linux 上での実行はしない）。
# テストのビルドは -exec /usr/bin/true で全パッケージを一度に通す（go test -c -o /dev/null は 1 パッケージしか取れない）。
# 走らせるのは true なので、ok と表示されてもテストは実行されていない。cgo は使わない（dist と同じく CGO_ENABLED=0）。
# 途中で落ちても全アーキテクチャを最後まで回し、落ちたものをまとめて報告する。
check-go-linux: require-go bundle
	@failed=""; \
	for arch in $(LINUX_CHECK_ARCHS); do \
	  echo "=== GOOS=linux GOARCH=$${arch} go vet ./..."; \
	  (cd $(RUNTIME_DIR) && CGO_ENABLED=0 GOOS=linux GOARCH="$${arch}" go vet ./...) || failed="$${failed} vet/linux/$${arch}"; \
	  echo "=== GOOS=linux GOARCH=$${arch} go test -run '^$$' -exec /usr/bin/true ./... (build only)"; \
	  (cd $(RUNTIME_DIR) && CGO_ENABLED=0 GOOS=linux GOARCH="$${arch}" go test -run '^$$' -exec /usr/bin/true ./...) || failed="$${failed} test-build/linux/$${arch}"; \
	done; \
	if [ -n "$${failed}" ]; then echo "NG: Linux cross check failed:$${failed}"; exit 1; fi; \
	echo "=== check-go-linux: passed ($(LINUX_CHECK_ARCHS))"

# 2 回目は埋め込んだ定義を、作業ツリーの外（一時ディレクトリ）から --workflow-dir / --scripts-dir 無しで検証する。
# 展開先（HARNESS_DATA_DIR）も一時ディレクトリへ向け、利用者の ~/.local/share を汚さない。
check-validate: require-go bundle
	@echo "=== harness validate (working tree)"
	cd $(RUNTIME_DIR) && go run ./cmd/harness validate --workflow-dir workflows --scripts-dir ../plugin/scripts
	@echo "=== harness validate (embedded)"
	@set -e; tmp="$$(mktemp -d "$${TMPDIR:-/tmp}/harness-validate.XXXXXX")"; \
	trap 'rm -rf "$${tmp}"' EXIT; \
	(cd $(RUNTIME_DIR) && go build -o "$${tmp}/harness" ./cmd/harness); \
	cd "$${tmp}" && HARNESS_DATA_DIR="$${tmp}/data" ./harness validate

# リリースの成果物（§6.4）: $(PLATFORMS) ごとに harness_<版>_<os>_<arch>.tar.gz（中身は harness の 1 ファイル）と、
# 全アーカイブの sha256 を並べた checksums.txt。版は -ldflags で埋める（harness version が表示する）。
dist: require-go bundle
	@if [ -z "$(VERSION)" ]; then echo "NG: make dist needs VERSION=X.Y.Z (the tag runtime/vX.Y.Z without runtime/v)"; exit 1; fi
	@if ! printf '%s' "$(VERSION)" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$$'; then echo "NG: VERSION=$(VERSION) is not a semver X.Y.Z[-pre]"; exit 1; fi
	@set -e; stage=""; trap 'if [ -n "$${stage}" ]; then rm -rf "$${stage}"; fi' EXIT; \
	out="$$(mkdir -p "$(DIST_DIR)" && cd "$(DIST_DIR)" && pwd)"; \
	rm -f "$${out}"/harness_*.tar.gz "$${out}/checksums.txt"; \
	for p in $(PLATFORMS); do \
	  os="$${p%/*}"; arch="$${p#*/}"; name="harness_$(VERSION)_$${os}_$${arch}"; \
	  echo "=== build $${name}"; \
	  stage="$$(mktemp -d "$${TMPDIR:-/tmp}/harness-dist.XXXXXX")"; \
	  (cd $(RUNTIME_DIR) && CGO_ENABLED=0 GOOS="$${os}" GOARCH="$${arch}" \
	    go build -trimpath -ldflags "-s -w -X $(VERSION_PKG).Version=$(VERSION)" -o "$${stage}/harness" ./cmd/harness); \
	  tar -C "$${stage}" -czf "$${out}/$${name}.tar.gz" harness; \
	  rm -rf "$${stage}"; stage=""; \
	done; \
	cd "$${out}" && if command -v sha256sum >/dev/null 2>&1; then sha256sum harness_*.tar.gz; else shasum -a 256 harness_*.tar.gz; fi > checksums.txt; \
	echo "=== dist: $${out}"; ls -1 "$${out}"

#!/bin/bash
# テスト用: カレントディレクトリ（symlink を解決した実体）を JSON で出す（ステップがどのディレクトリで動いたかを確かめる）。
printf '{"outcome":"ok","dir":"%s","scripts_dir":"%s"}\n' "$(pwd -P)" "${HARNESS_SCRIPTS_DIR:-}"

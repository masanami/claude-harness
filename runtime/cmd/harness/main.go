// Command harness は claude-harness の headless workflow runtime（docs/harness-runtime-design.md）。
package main

import (
	"os"

	"github.com/masanami/claude-harness/runtime/internal/cli"
)

func main() {
	os.Exit(cli.Main(os.Args[1:], cli.DefaultEnv()))
}

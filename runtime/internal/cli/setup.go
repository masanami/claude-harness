package cli

// harness setup（docs/harness-runtime-design.md §5.1・決定①）: claude plugin marketplace add / claude plugin install を呼んで
// プラグインを整え、導入されたプラグインの版を CLI の対応範囲と照合する。
//
// 何度実行してもよい: marketplace が登録済みなら add しない、プラグインが導入済みなら install しない（更新もしない。
// 自動更新は持たない。範囲外なら更新の方法を案内して ExitVersion で止まる）。

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
	"strings"

	"github.com/masanami/claude-harness/runtime/internal/version"
)

// Marketplace は claude-harness の marketplace（.claude-plugin/marketplace.json の name）と、既定の登録元。
const (
	MarketplaceName   = "masanami-harness"
	MarketplaceSource = "masanami/claude-harness"
	PluginID          = "claude-harness@" + MarketplaceName
)

type marketplaceEntry struct {
	Name string `json:"name"`
}

type pluginEntry struct {
	ID      string `json:"id"`
	Version string `json:"version"`
	Scope   string `json:"scope"`
	Enabled bool   `json:"enabled"`
}

func cmdSetup(args []string, env Env) int {
	flags, pos, err := parseArgs(args, flagSpec{name: "scope", value: true}, flagSpec{name: "marketplace", value: true})
	if err != nil {
		return usageErr(env, err)
	}
	if len(pos) != 0 {
		return usageErr(env, errors.New("setup takes no arguments"))
	}
	scope := first(flags, "scope")
	switch scope {
	case "", "user", "project", "local":
	default:
		return usageErr(env, fmt.Errorf("--scope must be user, project or local (got %q)", scope))
	}
	src := first(flags, "marketplace")
	if src == "" {
		src = MarketplaceSource
	}
	claude := env.Getenv("HARNESS_CLAUDE_BIN")
	if claude == "" {
		claude = "claude"
	}
	run := func(capture bool, args ...string) ([]byte, bool) {
		cmd := exec.Command(claude, args...)
		var out bytes.Buffer
		cmd.Stdout, cmd.Stderr = &out, env.Stderr
		if !capture {
			cmd.Stdout = env.Stderr
		}
		if err := cmd.Run(); err != nil {
			fmt.Fprintf(env.Stderr, "harness: setup: %s %s failed: %v\n", claude, strings.Join(args, " "), err)
			return nil, false
		}
		return out.Bytes(), true
	}
	withScope := func(args ...string) []string {
		if scope != "" {
			args = append(args, "--scope", scope)
		}
		return args
	}

	// 1. marketplace
	out, ok := run(true, "plugin", "marketplace", "list", "--json")
	if !ok {
		return ExitFailed
	}
	var markets []marketplaceEntry
	if err := json.Unmarshal(out, &markets); err != nil {
		fmt.Fprintf(env.Stderr, "harness: setup: cannot read claude plugin marketplace list --json: %v\n", err)
		return ExitFailed
	}
	registered := false
	for _, m := range markets {
		registered = registered || m.Name == MarketplaceName
	}
	if registered {
		fmt.Fprintf(env.Stdout, "marketplace %s: already added\n", MarketplaceName)
	} else {
		if _, ok := run(false, withScope("plugin", "marketplace", "add", src)...); !ok {
			return ExitFailed
		}
		fmt.Fprintf(env.Stdout, "marketplace %s: added from %s\n", MarketplaceName, src)
	}

	// 2. plugin
	installed, ok := listPlugin(env, run)
	if !ok {
		return ExitFailed
	}
	if len(installed) > 0 {
		fmt.Fprintf(env.Stdout, "plugin %s: already installed\n", PluginID)
	} else {
		if _, ok := run(false, withScope("plugin", "install", PluginID)...); !ok {
			return ExitFailed
		}
		if installed, ok = listPlugin(env, run); !ok {
			return ExitFailed
		}
		if len(installed) == 0 {
			fmt.Fprintf(env.Stderr, "harness: setup: %s is not listed by claude plugin list after the install\n", PluginID)
			return ExitFailed
		}
		fmt.Fprintf(env.Stdout, "plugin %s: installed\n", PluginID)
	}

	// 3. 版の照合（導入されたすべての scope）
	code := ExitOK
	for _, p := range installed {
		state := "enabled"
		if !p.Enabled {
			state = "disabled (claude plugin enable " + PluginID + ")"
		}
		if err := version.CheckPlugin(p.Version); err != nil {
			fmt.Fprintf(env.Stdout, "plugin %s %s (scope %s, %s): not supported by harness %s\n", PluginID, p.Version, p.Scope, state, version.CLI())
			fmt.Fprintf(env.Stderr, "harness: %v\n", err)
			code = ExitVersion
			continue
		}
		fmt.Fprintf(env.Stdout, "plugin %s %s (scope %s, %s): supported by harness %s (%s)\n", PluginID, p.Version, p.Scope, state, version.CLI(), version.PluginRange())
	}
	return code
}

func listPlugin(env Env, run func(bool, ...string) ([]byte, bool)) ([]pluginEntry, bool) {
	out, ok := run(true, "plugin", "list", "--json")
	if !ok {
		return nil, false
	}
	var all []pluginEntry
	if err := json.Unmarshal(out, &all); err != nil {
		fmt.Fprintf(env.Stderr, "harness: setup: cannot read claude plugin list --json: %v\n", err)
		return nil, false
	}
	var mine []pluginEntry
	for _, p := range all {
		if p.ID == PluginID {
			mine = append(mine, p)
		}
	}
	return mine, true
}

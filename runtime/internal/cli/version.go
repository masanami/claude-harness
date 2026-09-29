package cli

// 配布（docs/harness-runtime-design.md §6.5・§7）: 埋め込んだ定義・スクリプトの展開、version、プラグイン版の照合、
// 版をまたぐ resume（N3）。

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/masanami/claude-harness/runtime/internal/bundle"
	"github.com/masanami/claude-harness/runtime/internal/engine"
	"github.com/masanami/claude-harness/runtime/internal/runstate"
	"github.com/masanami/claude-harness/runtime/internal/statedir"
	"github.com/masanami/claude-harness/runtime/internal/version"
)

// PluginVersionEnv は呼び出し元（薄いスキル）が自分のプラグイン版を渡す環境変数。設定されていれば run・resume・approve
// （contract start・resume を含む）の前に範囲を照合し、範囲外なら ExitVersion で止まる（§7.3）。
// 設定されていなければ照合しない（スキルを通さない起動。flywheel・CI・人の端末）。
const PluginVersionEnv = "HARNESS_PLUGIN_VERSION"

// bundleDirName は展開先のディレクトリ名。版を持たないビルド（dev）は中身ごとに名前を分ける（同じ dev の名前で
// 中身の違う写しを上書きしない）。
func bundleDirName(digest string) string {
	v := version.CLI()
	if v == version.Dev {
		return "dev-" + digest[:12]
	}
	return v
}

// embeddedRoot は埋め込んだ定義を展開するディレクトリ（まだ展開しない）。埋め込んでいなければ bundle.ErrNotEmbedded。
func embeddedRoot(env Env) (root, digest string, err error) {
	if !bundle.Available(bundle.FS) {
		return "", "", bundle.ErrNotEmbedded
	}
	digest, err = bundle.Digest(bundle.FS)
	if err != nil {
		return "", "", err
	}
	data, err := statedir.ResolveData(env.Getenv)
	if err != nil {
		return "", "", err
	}
	return statedir.RuntimeDir(data, bundleDirName(digest)), digest, nil
}

// embeddedLayout は埋め込んだ定義を展開して、その場所を返す（展開済みなら印を確かめて使う）。
func embeddedLayout(env Env) (bundle.Layout, error) {
	root, _, err := embeddedRoot(env)
	if err != nil {
		return bundle.Layout{}, err
	}
	return bundle.Ensure(bundle.FS, root)
}

// checkPlugin は PluginVersionEnv が設定されていれば範囲を照合する。止めるなら終了コードを、続けてよければ -1 を返す。
func checkPlugin(env Env) int {
	p := env.Getenv(PluginVersionEnv)
	if p == "" {
		return -1
	}
	if err := version.CheckPlugin(p); err != nil {
		var m *version.Mismatch
		if errors.As(err, &m) {
			fmt.Fprintf(env.Stderr, "harness: %v\n", err)
			return ExitVersion
		}
		fmt.Fprintf(env.Stderr, "harness: %s: %v\n", PluginVersionEnv, err)
		return ExitUsage
	}
	return -1
}

// versionError は run を始めた版の定義で続けられないこと（N3）。終了コード ExitVersion で止め、開始時の版での resume か cancel を案内する。
type versionError struct{ msg string }

func (e *versionError) Error() string { return e.msg }

func startedBy(st *runstate.State) string {
	if st.CLIVersion == "" {
		return "the harness version that started it (not recorded)"
	}
	return "harness " + st.CLIVersion
}

func versionErrorf(st *runstate.State, format string, args ...any) error {
	return &versionError{msg: fmt.Sprintf(format, args...) +
		fmt.Sprintf("; resume run %s with %s, or stop it with harness cancel %s", st.RunID, startedBy(st), st.RunID)}
}

// reopen は run を開始時の定義で開き直す（N3）。埋め込みから始めた run は、開始時の版の展開ディレクトリ
// （<data>/runtime/<開始時の版>/）の定義を、この CLI がそのスキーマ版を読めれば読んで続ける。そのディレクトリが無く、
// 開始時の版がこの CLI と同じなら展開し直す。読めなければ versionError で止まる。
func reopen(env Env, run *runstate.Run, st *runstate.State) (*engine.Engine, error) {
	if !version.SupportsSchema(st.Workflow.Schema) {
		return nil, versionErrorf(st, "run %s uses workflow schema %q, which this harness %s does not read (supported: %v)",
			st.RunID, st.Workflow.Schema, version.CLI(), version.WorkflowSchemas)
	}
	if st.Embedded {
		if _, err := os.Stat(st.Workflow.Path); errors.Is(err, os.ErrNotExist) {
			root, _, rerr := embeddedRoot(env)
			if rerr != nil || filepath.Clean(root) != filepath.Clean(filepath.Dir(st.WorkflowDir)) {
				return nil, versionErrorf(st, "the definitions run %s started with (%s) are gone", st.RunID, filepath.Dir(st.WorkflowDir))
			}
			// 開始時と同じ版（同じ中身）の CLI: 消された展開ディレクトリを作り直す。
			if _, err := embeddedLayout(env); err != nil {
				return nil, err
			}
		}
	}
	eng, err := engine.Reopen(run, st)
	var re *engine.ReopenError
	if errors.As(err, &re) && re.Load && st.Embedded && st.CLIVersion != version.CLI() {
		return nil, versionErrorf(st, "this harness %s cannot load the definitions of %s: %v", version.CLI(), startedBy(st), re)
	}
	return eng, err
}

// versionView は version --json の中身（§5.1・§7.3）。
type versionView struct {
	CLIVersion         string       `json:"cli_version"`
	PluginVersionRange pluginRange  `json:"plugin_version_range"`
	WorkflowSchemas    []string     `json:"workflow_schemas"`
	Embedded           bool         `json:"embedded"`
	BundleSHA256       string       `json:"bundle_sha256,omitempty"`
	RuntimeDir         string       `json:"runtime_dir,omitempty"`
	Plugin             *pluginCheck `json:"plugin,omitempty"`
}

type pluginRange struct {
	Min          string `json:"min"`
	MaxExclusive string `json:"max_exclusive"`
}

// pluginCheck は PluginVersionEnv が渡されたときの照合の結果。Update は範囲外のとき更新すべき側（plugin | cli）。
type pluginCheck struct {
	Version    string `json:"version"`
	Compatible bool   `json:"compatible"`
	Update     string `json:"update,omitempty"`
	Error      string `json:"error,omitempty"`
}

func cmdVersion(args []string, env Env) int {
	flags, pos, err := parseArgs(args, flagSpec{name: "json"})
	if err != nil {
		return usageErr(env, err)
	}
	if len(pos) != 0 {
		return usageErr(env, errors.New("version takes no arguments"))
	}
	v := versionView{
		CLIVersion:         version.CLI(),
		PluginVersionRange: pluginRange{Min: version.PluginMin, MaxExclusive: version.PluginMaxExclusive},
		WorkflowSchemas:    version.WorkflowSchemas,
	}
	root, digest, err := embeddedRoot(env)
	switch {
	case err == nil:
		v.Embedded, v.BundleSHA256, v.RuntimeDir = true, digest, root
	case !errors.Is(err, bundle.ErrNotEmbedded):
		fmt.Fprintf(env.Stderr, "harness: %v\n", err)
		return ExitFailed
	}
	if p := env.Getenv(PluginVersionEnv); p != "" {
		c := &pluginCheck{Version: p, Compatible: true}
		if err := version.CheckPlugin(p); err != nil {
			c.Compatible, c.Error = false, err.Error()
			var m *version.Mismatch
			if errors.As(err, &m) {
				c.Update = m.Update
			}
		}
		v.Plugin = c
	}
	if _, ok := flags["json"]; ok {
		writeJSON(env.Stdout, v)
		return ExitOK
	}
	fmt.Fprintf(env.Stdout, "harness %s\nplugin claude-harness: %s\nworkflow schemas: %v\n", v.CLIVersion, version.PluginRange(), v.WorkflowSchemas)
	if v.Embedded {
		fmt.Fprintf(env.Stdout, "embedded workflows and scripts: yes (sha256 %s)\nextracted to: %s\n", v.BundleSHA256, v.RuntimeDir)
	} else {
		fmt.Fprintln(env.Stdout, "embedded workflows and scripts: no (pass --workflow-dir and --scripts-dir)")
	}
	if c := v.Plugin; c != nil {
		if c.Compatible {
			fmt.Fprintf(env.Stdout, "plugin %s (%s): compatible\n", c.Version, PluginVersionEnv)
		} else {
			fmt.Fprintf(env.Stdout, "plugin %s (%s): %s\n", c.Version, PluginVersionEnv, c.Error)
		}
	}
	return ExitOK
}

package cli

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"syscall"
	"unsafe"

	"github.com/masanami/claude-harness/runtime/internal/graph"
	"github.com/masanami/claude-harness/runtime/internal/version"
	"github.com/masanami/claude-harness/runtime/internal/workflow"
)

// graph 形式（docs/harness-runtime-visualization.md §7）。mermaid は段 2（#316）で足すので、この段では使い方の誤りにする。
const (
	formatText    = "text"
	formatJSON    = "json"
	formatMermaid = "mermaid"
)

// cmdGraph はワークフロー定義の形を出す（§3・§6.1・§7）。読み取りだけのコマンドで、run を進めないので版の照合
// （HARNESS_PLUGIN_VERSION）はしない。終了コードは 0 = 出力した、2 = 使い方の誤り・定義の不正。
func cmdGraph(args []string, env Env) int {
	flags, pos, err := parseArgs(args,
		flagSpec{name: "format", value: true}, flagSpec{name: "json"},
		flagSpec{name: "workflow-dir", value: true}, flagSpec{name: "scripts-dir", value: true})
	if err != nil {
		return usageErr(env, err)
	}
	format := formatText
	if f, ok := flags["format"]; ok {
		format = f[0]
	}
	if _, ok := flags["json"]; ok {
		if _, both := flags["format"]; both && format != formatJSON {
			return usageErr(env, fmt.Errorf("--json is --format json; it cannot be combined with --format %s", format))
		}
		format = formatJSON
	}
	switch format {
	case formatText, formatJSON:
	case formatMermaid:
		return usageErr(env, errors.New("graph --format mermaid is not implemented yet (use --format text or json)"))
	default:
		return usageErr(env, fmt.Errorf("unknown graph format %q (text or json)", format))
	}
	if len(pos) != 1 {
		return usageErr(env, errors.New("graph takes exactly one workflow"))
	}
	src, err := dirs(flags, env)
	if err != nil {
		return usageErr(env, err)
	}
	path, err := workflowPath(src.wd, pos[0])
	if err != nil {
		return usageErr(env, err)
	}
	wf, err := workflow.LoadAndValidate(path, workflow.Options{ScriptsDir: src.sd})
	if err != nil {
		fmt.Fprintf(env.Stderr, "harness: workflow is not valid\n%v\n", err)
		return ExitUsage
	}
	// 埋め込みから読んだと言えるのは run が Embedded を記録するときと同じ条件（フラグ無しで展開ディレクトリの定義を読んだ）。
	source := graph.SourceWorkflowDir
	if src.embedded && filepath.Dir(path) == src.wd {
		source = graph.SourceEmbedded
	}
	g := graph.Build(wf, source, version.CLI())
	if format == formatJSON {
		writeJSON(env.Stdout, g)
		return ExitOK
	}
	graph.WriteText(env.Stdout, g, outputWidth(env))
	return ExitOK
}

// outputWidth はテキスト表示を折り返す幅。$COLUMNS が正の整数ならそれ、標準出力が端末ならその幅、どちらでもなければ
// 0（折り返さない。パイプ・リダイレクト先では 1 ステップ 1 行のまま出して grep しやすくする）。
func outputWidth(env Env) int {
	if c, err := strconv.Atoi(env.Getenv("COLUMNS")); err == nil && c > 0 {
		return c
	}
	if f, ok := env.Stdout.(*os.File); ok {
		return terminalWidth(f)
	}
	return 0
}

// terminalWidth は f が端末ならその桁数を、端末でなければ 0 を返す。
func terminalWidth(f *os.File) int {
	var ws struct{ row, col, xpixel, ypixel uint16 }
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, f.Fd(), uintptr(syscall.TIOCGWINSZ), uintptr(unsafe.Pointer(&ws)))
	if errno != 0 {
		return 0
	}
	return int(ws.col)
}

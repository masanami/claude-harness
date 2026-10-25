package cli

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"syscall"
	"unsafe"

	"github.com/masanami/claude-harness/runtime/internal/engine"
	"github.com/masanami/claude-harness/runtime/internal/graph"
	"github.com/masanami/claude-harness/runtime/internal/runstate"
	"github.com/masanami/claude-harness/runtime/internal/version"
	"github.com/masanami/claude-harness/runtime/internal/workflow"
)

// graph 形式（docs/harness-runtime-visualization.md §7）。
const (
	formatText    = "text"
	formatJSON    = "json"
	formatMermaid = "mermaid"
)

// cmdGraph はワークフロー定義の形を出す（§3・§6・§7）。--run を付けると、その run が使った定義の形に現在地を重ねる
// （§4・§5.2）。読み取りだけのコマンドで、run を進めず状態も変えないので版の照合（HARNESS_PLUGIN_VERSION）はしない。
// 終了コードは 0 = 出力した、1 = run が見つからない・run の定義を組み立て直せない、2 = 使い方の誤り・定義の不正。
// run が待機中・停止済みでも 3・4 は返さない（run の状態は出力の run.status で読む）。
func cmdGraph(args []string, env Env) int {
	flags, pos, err := parseArgs(args,
		flagSpec{name: "format", value: true}, flagSpec{name: "json"}, flagSpec{name: "run", value: true},
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
	case formatText, formatJSON, formatMermaid:
	default:
		return usageErr(env, fmt.Errorf("unknown graph format %q (text, json or mermaid)", format))
	}
	if _, ok := flags["run"]; ok {
		// --run のときは定義を run の記録から決めるので、定義を選ぶ引数は使い方の誤り（§7）。
		if len(pos) > 0 {
			return usageErr(env, errors.New("graph takes either a workflow or --run <run-id>, not both"))
		}
		for _, f := range []string{"workflow-dir", "scripts-dir"} {
			if _, ok := flags[f]; ok {
				return usageErr(env, fmt.Errorf("--%s cannot be used with --run (the run's record decides the workflow)", f))
			}
		}
		return graphRun(env, first(flags, "run"), format)
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
	writeGraph(env, graph.Build(wf, source, version.CLI()), format)
	return ExitOK
}

func writeGraph(env Env, g *graph.Graph, format string) {
	switch format {
	case formatJSON:
		writeJSON(env.Stdout, g)
	case formatMermaid:
		graph.WriteMermaid(env.Stdout, g)
	default:
		graph.WriteText(env.Stdout, g, outputWidth(env))
	}
}

// graphRun は run の記録から resume と同じ手順（engine.Reopen）で定義を組み立て直し、その形に現在地を重ねる（§5.2）。
// status と違い、runner の居ない実行中の run を interrupted に記録し直さない（§4: 読み取りのコマンドは状態を変えない）。
// Reopen は定義と上書きの写しを読んで照合するだけで、run には何も書かない。
func graphRun(env Env, id, format string) int {
	run, err := openRun(env, id)
	if err != nil {
		fmt.Fprintf(env.Stderr, "harness: %v\n", err)
		return ExitFailed
	}
	st, _, err := run.Load()
	if err != nil {
		fmt.Fprintf(env.Stderr, "harness: %v\n", err)
		return ExitFailed
	}
	hint := fmt.Sprintf("harness status %s still shows where the run is", st.RunID)
	// 上書きの写しから組み立て直した形の描き方（changes・overridden・skipped）は段 3（#317）で足す。それまでは、
	// 上書きの印の無い形に重ねて付け替えた辺を元の定義の辺のように見せないよう、描かずに止める。
	if len(st.Overrides.Overrides) > 0 {
		fmt.Fprintf(env.Stderr, "harness: run %s started with overrides; graph --run does not draw an overridden workflow yet\n%s\n", st.RunID, hint)
		return ExitFailed
	}
	eng, err := engine.Reopen(run, st)
	if err != nil {
		fmt.Fprintf(env.Stderr, "harness: cannot rebuild the workflow run %s started with, so its shape is not drawn: %v\n%s\n", st.RunID, err, hint)
		return ExitFailed
	}
	source := graph.SourceWorkflowDir
	if st.Embedded {
		source = graph.SourceEmbedded
	}
	// 描く定義は run を始めた版の写しなので、版も run を始めた CLI の版にする（記録の無い古い run は今の版）。
	cli := st.CLIVersion
	if cli == "" {
		cli = version.CLI()
	}
	g := graph.Build(eng.WF, source, cli)
	g.Run = graph.NewRun(st, runnerAlive(st), func(u *runstate.Unit) graph.Waiting { return graph.Waiting(waiting(st.RunID, u)) })
	writeGraph(env, g, format)
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

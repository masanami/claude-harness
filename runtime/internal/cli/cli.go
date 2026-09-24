// Package cli は harness コマンドの面（docs/harness-runtime-design.md §5.1 のうち PR-2 の範囲:
// run / status / runs / cancel / validate）。
//
// 終了コード（harness 内部の割り当て。flywheel 向けの接続契約としては固定していない。§0.1・§5.6）:
//
//	0 成功（run は succeeded）  1 失敗（run が failed・validate の違反・操作の失敗）
//	2 使い方の誤り（run に渡したワークフロー定義が不正で run を始めなかった場合を含む）
//	3 待機（ゲート。PR-3 で使う）  4 停止（run が cancelled）
package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/masanami/claude-harness/runtime/internal/engine"
	"github.com/masanami/claude-harness/runtime/internal/runstate"
	"github.com/masanami/claude-harness/runtime/internal/statedir"
	"github.com/masanami/claude-harness/runtime/internal/workflow"
)

// 終了コード。
const (
	ExitOK        = 0
	ExitFailed    = 1
	ExitUsage     = 2
	ExitWaiting   = 3
	ExitCancelled = 4
)

// Env は CLI が外界から受け取るもの（テストで差し替える）。
type Env struct {
	Stdin  *os.File
	Stdout io.Writer
	Stderr io.Writer
	Getenv func(string) string
	Getwd  func() (string, error)
}

// DefaultEnv はプロセスの標準入出力と環境変数。
func DefaultEnv() Env {
	return Env{Stdin: os.Stdin, Stdout: os.Stdout, Stderr: os.Stderr, Getenv: os.Getenv, Getwd: os.Getwd}
}

const usage = `usage: harness <command> [options]

commands:
  run [--workflow-dir DIR] [--scripts-dir DIR] [--input NAME=VALUE]... <workflow>
      start a run and advance it until it ends
  status [--json] <run-id>
      show where a run is (the event log is the source of truth)
  runs [--json]
      list runs in the state directory
  cancel <run-id>
      stop a run: stop its child process and record the stop
  validate [--workflow-dir DIR] [--scripts-dir DIR] [<workflow>...]
      statically check workflow definitions (all *.yaml in the workflow directory by default)

state directory: $HARNESS_STATE_DIR, else $XDG_STATE_HOME/claude-harness, else ~/.local/state/claude-harness
`

// Main は harness コマンドを実行して終了コードを返す。
func Main(args []string, env Env) int {
	if len(args) == 0 {
		fmt.Fprint(env.Stderr, usage)
		return ExitUsage
	}
	cmd, rest := args[0], args[1:]
	switch cmd {
	case "run":
		return cmdRun(rest, env)
	case "status":
		return cmdStatus(rest, env)
	case "runs":
		return cmdRuns(rest, env)
	case "cancel":
		return cmdCancel(rest, env)
	case "validate":
		return cmdValidate(rest, env)
	case "help", "-h", "--help":
		fmt.Fprint(env.Stdout, usage)
		return ExitOK
	}
	fmt.Fprintf(env.Stderr, "harness: unknown command %q\n\n%s", cmd, usage)
	return ExitUsage
}

// --- 引数 -------------------------------------------------------------------

type flagSpec struct {
	name  string
	value bool // 値を取る
	multi bool
}

// parseArgs はフラグと位置引数を分ける（フラグは位置引数の前後どちらに置いてもよい）。
func parseArgs(args []string, specs ...flagSpec) (map[string][]string, []string, error) {
	flags := map[string][]string{}
	var pos []string
	find := func(name string) *flagSpec {
		for i := range specs {
			if specs[i].name == name {
				return &specs[i]
			}
		}
		return nil
	}
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "--" {
			pos = append(pos, args[i+1:]...)
			break
		}
		if !strings.HasPrefix(a, "--") || a == "--" {
			pos = append(pos, a)
			continue
		}
		name, val, hasVal := strings.Cut(strings.TrimPrefix(a, "--"), "=")
		spec := find(name)
		if spec == nil {
			return nil, nil, fmt.Errorf("unknown option --%s", name)
		}
		if spec.value && !hasVal {
			if i+1 >= len(args) {
				return nil, nil, fmt.Errorf("option --%s needs a value", name)
			}
			i++
			val = args[i]
		} else if !spec.value && hasVal {
			return nil, nil, fmt.Errorf("option --%s takes no value", name)
		}
		if len(flags[name]) > 0 && !spec.multi {
			return nil, nil, fmt.Errorf("option --%s given twice", name)
		}
		flags[name] = append(flags[name], val)
	}
	return flags, pos, nil
}

func first(flags map[string][]string, name string) string {
	if v := flags[name]; len(v) > 0 {
		return v[0]
	}
	return ""
}

func usageErr(env Env, err error) int {
	fmt.Fprintf(env.Stderr, "harness: %v\n\n%s", err, usage)
	return ExitUsage
}

// dirs はワークフロー定義とスクリプトの置き場を決める。指定が無ければ、作業ツリーの中から
// runtime/workflows と plugin/scripts を持つディレクトリを上へ探す（開発時の作業ツリーを指す。§6.5 の
// --workflow-dir / --scripts-dir。バイナリへの埋め込み〔S1〕は PR-6 の範囲）。
func dirs(flags map[string][]string, env Env) (string, string, error) {
	wd, sd := first(flags, "workflow-dir"), first(flags, "scripts-dir")
	if wd == "" || sd == "" {
		cwd, err := env.Getwd()
		if err != nil {
			return "", "", err
		}
		root := ""
		for d := cwd; ; d = filepath.Dir(d) {
			if isDir(filepath.Join(d, "runtime", "workflows")) && isDir(filepath.Join(d, "plugin", "scripts")) {
				root = d
				break
			}
			if filepath.Dir(d) == d {
				break
			}
		}
		if root == "" {
			return "", "", errors.New("cannot find runtime/workflows and plugin/scripts above the current directory; pass --workflow-dir and --scripts-dir")
		}
		if wd == "" {
			wd = filepath.Join(root, "runtime", "workflows")
		}
		if sd == "" {
			sd = filepath.Join(root, "plugin", "scripts")
		}
	}
	wd, err := filepath.Abs(wd)
	if err != nil {
		return "", "", err
	}
	sd, err = filepath.Abs(sd)
	if err != nil {
		return "", "", err
	}
	return wd, sd, nil
}

func isDir(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.IsDir()
}

// workflowPath は名前（<workflow-dir>/<名前>.yaml）かパスを受け付ける。
func workflowPath(wd, arg string) (string, error) {
	if strings.Contains(arg, "/") || strings.HasSuffix(arg, ".yaml") {
		return filepath.Abs(arg)
	}
	return filepath.Join(wd, arg+".yaml"), nil
}

func runsDir(env Env) (string, error) {
	sd, err := statedir.Resolve(env.Getenv)
	if err != nil {
		return "", err
	}
	return statedir.RunsDir(sd), nil
}

// --- run --------------------------------------------------------------------

func cmdRun(args []string, env Env) int {
	flags, pos, err := parseArgs(args,
		flagSpec{name: "workflow-dir", value: true}, flagSpec{name: "scripts-dir", value: true},
		flagSpec{name: "input", value: true, multi: true})
	if err != nil {
		return usageErr(env, err)
	}
	if len(pos) != 1 {
		return usageErr(env, errors.New("run takes exactly one workflow"))
	}
	wd, sd, err := dirs(flags, env)
	if err != nil {
		return usageErr(env, err)
	}
	path, err := workflowPath(wd, pos[0])
	if err != nil {
		return usageErr(env, err)
	}
	wf, err := workflow.LoadAndValidate(path, workflow.Options{ScriptsDir: sd})
	if err != nil {
		fmt.Fprintf(env.Stderr, "harness: workflow is not valid; no run was started\n%v\n", err)
		return ExitUsage
	}
	inputs, err := parseInputs(wf, flags["input"])
	if err != nil {
		return usageErr(env, err)
	}
	rd, err := runsDir(env)
	if err != nil {
		fmt.Fprintf(env.Stderr, "harness: %v\n", err)
		return ExitFailed
	}
	cwd, err := env.Getwd()
	if err != nil {
		fmt.Fprintf(env.Stderr, "harness: %v\n", err)
		return ExitFailed
	}
	eng, err := engine.Start(engine.StartParams{
		RunsDir: rd, WF: wf, Inputs: inputs, ScriptsDir: sd, WorkflowDir: wd, Cwd: cwd, Origin: "cli",
	})
	if err != nil {
		fmt.Fprintf(env.Stderr, "harness: cannot start the run: %v\n", err)
		return ExitFailed
	}
	fmt.Fprintf(env.Stderr, "harness: run %s started (%s)\n", eng.Run.ID, eng.Run.Dir)
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)
	defer stop()
	st, err := eng.Loop(ctx)
	if err != nil {
		fmt.Fprintf(env.Stderr, "harness: run %s stopped with an internal error: %v\n", eng.Run.ID, err)
		return ExitFailed
	}
	writeJSON(env.Stdout, view(eng.Run, st, nil))
	return exitFor(st.Status)
}

func exitFor(status string) int {
	switch status {
	case runstate.StatusSucceeded:
		return ExitOK
	case runstate.StatusCancelled:
		return ExitCancelled
	case runstate.StatusWaiting:
		return ExitWaiting
	}
	return ExitFailed
}

// parseInputs は --input NAME=VALUE を宣言された型で読む。integer・string はそのまま、array・object は JSON で渡す。
func parseInputs(wf *workflow.Workflow, raw []string) (map[string]json.RawMessage, error) {
	out := map[string]json.RawMessage{}
	for _, kv := range raw {
		name, val, ok := strings.Cut(kv, "=")
		if !ok {
			return nil, fmt.Errorf("--input %q must be NAME=VALUE", kv)
		}
		in := wf.Input(name)
		if in == nil {
			return nil, fmt.Errorf("input %q is not declared by workflow %s", name, wf.ID)
		}
		if _, dup := out[name]; dup {
			return nil, fmt.Errorf("input %q given twice", name)
		}
		var v any
		switch in.Type.Name {
		case "string":
			v = val
		case "integer":
			n, err := strconv.ParseInt(val, 10, 64)
			if err != nil {
				return nil, fmt.Errorf("input %q must be an integer", name)
			}
			v = n
		default:
			dec := json.NewDecoder(strings.NewReader(val))
			dec.UseNumber()
			if err := dec.Decode(&v); err != nil {
				return nil, fmt.Errorf("input %q must be JSON of type %s", name, in.Type)
			}
			if err := checkType(v, in.Type); err != nil {
				return nil, fmt.Errorf("input %q: %v", name, err)
			}
		}
		b, err := json.Marshal(v)
		if err != nil {
			return nil, err
		}
		out[name] = b
	}
	for _, in := range wf.Inputs {
		if _, ok := out[in.Name]; in.Required && !ok {
			return nil, fmt.Errorf("input %q is required (--input %s=...)", in.Name, in.Name)
		}
	}
	return out, nil
}

func checkType(v any, t *workflow.Type) error {
	switch t.Name {
	case "string":
		if _, ok := v.(string); !ok {
			return fmt.Errorf("want string")
		}
	case "integer":
		n, ok := v.(json.Number)
		if !ok {
			return fmt.Errorf("want integer")
		}
		if _, err := n.Int64(); err != nil {
			return fmt.Errorf("want integer")
		}
	case "object":
		if _, ok := v.(map[string]any); !ok {
			return fmt.Errorf("want object")
		}
	case "array":
		arr, ok := v.([]any)
		if !ok {
			return fmt.Errorf("want array")
		}
		if t.Items != nil {
			for _, it := range arr {
				if err := checkType(it, t.Items); err != nil {
					return fmt.Errorf("array item: %v", err)
				}
			}
		}
	}
	return nil
}

// --- status / runs ----------------------------------------------------------

// statusView は status --json の中身: 畳み込んだ状態に、外から run を辿るための場所と、
// 読み込みで気付いたこと（末尾の切れた行）を添える（§5.5）。
// RunnerAlive は終端でない run についてだけ出す: running のまま runner のプロセスが居なければ、その run は
// 誰も進めていない（落ちた runner。§4.5 の interrupted の扱いは後の PR。ここでは外から見分けられるようにする）。
type statusView struct {
	*runstate.State
	RunDir      string `json:"run_dir"`
	EventsFile  string `json:"events_file"`
	RunnerAlive *bool  `json:"runner_alive,omitempty"`
	TornTail    *int   `json:"torn_tail_bytes,omitempty"`
}

func view(run *runstate.Run, st *runstate.State, torn *runstate.Torn) statusView {
	v := statusView{State: st, RunDir: run.Dir, EventsFile: filepath.Join(run.Dir, runstate.EventsFile)}
	if !runstate.Terminal(st.Status) {
		alive := runstate.Alive(st.PID)
		v.RunnerAlive = &alive
	}
	if torn != nil {
		n := torn.Bytes
		v.TornTail = &n
	}
	return v
}

func writeJSON(w io.Writer, v any) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetIndent("", "  ")
	_ = enc.Encode(v)
	_, _ = w.Write(buf.Bytes())
}

func openRun(env Env, id string) (*runstate.Run, error) {
	rd, err := runsDir(env)
	if err != nil {
		return nil, err
	}
	return runstate.Open(rd, id)
}

func cmdStatus(args []string, env Env) int {
	flags, pos, err := parseArgs(args, flagSpec{name: "json"})
	if err != nil {
		return usageErr(env, err)
	}
	if len(pos) != 1 {
		return usageErr(env, errors.New("status takes exactly one run id"))
	}
	run, err := openRun(env, pos[0])
	if err != nil {
		fmt.Fprintf(env.Stderr, "harness: %v\n", err)
		return ExitFailed
	}
	st, torn, err := run.Load()
	if err != nil {
		fmt.Fprintf(env.Stderr, "harness: %v\n", err)
		return ExitFailed
	}
	if _, ok := flags["json"]; ok {
		writeJSON(env.Stdout, view(run, st, torn))
		return ExitOK
	}
	fmt.Fprintf(env.Stdout, "run:      %s\nworkflow: %s\nstatus:   %s", st.RunID, st.Workflow.ID, st.Status)
	if st.Reason != "" {
		fmt.Fprintf(env.Stdout, " (%s)", st.Reason)
	}
	if !runstate.Terminal(st.Status) && !runstate.Alive(st.PID) {
		fmt.Fprintf(env.Stdout, " (runner pid %d is not alive; nothing is advancing this run)", st.PID)
	}
	fmt.Fprintf(env.Stdout, "\nupdated:  %s\nrun dir:  %s\n", st.UpdatedAt, run.Dir)
	for _, u := range st.Units {
		fmt.Fprintf(env.Stdout, "unit %s: %s", u.Key, u.Status)
		if u.Reason != "" {
			fmt.Fprintf(env.Stdout, " (%s)", u.Reason)
		}
		fmt.Fprintf(env.Stdout, ", round %d, step %s\n", len(u.Rounds), u.CurrentStep)
		if r := u.CurrentRound(); r != nil {
			for _, x := range r.Steps {
				o := x.Outcome
				if x.Status != "finished" {
					o = x.Status
				}
				fmt.Fprintf(env.Stdout, "  %s#%d  %s\n", x.Step, x.Attempt, o)
			}
		}
	}
	if torn != nil {
		fmt.Fprintf(env.Stdout, "note: the last %d bytes of events.jsonl are an incomplete line and were ignored\n", torn.Bytes)
	}
	return ExitOK
}

// runSummary は runs の 1 行。読めない run も隠さず error 付きで出す。
type runSummary struct {
	RunID       string `json:"run_id"`
	Workflow    string `json:"workflow,omitempty"`
	Status      string `json:"status"`
	Reason      string `json:"reason,omitempty"`
	CurrentStep string `json:"current_step,omitempty"`
	CreatedAt   string `json:"created_at,omitempty"`
	UpdatedAt   string `json:"updated_at,omitempty"`
	RunDir      string `json:"run_dir"`
	Error       string `json:"error,omitempty"`
}

func cmdRuns(args []string, env Env) int {
	flags, pos, err := parseArgs(args, flagSpec{name: "json"})
	if err != nil {
		return usageErr(env, err)
	}
	if len(pos) != 0 {
		return usageErr(env, errors.New("runs takes no arguments"))
	}
	rd, err := runsDir(env)
	if err != nil {
		fmt.Fprintf(env.Stderr, "harness: %v\n", err)
		return ExitFailed
	}
	ids, err := runstate.List(rd)
	if err != nil {
		fmt.Fprintf(env.Stderr, "harness: %v\n", err)
		return ExitFailed
	}
	sort.Sort(sort.Reverse(sort.StringSlice(ids))) // 新しい順
	out := []runSummary{}
	for _, id := range ids {
		run, err := runstate.Open(rd, id)
		if err != nil {
			continue
		}
		s := runSummary{RunID: id, RunDir: run.Dir}
		st, _, err := run.Load()
		if err != nil {
			s.Status, s.Error = "unreadable", err.Error()
		} else {
			s.Workflow, s.Status, s.Reason, s.CreatedAt, s.UpdatedAt = st.Workflow.ID, st.Status, st.Reason, st.CreatedAt, st.UpdatedAt
			if len(st.Units) > 0 {
				s.CurrentStep = st.Units[0].CurrentStep
			}
		}
		out = append(out, s)
	}
	if _, ok := flags["json"]; ok {
		writeJSON(env.Stdout, out)
		return ExitOK
	}
	for _, s := range out {
		fmt.Fprintf(env.Stdout, "%s  %-10s %-12s %s\n", s.RunID, s.Status, s.Workflow, s.CurrentStep)
	}
	return ExitOK
}

// --- cancel -----------------------------------------------------------------

// cancel の待ち時間。runner は子プロセスへ SIGTERM を送り、猶予（5 秒）内に終わらなければ SIGKILL を送る。
var cancelWait = 20 * time.Second

func cmdCancel(args []string, env Env) int {
	_, pos, err := parseArgs(args)
	if err != nil {
		return usageErr(env, err)
	}
	if len(pos) != 1 {
		return usageErr(env, errors.New("cancel takes exactly one run id"))
	}
	run, err := openRun(env, pos[0])
	if err != nil {
		fmt.Fprintf(env.Stderr, "harness: %v\n", err)
		return ExitFailed
	}
	st, _, err := run.Load()
	if err != nil {
		fmt.Fprintf(env.Stderr, "harness: %v\n", err)
		return ExitFailed
	}
	switch st.Status {
	case runstate.StatusCancelled:
		fmt.Fprintf(env.Stdout, "run %s is already cancelled\n", st.RunID)
		return ExitOK
	case runstate.StatusSucceeded, runstate.StatusFailed:
		fmt.Fprintf(env.Stderr, "harness: run %s already ended as %s; nothing to cancel\n", st.RunID, st.Status)
		return ExitFailed
	}
	channel := "non-tty"
	if fi, err := env.Stdin.Stat(); err == nil && fi.Mode()&os.ModeCharDevice != 0 {
		channel = "tty"
	}
	if _, err := run.Append(runstate.Event{Type: runstate.EvCancelRequested, CancelRequested: &runstate.CancelRequested{Actor: "cli", Channel: channel}}); err != nil {
		fmt.Fprintf(env.Stderr, "harness: cannot record the cancel request: %v\n", err)
		return ExitFailed
	}
	if err := os.WriteFile(filepath.Join(run.Dir, runstate.CancelFile), []byte(strconv.Itoa(os.Getpid())), 0o644); err != nil {
		fmt.Fprintf(env.Stderr, "harness: %v\n", err)
		return ExitFailed
	}
	deadline := time.Now().Add(cancelWait)
	for {
		st, _, err = run.Load()
		if err != nil {
			fmt.Fprintf(env.Stderr, "harness: %v\n", err)
			return ExitFailed
		}
		if runstate.Terminal(st.Status) {
			break
		}
		if !runstate.Alive(st.PID) {
			// runner が居ない（落ちた run）。子プロセスが残っていれば止め、停止を自分で記録する。
			for _, u := range st.Units {
				if x := u.Running(); x != nil {
					engine.StopOrphan(x.PID, 5*time.Second)
				}
			}
			if _, err := run.Append(engine.CancelEvents(st, "cli", channel, "runner was not alive; stopped by cancel")...); err != nil {
				// runner が同時に終えた等。読み直して終端なら良い。
				if st2, _, lerr := run.Load(); lerr == nil && runstate.Terminal(st2.Status) {
					st = st2
					break
				}
				fmt.Fprintf(env.Stderr, "harness: cannot record the stop: %v\n", err)
				return ExitFailed
			}
			continue
		}
		if time.Now().After(deadline) {
			fmt.Fprintf(env.Stderr, "harness: run %s did not stop within %s (runner pid %d is alive); the cancel request stays recorded\n", st.RunID, cancelWait, st.PID)
			return ExitFailed
		}
		time.Sleep(100 * time.Millisecond)
	}
	if st.Status != runstate.StatusCancelled {
		fmt.Fprintf(env.Stdout, "run %s ended as %s before the cancel took effect\n", st.RunID, st.Status)
		return ExitFailed
	}
	fmt.Fprintf(env.Stdout, "run %s cancelled\n", st.RunID)
	return ExitOK
}

// --- validate ---------------------------------------------------------------

func cmdValidate(args []string, env Env) int {
	flags, pos, err := parseArgs(args, flagSpec{name: "workflow-dir", value: true}, flagSpec{name: "scripts-dir", value: true})
	if err != nil {
		return usageErr(env, err)
	}
	wd, sd, err := dirs(flags, env)
	if err != nil {
		return usageErr(env, err)
	}
	var paths []string
	if len(pos) == 0 {
		paths, err = filepath.Glob(filepath.Join(wd, "*.yaml"))
		if err != nil {
			return usageErr(env, err)
		}
		if len(paths) == 0 {
			// 検査していないものを通過と報告しない。
			fmt.Fprintf(env.Stderr, "harness: no workflows (*.yaml) found in %s\n", wd)
			return ExitFailed
		}
	}
	for _, a := range pos {
		p, err := workflowPath(wd, a)
		if err != nil {
			return usageErr(env, err)
		}
		paths = append(paths, p)
	}
	failed := 0
	for _, p := range paths {
		if _, err := workflow.LoadAndValidate(p, workflow.Options{ScriptsDir: sd}); err != nil {
			failed++
			fmt.Fprintf(env.Stderr, "NG %s\n%v\n", p, err)
			continue
		}
		fmt.Fprintf(env.Stdout, "ok %s\n", p)
	}
	fmt.Fprintf(env.Stdout, "harness validate: total=%d passed=%d failed=%d\n", len(paths), len(paths)-failed, failed)
	if failed > 0 {
		return ExitFailed
	}
	return ExitOK
}

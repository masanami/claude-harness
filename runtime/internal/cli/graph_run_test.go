package cli

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
)

// harness graph --run（docs/harness-runtime-visualization.md §4・§5.2・§7。#316）: run が使った定義の形に現在地を重ね、
// run の状態は変えない。

// graphRunDoc は graph --run --json のうち、テストで読む部分。
type graphRunDoc struct {
	Workflow struct {
		ID     string `json:"id"`
		Source string `json:"source"`
		Path   string `json:"path"`
		Hash   string `json:"hash"`
	} `json:"workflow"`
	Nodes []struct {
		ID string `json:"id"`
	} `json:"nodes"`
	Run *struct {
		RunID       string  `json:"run_id"`
		Status      string  `json:"status"`
		Reason      *string `json:"reason"`
		RunnerAlive *bool   `json:"runner_alive"`
		Units       []struct {
			Key         string           `json:"key"`
			Status      string           `json:"status"`
			CurrentStep string           `json:"current_step"`
			Round       int              `json:"round"`
			Waiting     *waitingView     `json:"waiting"`
			Visited     []map[string]any `json:"visited"`
			LimitsUsed  map[string]int   `json:"limits_used"`
			Budget      *runstate.Budget `json:"budget"`
		} `json:"units"`
	} `json:"run"`
}

func graphRunJSON(t *testing.T, h *harness, id string) (graphRunDoc, string) {
	t.Helper()
	out, errOut, code := h.run("graph", "--run", id, "--json")
	if code != ExitOK || errOut != "" {
		t.Fatalf("graph --run %s --json: exit %d\n%s\n%s", id, code, out, errOut)
	}
	return decode[graphRunDoc](t, out), out
}

func visitedString(vs []map[string]any) string {
	var parts []string
	for _, v := range vs {
		b, _ := json.Marshal([]any{v["step"], v["executions"], v["last_outcome"]})
		parts = append(parts, string(b))
	}
	return strings.Join(parts, " ")
}

// 待機中の run: いまのステップ・待っているゲート・ラウンド・通ったステップ・使った予算を、status --json と同じ名前と値で
// 重ねる。終了コードは 0（3 を返さない）。テキストは印と要約、Mermaid はクラスで現在地を出す。
func TestGraphRunWaiting(t *testing.T) {
	fdir, fenv := fakeClaude(t)
	respond(t, fdir, 1, 0, passResult(0.4))
	respond(t, fdir, 2, 0, passResult(0.7)) // fix は implement のセッションを続けるので、claude はセッションの累計を報告する
	state := t.TempDir()
	h := newHarness(t, append(fenv, "HARNESS_STATE_DIR="+state)...)
	out, errOut, code := h.run(runArgs(t, "llm", "issue=5")...)
	if code != ExitWaiting {
		t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
	}
	id := decode[statusView](t, out).RunID
	if _, errOut, code := h.run("resume", id, "--input", "respond"); code != ExitWaiting {
		t.Fatalf("resume exit %d\n%s", code, errOut)
	}

	d, _ := graphRunJSON(t, h, id)
	sout, _, _ := h.run("status", "--json", id)
	sv := decode[statusView](t, sout)
	if d.Workflow.ID != "llm" || d.Workflow.Source != "workflow-dir" || d.Workflow.Path != sv.Workflow.Path || d.Workflow.Hash != sv.Workflow.Hash {
		t.Fatalf("workflow = %+v", d.Workflow)
	}
	r := d.Run
	if r == nil || r.RunID != id || r.Status != "waiting" || r.Reason != nil || r.RunnerAlive != nil || len(r.Units) != 1 {
		t.Fatalf("run = %+v", r)
	}
	u := r.Units[0]
	if u.Key != sv.Units[0].Key || u.Status != "waiting" || u.CurrentStep != "review" || u.Round != 2 {
		t.Fatalf("unit = %+v", u)
	}
	if u.Waiting == nil || len(sv.Waiting) != 1 {
		t.Fatalf("waiting = %+v (status: %+v)", u.Waiting, sv.Waiting)
	}
	gw, _ := json.Marshal(u.Waiting)
	sw, _ := json.Marshal(sv.Waiting[0])
	if string(gw) != string(sw) {
		t.Fatalf("waiting differs from status --json:\ngraph:  %s\nstatus: %s", gw, sw)
	}
	if got := visitedString(u.Visited); got != `["implement",1,"pass"] ["fix",1,"pass"]` {
		t.Fatalf("visited = %s", got)
	}
	if u.Budget == nil || *u.Budget != *sv.Units[0].Budget || u.Budget.SpentUSD != 0.7 {
		t.Fatalf("budget = %+v", u.Budget)
	}
	if u.LimitsUsed == nil || len(u.LimitsUsed) != 0 {
		t.Fatalf("limits_used = %v", u.LimitsUsed)
	}

	text, errOut, code := h.run("graph", "--run", id)
	if code != ExitOK || errOut != "" {
		t.Fatalf("graph --run (text): exit %d\n%s", code, errOut)
	}
	for _, want := range []string{
		"legend: ", "> current step", "* visited (executions, last outcome)",
		"\n* implement ", "(x1, last pass)\n",
		"\n* fix ", "\n> review ",
		"\nrun " + id + ": waiting at review (decider any), round 2, spent 0.70/5.00 USD\n",
		"\n  resume: harness resume " + id + " --unit " + u.Key + " --input <respond|ready> [--note <text>]\n",
	} {
		if !strings.Contains(text, want) {
			t.Errorf("text does not contain %q:\n%s", want, text)
		}
	}

	mmd, errOut, code := h.run("graph", "--run", id, "--format", "mermaid")
	if code != ExitOK || errOut != "" {
		t.Fatalf("graph --run --format mermaid: exit %d\n%s", code, errOut)
	}
	// llm の節点は implement=n0・review=n1・fix=n2 の順。
	for _, want := range []string{"\n  class n0,n2 visited\n", "\n  class n1 current\n", "%% run " + id + ": waiting at review"} {
		if !strings.Contains(mmd, want) {
			t.Errorf("mermaid does not contain %q:\n%s", want, mmd)
		}
	}
}

// 完了した run: 通ったステップと使った上限（rework）を出し、いまいるステップの印は付けない（終端に居る）。
func TestGraphRunSucceeded(t *testing.T) {
	dir := t.TempDir()
	state := t.TempDir()
	h := newHarness(t, "HARNESS_STATE_DIR="+state)
	out, errOut, code := h.run(runArgs(t, "rework", "state="+filepath.Join(dir, "n"), "outcomes=red,red,green", "log="+filepath.Join(dir, "log"))...)
	if code != ExitOK {
		t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
	}
	id := decode[runstate.State](t, out).RunID
	d, _ := graphRunJSON(t, h, id)
	r := d.Run
	if r.Status != "succeeded" || r.Reason == nil || *r.Reason != "green" || r.RunnerAlive != nil {
		t.Fatalf("run = %+v", r)
	}
	u := r.Units[0]
	if u.Status != "succeeded" || u.CurrentStep != "ci" || u.Waiting != nil || u.LimitsUsed["rework"] != 2 || u.Budget != nil {
		t.Fatalf("unit = %+v", u)
	}
	if got := visitedString(u.Visited); got != `["ci",3,"green"] ["fix",2,"pass"]` {
		t.Fatalf("visited = %s", got)
	}
	text, _, code := h.run("graph", "--run", id)
	if code != ExitOK || strings.Contains(text, "\n> ") || !strings.Contains(text, "\n* ci ") ||
		!strings.Contains(text, "\nrun "+id+": succeeded (green) after ci, round 1, rework 2/2\n") {
		t.Fatalf("text (exit %d):\n%s", code, text)
	}
	// Mermaid は終端 done:green に current を付ける。
	mmd, _, _ := h.run("graph", "--run", id, "--format", "mermaid")
	if !strings.Contains(mmd, `(("done: green"))`) {
		t.Fatalf("mermaid:\n%s", mmd)
	}
	var green string
	for _, l := range strings.Split(mmd, "\n") {
		if strings.Contains(l, `(("done: green"))`) {
			green = strings.Fields(l)[0]
			green = green[:strings.Index(green, "(")]
		}
	}
	if !strings.Contains(mmd, "\n  class "+green+" current\n") {
		t.Fatalf("done: green (%s) is not current:\n%s", green, mmd)
	}
}

// 停止済みの run: 終了コードは 0（4 を返さない）。待っていたゲートは待っているものとして出さない。
func TestGraphRunCancelled(t *testing.T) {
	state := t.TempDir()
	h := newHarness(t, "HARNESS_STATE_DIR="+state)
	out, _, code := h.run(runArgs(t, "gates", `json={"outcome":"any"}`, "log=x", "state=x")...)
	if code != ExitWaiting {
		t.Fatalf("run exit %d", code)
	}
	id := decode[statusView](t, out).RunID
	if _, errOut, code := h.run("cancel", id); code != ExitOK {
		t.Fatalf("cancel exit %d\n%s", code, errOut)
	}
	d, _ := graphRunJSON(t, h, id)
	u := d.Run.Units[0]
	if d.Run.Status != "cancelled" || u.Status != "cancelled" || u.Waiting != nil || u.CurrentStep != "ask-any" {
		t.Fatalf("run = %+v unit = %+v", d.Run, u)
	}
	for _, f := range [][]string{{}, {"--format", "mermaid"}} {
		out, errOut, code := h.run(append([]string{"graph", "--run", id}, f...)...)
		if code != ExitOK || errOut != "" || !strings.Contains(out, "run "+id+": cancelled (cancelled) after ask-any, round 1") {
			t.Fatalf("graph --run %v: exit %d\n%s\n%s", f, code, out, errOut)
		}
	}
}

// 実行中のまま runner が居ない run を、graph は interrupted に記録し直さない（§4）。runner_alive は false、waiting は
// null のままで、テキストは「誰も進めていない」ことと status・resume の後の見え方を書く。その後の status は記録し直す。
func TestGraphRunDoesNotRecordTheInterruption(t *testing.T) {
	fdir, fenv := fakeClaude(t)
	state := t.TempDir()
	h := newHarness(t, append(fenv, "HARNESS_STATE_DIR="+state)...)
	id, pid, killRunner := startSleepingLLM(t, h, fdir)
	killRunner()
	_ = syscall.Kill(-pid, syscall.SIGKILL)
	waitFor(t, func() bool { return !runstate.Alive(pid) })

	dir := filepath.Join(state, "runs", id)
	before := eventTypes(t, dir)
	stateBefore, err := os.ReadFile(filepath.Join(dir, "state.json"))
	if err != nil {
		t.Fatal(err)
	}
	d, _ := graphRunJSON(t, h, id)
	r := d.Run
	if r.Status != "running" || r.RunnerAlive == nil || *r.RunnerAlive || r.Units[0].Waiting != nil || r.Units[0].CurrentStep != "implement" {
		t.Fatalf("run = %+v", r)
	}
	if got := visitedString(r.Units[0].Visited); got != `["implement",1,"running"]` {
		t.Fatalf("visited = %s", got)
	}
	text, _, _ := h.run("graph", "--run", id)
	mmd, _, _ := h.run("graph", "--run", id, "--format", "mermaid")
	for _, want := range []string{"\n> implement ", "run " + id + ": running at implement, round 1",
		"the runner is not alive: nothing is advancing this run. graph does not record that; harness status or harness resume will end step implement as interrupted and wait at the built-in gate interrupted"} {
		if !strings.Contains(text, want) {
			t.Errorf("text does not contain %q:\n%s", want, text)
		}
	}
	if !strings.Contains(mmd, "the runner is not alive") {
		t.Errorf("mermaid comments do not say the runner is gone:\n%s", mmd)
	}
	after := eventTypes(t, dir)
	stateAfter, _ := os.ReadFile(filepath.Join(dir, "state.json"))
	if after != before || string(stateAfter) != string(stateBefore) {
		t.Fatalf("graph changed the run:\nevents %s\n    -> %s", before, after)
	}

	// 直後の status は記録し直し、interrupted ゲートで待つ（graph との見え方の違い。§12）。
	h.run("status", id)
	d, _ = graphRunJSON(t, h, id)
	if w := d.Run.Units[0].Waiting; d.Run.Status != "waiting" || w == nil || w.Gate != "interrupted" || d.Run.Units[0].CurrentStep != "implement" {
		t.Fatalf("after status: run = %+v", d.Run)
	}
}

// 終了コード（§7）: run が見つからない・定義を組み立て直せないは 1。上書きで始めた run は描ける（0。中身は
// graph_override_test.go）。<workflow> と --run の併用、--run と定義を選ぶ引数（--override を含む）の併用は 2。
// 失敗のとき標準出力は空。
func TestGraphRunExitCodes(t *testing.T) {
	state := t.TempDir()
	wd := t.TempDir()
	writeFile(t, filepath.Join(wd, "rte.yaml"), routeWorkflow)
	h := newHarness(t, "HARNESS_STATE_DIR="+state)
	start := func(extra ...string) string {
		out, errOut, code := h.run(append(append([]string{"run", "--workflow-dir", wd, "--scripts-dir", abs(t, testScripts)}, extra...), "rte")...)
		if code != ExitWaiting {
			t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
		}
		return decode[statusView](t, out).RunID
	}
	plain := start()
	overridden := start("--override", writeFile(t, filepath.Join(t.TempDir(), "arg.yaml"), routeOverride))
	// 対応範囲外のプラグイン版でも graph --run は止まらない（run を進めないので版を照合しない）。
	hv := newHarness(t, "HARNESS_STATE_DIR="+state, PluginVersionEnv+"=999.0.0")
	if out, errOut, code := hv.run("graph", "--run", plain); code != ExitOK || out == "" {
		t.Fatalf("graph --run with an unsupported plugin version: exit %d\n%s", code, errOut)
	}
	if out, errOut, code := h.run("graph", "--run", overridden); code != ExitOK || out == "" || errOut != "" {
		t.Fatalf("graph --run of a run started with overrides: exit %d\n%s", code, errOut)
	}

	cases := []struct {
		name string
		args []string
		want int
		msg  string
	}{
		{"missing run", []string{"graph", "--run", "no-such-run"}, ExitFailed, `run "no-such-run" not found`},
		{"workflow and --run", []string{"graph", "--run", plain, "rte"}, ExitUsage, "either a workflow or --run"},
		{"--run and --workflow-dir", []string{"graph", "--run", plain, "--workflow-dir", wd}, ExitUsage, "--workflow-dir cannot be used with --run"},
		{"--run and --scripts-dir", []string{"graph", "--run", plain, "--scripts-dir", wd}, ExitUsage, "--scripts-dir cannot be used with --run"},
		{"--run and --override", []string{"graph", "--run", plain, "--override", "x.yaml"}, ExitUsage, "--override cannot be used with --run"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			out, errOut, code := h.run(c.args...)
			if code != c.want || !strings.Contains(errOut, c.msg) || out != "" {
				t.Fatalf("exit %d (want %d)\nstdout:\n%s\nstderr:\n%s", code, c.want, out, errOut)
			}
		})
	}

	// 開始後に定義を書き換えた run は組み立て直せないので描かない（§5.2）。status は読める。
	writeFile(t, filepath.Join(wd, "rte.yaml"), strings.Replace(routeWorkflow, "say go", "say go now", 1))
	out, errOut, code := h.run("graph", "--run", plain, "--format", "mermaid")
	if code != ExitFailed || out != "" || !strings.Contains(errOut, "changed since the run started") ||
		!strings.Contains(errOut, "harness status "+plain+" still shows where the run is") {
		t.Fatalf("changed workflow: exit %d\n%s\n%s", code, out, errOut)
	}
	if _, _, code := h.run("status", plain); code != ExitOK {
		t.Fatalf("status exit %d", code)
	}
}

// --format mermaid は同梱の ticket を描ける（§6.2）: 19 ステップと終端が n0… の節点になり、辺は outcome のラベル付きで、
// 人のゲート 3 つにクラス human が付く。
func TestGraphMermaidTicket(t *testing.T) {
	h := newHarness(t)
	out, errOut, code := h.run("graph", "--format", "mermaid", "--workflow-dir", abs(t, repoWorkflows), "--scripts-dir", abs(t, repoScripts), "ticket")
	if code != ExitOK || errOut != "" {
		t.Fatalf("exit %d\n%s", code, errOut)
	}
	if !strings.HasPrefix(out, "flowchart TD\n") {
		t.Fatalf("mermaid:\n%s", out)
	}
	for _, want := range []string{
		`  n0["resolve<br/>command 2m"]`, `  n3("implement<br/>llm $15 90m")`, `  n11{{"review<br/>gate input any"}}`,
		`  n14{"merge-route<br/>select $steps.resolve.base_kind"}`,
		`  n2 -->|"provided / created / reused"| n3`,
		`  n7 -->|"fail (rework#lt;=3)"| n4`, `  n7 -.->|"fail (rework exhausted)"| n25`,
		`  n9 -->|"timeout (retry#lt;=1)"| n9`, `  n9 -.->|"timeout (retry exhausted)"| n10`,
		"  class n13,n16,n17 human\n",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("mermaid does not contain %q", want)
		}
	}
	if strings.Contains(out, "class n") && strings.Contains(out, " current\n") {
		t.Errorf("a graph without --run marks a current step:\n%s", out)
	}
	if t.Failed() {
		t.Log(out)
	}
}

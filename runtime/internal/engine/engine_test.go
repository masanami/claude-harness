package engine

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
	"github.com/masanami/claude-harness/runtime/internal/workflow"
)

func testdata(t *testing.T, parts ...string) string {
	t.Helper()
	p, err := filepath.Abs(filepath.Join(append([]string{"testdata"}, parts...)...))
	if err != nil {
		t.Fatal(err)
	}
	return p
}

// run はテスト用ワークフローを最後まで実行し、畳み込んだ状態を返す。
func run(t *testing.T, name string, inputs map[string]any) (*runstate.State, *Engine) {
	t.Helper()
	scripts := testdata(t, "scripts")
	wf, err := workflow.LoadAndValidate(testdata(t, "workflows", name+".yaml"), workflow.Options{ScriptsDir: scripts})
	if err != nil {
		t.Fatal(err)
	}
	raw := map[string]json.RawMessage{}
	for k, v := range inputs {
		b, _ := json.Marshal(v)
		raw[k] = b
	}
	e, err := Start(StartParams{RunsDir: t.TempDir(), WF: wf, Inputs: raw, ScriptsDir: scripts, WorkflowDir: testdata(t, "workflows"), Cwd: t.TempDir(), Origin: "test"})
	if err != nil {
		t.Fatal(err)
	}
	e.KillGrace, e.PollInterval = time.Second, 20*time.Millisecond
	st, err := e.Loop(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	return st, e
}

func steps(st *runstate.State) []string {
	var out []string
	for _, r := range st.Unit(MainUnit).Rounds {
		for _, x := range r.Steps {
			out = append(out, x.Step+":"+x.Outcome)
		}
	}
	return out
}

func lastTransition(t *testing.T, e *Engine) *runstate.Transition {
	t.Helper()
	evs, _, err := runstate.ReadEvents(filepath.Join(e.Run.Dir, runstate.EventsFile))
	if err != nil {
		t.Fatal(err)
	}
	for i := len(evs) - 1; i >= 0; i-- {
		if evs[i].Transition != nil {
			return evs[i].Transition
		}
	}
	t.Fatal("no transition")
	return nil
}

func TestSucceeds(t *testing.T) {
	st, _ := run(t, "emit", map[string]any{"json": `{"outcome":"ok"}`, "code": 0})
	if st.Status != runstate.StatusSucceeded || st.Reason != "ok" {
		t.Fatalf("status = %s (%s)", st.Status, st.Reason)
	}
	if got := string(st.Unit(MainUnit).Outputs["emit"]); got != `{"outcome":"ok"}` {
		t.Fatalf("output = %s", got)
	}
}

// 予約値が on に無ければ run は failed（fail-closed）。
func TestReservedOutcomesFailClosed(t *testing.T) {
	cases := []struct {
		name    string
		json    string
		code    int
		outcome string
	}{
		{"non-zero exit", `{"outcome":"ok"}`, 3, "step_error"},
		{"not json", `hello`, 0, "invalid_output"},
		{"schema mismatch", `{"outcome":"ok","extra":1}`, 0, "invalid_output"}, // emit.json は additionalProperties: false
		{"unknown enum value", `{"outcome":"maybe"}`, 0, "invalid_output"},
		{"missing outcome", `{}`, 0, "invalid_output"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			st, e := run(t, "emit", map[string]any{"json": c.json, "code": c.code})
			if st.Status != runstate.StatusFailed || st.Reason != c.outcome {
				t.Fatalf("status = %s (%s), want failed (%s)", st.Status, st.Reason, c.outcome)
			}
			x := st.Unit(MainUnit).CurrentRound().Steps[0]
			if x.Outcome != c.outcome || !x.Reserved {
				t.Fatalf("step = %+v", x)
			}
			if tr := lastTransition(t, e); !tr.Default || tr.Action != "fail" {
				t.Fatalf("transition = %+v, want the fail-closed default", tr)
			}
			if st.Unit(MainUnit).Outputs["emit"] != nil {
				t.Fatal("an invalid output must not become a referable output")
			}
		})
	}
}

// 予約値を on に書けば、明示的に別の遷移へ送れる。timeout では子プロセスをグループごと止める。
func TestTimeoutRoutedExplicitly(t *testing.T) {
	pidfile := filepath.Join(t.TempDir(), "pids")
	start := time.Now()
	st, e := run(t, "timeout", map[string]any{"pidfile": pidfile})
	if time.Since(start) > 20*time.Second {
		t.Fatal("timeout did not stop the step")
	}
	if st.Status != runstate.StatusSucceeded || st.Reason != "timeout_routed" {
		t.Fatalf("status = %s (%s)", st.Status, st.Reason)
	}
	if tr := lastTransition(t, e); tr.Default || tr.Outcome != "step_timeout" {
		t.Fatalf("transition = %+v", tr)
	}
	assertDead(t, pidfile)
}

func assertDead(t *testing.T, pidfile string) {
	t.Helper()
	data, err := os.ReadFile(pidfile)
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range strings.Fields(string(data)) {
		var pid int
		if _, err := fmt.Sscan(f, &pid); err != nil {
			t.Fatal(err)
		}
		deadline := time.Now().Add(5 * time.Second)
		for runstate.Alive(pid) && time.Now().Before(deadline) {
			time.Sleep(20 * time.Millisecond)
		}
		if runstate.Alive(pid) {
			t.Fatalf("process %d is still alive", pid)
		}
	}
}

// limit は unit 単位で数え、上限に達したら exhausted へ。$edge は遷移の with の値を遷移先へ渡す。
func TestLimitAndEdge(t *testing.T) {
	dir := t.TempDir()
	log := filepath.Join(dir, "log")
	st, _ := run(t, "rework", map[string]any{"state": filepath.Join(dir, "n"), "outcomes": "red,red,green", "log": log})
	if st.Status != runstate.StatusSucceeded || st.Reason != "green" {
		t.Fatalf("status = %s (%s) steps=%v", st.Status, st.Reason, steps(st))
	}
	if got := st.Unit(MainUnit).LimitsUsed["rework"]; got != 2 {
		t.Fatalf("limits_used.rework = %d, want 2", got)
	}
	data, _ := os.ReadFile(log)
	for _, want := range []string{"--failure fail-1 --count 1 --first red", "--failure fail-2 --count 2 --first red"} {
		if !strings.Contains(string(data), want) {
			t.Fatalf("log does not show %q:\n%s", want, data)
		}
	}

	dir = t.TempDir()
	st, e := run(t, "rework", map[string]any{"state": filepath.Join(dir, "n"), "outcomes": "red", "log": filepath.Join(dir, "log")})
	if st.Status != runstate.StatusFailed || st.Reason != "ci_red" {
		t.Fatalf("status = %s (%s)", st.Status, st.Reason)
	}
	if want := []string{"ci:red", "fix:pass", "ci:red", "fix:pass", "ci:red"}; strings.Join(steps(st), " ") != strings.Join(want, " ") {
		t.Fatalf("steps = %v, want %v", steps(st), want)
	}
	if tr := lastTransition(t, e); tr.Exhausted != "limit" {
		t.Fatalf("transition = %+v", tr)
	}
}

// $steps.<id>.outcome は exit 表のステップでも outcome を指す（出力 JSON を持たなくても解決できる）。
func TestOutcomeReferenceOfExitTableStep(t *testing.T) {
	for _, c := range []struct {
		code       int
		reason, in string
	}{{0, "recorded", "--outcome fine"}, {3, "noted", "--seen odd"}} {
		log := filepath.Join(t.TempDir(), "log")
		st, _ := run(t, "exit-outcome", map[string]any{"code": c.code, "log": log})
		if st.Status != runstate.StatusSucceeded || st.Reason != c.reason {
			t.Fatalf("code %d: status = %s (%s) steps = %v", c.code, st.Status, st.Reason, steps(st))
		}
		if data, _ := os.ReadFile(log); !strings.Contains(string(data), c.in) {
			t.Fatalf("code %d: log does not show %q:\n%s", c.code, c.in, data)
		}
	}
}

func TestRetry(t *testing.T) {
	dir := t.TempDir()
	st, _ := run(t, "retry", map[string]any{"state": filepath.Join(dir, "n"), "outcomes": "again,ok"})
	if st.Status != runstate.StatusSucceeded || strings.Join(steps(st), " ") != "flaky:again flaky:ok" {
		t.Fatalf("status = %s steps = %v", st.Status, steps(st))
	}
	dir = t.TempDir()
	st, e := run(t, "retry", map[string]any{"state": filepath.Join(dir, "n"), "outcomes": "again"})
	if st.Status != runstate.StatusFailed || st.Reason != "gave_up" || len(steps(st)) != 3 {
		t.Fatalf("status = %s (%s) steps = %v", st.Status, st.Reason, steps(st))
	}
	if got := st.Unit(MainUnit).CurrentRound().Retries["flaky"]; got != 2 {
		t.Fatalf("retries = %d, want 2", got)
	}
	if tr := lastTransition(t, e); tr.Exhausted != "retry" {
		t.Fatalf("transition = %+v", tr)
	}
}

// cancel の印があれば、実行中の子プロセス（孫を含む）を止めて停止を記録する。
func TestCancelStopsTheChild(t *testing.T) {
	scripts := testdata(t, "scripts")
	wf, err := workflow.LoadAndValidate(testdata(t, "workflows", "sleeper.yaml"), workflow.Options{ScriptsDir: scripts})
	if err != nil {
		t.Fatal(err)
	}
	pidfile := filepath.Join(t.TempDir(), "pids")
	b, _ := json.Marshal(pidfile)
	e, err := Start(StartParams{RunsDir: t.TempDir(), WF: wf, Inputs: map[string]json.RawMessage{"pidfile": b}, ScriptsDir: scripts, Cwd: t.TempDir(), Origin: "test"})
	if err != nil {
		t.Fatal(err)
	}
	e.KillGrace, e.PollInterval = time.Second, 20*time.Millisecond
	done := make(chan *runstate.State, 1)
	go func() {
		st, err := e.Loop(context.Background())
		if err != nil {
			t.Error(err)
		}
		done <- st
	}()
	waitFile(t, pidfile)
	if err := os.WriteFile(filepath.Join(e.Run.Dir, runstate.CancelFile), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	var st *runstate.State
	select {
	case st = <-done:
	case <-time.After(20 * time.Second):
		t.Fatal("the run did not stop after the cancel request")
	}
	if st.Status != runstate.StatusCancelled {
		t.Fatalf("status = %s", st.Status)
	}
	if x := st.Unit(MainUnit).CurrentRound().Steps[0]; x.Status != "cancelled" {
		t.Fatalf("step = %+v", x)
	}
	assertDead(t, pidfile)
}

func waitFile(t *testing.T, p string) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(p); err == nil {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("%s did not appear", p)
}

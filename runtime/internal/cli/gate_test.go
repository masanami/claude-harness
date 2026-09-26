package cli

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
)

// fakeClaude は偽の claude（engine/testdata/scripts/fake-claude.sh）の置き場を作り、harness の環境変数を返す。
func fakeClaude(t *testing.T) (string, []string) {
	t.Helper()
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "responses"), 0o755); err != nil {
		t.Fatal(err)
	}
	return dir, []string{"FAKE_CLAUDE_DIR=" + dir, "HARNESS_CLAUDE_BIN=" + abs(t, testScripts+"/fake-claude.sh")}
}

func respond(t *testing.T, dir string, n int, code int, stdout string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, "responses", fmt.Sprint(n)), []byte(fmt.Sprintf("%d\n%s\n", code, stdout)), 0o644); err != nil {
		t.Fatal(err)
	}
}

func passResult(cost float64) string {
	return fmt.Sprintf(`{"type":"result","subtype":"success","is_error":false,"session_id":"@SID@","total_cost_usd":%v,"structured_output":{"outcome":"pass","summary":"done"}}`, cost)
}

func runArgs(t *testing.T, workflow string, inputs ...string) []string {
	args := []string{"run", "--workflow-dir", abs(t, testWorkflows), "--scripts-dir", abs(t, testScripts)}
	for _, in := range inputs {
		args = append(args, "--input", in)
	}
	return append(args, workflow)
}

// ゲートに達した run は、非対話で構造化 JSON と「待機中」の終了コード（3）を返して終わる（§5.2）。
// resume は次のラウンドへ進め、閉じたラウンドのステップを再実行しない。
func TestRunWaitsAtGateAndResumes(t *testing.T) {
	fdir, fenv := fakeClaude(t)
	respond(t, fdir, 1, 0, passResult(0.4))
	respond(t, fdir, 2, 0, passResult(0.9))
	state := t.TempDir()
	h := newHarness(t, append(fenv, "HARNESS_STATE_DIR="+state)...)

	out, errOut, code := h.run(runArgs(t, "llm", "issue=5")...)
	if code != ExitWaiting {
		t.Fatalf("run exit %d, want %d\n%s\n%s", code, ExitWaiting, out, errOut)
	}
	v := decode[statusView](t, out)
	if v.Status != "waiting" || len(v.Waiting) != 1 {
		t.Fatalf("view = %s", out)
	}
	w := v.Waiting[0]
	if w.Gate != "review" || w.RequiresTTY || strings.Join(w.Inputs, ",") != "respond,ready" ||
		w.ResumeCommand != "harness resume "+v.RunID+" --unit main --input <respond|ready> [--note <text>]" || w.RequestedAction == "" {
		t.Fatalf("waiting = %+v", w)
	}
	if b := v.Units[0].Budget; b == nil || b.SpentUSD != 0.4 || b.LimitUSD != 5 {
		t.Fatalf("budget = %+v", b)
	}

	out, errOut, code = h.run("resume", v.RunID, "--input", "respond")
	if code != ExitWaiting {
		t.Fatalf("resume exit %d\n%s\n%s", code, out, errOut)
	}
	out, errOut, code = h.run("resume", v.RunID, "--input", "ready")
	if code != ExitOK {
		t.Fatalf("resume exit %d\n%s\n%s", code, out, errOut)
	}
	st := decode[runstate.State](t, out)
	u := st.Units[0]
	if st.Status != "succeeded" || len(u.Rounds) != 2 || u.Rounds[1].Steps[0].Step != "fix" || len(u.Rounds[1].Steps) != 1 {
		t.Fatalf("state = %s", out)
	}
	// イベントログにステップ実行が重複しない（閉じたラウンドの implement は 1 回だけ）。
	types := eventTypes(t, filepath.Join(state, "runs", v.RunID))
	if strings.Count(types, "step_started") != 2 || strings.Count(types, "round_started") != 2 || strings.Count(types, "gate_resolved") != 2 {
		t.Fatalf("events = %s", types)
	}
	if !strings.Contains(types, "gate_opened runner_started gate_resolved transition round_started step_started") {
		t.Fatalf("events = %s", types)
	}
}

// input×human のゲートは resume で解決できず、approve は端末が無ければ拒否する。記録は何も増えない。
func TestHumanInputGateNeedsApproveFromATerminal(t *testing.T) {
	state := t.TempDir()
	h := newHarness(t, "HARNESS_STATE_DIR="+state, "USER=tester")
	out, errOut, code := h.run(runArgs(t, "gates", `json={"outcome":"human"}`, "log="+filepath.Join(t.TempDir(), "log"), "state=x")...)
	if code != ExitWaiting {
		t.Fatalf("run exit %d\n%s", code, errOut)
	}
	v := decode[statusView](t, out)
	if w := v.Waiting[0]; !w.RequiresTTY || !strings.HasPrefix(w.ResumeCommand, "harness approve ") {
		t.Fatalf("waiting = %+v", w)
	}
	before := eventTypes(t, filepath.Join(state, "runs", v.RunID))

	out, errOut, code = h.run("resume", v.RunID, "--input", "follow", "--note", "go")
	if code != ExitFailed || !strings.Contains(errOut, "resume cannot resolve it") || !strings.Contains(errOut, "harness approve") {
		t.Fatalf("resume exit %d\n%s", code, errOut)
	}
	if decode[statusView](t, out).Status != "waiting" {
		t.Fatalf("resume refusal must report the waiting state: %s", out)
	}
	// exec.Cmd の既定の stdin は /dev/null（端末ではない文字デバイス）。
	_, errOut, code = h.run("approve", v.RunID, "--input", "follow", "--note", "go")
	if code != ExitFailed || !strings.Contains(errOut, "not a terminal") {
		t.Fatalf("approve without a tty exit %d\n%s", code, errOut)
	}
	if after := eventTypes(t, filepath.Join(state, "runs", v.RunID)); after != before {
		t.Fatalf("a refused resolution recorded events:\n%s\n%s", before, after)
	}
}

// approve は端末があれば対象の要約を表示し、yes の入力で解決する。actor・channel が記録に残る。
func TestApproveFromATerminal(t *testing.T) {
	state := t.TempDir()
	log := filepath.Join(t.TempDir(), "log")
	h := newHarness(t, "HARNESS_STATE_DIR="+state)
	out, _, code := h.run(runArgs(t, "gates", `json={"outcome":"human"}`, "log="+log, "state=x")...)
	if code != ExitWaiting {
		t.Fatalf("run exit %d", code)
	}
	id := decode[statusView](t, out).RunID

	approve := func(answer string) (string, string, int) {
		r, w, err := os.Pipe()
		if err != nil {
			t.Fatal(err)
		}
		defer r.Close()
		w.WriteString(answer)
		w.Close()
		var stdout, stderr bytes.Buffer
		envs := map[string]string{"HARNESS_STATE_DIR": state, "USER": "tester"}
		code := Main([]string{"approve", id, "--input", "follow", "--note", "keep the ticket's decision"}, Env{
			Stdin: r, Stdout: &stdout, Stderr: &stderr,
			Getenv:     func(k string) string { return envs[k] },
			Getwd:      os.Getwd,
			IsTerminal: func(*os.File) bool { return true },
		})
		return stdout.String(), stderr.String(), code
	}
	_, errOut, code := approve("no\n")
	if code != ExitFailed || !strings.Contains(errOut, "not approved") || !strings.Contains(errOut, "a critical design deviation") {
		t.Fatalf("approve answered no: exit %d\n%s", code, errOut)
	}
	out, errOut, code = approve("yes\n")
	if code != ExitOK {
		t.Fatalf("approve exit %d\n%s\n%s", code, out, errOut)
	}
	st := decode[runstate.State](t, out)
	r := st.Units[0].Gates[0].Resolution
	if st.Status != "succeeded" || r.Actor != "approve" || r.Channel != "tty" || r.User != "tester" || r.Outcome != "follow" {
		t.Fatalf("status = %s resolution = %+v", st.Status, r)
	}
}

// decider: parent / any のゲートは TTY を要求しない（resume で解決でき、channel は non-tty で残る）。
func TestParentAndAnyGatesResolveWithoutATerminal(t *testing.T) {
	for _, to := range []string{"parent", "any"} {
		h := newHarness(t, "HARNESS_STATE_DIR="+t.TempDir())
		out, _, code := h.run(runArgs(t, "gates", fmt.Sprintf(`json={"outcome":%q}`, to), "log=x", "state=x")...)
		if code != ExitWaiting {
			t.Fatalf("%s: run exit %d", to, code)
		}
		id := decode[statusView](t, out).RunID
		out, errOut, code := h.run("resume", id, "--input", "go")
		if code != ExitOK {
			t.Fatalf("%s: resume exit %d\n%s", to, code, errOut)
		}
		if r := decode[runstate.State](t, out).Units[0].Gates[0].Resolution; r.Channel != "non-tty" || r.Actor != "resume" {
			t.Fatalf("%s: resolution = %+v", to, r)
		}
	}
}

// startSleepingLLM は偽の claude が眠る run を別プロセスで始め、claude の PID が記録されるまで待つ。
func startSleepingLLM(t *testing.T, h *harness, fdir string) (string, int, func()) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(fdir, "responses", "1.sleep"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	runner := h.cmd(runArgs(t, "llm", "issue=1")...)
	if err := runner.Start(); err != nil {
		t.Fatal(err)
	}
	id := onlyRun(t, h)
	var pid int
	waitFor(t, func() bool {
		out, _, _ := h.run("status", "--json", id)
		x := decode[runstate.State](t, out).Units[0].Running()
		if x != nil && x.PID != 0 {
			pid = x.PID
			return true
		}
		return false
	})
	return id, pid, func() {
		_ = runner.Process.Signal(syscall.SIGKILL)
		_ = runner.Wait()
	}
}

// runner が落ちて running のまま残ったステップ実行は、次の status で interrupted になり、unit は interrupted ゲートへ
// 送られる（自動で再実行しない）。費用は付与した上限額で数える。
func TestStatusInterruptsAStepLeftByADeadRunner(t *testing.T) {
	fdir, fenv := fakeClaude(t)
	state := t.TempDir()
	h := newHarness(t, append(fenv, "HARNESS_STATE_DIR="+state)...)
	id, pid, killRunner := startSleepingLLM(t, h, fdir)
	killRunner()

	// 子プロセス（claude）がまだ生きている間は、status は打ち切らない。
	out, _, _ := h.run("status", "--json", id)
	v := decode[statusView](t, out)
	if v.Units[0].Running() == nil || v.RunnerAlive == nil || *v.RunnerAlive {
		t.Fatalf("status while the orphan lives = %s", out)
	}
	_ = syscall.Kill(-pid, syscall.SIGKILL)
	waitFor(t, func() bool { return !runstate.Alive(pid) })

	out, _, code := h.run("status", "--json", id)
	if code != ExitOK {
		t.Fatalf("status exit %d", code)
	}
	v = decode[statusView](t, out)
	u := v.Units[0]
	x := u.Rounds[0].Steps[0]
	if v.Status != "waiting" || x.Status != "interrupted" || u.Gate == nil || u.Gate.Gate != "interrupted" || !u.Gate.Builtin {
		t.Fatalf("status after the orphan died = %s", out)
	}
	if u.Budget.SpentUSD != 2 || u.Budget.UnknownCostCount != 1 {
		t.Fatalf("budget = %+v", u.Budget)
	}
	if len(v.Waiting) != 1 || !strings.Contains(v.Waiting[0].ResumeCommand, "<rerun|abort>") {
		t.Fatalf("waiting = %+v", v.Waiting)
	}
	// 2 回目の status は何も記録しない。
	before := eventTypes(t, filepath.Join(state, "runs", id))
	h.run("status", id)
	if after := eventTypes(t, filepath.Join(state, "runs", id)); after != before {
		t.Fatalf("status recorded again:\n%s\n%s", before, after)
	}

	out, errOut, code := h.run("resume", id, "--input", "abort")
	if code != ExitFailed || decode[runstate.State](t, out).Reason != "interrupted" {
		t.Fatalf("resume abort exit %d\n%s%s", code, out, errOut)
	}
}

// resume は、runner が落ちて残った子プロセスを止めてから interrupted にし、rerun でそのステップを新しいラウンドでやり直す。
func TestResumeStopsTheOrphanAndReruns(t *testing.T) {
	fdir, fenv := fakeClaude(t)
	respond(t, fdir, 2, 0, passResult(0.3))
	state := t.TempDir()
	h := newHarness(t, append(fenv, "HARNESS_STATE_DIR="+state)...)
	id, pid, killRunner := startSleepingLLM(t, h, fdir)
	killRunner()

	out, errOut, code := h.run("resume", id, "--input", "rerun")
	if code != ExitWaiting {
		t.Fatalf("resume exit %d\n%s%s", code, out, errOut)
	}
	if runstate.Alive(pid) {
		t.Fatalf("the orphaned claude (pid %d) is still alive", pid)
	}
	st := decode[runstate.State](t, out)
	u := st.Units[0]
	if len(u.Rounds) != 2 || u.Rounds[0].Steps[0].Status != "interrupted" || u.Rounds[1].Trigger.Gate != "interrupted" ||
		u.Rounds[1].Steps[0].Step != "implement" || u.Rounds[1].Steps[0].Attempt != 2 || u.Gate == nil || u.Gate.Gate != "review" {
		t.Fatalf("state = %s", out)
	}
	if u.Budget.SpentUSD != 2.3 || u.Budget.UnknownCostCount != 1 {
		t.Fatalf("budget = %+v", u.Budget)
	}
}

// ゲートで待っている run の cancel は、runner を待たずに停止を記録する（待機中の run には runner が居ない）。
func TestCancelOfAWaitingRun(t *testing.T) {
	state := t.TempDir()
	h := newHarness(t, "HARNESS_STATE_DIR="+state)
	out, _, code := h.run(runArgs(t, "gates", `json={"outcome":"any"}`, "log=x", "state=x")...)
	if code != ExitWaiting {
		t.Fatalf("run exit %d", code)
	}
	id := decode[statusView](t, out).RunID
	// 終わった runner の PID が別のプロセス（このテスト自身）に再利用された状況を作る。
	run, err := runstate.Open(filepath.Join(state, "runs"), id)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := run.Append(runstate.Event{Type: runstate.EvRunnerStarted, RunnerStarted: &runstate.RunnerStarted{PID: os.Getpid(), Command: "test"}}); err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	out, errOut, code := h.run("cancel", id)
	if code != ExitOK || time.Since(start) > 10*time.Second {
		t.Fatalf("cancel exit %d after %s\n%s%s", code, time.Since(start), out, errOut)
	}
	out, _, _ = h.run("status", "--json", id)
	st := decode[runstate.State](t, out)
	if st.Status != "cancelled" || st.Units[0].Gate != nil || st.Units[0].Status != "cancelled" {
		t.Fatalf("status = %s", out)
	}
}

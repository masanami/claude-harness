package cli

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/masanami/claude-harness/runtime/internal/engine"
	"github.com/masanami/claude-harness/runtime/internal/runstate"
	"github.com/masanami/claude-harness/runtime/internal/version"
	"github.com/masanami/claude-harness/runtime/internal/workflow"
)

// 切り離した run（#347）のテスト。run の中身は sleeper（孫の sleep を待つ command ステップ）で、孫の sleep を止めると
// ステップが終わって run が succeeded になる。呼び出し元（h.run のプロセス）は run の終わりより前に終わっている。

// waitFile は path が現れるまで待ち、中身を返す。
func waitFile(t *testing.T, path string) string {
	t.Helper()
	deadline := time.Now().Add(30 * time.Second)
	for {
		if b, err := os.ReadFile(path); err == nil {
			return string(b)
		}
		if time.Now().After(deadline) {
			t.Fatalf("%s did not appear", path)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// sleeperPIDs は sleeper.sh が書いた自分（ステップのプロセスグループの長）と孫の sleep の PID。
func sleeperPIDs(t *testing.T, pidfile string) (int, int) {
	t.Helper()
	f := strings.Fields(waitFile(t, pidfile))
	if len(f) != 2 {
		t.Fatalf("pidfile = %q", f)
	}
	step, err1 := strconv.Atoi(f[0])
	child, err2 := strconv.Atoi(f[1])
	if err1 != nil || err2 != nil {
		t.Fatalf("pidfile = %q", f)
	}
	return step, child
}

// statusOf は status --json を読む。
func (h *harness) statusOf(id string) statusView {
	h.t.Helper()
	out, errOut, code := h.run("status", id, "--json")
	if code != ExitOK {
		h.t.Fatalf("status exit %d\n%s\n%s", code, out, errOut)
	}
	return decode[statusView](h.t, out)
}

// waitStatus は status --json の status が want になるまで待つ。
func (h *harness) waitStatus(id, want string) statusView {
	h.t.Helper()
	deadline := time.Now().Add(30 * time.Second)
	for {
		v := h.statusOf(id)
		if v.Status == want {
			h.waitRunnerExit(v)
			return v
		}
		if time.Now().After(deadline) {
			h.t.Fatalf("run %s is %s, want %s", id, v.Status, want)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// waitRunnerExit は、ゲートか終端に達した run の runner が終わるまで待つ（runner は最後の記録の後に runner.log へ
// 結果を書いてから終わる。テストの一時ディレクトリを消す前に書き終えさせる）。
func (h *harness) waitRunnerExit(v statusView) {
	h.t.Helper()
	deadline := time.Now().Add(30 * time.Second)
	for runstate.Alive(v.PID) && v.PID != os.Getpid() {
		if time.Now().After(deadline) {
			h.t.Fatalf("the runner (pid %d) of run %s did not end", v.PID, v.RunID)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// startDetached は sleeper を run --detach で始め、run ID と pidfile を返す。
func startDetached(t *testing.T, h *harness) (string, string) {
	t.Helper()
	pidfile := filepath.Join(t.TempDir(), "pid")
	args := runArgs(t, "sleeper", "pidfile="+pidfile)
	out, errOut, code := h.run(append([]string{"run", "--detach"}, args[1:]...)...)
	if code != ExitOK {
		t.Fatalf("run --detach exit %d\n%s\n%s", code, out, errOut)
	}
	id := strings.TrimSpace(out)
	if id == "" || strings.ContainsAny(id, " \n{") || !strings.Contains(errOut, "run "+id+" started") {
		t.Fatalf("run --detach must print only the run id: stdout %q\n%s", out, errOut)
	}
	// 一時ディレクトリ（HARNESS_STATE_DIR・pidfile）は、この登録より前に作ったので、t.Cleanup の逆順により
	// この片付けの後に消える。runner は孫の sleep が終わると run の記録（events・状態・runner.log）を書いてから
	// 終わるので、それを待たずに一時ディレクトリを消すと、runner の書き込みと競合して RemoveAll が
	// directory not empty で落ちる。
	t.Cleanup(func() { stopDetached(t, h, id, pidfile) })
	return id, pidfile
}

// stopDetached は、startDetached で始めた run の runner がまだ生きていれば、孫の sleep を止めて run を終わらせ、
// runner が終わるまで待つ。テストが途中で落ちたときも runner と sleep を残さない。
func stopDetached(t *testing.T, h *harness, id, pidfile string) {
	t.Helper()
	v := h.statusOf(id)
	if !runstate.Alive(v.PID) || v.PID == os.Getpid() {
		return
	}
	if b, err := os.ReadFile(pidfile); err == nil {
		if f := strings.Fields(string(b)); len(f) == 2 {
			if child, err := strconv.Atoi(f[1]); err == nil {
				_ = syscall.Kill(child, syscall.SIGTERM) // 孫の sleep を止めるとステップが終わり、runner も終わる
			}
		}
	}
	h.waitRunnerExit(v)
}

// (a) 切り離して始めた run は、呼び出し元のプロセスが終わった後も最後まで進み、status・contract status で終わりまで読める。
// run を進めたのは呼び出し元とは別の、新しいセッションの runner で、その PID と開始時刻が記録に残る。
func TestDetachedRunOutlivesTheCaller(t *testing.T) {
	h := newHarness(t, "HARNESS_STATE_DIR="+t.TempDir())
	id, pidfile := startDetached(t, h)
	_, child := sleeperPIDs(t, pidfile) // 呼び出し元（h.run）は既に終わっている。ステップはまだ走っている

	v := h.statusOf(id)
	if v.Status != runstate.StatusRunning || v.RunnerAlive == nil || !*v.RunnerAlive || v.PIDStart == "" {
		t.Fatalf("while the step runs: status %s runner_alive %v pid_start %q", v.Status, v.RunnerAlive, v.PIDStart)
	}
	if sid, err := getsid(v.PID); err != nil || sid != v.PID {
		t.Fatalf("the runner (pid %d) does not lead its own session: sid %d %v", v.PID, sid, err)
	}
	if c, _ := h.contractNow("status", id); c.State != runstate.StatusRunning {
		t.Fatalf("contract status while running = %+v", c)
	}

	_ = syscall.Kill(child, syscall.SIGTERM) // 孫の sleep を止めるとステップが終わる
	v = h.waitStatus(id, runstate.StatusSucceeded)
	if v.Reason != "finished" {
		t.Fatalf("final = %s (%s)", v.Status, v.Reason)
	}
	if c, _ := h.contractNow("status", id); c.State != runstate.StatusSucceeded || c.RequestedAction != nil {
		t.Fatalf("contract status at the end = %+v", c)
	}
	if et := eventTypes(t, v.RunDir); !strings.Contains(et, "run_started round_started runner_started step_started") {
		t.Fatalf("events = %s", et)
	}
	log := waitFile(t, filepath.Join(v.RunDir, runstate.RunnerLogFile))
	if !strings.Contains(log, `"status": "succeeded"`) {
		t.Fatalf("runner.log does not have the runner's output:\n%s", log)
	}
}

// (b) contract start は run の終わりを待たず、run ID と running を含む契約の JSON をすぐ返す。
func TestContractStartReturnsAtOnce(t *testing.T) {
	h := newHarness(t, "HARNESS_STATE_DIR="+t.TempDir())
	pidfile := filepath.Join(t.TempDir(), "pid")
	args := runArgs(t, "sleeper", "pidfile="+pidfile)
	began := time.Now()
	d, _ := h.contractNow(append([]string{"start"}, args[1:]...)...)
	took := time.Since(began)
	id := runIDOf(t, d)
	// sleeper はゲートを持たず、孫の sleep を止めるまでステップが終わらないので、start の直後は必ず running になる
	// （runner の速さに依らない。ゲートを持つ run の start は waiting も返しうる＝checkJustStarted）。
	if d.State != runstate.StatusRunning || d.RequestedAction != nil || d.CostUSD == nil || took > 20*time.Second {
		t.Fatalf("contract start = %+v (took %s)", d, took)
	}
	_, child := sleeperPIDs(t, pidfile)
	if c, _ := h.contractNow("status", id); c.State != runstate.StatusRunning { // start が戻った後も、ステップは走っている
		t.Fatalf("contract status = %+v", c)
	}
	_ = syscall.Kill(child, syscall.SIGTERM)
	if s := h.settle(id); s.State != runstate.StatusSucceeded {
		t.Fatalf("contract status at the end = %+v", s)
	}
}

// (c) 同じ run を 2 つのプロセスが進めない: runner が進めている run は、別の runner（内部の入口）も resume も弾かれ、
// 記録は増えない。
func TestDetachedRunnerLockRefusesASecondRunner(t *testing.T) {
	h := newHarness(t, "HARNESS_STATE_DIR="+t.TempDir())
	id, pidfile := startDetached(t, h)
	sleeperPIDs(t, pidfile) // ステップが走っている（runner がロックを持っている）。片付けは startDetached が登録した stopDetached
	dir := h.statusOf(id).RunDir
	before := eventTypes(t, dir)

	_, errOut, code := h.run(detachedRunnerCmd, id)
	if code != ExitFailed || !strings.Contains(errOut, "already being advanced by another runner") {
		t.Fatalf("second runner: exit %d\n%s", code, errOut)
	}
	_, errOut, code = h.run("resume", id)
	if code != ExitFailed || !strings.Contains(errOut, "already being advanced by another runner") {
		t.Fatalf("resume of a run a runner advances: exit %d\n%s", code, errOut)
	}
	if after := eventTypes(t, dir); after != before {
		t.Fatalf("a refused runner recorded events:\n%s\n%s", before, after)
	}
}

// (d) runner を強制終了すると、status・contract status は runner が生きていないことを示し、running のまま
// 「進んでいる」ようには見せない。ステップのプロセスも消えれば、既存の規則（§4.5）どおり interrupted ゲートで待ち、
// contract resume で再開（rerun）・打ち切り（abort）できる。
func TestKilledDetachedRunnerIsSeen(t *testing.T) {
	h := newHarness(t, "HARNESS_STATE_DIR="+t.TempDir())
	id, pidfile := startDetached(t, h)
	step, child := sleeperPIDs(t, pidfile)
	runner := h.statusOf(id).PID
	if err := syscall.Kill(runner, syscall.SIGKILL); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(10 * time.Second)
	for runstate.Alive(runner) && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}

	// ステップのプロセスがまだ生きている間は running のまま、runner が居ないことを出す。
	v := h.statusOf(id)
	if v.Status != runstate.StatusRunning || v.RunnerAlive == nil || *v.RunnerAlive {
		t.Fatalf("after the runner died: status %s runner_alive %v", v.Status, v.RunnerAlive)
	}
	if c, _ := h.contractNow("status", id); c.State != runstate.StatusRunning || !strings.Contains(c.Summary, fmt.Sprintf("the runner (pid %d) is not alive", runner)) {
		t.Fatalf("contract status = %+v", c)
	}

	_ = syscall.Kill(-step, syscall.SIGKILL) // ステップのプロセスグループも消える
	_ = syscall.Kill(child, syscall.SIGKILL)
	v = h.waitStatus(id, runstate.StatusWaiting)
	if len(v.Waiting) != 1 || v.Waiting[0].Gate != "interrupted" {
		t.Fatalf("waiting = %+v", v.Waiting)
	}
	c, _ := h.contractNow("status", id)
	if c.State != runstate.StatusWaiting || c.RequestedAction == nil || c.RequestedAction.Kind != "answer" ||
		!strings.Contains(c.RequestedAction.Text, "harness contract resume "+id) {
		t.Fatalf("contract status = %+v %+v", c, c.RequestedAction)
	}
	if r, _ := h.contractNow("resume", id, "--input", "abort"); r.State != runstate.StatusFailed {
		t.Fatalf("contract resume --input abort = %+v", r)
	}
}

// (e) runner は呼び出し元の環境変数（HARNESS_PLUGIN_VERSION・HARNESS_CLAUDE_PERMISSION_MODE ほか）と作業ディレクトリを
// そのまま引き継ぐ。
func TestDetachedRunnerInheritsEnvAndCwd(t *testing.T) {
	wd, sd := t.TempDir(), t.TempDir()
	writeFile(t, filepath.Join(wd, "probe.yaml"), `schema: harness.workflow/v1
id: probe
inputs:
  out: { type: string, required: true }
steps:
  probe:
    kind: command
    run: probe
    with: { out: $inputs.out }
    exit: { 0: probed }
    on:
      probed: { done: probed }
`)
	writeFile(t, filepath.Join(sd, "probe.sh"), `#!/bin/bash
out=''
while [ $# -gt 0 ]; do
  case "$1" in
    --out) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
{
  echo "plugin=$HARNESS_PLUGIN_VERSION"
  echo "mode=$HARNESS_CLAUDE_PERMISSION_MODE"
  echo "extra=$HARNESS_DETACH_PROBE"
} > "$out.tmp" && mv "$out.tmp" "$out"
printf '{"outcome":"probed"}\n'
`)
	if err := os.Chmod(filepath.Join(sd, "probe.sh"), 0o755); err != nil {
		t.Fatal(err)
	}
	h := newHarness(t, "HARNESS_STATE_DIR="+t.TempDir(), PluginVersionEnv+"=5.0.0", PermissionModeEnv+"=auto", "HARNESS_DETACH_PROBE=yes")
	out := filepath.Join(t.TempDir(), "probe")
	o, errOut, code := h.run("run", "--detach", "--workflow-dir", wd, "--scripts-dir", sd, "--input", "out="+out, "probe")
	if code != ExitOK {
		t.Fatalf("run --detach exit %d\n%s\n%s", code, o, errOut)
	}
	v := h.waitStatus(strings.TrimSpace(o), runstate.StatusSucceeded)
	got := waitFile(t, out)
	for _, want := range []string{"plugin=5.0.0\n", "mode=auto\n", "extra=yes\n"} {
		if !strings.Contains(got, want) {
			t.Errorf("the step did not get %q:\n%s", want, got)
		}
	}
	cwd, _ := filepath.EvalSymlinks(h.cwd)
	if rc, _ := filepath.EvalSymlinks(v.Cwd); rc != cwd {
		t.Errorf("run cwd = %s, want %s", v.Cwd, h.cwd)
	}
}

// HARNESS_CLAUDE_PERMISSION_MODE は切り離した runner が起動する claude にも --permission-mode で渡る。
func TestDetachedRunnerPassesThePermissionMode(t *testing.T) {
	fdir, fenv := fakeClaude(t)
	respond(t, fdir, 1, 0, passResult(0.4))
	h := newHarness(t, append(fenv, "HARNESS_STATE_DIR="+t.TempDir(), PermissionModeEnv+"=auto")...)
	args := runArgs(t, "llm", "issue=5")
	out, errOut, code := h.run(append([]string{"run", "--detach"}, args[1:]...)...)
	if code != ExitOK {
		t.Fatalf("run --detach exit %d\n%s\n%s", code, out, errOut)
	}
	h.waitStatus(strings.TrimSpace(out), runstate.StatusWaiting)
	b, err := os.ReadFile(filepath.Join(fdir, "calls", "1.argv"))
	if err != nil || !strings.Contains(string(b), "--permission-mode\nauto\n") {
		t.Fatalf("argv does not pass the mode (%v):\n%s", err, b)
	}
}

// (f) --detach を付けない run は従来どおり同期: ゲートか終端まで進めてから、状態の JSON と終了コードを返す。
// 進めたのは呼び出したプロセス自身で、runner_started は記録しない。
func TestRunWithoutDetachIsSynchronous(t *testing.T) {
	h := newHarness(t, "HARNESS_STATE_DIR="+t.TempDir())
	out, errOut, code := h.run(runArgs(t, "gates", `json={"outcome":"parent"}`, "log="+filepath.Join(t.TempDir(), "log"), "state=x")...)
	if code != ExitWaiting {
		t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
	}
	v := decode[statusView](t, out)
	if v.Status != runstate.StatusWaiting || v.PIDStart == "" || strings.Contains(eventTypes(t, v.RunDir), "runner_started") {
		t.Fatalf("status %s pid_start %q events %s", v.Status, v.PIDStart, eventTypes(t, v.RunDir))
	}
	if _, err := os.Stat(filepath.Join(v.RunDir, runstate.RunnerLogFile)); !os.IsNotExist(err) {
		t.Fatalf("a synchronous run wrote %s (%v)", runstate.RunnerLogFile, err)
	}
}

// ステップとステップの間で runner が落ちた run（実行中のステップが無い）も、status を読んだときに interrupted ゲートで
// 待たせ、running のまま残さない（#347・オーナーの回答 A）。contract では answer × parent で、contract resume --input rerun が
// 次に実行するはずだったステップから続ける。
func TestStatusInterruptsARunWhoseRunnerDiedBetweenSteps(t *testing.T) {
	state := t.TempDir()
	h := newHarness(t, "HARNESS_STATE_DIR="+state)
	sd := abs(t, testScripts)
	wf, err := workflow.LoadAndValidate(filepath.Join(abs(t, testWorkflows), "gates.yaml"), workflow.Options{ScriptsDir: sd})
	if err != nil {
		t.Fatal(err)
	}
	inputs, err := parseInputs(wf, []string{`json={"outcome":"parent"}`, "log=" + filepath.Join(t.TempDir(), "log"), "state=x"})
	if err != nil {
		t.Fatal(err)
	}
	eng, err := engine.Start(engine.StartParams{RunsDir: filepath.Join(state, "runs"), WF: wf, Inputs: inputs, ScriptsDir: sd,
		WorkflowDir: abs(t, testWorkflows), Cwd: h.cwd, Origin: "cli", CLIVersion: version.CLI()})
	if err != nil {
		t.Fatal(err)
	}
	dead := exec.Command("true")
	if err := dead.Run(); err != nil {
		t.Fatal(err)
	}
	if _, err := eng.Run.Append(runstate.Event{Type: runstate.EvRunnerStarted, RunnerStarted: &runstate.RunnerStarted{
		PID: dead.Process.Pid, PIDStart: "Thu Jan  1 00:00:00 1970", Command: "detached"}}); err != nil {
		t.Fatal(err)
	}
	id := eng.Run.ID

	v := h.statusOf(id)
	if v.Status != runstate.StatusWaiting || len(v.Waiting) != 1 || v.Waiting[0].Gate != "interrupted" ||
		!strings.Contains(v.Waiting[0].RequestedAction, "died before step route started") || v.Units[0].CurrentStep != "route" {
		t.Fatalf("status = %s %+v", v.Status, v.Waiting)
	}
	c, _ := h.contractNow("status", id)
	if c.State != runstate.StatusWaiting || c.RequestedAction == nil || c.RequestedAction.Kind != "answer" || c.RequestedAction.Decider != "parent" ||
		!strings.Contains(c.RequestedAction.Text, "harness contract resume "+id+" --unit main --input <rerun|abort>") {
		t.Fatalf("contract status = %+v %+v", c, c.RequestedAction)
	}
	before := eventTypes(t, v.RunDir)
	h.run("status", id) // 2 回目の status は何も記録しない
	if after := eventTypes(t, v.RunDir); after != before {
		t.Fatalf("status recorded again:\n%s\n%s", before, after)
	}
	// contract resume は切り離して再開し、すぐ戻る（#359）ので、直後の state は running か waiting。続きは status で読む。
	r, _ := h.contractNow("resume", id, "--input", "rerun")
	checkJustStarted(t, r.State, r.RequestedAction != nil)
	if r = h.settle(id); r.State != runstate.StatusWaiting || r.RequestedAction == nil || !strings.Contains(r.Summary, "at gate ask-parent") {
		t.Fatalf("contract resume --input rerun, then status = %+v", r)
	}
}

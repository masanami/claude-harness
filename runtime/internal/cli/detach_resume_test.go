package cli

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
)

// 切り離した再開（#359）のテスト。#347 の切り離した run のテスト（detach_test.go）と同じ形で、run の中身は
// ゲートの後ろの sleeper（孫の sleep を待つ command ステップ）。ゲートを解いた後の進行は切り離した runner が
// 行うので、呼び出し元のプロセスグループを止めても run は最後まで進む。

// gatedSleeper はゲートで待ってから sleeper を実行するワークフロー（decider でゲートの種類を選ぶ: parent は resume、
// human は approve で解く）を書き、その run を同期の run で始めてゲートで待たせる。run ID と pidfile を返す。
func gatedSleeper(t *testing.T, h *harness, decider string) (string, string) {
	t.Helper()
	wd := t.TempDir()
	writeFile(t, filepath.Join(wd, "gated-sleeper.yaml"), `schema: harness.workflow/v1
id: gated-sleeper
inputs:
  pidfile: { type: string, required: true }
steps:
  begin:
    kind: command
    run: emit
    with: { json: "{}", code: 0 }
    exit: { 0: asked }
    on:
      asked: { gate: ask }
  ask:
    kind: gate
    type: input
    decider: `+decider+`
    requested_action: decide whether to go on
    inputs: [go, stop]
    on:
      go: { goto: sleep }
      stop: { fail: stopped }
  sleep:
    kind: command
    run: sleeper
    with: { pidfile: $inputs.pidfile }
    exit: { 0: finished }
    on:
      finished: { done: finished }
`)
	pidfile := filepath.Join(t.TempDir(), "pid")
	out, errOut, code := h.run("run", "--workflow-dir", wd, "--scripts-dir", abs(t, testScripts), "--input", "pidfile="+pidfile, "gated-sleeper")
	if code != ExitWaiting {
		t.Fatalf("run exit %d\n%s\n%s", code, out, errOut)
	}
	return decode[statusView](t, out).RunID, pidfile
}

// checkJustResumed は切り離した再開が返した状態が、再開の直後にありうる値かを確かめる（checkJustStarted と同じ考え方）。
// 再開は run の終わりを待たないが、返す状態は run の状態そのものなので、速い runner（Linux）がもうゲートへ着いて
// いれば waiting になる。running なら待っているゲートは無く、waiting ならある。終わりの状態は受け付けない。
func checkJustResumed(t *testing.T, v statusView) {
	t.Helper()
	switch {
	case v.Status == runstate.StatusRunning && len(v.Waiting) == 0, v.Status == runstate.StatusWaiting && len(v.Waiting) > 0:
	default:
		t.Fatalf("a detached resume returned status %q (waiting at %d gate(s)), want running or waiting (it does not wait for the run to end)",
			v.Status, len(v.Waiting))
	}
}

// inOwnGroup は harness <args> を、自分のプロセスグループの長として起動したシェルの中で実行する。シェルは harness の
// 標準出力を out へ書いた後も眠り続けるので、harness が戻った後に呼び出し元（シェル）のプロセスグループを止められる
// （Claude Code の Bash ツールが待ち時間の上限で止める形）。harness の終了コードを code へ書く。
func (h *harness) inOwnGroup(dir string, args ...string) *exec.Cmd {
	h.t.Helper()
	script := `"$0" "$@" > "$HARNESS_TEST_OUT" 2> "$HARNESS_TEST_OUT.err"; echo $? > "$HARNESS_TEST_OUT.code"; sleep 60`
	c := exec.Command("/bin/sh", append([]string{"-c", script, os.Args[0]}, args...)...)
	c.Env = append(append([]string{}, h.env...), "HARNESS_TEST_OUT="+filepath.Join(dir, "out"))
	c.Dir = h.cwd
	c.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := c.Start(); err != nil {
		h.t.Fatal(err)
	}
	return c
}

// stopGroup は呼び出し元のプロセスグループに SIGTERM を送り、シェルが終わるのを待つ。
func stopGroup(t *testing.T, c *exec.Cmd) {
	t.Helper()
	if err := syscall.Kill(-c.Process.Pid, syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	_ = c.Wait()
}

// (a) resume --detach はゲートを解いた後の進行を切り離した runner に渡してすぐ戻る。呼び出し元のプロセスグループを
// 止めても run は最後まで進み、status・contract status で終わりまで読める。runner は新しいセッションで動き、
// runner_started は resume（ゲートを解いたプロセス）と detached（引き継いだ runner）の順に残る。
func TestDetachedResumeOutlivesTheCallerGroup(t *testing.T) {
	h := newHarness(t, "HARNESS_STATE_DIR="+t.TempDir())
	id, pidfile := gatedSleeper(t, h, "parent")

	dir := t.TempDir()
	began := time.Now()
	c := h.inOwnGroup(dir, "resume", "--detach", id, "--input", "go")
	code := strings.TrimSpace(waitFile(t, filepath.Join(dir, "out.code")))
	took := time.Since(began)
	out, _ := os.ReadFile(filepath.Join(dir, "out"))
	errOut, _ := os.ReadFile(filepath.Join(dir, "out.err"))
	if code != "0" || took > 20*time.Second {
		t.Fatalf("resume --detach exit %s (took %s)\n%s\n%s", code, took, out, errOut)
	}
	checkJustResumed(t, decode[statusView](t, string(out)))
	if !strings.Contains(string(errOut), "advanced by a detached runner") {
		t.Fatalf("resume --detach did not say it detached:\n%s", errOut)
	}
	_, child := sleeperPIDs(t, pidfile) // ステップは切り離した runner の下で走っている
	stopGroup(t, c)                     // 呼び出し元のプロセスグループを止める

	v := h.statusOf(id)
	if v.Status != runstate.StatusRunning || v.RunnerAlive == nil || !*v.RunnerAlive {
		t.Fatalf("after the caller's group was stopped: status %s runner_alive %v", v.Status, v.RunnerAlive)
	}
	if sid, err := getsid(v.PID); err != nil || sid != v.PID {
		t.Fatalf("the runner (pid %d) does not lead its own session: sid %d %v", v.PID, sid, err)
	}
	if cd, _ := h.contractNow("status", id); cd.State != runstate.StatusRunning {
		t.Fatalf("contract status while running = %+v", cd)
	}

	_ = syscall.Kill(child, syscall.SIGTERM)
	v = h.waitStatus(id, runstate.StatusSucceeded)
	if v.Reason != "finished" {
		t.Fatalf("final = %s (%s)", v.Status, v.Reason)
	}
	if cd, _ := h.contractNow("status", id); cd.State != runstate.StatusSucceeded || cd.RequestedAction != nil {
		t.Fatalf("contract status at the end = %+v", cd)
	}
	if et := eventTypes(t, v.RunDir); !strings.Contains(et, "gate_resolved transition round_started") ||
		!strings.Contains(runnerCommands(t, v.RunDir), "resume detached") {
		t.Fatalf("events = %s (runner commands %s)", et, runnerCommands(t, v.RunDir))
	}
	if r := v.Units[0].Gates[0].Resolution; r == nil || r.Actor != "resume" || r.Outcome != "go" {
		t.Fatalf("resolution = %+v", r)
	}
	if log := waitFile(t, filepath.Join(v.RunDir, runstate.RunnerLogFile)); !strings.Contains(log, `"status": "succeeded"`) {
		t.Fatalf("runner.log does not have the runner's output:\n%s", log)
	}
}

// (b) contract resume はフラグ無しで常に切り離して再開し、すぐ戻る。返す JSON は再開の直後の状態（running で
// requested_action が無いか、waiting であるか）。呼び出し元のプロセスグループを止めても run は最後まで進む。
func TestContractResumeReturnsAtOnceAndOutlivesTheCallerGroup(t *testing.T) {
	h := newHarness(t, "HARNESS_STATE_DIR="+t.TempDir())
	id, pidfile := gatedSleeper(t, h, "parent")

	dir := t.TempDir()
	began := time.Now()
	c := h.inOwnGroup(dir, "contract", "resume", id, "--input", "go")
	code := strings.TrimSpace(waitFile(t, filepath.Join(dir, "out.code")))
	took := time.Since(began)
	out, _ := os.ReadFile(filepath.Join(dir, "out"))
	if code != "0" || took > 20*time.Second {
		t.Fatalf("contract resume exit %s (took %s)\n%s", code, took, out)
	}
	d := decode[contractDoc](t, string(out))
	if runIDOf(t, d) != id || d.CostUSD == nil {
		t.Fatalf("contract resume = %+v", d)
	}
	checkJustStarted(t, d.State, d.RequestedAction != nil)
	_, child := sleeperPIDs(t, pidfile)
	stopGroup(t, c)

	if cd, _ := h.contractNow("status", id); cd.State != runstate.StatusRunning || strings.Contains(cd.Summary, "is not alive") {
		t.Fatalf("contract status after the caller's group was stopped = %+v", cd)
	}
	_ = syscall.Kill(child, syscall.SIGTERM)
	if s := h.settle(id); s.State != runstate.StatusSucceeded || s.RequestedAction != nil {
		t.Fatalf("contract status at the end = %+v", s)
	}
	if v := h.statusOf(id); !strings.Contains(runnerCommands(t, v.RunDir), "resume detached") {
		t.Fatalf("runner commands = %s", runnerCommands(t, v.RunDir))
	}
}

// (c) approve --detach も同じ: 端末で確認を取ってゲートを解き、その後の進行は切り離した runner に渡してすぐ戻る。
// approve は端末を要るので、このテストのプロセスの中で（端末があることにして）呼ぶ。呼び出し元（このテストの
// プロセス）とは別のセッションの runner が run を最後まで進める。
func TestDetachedApproveHandsTheRunToARunner(t *testing.T) {
	state := t.TempDir()
	h := newHarness(t, "HARNESS_STATE_DIR="+state)
	id, pidfile := gatedSleeper(t, h, "human")
	// runner はこのプロセスの実行ファイル（テストバイナリ）を起動し直すので、harness として動く印を環境に置く。
	t.Setenv("HARNESS_CLI_TEST_MAIN", "1")

	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	w.WriteString("yes\n")
	w.Close()
	var stdout, stderr bytes.Buffer
	envs := map[string]string{"HARNESS_STATE_DIR": state, "HOME": t.TempDir(), "PATH": os.Getenv("PATH"), "USER": "tester"}
	began := time.Now()
	code := Main([]string{"approve", "--detach", id, "--input", "go"}, Env{
		Stdin: r, Stdout: &stdout, Stderr: &stderr,
		Getenv:     func(k string) string { return envs[k] },
		Getwd:      func() (string, error) { return h.cwd, nil },
		IsTerminal: func(*os.File) bool { return true },
	})
	if code != ExitOK || time.Since(began) > 20*time.Second {
		t.Fatalf("approve --detach exit %d (took %s)\n%s\n%s", code, time.Since(began), stdout.String(), stderr.String())
	}
	checkJustResumed(t, decode[statusView](t, stdout.String()))
	_, child := sleeperPIDs(t, pidfile)

	v := h.statusOf(id)
	if v.Status != runstate.StatusRunning || v.PID == os.Getpid() || v.RunnerAlive == nil || !*v.RunnerAlive {
		t.Fatalf("after approve returned: status %s pid %d (this process %d) runner_alive %v", v.Status, v.PID, os.Getpid(), v.RunnerAlive)
	}
	if sid, err := getsid(v.PID); err != nil || sid != v.PID {
		t.Fatalf("the runner (pid %d) does not lead its own session: sid %d %v", v.PID, sid, err)
	}
	_ = syscall.Kill(child, syscall.SIGTERM)
	v = h.waitStatus(id, runstate.StatusSucceeded)
	res := v.Units[0].Gates[0].Resolution
	if res == nil || res.Actor != "approve" || res.Channel != "tty" || res.User != "tester" || res.Outcome != "go" {
		t.Fatalf("resolution = %+v", res)
	}
	if !strings.Contains(runnerCommands(t, v.RunDir), "approve detached") {
		t.Fatalf("runner commands = %s", runnerCommands(t, v.RunDir))
	}
	if cd, _ := h.contractNow("status", id); cd.State != runstate.StatusSucceeded {
		t.Fatalf("contract status at the end = %+v", cd)
	}
}

// (d) 解いたゲートの遷移先が終端なら、進めるものが無いので runner を起動せず、終わった状態をそのまま返す。
// 入力の誤りは、切り離す前にこのプロセスで拒否し、何も記録しない。
func TestDetachedResumeRefusesAndEndsInPlace(t *testing.T) {
	h := newHarness(t, "HARNESS_STATE_DIR="+t.TempDir())
	id, _ := gatedSleeper(t, h, "parent")
	dir := h.statusOf(id).RunDir
	before := eventTypes(t, dir)

	out, errOut, code := h.run("resume", "--detach", id, "--input", "nope")
	if code != ExitFailed || !strings.Contains(errOut, `does not accept "nope"`) || decode[statusView](t, out).Status != runstate.StatusWaiting {
		t.Fatalf("resume --detach with a wrong input: exit %d\n%s\n%s", code, out, errOut)
	}
	if after := eventTypes(t, dir); after != before {
		t.Fatalf("a refused resume recorded events:\n%s\n%s", before, after)
	}

	out, errOut, code = h.run("resume", "--detach", id, "--input", "stop")
	if code != ExitFailed || decode[statusView](t, out).Status != runstate.StatusFailed {
		t.Fatalf("resume --detach to an end: exit %d\n%s\n%s", code, out, errOut)
	}
	if _, err := os.Stat(filepath.Join(dir, runstate.RunnerLogFile)); !os.IsNotExist(err) {
		t.Fatalf("a resume that ended the run started a runner (%s: %v)", runstate.RunnerLogFile, err)
	}
	if strings.Contains(runnerCommands(t, dir), "detached") {
		t.Fatalf("runner commands = %s", runnerCommands(t, dir))
	}
	// 終わった run は、切り離した再開でも already ended として拒否する（既存の規則のまま）。
	_, errOut, code = h.run("resume", "--detach", id)
	if code != ExitFailed || !strings.Contains(errOut, "already ended as failed") {
		t.Fatalf("resume --detach of an ended run: exit %d\n%s", code, errOut)
	}
}

// (e) --detach を付けない resume は従来どおり同期: run の終わり（ここでは sleeper の終わり）まで戻らず、進めたのは
// 呼び出したプロセス自身で、切り離した runner は起動しない（runner.log を書かない）。
func TestResumeWithoutDetachIsSynchronous(t *testing.T) {
	h := newHarness(t, "HARNESS_STATE_DIR="+t.TempDir())
	id, pidfile := gatedSleeper(t, h, "parent")
	done := make(chan struct{})
	var out, errOut string
	var code int
	go func() {
		defer close(done)
		out, errOut, code = h.run("resume", id, "--input", "go")
	}()
	_, child := sleeperPIDs(t, pidfile)
	select {
	case <-done:
		t.Fatalf("resume returned while the step still runs: exit %d\n%s\n%s", code, out, errOut)
	case <-time.After(300 * time.Millisecond):
	}
	_ = syscall.Kill(child, syscall.SIGTERM)
	<-done
	if code != ExitOK {
		t.Fatalf("resume exit %d\n%s\n%s", code, out, errOut)
	}
	v := decode[statusView](t, out)
	if v.Status != runstate.StatusSucceeded {
		t.Fatalf("status = %s", v.Status)
	}
	if cmds := runnerCommands(t, v.RunDir); cmds != "resume" {
		t.Fatalf("runner commands = %q, want only the synchronous resume", cmds)
	}
	if _, err := os.Stat(filepath.Join(v.RunDir, runstate.RunnerLogFile)); !os.IsNotExist(err) {
		t.Fatalf("a synchronous resume wrote %s (%v)", runstate.RunnerLogFile, err)
	}
}

// (f) --detach を付けない approve も同期のまま: run の終わりまで進めてから終わった状態を返し、runner を起動しない。
func TestApproveWithoutDetachIsSynchronous(t *testing.T) {
	state := t.TempDir()
	h := newHarness(t, "HARNESS_STATE_DIR="+state)
	id, pidfile := gatedSleeper(t, h, "human")
	// approve はこのゴルーチンで run の終わりまで戻らないので、別のゴルーチンで孫の sleep を止める（t は使わない）。
	go func() {
		deadline := time.Now().Add(30 * time.Second)
		for time.Now().Before(deadline) {
			if b, err := os.ReadFile(pidfile); err == nil {
				if f := strings.Fields(string(b)); len(f) == 2 {
					if child, err := strconv.Atoi(f[1]); err == nil {
						_ = syscall.Kill(child, syscall.SIGTERM)
						return
					}
				}
			}
			time.Sleep(20 * time.Millisecond)
		}
	}()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	w.WriteString("yes\n")
	w.Close()
	var stdout, stderr bytes.Buffer
	envs := map[string]string{"HARNESS_STATE_DIR": state, "USER": "tester"}
	code := Main([]string{"approve", id, "--input", "go"}, Env{
		Stdin: r, Stdout: &stdout, Stderr: &stderr,
		Getenv:     func(k string) string { return envs[k] },
		Getwd:      os.Getwd,
		IsTerminal: func(*os.File) bool { return true },
	})
	if code != ExitOK {
		t.Fatalf("approve exit %d\n%s\n%s", code, stdout.String(), stderr.String())
	}
	v := decode[statusView](t, stdout.String())
	if v.Status != runstate.StatusSucceeded || v.PID != os.Getpid() {
		t.Fatalf("status %s pid %d (this process %d)", v.Status, v.PID, os.Getpid())
	}
	if cmds := runnerCommands(t, v.RunDir); cmds != "approve" {
		t.Fatalf("runner commands = %q, want only the synchronous approve", cmds)
	}
	if _, err := os.Stat(filepath.Join(v.RunDir, runstate.RunnerLogFile)); !os.IsNotExist(err) {
		t.Fatalf("a synchronous approve wrote %s (%v)", runstate.RunnerLogFile, err)
	}
}

// runnerCommands は runner_started の command を記録の順に空白で並べる（誰が run を進めたか）。
func runnerCommands(t *testing.T, dir string) string {
	t.Helper()
	evs, _, err := runstate.ReadEvents(filepath.Join(dir, runstate.EventsFile))
	if err != nil {
		t.Fatal(err)
	}
	var cmds []string
	for _, ev := range evs {
		if ev.RunnerStarted != nil {
			cmds = append(cmds, ev.RunnerStarted.Command)
		}
	}
	return strings.Join(cmds, " ")
}

package engine

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
	"github.com/masanami/claude-harness/runtime/internal/workflow"
)

// maxStdout は command の stdout として読む上限（出力規約は JSON 1 個。これを超えるものは不正な出力として扱う）。
const maxStdout = 32 << 20

// execute は command 種類（§3.2）を 1 回実行する: plugin/scripts/<run>.sh を argv で起動し、
// stdout の JSON を output のスキーマで検証して outcome を得る。子プロセスは自分のプロセスグループで起動し、
// timeout・cancel ではグループごと止める（スクリプトが起動した孫プロセスを残さない）。
func (e *Engine) execute(ctx context.Context, st *runstate.State, u *runstate.Unit, step *workflow.Step) result {
	attempt := u.Attempts(step.ID) + 1
	res := e.executeAttempt(ctx, st, u, step, attempt)
	res.attempt = attempt
	return res
}

func (e *Engine) executeAttempt(ctx context.Context, st *runstate.State, u *runstate.Unit, step *workflow.Step, attempt int) result {
	started := &runstate.StepStarted{Unit: u.Key, Step: step.ID, Attempt: attempt}
	fail := func(outcome, msg string, code *int) result {
		return result{outcome: outcome, reserved: true, errText: msg, exitCode: code}
	}
	record := func() error {
		_, err := e.Run.Append(runstate.Event{Type: runstate.EvStepStarted, StepStarted: started})
		return err
	}

	args, err := argv(st, u, step)
	if err != nil {
		if rerr := record(); rerr != nil {
			return result{err: rerr}
		}
		return fail("step_error", "cannot build arguments: "+err.Error(), nil)
	}
	base := fmt.Sprintf("%s.%d", step.ID, attempt)
	started.StdoutLog = filepath.Join(runstate.LogsDir, base+".stdout")
	started.StderrLog = filepath.Join(runstate.LogsDir, base+".stderr")
	stdout, err := os.Create(filepath.Join(e.Run.Dir, started.StdoutLog))
	if err != nil {
		return result{err: err}
	}
	defer stdout.Close()
	stderr, err := os.Create(filepath.Join(e.Run.Dir, started.StderrLog))
	if err != nil {
		return result{err: err}
	}
	defer stderr.Close()

	script := filepath.Join(e.ScriptsDir, step.Run+".sh")
	cmd := exec.Command("bash", append([]string{script}, args...)...)
	cmd.Dir = e.Cwd
	cmd.Stdout, cmd.Stderr = stdout, stderr
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	started.Argv = cmd.Args
	if err := cmd.Start(); err != nil {
		if rerr := record(); rerr != nil {
			return result{err: rerr}
		}
		return fail("step_error", "cannot start: "+err.Error(), nil)
	}
	started.PID = cmd.Process.Pid
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	if err := record(); err != nil {
		e.stop(cmd.Process.Pid, done)
		return result{err: err}
	}

	var timeout <-chan time.Time
	if step.Timeout > 0 {
		t := time.NewTimer(step.Timeout)
		defer t.Stop()
		timeout = t.C
	}
	tick := time.NewTicker(e.poll())
	defer tick.Stop()
	var waitErr error
wait:
	for {
		select {
		case waitErr = <-done:
			break wait
		case <-timeout:
			e.stop(cmd.Process.Pid, done)
			return fail("step_timeout", fmt.Sprintf("exceeded timeout %s", step.Timeout), nil)
		case <-tick.C:
			if e.cancelRequested(ctx) {
				e.stop(cmd.Process.Pid, done)
				return result{cancelled: true}
			}
		case <-ctx.Done():
			e.stop(cmd.Process.Pid, done)
			return result{cancelled: true}
		}
	}

	// 正常に終わった後もグループに残る孫プロセス（スクリプトが背後で起動したもの）を止める。
	// 読み終えた stdout のログへ後から書き込ませず、runtime の外で動き続けるものを残さない。
	_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	code := cmd.ProcessState.ExitCode()
	var exitErr *exec.ExitError
	if waitErr != nil && !errors.As(waitErr, &exitErr) {
		return fail("step_error", "wait: "+waitErr.Error(), nil)
	}
	if code < 0 {
		return fail("step_error", "terminated by a signal"+tail(e.Run.Dir, started.StderrLog), nil)
	}
	out, err := readCapped(filepath.Join(e.Run.Dir, started.StdoutLog))
	if err != nil {
		return fail("invalid_output", err.Error(), &code)
	}
	if len(step.Exit) > 0 {
		outcome := ""
		for _, x := range step.Exit {
			if x.Code == code {
				outcome = x.Outcome
			}
		}
		if outcome == "" {
			return fail("step_error", fmt.Sprintf("exit code %d is not in the exit table", code)+tail(e.Run.Dir, started.StderrLog), &code)
		}
		if step.OutputSchema == nil {
			return result{outcome: outcome, exitCode: &code}
		}
		output, _, err := validateOutput(step, out)
		if err != nil {
			return fail("invalid_output", err.Error(), &code)
		}
		return result{outcome: outcome, output: output, exitCode: &code}
	}
	if code != 0 {
		return fail("step_error", fmt.Sprintf("exit code %d", code)+tail(e.Run.Dir, started.StderrLog), &code)
	}
	output, outcome, err := validateOutput(step, out)
	if err != nil {
		return fail("invalid_output", err.Error(), &code)
	}
	return result{outcome: outcome, output: output, exitCode: &code}
}

// stop はプロセスグループへ SIGTERM を送り、猶予内に終わらなければ SIGKILL を送る。
// リーダーが終わった後もグループに残る孫プロセスへ、最後に SIGKILL を送る。
func (e *Engine) stop(pgid int, done <-chan error) {
	_ = syscall.Kill(-pgid, syscall.SIGTERM)
	select {
	case <-done:
	case <-time.After(e.grace()):
		_ = syscall.Kill(-pgid, syscall.SIGKILL)
		<-done
	}
	_ = syscall.Kill(-pgid, syscall.SIGKILL)
}

func readCapped(path string) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, maxStdout+1))
	if err != nil {
		return nil, err
	}
	if len(data) > maxStdout {
		return nil, fmt.Errorf("stdout exceeds %d bytes", maxStdout)
	}
	return data, nil
}

// tail は stderr の末尾を報告に添える（失敗の理由を run ディレクトリを開かずに読めるように）。
func tail(dir, rel string) string {
	data, err := os.ReadFile(filepath.Join(dir, rel))
	if err != nil || len(data) == 0 {
		return ""
	}
	const n = 400
	if len(data) > n {
		data = data[len(data)-n:]
	}
	return "; stderr: " + string(data)
}

// StopOrphan は runner が居ないときに cancel が子プロセスを止めるために使う（runner が落ちた run の停止）。
// リーダーが終わっていてもグループに残るプロセスを止めるため、生存確認もグループ宛て（-pgid）で行う。
func StopOrphan(pgid int, grace time.Duration) {
	if pgid <= 0 || !groupAlive(pgid) {
		return
	}
	_ = syscall.Kill(-pgid, syscall.SIGTERM)
	deadline := time.Now().Add(grace)
	for time.Now().Before(deadline) && groupAlive(pgid) {
		time.Sleep(50 * time.Millisecond)
	}
	_ = syscall.Kill(-pgid, syscall.SIGKILL)
}

func groupAlive(pgid int) bool {
	err := syscall.Kill(-pgid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}

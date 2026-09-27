package engine

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/masanami/claude-harness/runtime/internal/runstate"
	"github.com/masanami/claude-harness/runtime/internal/workflow"
)

// toolTimeout は Go の種類（workspace・pull-request）が起動する 1 つの外部コマンド（git・gh・worktree スクリプト）の上限。
// これらの種類は YAML に timeout を持たない（外部コマンドの待ち方は種類が決める）。
const toolTimeout = 10 * time.Minute

func (e *Engine) gitBin() string {
	if e.GitBin != "" {
		return e.GitBin
	}
	return "git"
}

func (e *Engine) ghBin() string {
	if e.GhBin != "" {
		return e.GhBin
	}
	return "gh"
}

// dirFor は unit のステップが動くディレクトリ: acquire 済みでまだ release していない作業ツリーがあればそこ、無ければ run を
// 開始したディレクトリ（§4.1 Workspace。workspace で払い出した後の実装・PR・CI 確認は作業ツリーの中で行う）。
func (e *Engine) dirFor(u *runstate.Unit) string {
	if p := u.ActiveWorkspace(); p != "" {
		return p
	}
	return e.Cwd
}

// childEnv は子プロセスへ渡す環境。ワークフローに付属するスクリプトがプラグインのスクリプトを呼べるよう、
// その置き場を HARNESS_SCRIPTS_DIR で渡す。
func (e *Engine) childEnv() []string {
	return append(os.Environ(), "HARNESS_SCRIPTS_DIR="+e.ScriptsDir)
}

// withValues は with の値を解決する。省略された任意の入力は渡さない（キーごと無い）。
func withValues(st *runstate.State, u *runstate.Unit, step *workflow.Step) (map[string]json.RawMessage, error) {
	out := map[string]json.RawMessage{}
	for _, b := range step.With {
		if r := b.Value.Ref; r != nil && r.Kind == workflow.RefInputs {
			if _, given := st.Inputs[r.Name]; !given {
				continue
			}
		}
		v, err := value(st, succeeded(u), u.Edge, b.Value)
		if err != nil {
			return nil, err
		}
		out[b.Name] = v
	}
	return out, nil
}

// stepTools は Go の種類が 1 回の実行の中で起動する外部コマンドを、ログへ残しながら順に走らせる。
// ステップ実行の開始（step_started）は最初に 1 回だけ記録する。複数のコマンドを起動するので PID は記録しない
// （runner が落ちた場合は、次の status / resume がそのステップを interrupted にする。§4.5）。
type stepTools struct {
	e       *Engine
	ctx     context.Context
	stdout  *os.File
	stderr  *os.File
	started *runstate.StepStarted
}

// beginTools は step_started を記録し、ログを開く。
func (e *Engine) beginTools(ctx context.Context, u *runstate.Unit, step *workflow.Step, attempt int) (*stepTools, error) {
	base := fmt.Sprintf("%s.%d", step.ID, attempt)
	started := &runstate.StepStarted{Unit: u.Key, Step: step.ID, Attempt: attempt,
		StdoutLog: filepath.Join(runstate.LogsDir, base+".stdout"), StderrLog: filepath.Join(runstate.LogsDir, base+".stderr")}
	stdout, err := os.Create(filepath.Join(e.Run.Dir, started.StdoutLog))
	if err != nil {
		return nil, err
	}
	stderr, err := os.Create(filepath.Join(e.Run.Dir, started.StderrLog))
	if err != nil {
		stdout.Close()
		return nil, err
	}
	if _, err := e.Run.Append(runstate.Event{Type: runstate.EvStepStarted, StepStarted: started}); err != nil {
		stdout.Close()
		stderr.Close()
		return nil, err
	}
	return &stepTools{e: e, ctx: ctx, stdout: stdout, stderr: stderr, started: started}, nil
}

func (t *stepTools) close() {
	t.stdout.Close()
	t.stderr.Close()
}

// toolResult は外部コマンド 1 回の結果。
type toolResult struct {
	stdout   []byte
	stderr   string
	code     int
	how      waitOutcome
	startErr error
}

// ok は正常に起動して 0 で終わったか。
func (r toolResult) ok() bool { return r.startErr == nil && r.how == exited && r.code == 0 }

// describe は失敗の説明（報告用）。
func (r toolResult) describe(argv []string) string {
	name := strings.Join(argv, " ")
	switch {
	case r.startErr != nil:
		return fmt.Sprintf("%s: cannot start: %v", name, r.startErr)
	case r.how == timedOut:
		return fmt.Sprintf("%s: exceeded %s", name, toolTimeout)
	case r.code < 0:
		return fmt.Sprintf("%s: terminated by a signal", name)
	}
	msg := strings.TrimSpace(r.stderr)
	if len(msg) > 400 {
		msg = msg[len(msg)-400:]
	}
	return fmt.Sprintf("%s: exit code %d: %s", name, r.code, msg)
}

// run は外部コマンドを dir で起動して待つ（自分のプロセスグループで起動し、timeout・cancel ではグループごと止める）。
// stdout と stderr はステップのログへも追記する。
func (t *stepTools) run(dir string, argv ...string) toolResult {
	fmt.Fprintf(t.stderr, "$ (cd %s && %s)\n", dir, strings.Join(argv, " "))
	var out, errb bytes.Buffer
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Dir = dir
	cmd.Env = t.e.childEnv()
	cmd.Stdout = io.MultiWriter(&out, t.stdout)
	cmd.Stderr = io.MultiWriter(&errb, t.stderr)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		fmt.Fprintf(t.stderr, "cannot start: %v\n", err)
		return toolResult{startErr: err, code: -1}
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	how, waitErr := t.e.wait(t.ctx, cmd.Process.Pid, done, toolTimeout)
	if how != exited {
		return toolResult{how: how, code: -1, stderr: errb.String()}
	}
	_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	var exitErr *exec.ExitError
	if waitErr != nil && !errors.As(waitErr, &exitErr) {
		return toolResult{startErr: waitErr, code: -1, stderr: errb.String()}
	}
	return toolResult{stdout: out.Bytes(), stderr: errb.String(), code: cmd.ProcessState.ExitCode()}
}

// toolFailure は外部コマンドの失敗をステップの結果にする（cancel は cancelled、それ以外は step_error）。
func toolFailure(r toolResult, argv []string) result {
	if r.how == cancelledByRequest {
		return result{cancelled: true}
	}
	if r.how == timedOut {
		return result{outcome: "step_timeout", reserved: true, errText: r.describe(argv)}
	}
	return result{outcome: "step_error", reserved: true, errText: r.describe(argv)}
}

func stepError(format string, args ...any) result {
	return result{outcome: "step_error", reserved: true, errText: fmt.Sprintf(format, args...)}
}

// builtinOutput は Go が作った出力を種類の出力スキーマで検証して結果にする（Go の不具合で形の崩れた出力を先へ流さない）。
func builtinOutput(step *workflow.Step, out any) result {
	data, err := json.Marshal(out)
	if err != nil {
		return stepError("cannot encode the output: %v", err)
	}
	output, outcome, err := validateOutput(step, data)
	if err != nil {
		return result{outcome: "invalid_output", reserved: true, errText: err.Error()}
	}
	return result{outcome: outcome, output: output}
}

func jsonString(raw json.RawMessage) (string, bool) {
	var s string
	if raw == nil || json.Unmarshal(raw, &s) != nil {
		return "", false
	}
	return s, true
}

func jsonInt(raw json.RawMessage) (int64, bool) {
	var n int64
	if raw == nil || json.Unmarshal(raw, &n) != nil {
		return 0, false
	}
	return n, true
}

// samePath は 2 つのパスが同じ実体を指すか（macOS の /var → /private/var 等の symlink を解決して比べる）。
func samePath(a, b string) bool {
	ra, err1 := filepath.EvalSymlinks(a)
	rb, err2 := filepath.EvalSymlinks(b)
	if err1 != nil || err2 != nil {
		return filepath.Clean(a) == filepath.Clean(b)
	}
	return ra == rb
}
